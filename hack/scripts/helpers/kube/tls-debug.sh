#!/usr/bin/env bash

control_plane_node_from_kubeconfig() {
  local kubeconfig="$1"
  local attempts="${2:-60}"
  local sleep_seconds="${3:-10}"
  local node i

  for ((i=1; i<=attempts; i++)); do
    node="$(kubectl --kubeconfig "$kubeconfig" get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$node" ]]; then
      echo "$node"
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

node_file_exists_via_kubectl_debug() {
  local kubeconfig="$1"
  local node="$2"
  local file_path="$3"
  local namespace="${4:-default}"
  local debug_image="${5:-busybox:1.36}"

  if command -v docker >/dev/null 2>&1 && docker inspect "$node" >/dev/null 2>&1; then
    docker exec "$node" sh -ceu "test -f '$file_path'" >/dev/null 2>&1
    return $?
  fi

  kubectl --kubeconfig "$kubeconfig" -n "$namespace" \
    debug "node/$node" --image="$debug_image" --quiet -- \
    chroot /host test -f "$file_path" >/dev/null 2>&1
}

node_file_sha256_via_kubectl_debug() {
  local kubeconfig="$1"
  local node="$2"
  local file_path="$3"
  local namespace="${4:-default}"
  local debug_image="${5:-busybox:1.36}"

  if command -v docker >/dev/null 2>&1 && docker inspect "$node" >/dev/null 2>&1; then
    docker exec "$node" sh -ceu "sha256sum '$file_path' | awk '{print \$1}'" 2>/dev/null || true
    return 0
  fi

  kubectl --kubeconfig "$kubeconfig" -n "$namespace" \
    debug "node/$node" --image="$debug_image" --quiet -- \
    chroot /host sh -ceu "sha256sum '$file_path' | awk '{print \\\$1}'" 2>/dev/null || true
}

node_exec_via_kubectl_debug() {
  local kubeconfig="$1"
  local node="$2"
  local shell_cmd="$3"
  local namespace="${4:-default}"
  local debug_image="${5:-busybox:1.36}"

  if command -v docker >/dev/null 2>&1 && docker inspect "$node" >/dev/null 2>&1; then
    docker exec "$node" sh -ceu "$shell_cmd"
    return $?
  fi

  kubectl --kubeconfig "$kubeconfig" -n "$namespace" \
    debug "node/$node" --image="$debug_image" --quiet -- \
    chroot /host sh -ceu "$shell_cmd"
}

issuer_from_apiserver() {
  local kubeconfig="$1"
  local endpoint host port
  endpoint="$(api_endpoint_from_kubeconfig "$kubeconfig")"
  host="$(host_from_url "$endpoint")"
  port="$(port_from_url "$endpoint")"
  echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null | \
    openssl x509 -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//'
}

dump_apiserver_chain_from_kubeconfig() {
  local kubeconfig="$1"
  local out_file="$2"
  local endpoint host port
  endpoint="$(api_endpoint_from_kubeconfig "$kubeconfig")"
  host="$(host_from_url "$endpoint")"
  port="$(port_from_url "$endpoint")"
  mkdir -p "$(dirname "$out_file")"
  openssl s_client -showcerts -connect "${host}:${port}" </dev/null > "$out_file" 2>&1 || true
}
