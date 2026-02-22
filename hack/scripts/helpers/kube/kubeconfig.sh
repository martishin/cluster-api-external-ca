#!/usr/bin/env bash

write_kubeconfig_from_secret() {
  local namespace="$1"
  local cluster_name="$2"
  local out_file="$3"
  local attempts="${4:-60}"
  local sleep_seconds="${5:-5}"
  local i

  mkdir -p "$(dirname "$out_file")"
  for ((i=1; i<=attempts; i++)); do
    if kubectl -n "$namespace" get secret "${cluster_name}-kubeconfig" >/dev/null 2>&1; then
      if kubectl -n "$namespace" get secret "${cluster_name}-kubeconfig" -o jsonpath='{.data.value}' | base64 -d > "$out_file"; then
        if [[ -s "$out_file" ]]; then
          rewrite_capd_kubeconfig_endpoint "$cluster_name" "$out_file"
          return 0
        fi
      fi
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

rewrite_capd_kubeconfig_endpoint() {
  local cluster_name="$1"
  local kubeconfig="$2"
  local lb_name="${cluster_name}-lb"
  local lb_port cluster_id tls_server_name

  lb_port="$(docker inspect -f '{{(index (index .NetworkSettings.Ports "6443/tcp") 0).HostPort}}' "$lb_name" 2>/dev/null || true)"
  if [[ -z "$lb_port" ]]; then
    return 0
  fi

  cluster_id="$(kubectl config view --kubeconfig "$kubeconfig" -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
  if [[ -z "$cluster_id" ]]; then
    return 0
  fi

  # CAPD load balancer forwards to different control-plane nodes; "kubernetes"
  # is the stable SAN present across kubeadm apiserver certs.
  tls_server_name="${KUBECONFIG_TLS_SERVER_NAME:-kubernetes}"

  kubectl config set-cluster "$cluster_id" \
    --kubeconfig "$kubeconfig" \
    --server="https://127.0.0.1:${lb_port}" \
    --tls-server-name="$tls_server_name" \
    --insecure-skip-tls-verify=false >/dev/null

  log "rewrote CAPD kubeconfig endpoint for ${cluster_name}: https://127.0.0.1:${lb_port} (tls-server-name=${tls_server_name})"
}

api_endpoint_from_kubeconfig() {
  local kubeconfig="$1"
  local current_context cluster_name endpoint

  current_context="$(kubectl config current-context --kubeconfig "$kubeconfig" 2>/dev/null || true)"
  if [[ -n "$current_context" ]]; then
    cluster_name="$(kubectl config view --kubeconfig "$kubeconfig" -o jsonpath="{.contexts[?(@.name==\"${current_context}\")].context.cluster}" 2>/dev/null || true)"
  fi
  if [[ -z "${cluster_name:-}" ]]; then
    cluster_name="$(kubectl config view --kubeconfig "$kubeconfig" -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
  fi
  if [[ -z "${cluster_name:-}" ]]; then
    return 1
  fi

  endpoint="$(kubectl config view --kubeconfig "$kubeconfig" -o jsonpath="{.clusters[?(@.name==\"${cluster_name}\")].cluster.server}" 2>/dev/null || true)"
  if [[ -z "${endpoint:-}" ]]; then
    endpoint="$(kubectl config view --kubeconfig "$kubeconfig" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  fi
  [[ -n "${endpoint:-}" ]] || return 1
  echo "$endpoint"
}

host_from_url() {
  local url="$1"
  local authority host

  authority="${url#*://}"
  authority="${authority%%/*}"
  if [[ "$authority" =~ ^\[(.*)\](:[0-9]+)?$ ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$authority" =~ ^([^:]+):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  else
    host="$authority"
  fi
  echo "$host"
}

port_from_url() {
  local url="$1"
  local authority

  authority="${url#*://}"
  authority="${authority%%/*}"
  if [[ "$authority" =~ ^\[[^]]+\]:([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$authority" =~ ^[^:]+:([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "443"
}
