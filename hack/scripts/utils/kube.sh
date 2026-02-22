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
  local lb_port cluster_id

  lb_port="$(docker inspect -f '{{(index (index .NetworkSettings.Ports "6443/tcp") 0).HostPort}}' "$lb_name" 2>/dev/null || true)"
  if [[ -z "$lb_port" ]]; then
    return 0
  fi

  cluster_id="$(kubectl config view --kubeconfig "$kubeconfig" -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)"
  if [[ -z "$cluster_id" ]]; then
    return 0
  fi

  kubectl config set-cluster "$cluster_id" \
    --kubeconfig "$kubeconfig" \
    --server="https://127.0.0.1:${lb_port}" \
    --insecure-skip-tls-verify=true >/dev/null

  log "rewrote CAPD kubeconfig endpoint for ${cluster_name}: https://127.0.0.1:${lb_port}"
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

wait_cluster_ready() {
  local cluster_name="$1"
  local timeout="${2:-20m}"

  log "waiting for cluster/${cluster_name} infrastructure and control-plane readiness"
  kubectl wait --for=condition=ControlPlaneReady "cluster/${cluster_name}" --timeout="$timeout"
  kubectl wait --for=condition=InfrastructureReady "cluster/${cluster_name}" --timeout="$timeout"

  if command -v clusterctl >/dev/null 2>&1; then
    clusterctl describe cluster "$cluster_name" --namespace default --show-conditions all
  fi
}

wait_for_kcp_object() {
  local namespace="$1"
  local kcp_name="$2"
  local attempts="${3:-60}"
  local sleep_seconds="${4:-5}"

  local i
  for ((i=1; i<=attempts; i++)); do
    if kubectl -n "$namespace" get "kubeadmcontrolplane.controlplane.cluster.x-k8s.io/${kcp_name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

wait_ha_replicas() {
  local namespace="$1"
  local cluster_name="$2"
  local kcp_name="$3"
  local md_name="$4"
  local target_cp="$5"
  local target_md="$6"
  local max_iterations="${7:-135}" # 45 minutes with 20s sleep

  local i cp_running worker_running kcp_ready md_available
  for ((i=1; i<=max_iterations; i++)); do
    cp_running="$(
      kubectl -n "$namespace" get machines \
        -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/control-plane" \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | \
        grep -c '^Running$' || true
    )"
    worker_running="$(
      kubectl -n "$namespace" get machines \
        -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/deployment-name=${md_name}" \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | \
        grep -c '^Running$' || true
    )"
    kcp_ready="$(kubectl -n "$namespace" get "kubeadmcontrolplane/${kcp_name}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    md_available="$(kubectl -n "$namespace" get "machinedeployment/${md_name}" -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null || true)"

    cp_running="${cp_running:-0}"
    worker_running="${worker_running:-0}"

    if [[ "$cp_running" == "$target_cp" && "$worker_running" == "$target_md" && "$kcp_ready" == "True" && "$md_available" == "True" ]]; then
      log "target reached: control-plane running=${cp_running}/${target_cp}, workers running=${worker_running}/${target_md}, kcp Ready=True, md Available=True"
      return 0
    fi

    if (( i % 6 == 0 )); then
      log "waiting for HA replicas: control-plane running=${cp_running}/${target_cp}, workers running=${worker_running}/${target_md}, kcp Ready=${kcp_ready:-Unknown}, md Available=${md_available:-Unknown} (poll ${i}/${max_iterations})"
    fi
    sleep 20
  done

  echo "timed out waiting for HA replicas: control-plane=${target_cp}, workers=${target_md}" >&2
  return 1
}

install_workload_cni() {
  local kubeconfig="$1"
  local timeout="${2:-20m}"
  local cilium_chart_version="1.16.7"
  local cilium_operator_replicas="${CILIUM_OPERATOR_REPLICAS:-1}"
  local i

  log "installing workload CNI: cilium (chart v${cilium_chart_version}, operator replicas=${cilium_operator_replicas})"
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  for ((i=1; i<=6; i++)); do
    if helm --kubeconfig "$kubeconfig" upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      --version "$cilium_chart_version" \
      --set ipam.mode=kubernetes \
      --set kubeProxyReplacement=false \
      --set operator.replicas="$cilium_operator_replicas" \
      --wait --timeout "$timeout"; then
      break
    fi
    if [[ "$i" -eq 6 ]]; then
      echo "FAIL: unable to install cilium after retries" >&2
      return 1
    fi
    log "cilium install failed (attempt ${i}/6), retrying in 10s"
    sleep 10
  done
  kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status daemonset/cilium --timeout="$timeout"
  kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status deployment/cilium-operator --timeout="$timeout"
}

