#!/usr/bin/env bash

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
  local max_iterations="${7:-135}"

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

wait_workload_nodes_ready() {
  local kubeconfig="$1"
  local expected_nodes="$2"
  local max_iterations="${3:-90}"
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
