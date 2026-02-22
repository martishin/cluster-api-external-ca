#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/mode-config.sh"
source "$SCRIPT_DIR/../helpers/kube/wait.sh"
source "$SCRIPT_DIR/../helpers/reroll/control-plane/pki-refresh.sh"
source "$SCRIPT_DIR/../helpers/reroll/control-plane/node-debug.sh"
source "$SCRIPT_DIR/../helpers/reroll/control-plane/patch-kcp.sh"

MODE="$(mode_from_args "${1:-}")"
if [[ "$MODE" != "external-ca" ]]; then
  log "control-plane reroll is not required for mode=$MODE"
  exit 0
fi

cluster_name="$(cluster_name_for_mode "$MODE")"
kcp_name="$(kcp_name_for_mode "$MODE")"
worker_md_name="$(worker_md_for_mode "$MODE")"
namespace="${NAMESPACE:-default}"
kubeconfig_path="$(workload_kubeconfig_for_mode "$MODE")"
bootstrap_pki_dir="${BOOTSTRAP_PKI_DIR:-$OUT_DIR/workload/bootstrap-pki}"
refresh_script="$POC_DIR/scripts/setup/external-ca-bootstrap-pki.sh"
signer_secret="${cluster_name}-step-ca-signer"
external_ca_files_secret="${cluster_name}-external-ca-files"
signer_command="/usr/local/bin/capi-node-sign.sh"
control_plane_replicas="$(control_plane_replicas_for_mode "$MODE")"
worker_replicas="$(worker_replicas_for_mode "$MODE")"
expected_total_nodes=$((control_plane_replicas + worker_replicas))
legacy_kill_kubeadm_command="pkill -f 'kubeadm join' || true"
remove_bootstrap_kubelet_command="rm -f /etc/kubernetes/bootstrap-kubelet.conf /var/lib/kubelet/config.yaml"
legacy_stop_kubelet_command="systemctl stop kubelet || true"
ignore_preflight_kubelet_conf="FileAvailable--etc-kubernetes-kubelet.conf"
ignore_preflight_ca_crt="FileAvailable--etc-kubernetes-pki-ca.crt"
ignore_preflight_kubelet_port="Port-10250"
legacy_kill_kubeadm_short_command="pkill -x kubeadm || true"
legacy_remove_kubelet_conf_command="rm -f /etc/kubernetes/kubelet.conf"
legacy_remove_stale_manifests_command="rm -f /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/etcd.yaml"
legacy_cleanup_etcd_dir_command="rm -rf /var/lib/etcd/*"

if [[ ! -s "$kubeconfig_path" ]]; then
  echo "missing workload kubeconfig: $kubeconfig_path" >&2
  exit 1
fi

require_bin kubectl jq base64

log "patching KCP for per-node signer mode (replicas=1), preparing existing control-plane, then scaling to 3"
patch_kcp_for_signer_mode 1
refresh_external_bootstrap_material
prepare_existing_control_plane_for_join
patch_kcp_for_signer_mode "$control_plane_replicas"
wait_cp_ready_with_refresh "$control_plane_replicas" "$expected_total_nodes" "$worker_replicas"

oldest_machine="$(kubectl -n "$namespace" get machine -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/control-plane" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$oldest_machine" ]]; then
  echo "unable to identify oldest control-plane machine for reroll" >&2
  exit 1
fi

log "external-ca reroll: replacing oldest control-plane machine $oldest_machine"
refresh_external_bootstrap_material
kubectl -n "$namespace" delete machine "$oldest_machine"
wait_cp_ready_with_refresh "$control_plane_replicas" "$expected_total_nodes" "$worker_replicas"

kubectl --kubeconfig "$kubeconfig_path" get nodes -o wide > "$OUT_DIR/workload/nodes-after-control-plane-reroll.txt"
log "control-plane reroll completed"