wait_workload_api_authenticated() {
  local kubeconfig="$1"
  local attempts="${2:-60}"
  local sleep_seconds="${3:-5}"
  local i

  for ((i=1; i<=attempts; i++)); do
    if kubectl --kubeconfig "$kubeconfig" get --raw='/readyz' >/dev/null 2>&1 && \
       kubectl --kubeconfig "$kubeconfig" auth can-i --quiet get pods -A >/dev/null 2>&1 && \
       kubectl --kubeconfig "$kubeconfig" get namespaces >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

assert_cilium_healthy() {
  local kubeconfig="$1"
  local results_file="${2:-}"
  local ds_ready ds_desired op_available ds_state

  ds_state="$(
    kubectl --kubeconfig "$kubeconfig" -n kube-system get daemonset cilium \
      -o jsonpath='{.status.numberReady} {.status.desiredNumberScheduled}' 2>/dev/null || true
  )"
  if [[ -z "${ds_state// }" ]]; then
    echo "FAIL: unable to read cilium daemonset status" >&2
    return 1
  fi
  read -r ds_ready ds_desired <<<"$ds_state"
  op_available="$(
    kubectl --kubeconfig "$kubeconfig" -n kube-system get deployment cilium-operator \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true
  )"
  op_available="${op_available:-0}"

  if [[ "${ds_desired:-0}" -eq 0 || "${ds_ready:-0}" -ne "${ds_desired:-0}" ]]; then
    echo "FAIL: cilium daemonset not healthy (ready=${ds_ready:-0} desired=${ds_desired:-0})" >&2
    return 1
  fi
  if [[ "${op_available:-0}" -lt 1 ]]; then
    echo "FAIL: cilium-operator has no available replicas" >&2
    return 1
  fi

  if [[ -n "$results_file" ]]; then
    mkdir -p "$(dirname "$results_file")"
    kubectl --kubeconfig "$kubeconfig" -n kube-system get pods -l k8s-app=cilium -o wide > "$results_file"
  fi
  log "PASS: cilium is healthy (daemonset ${ds_ready}/${ds_desired}, operator available=${op_available})"
}

wait_cilium_healthy() {
  local kubeconfig="$1"
  local results_file="${2:-}"
  local attempts="${3:-30}"
  local sleep_seconds="${4:-10}"
  local i

  for ((i=1; i<=attempts; i++)); do
    if assert_cilium_healthy "$kubeconfig" "$results_file"; then
      return 0
    fi
    if [[ "$i" -eq "$attempts" ]]; then
      echo "FAIL: cilium did not become healthy within retry window" >&2
      return 1
    fi
    log "waiting for cilium health (attempt ${i}/${attempts}), retrying in ${sleep_seconds}s"
    sleep "$sleep_seconds"
  done
}

wait_workload_nodes_ready() {
  local kubeconfig="$1"
  local expected_nodes="$2"
  local max_iterations="${3:-90}" # 30 minutes with 20s sleep
  local i total ready

  for ((i=1; i<=max_iterations; i++)); do
    read -r total ready < <(
      kubectl --kubeconfig "$kubeconfig" get nodes \
        -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null | \
        awk '
          BEGIN {total=0; ready=0}
          NF {total++; if ($1 == "True") ready++}
          END {printf "%d %d\n", total, ready}
        '
    )

    total="${total:-0}"
    ready="${ready:-0}"

    if [[ "$total" == "$expected_nodes" && "$ready" == "$expected_nodes" ]]; then
      log "all workload nodes ready: ${ready}/${expected_nodes}"
      return 0
    fi

    if (( i % 6 == 0 )); then
      log "waiting for workload node readiness: ready=${ready}/${expected_nodes}, totalSeen=${total} (poll ${i}/${max_iterations})"
    fi
    sleep 20
  done

  echo "timed out waiting for workload nodes ready=${expected_nodes}" >&2
  return 1
}

wait_kube_api_ready() {
  local kubeconfig="$1"
  local attempts="${2:-60}"
  local sleep_seconds="${3:-10}"

  local i
  for ((i=1; i<=attempts; i++)); do
    if kubectl --kubeconfig "$kubeconfig" get --raw='/readyz' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

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

  # CAPD/kind local path: node names map to docker containers.
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
    chroot /host sh -ceu "sha256sum '$file_path' | awk '{print \\$1}'" 2>/dev/null || true
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
