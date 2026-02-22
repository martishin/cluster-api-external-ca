#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/mode-config.sh"
source "$SCRIPT_DIR/../helpers/kube/wait.sh"
source "$POC_DIR/scripts/helpers/reroll/workers/patch-template.sh"
source "$POC_DIR/scripts/helpers/reroll/workers/rollout.sh"

MODE="$(mode_from_args "${1:-}")"
if [[ "$MODE" != "external-ca" ]]; then
  log "worker reroll is not required for mode=$MODE"
  exit 0
fi

cluster_name="$(cluster_name_for_mode "$MODE")"
kcp_name="$(kcp_name_for_mode "$MODE")"
worker_md_name="$(worker_md_for_mode "$MODE")"
namespace="${NAMESPACE:-default}"
kubeconfig_path="$(workload_kubeconfig_for_mode "$MODE")"
signer_secret="${cluster_name}-step-ca-signer"
external_ca_files_secret="${cluster_name}-external-ca-files"
worker_signer_command="/usr/local/bin/capi-worker-sign.sh"
control_plane_replicas="$(control_plane_replicas_for_mode "$MODE")"
worker_replicas="$(worker_replicas_for_mode "$MODE")"
expected_total_nodes=$((control_plane_replicas + worker_replicas))
ignore_preflight_kubelet_conf="FileAvailable--etc-kubernetes-kubelet.conf"
ignore_preflight_kubelet_port="Port-10250"

if [[ ! -s "$kubeconfig_path" ]]; then
  echo "missing workload kubeconfig: $kubeconfig_path" >&2
  exit 1
fi

require_bin kubectl jq

log "patching worker bootstrap template for signer-based kubelet cert issuance"
patch_worker_template_for_signer_mode
log "ensuring system:node clusterrolebinding contains system:nodes group"
ensure_system_node_clusterrolebinding
log "scaling workers to replicas=${worker_replicas}"
scale_workers "$worker_replicas"
wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$control_plane_replicas" "$worker_replicas" 135
wait_workload_nodes_ready "$kubeconfig_path" "$expected_total_nodes" 135
reroll_workers "$worker_replicas"

kubectl --kubeconfig "$kubeconfig_path" get nodes -o wide > "$OUT_DIR/workload/nodes-after-worker-reroll.txt"
log "worker reroll completed"
