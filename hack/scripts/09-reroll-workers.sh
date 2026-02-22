#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/env.sh"
source "$SCRIPT_DIR/utils/kube.sh"
source "$SCRIPT_DIR/utils/flow.sh"

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
control_plane_replicas=3
worker_replicas=3
expected_total_nodes=$((control_plane_replicas + worker_replicas))
ignore_preflight_kubelet_conf="FileAvailable--etc-kubernetes-kubelet.conf"
ignore_preflight_kubelet_port="Port-10250"

if [[ ! -s "$kubeconfig_path" ]]; then
  echo "missing workload kubeconfig: $kubeconfig_path" >&2
  exit 1
fi

require_bin kubectl jq

ensure_system_node_clusterrolebinding() {
  cat <<'EOF' | kubectl --kubeconfig "$kubeconfig_path" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:node
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:nodes
EOF

  if ! kubectl --kubeconfig "$kubeconfig_path" get clusterrolebinding system:node -o json | jq -e '
    .roleRef.kind == "ClusterRole" and
    .roleRef.name == "system:node" and
    ((.subjects // []) | any(.kind == "Group" and .name == "system:nodes"))
  ' >/dev/null; then
    echo "failed to enforce ClusterRoleBinding/system:node subjects" >&2
    exit 1
  fi
}

patch_worker_template_for_signer_mode() {
  local worker_template_name worker_patch_json
  worker_template_name="$(kubectl -n "$namespace" get "machinedeployment/${worker_md_name}" -o jsonpath='{.spec.template.spec.bootstrap.configRef.name}' 2>/dev/null || true)"
  if [[ -z "$worker_template_name" ]]; then
    echo "unable to determine worker bootstrap template name for ${worker_md_name}" >&2
    exit 1
  fi

  worker_patch_json="$(
    kubectl -n "$namespace" get "kubeadmconfigtemplate/${worker_template_name}" -o json | jq -c \
      --arg signerSecret "$signer_secret" \
      --arg externalCAFilesSecret "$external_ca_files_secret" \
      --arg workerSignerCommand "$worker_signer_command" \
      --arg ignorePreflightKubeletConf "$ignore_preflight_kubelet_conf" \
      --arg ignorePreflightKubeletPort "$ignore_preflight_kubelet_port" '
        def ensure_cmd($arr; $cmd):
          ($arr // []) as $base |
          if ($base | index($cmd)) == null then $base + [$cmd] else $base end;
        def ensure_list_value($arr; $value):
          ($arr // []) as $base |
          if ($base | index($value)) == null then $base + [$value] else $base end;
        def ensure_file($arr; $path; $perm; $key; $secret):
          ($arr // []) as $base |
          if ($base | map(.path == $path) | any) then
            $base
          else
            $base + [{
              path: $path,
              owner: "root:root",
              permissions: $perm,
              contentFrom: {secret: {name: $secret, key: $key}}
            }]
          end;
        def remove_file($arr; $path):
          ($arr // []) | map(select(.path != $path));
        .spec.template.spec as $cfg
        | {
            spec: {
              template: {
                spec: {
                  preKubeadmCommands: (
                    $cfg.preKubeadmCommands
                    | ensure_cmd(.; $workerSignerCommand)
                  ),
                  joinConfiguration: (
                    ($cfg.joinConfiguration // {}) as $joinCfg |
                    $joinCfg + {
                      nodeRegistration: (
                        ($joinCfg.nodeRegistration // {}) as $nodeReg |
                        $nodeReg + {
                          ignorePreflightErrors: (
                            $nodeReg.ignorePreflightErrors
                            | ensure_list_value(.; $ignorePreflightKubeletConf)
                            | ensure_list_value(.; $ignorePreflightKubeletPort)
                          )
                        }
                      )
                    }
                  ),
                  files: (
                    $cfg.files
                    | remove_file(.; "/etc/kubernetes/kubelet.conf")
                    | ensure_file(.; "/etc/kubernetes/admin.conf"; "0600"; "kubeconfig-admin"; $externalCAFilesSecret)
                    | ensure_file(.; "/usr/local/bin/capi-worker-sign.sh"; "0755"; "worker-script"; $signerSecret)
                    | ensure_file(.; "/etc/kubernetes/pki/step/provisioner.key"; "0600"; "provisioner-key"; $signerSecret)
                    | ensure_file(.; "/etc/kubernetes/pki/step/provisioner_password"; "0600"; "provisioner-password"; $signerSecret)
                    | ensure_file(.; "/etc/kubernetes/pki/step/root_ca.crt"; "0644"; "root-ca.crt"; $signerSecret)
                  )
                }
              }
            }
          }'
  )"
  kubectl -n "$namespace" patch "kubeadmconfigtemplate/${worker_template_name}" --type merge -p "$worker_patch_json"

  if ! kubectl -n "$namespace" get "kubeadmconfigtemplate/${worker_template_name}" -o json | jq -e \
    --arg workerSignerCommand "$worker_signer_command" \
    --arg ignorePreflightKubeletConf "$ignore_preflight_kubelet_conf" \
    --arg ignorePreflightKubeletPort "$ignore_preflight_kubelet_port" '
      ((.spec.template.spec.preKubeadmCommands // []) | index($workerSignerCommand) != null) and
      ((.spec.template.spec.joinConfiguration.nodeRegistration.ignorePreflightErrors // []) | index($ignorePreflightKubeletConf) != null) and
      ((.spec.template.spec.joinConfiguration.nodeRegistration.ignorePreflightErrors // []) | index($ignorePreflightKubeletPort) != null) and
      ((.spec.template.spec.files // []) | map(.path == "/etc/kubernetes/kubelet.conf") | any | not) and
      ((.spec.template.spec.files // []) | map(.path == "/etc/kubernetes/admin.conf") | any) and
      ((.spec.template.spec.files // []) | map(.path == "/usr/local/bin/capi-worker-sign.sh") | any) and
      ((.spec.template.spec.files // []) | map(.path == "/etc/kubernetes/pki/step/provisioner.key") | any) and
      ((.spec.template.spec.files // []) | map(.path == "/etc/kubernetes/pki/step/provisioner_password") | any) and
      ((.spec.template.spec.files // []) | map(.path == "/etc/kubernetes/pki/step/root_ca.crt") | any)
    ' >/dev/null; then
    echo "failed to patch worker template ${worker_template_name} with signer mode" >&2
    exit 1
  fi
}

scale_workers() {
  local target_replicas="$1"
  kubectl -n "$namespace" patch "machinedeployment/${worker_md_name}" --type merge -p "{\"spec\":{\"replicas\":${target_replicas}}}"
}

reroll_workers() {
  local target_replicas="$1"
  local worker_machine machine_count
  local expected_nodes=$((control_plane_replicas + target_replicas))

  machine_count="$(kubectl -n "$namespace" get machine -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/deployment-name=${worker_md_name}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$machine_count" -eq 0 ]]; then
    log "worker reroll skipped: no worker machines found"
    return 0
  fi

  while IFS= read -r worker_machine; do
    [[ -n "$worker_machine" ]] || continue
    log "external-ca reroll: replacing worker machine $worker_machine"
    kubectl -n "$namespace" delete machine "$worker_machine"
    wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$control_plane_replicas" "$target_replicas" 135
    wait_workload_nodes_ready "$kubeconfig_path" "$expected_nodes" 135
  done < <(
    kubectl -n "$namespace" get machine \
      -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/deployment-name=${worker_md_name}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )
}

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
