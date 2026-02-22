#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/env.sh"
source "$SCRIPT_DIR/utils/kube.sh"
source "$SCRIPT_DIR/utils/flow.sh"

MODE="$(mode_from_args "${1:-}")"
cluster_name="$(cluster_name_for_mode "$MODE")"
kcp_name="$(kcp_name_for_mode "$MODE")"
worker_md_name="$(worker_md_for_mode "$MODE")"
manifest_path="$(manifest_for_mode "$MODE")"
namespace="${NAMESPACE:-default}"
kubeconfig_out="$(workload_kubeconfig_for_mode "$MODE")"
out_dir="$(workload_out_dir_for_mode "$MODE")"
initial_control_plane_replicas=1
target_control_plane_replicas=3
worker_replicas=3
target_self_signed_total_nodes=$((target_control_plane_replicas + worker_replicas))
initial_external_total_nodes=$((initial_control_plane_replicas + worker_replicas))

ensure_out_dirs
mkdir -p "$out_dir"

apply_manifest_with_retry() {
  local manifest="$1"
  local attempts="${2:-18}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if kubectl apply -f "$manifest"; then
      return 0
    fi
    if [[ "$i" -eq "$attempts" ]]; then
      return 1
    fi
    sleep 10
  done
  return 1
}

log "applying workload cluster manifest: $manifest_path"
if ! apply_manifest_with_retry "$manifest_path"; then
  echo "unable to apply cluster manifest after retries: $manifest_path" >&2
  exit 1
fi

if [[ "$MODE" == "external-ca" ]]; then
  log "forcing initial control-plane replicas=${initial_control_plane_replicas} for external-ca bootstrap"
  kubectl -n "$namespace" patch "kubeadmcontrolplane/${kcp_name}" --type merge -p "{\"spec\":{\"replicas\":${initial_control_plane_replicas}}}"
fi

wait_cluster_ready "$cluster_name" 30m

if ! write_kubeconfig_from_secret "$namespace" "$cluster_name" "$kubeconfig_out"; then
  echo "unable to write workload kubeconfig from secret ${cluster_name}-kubeconfig" >&2
  exit 1
fi

if ! wait_workload_api_authenticated "$kubeconfig_out" 90 5; then
  echo "workload API is not authenticated yet for kubeconfig: $kubeconfig_out" >&2
  exit 1
fi

install_workload_cni "$kubeconfig_out" 20m

if [[ "$MODE" == "self-signed" ]]; then
  log "scaling self-signed cluster to control-plane replicas=${target_control_plane_replicas} and worker replicas=${worker_replicas}"
  kubectl -n "$namespace" patch "kubeadmcontrolplane/${kcp_name}" --type merge -p "{\"spec\":{\"replicas\":${target_control_plane_replicas}}}"
  kubectl -n "$namespace" patch "machinedeployment/${worker_md_name}" --type merge -p "{\"spec\":{\"replicas\":${worker_replicas}}}"
  wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$target_control_plane_replicas" "$worker_replicas" 135
  wait_workload_nodes_ready "$kubeconfig_out" "$target_self_signed_total_nodes" 90
else
  wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$initial_control_plane_replicas" 0 135
  wait_workload_nodes_ready "$kubeconfig_out" "$initial_control_plane_replicas" 90
  log "scaling initial external-ca workers to replicas=${worker_replicas}"
  kubectl -n "$namespace" patch "machinedeployment/${worker_md_name}" --type merge -p "{\"spec\":{\"replicas\":${worker_replicas}}}"
  wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$initial_control_plane_replicas" "$worker_replicas" 135
  wait_workload_nodes_ready "$kubeconfig_out" "$initial_external_total_nodes" 135
fi

kubectl --kubeconfig "$kubeconfig_out" get nodes -o wide > "$out_dir/nodes-after-provision.txt"
log "cluster provisioning completed for mode=$MODE; kubeconfig: $kubeconfig_out"
