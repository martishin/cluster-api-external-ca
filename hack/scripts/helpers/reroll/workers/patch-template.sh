#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shared/patch-jq.sh"

ensure_system_node_clusterrolebinding() {
  cat <<'RBAC' | kubectl --kubeconfig "$kubeconfig_path" apply -f -
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
RBAC

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
  local worker_template_name worker_patch_json jq_program

  reroll_require_signer_secret_keys "$namespace" "$signer_secret" \
    provisioner-key provisioner-password root-ca.crt signer-config script worker-script

  worker_template_name="$(kubectl -n "$namespace" get "machinedeployment/${worker_md_name}" -o jsonpath='{.spec.template.spec.bootstrap.configRef.name}' 2>/dev/null || true)"
  if [[ -z "$worker_template_name" ]]; then
    echo "unable to determine worker bootstrap template name for ${worker_md_name}" >&2
    exit 1
  fi

  jq_program="$(
    cat <<'JQ'
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
            | ensure_file(.; "/etc/kubernetes/pki/step/capi-signer.env"; "0600"; "signer-config"; $signerSecret)
            | ensure_file(.; "/etc/kubernetes/pki/step/provisioner.key"; "0600"; "provisioner-key"; $signerSecret)
            | ensure_file(.; "/etc/kubernetes/pki/step/provisioner_password"; "0600"; "provisioner-password"; $signerSecret)
            | ensure_file(.; "/etc/kubernetes/pki/step/root_ca.crt"; "0644"; "root-ca.crt"; $signerSecret)
          )
        }
      }
    }
  }
JQ
  )"

  worker_patch_json="$(
    kubectl -n "$namespace" get "kubeadmconfigtemplate/${worker_template_name}" -o json | jq -c \
      --arg signerSecret "$signer_secret" \
      --arg externalCAFilesSecret "$external_ca_files_secret" \
      --arg workerSignerCommand "$worker_signer_command" \
      --arg ignorePreflightKubeletConf "$ignore_preflight_kubelet_conf" \
      --arg ignorePreflightKubeletPort "$ignore_preflight_kubelet_port" \
      "$(reroll_jq_patch_common_defs)
${jq_program}"
  )"
  kubectl -n "$namespace" patch "kubeadmconfigtemplate/${worker_template_name}" --type merge -p "$worker_patch_json"

  if ! kubectl -n "$namespace" get "kubeadmconfigtemplate/${worker_template_name}" -o json | jq -e \
    --arg externalCAFilesSecret "$external_ca_files_secret" \
    --arg signerSecret "$signer_secret" \
    --arg workerSignerCommand "$worker_signer_command" \
    --arg ignorePreflightKubeletConf "$ignore_preflight_kubelet_conf" \
    --arg ignorePreflightKubeletPort "$ignore_preflight_kubelet_port" '
      ((.spec.template.spec.preKubeadmCommands // []) | index($workerSignerCommand) != null) and
      ((.spec.template.spec.joinConfiguration.nodeRegistration.ignorePreflightErrors // []) | index($ignorePreflightKubeletConf) != null) and
      ((.spec.template.spec.joinConfiguration.nodeRegistration.ignorePreflightErrors // []) | index($ignorePreflightKubeletPort) != null) and
      ((.spec.template.spec.files // []) | map(.path == "/etc/kubernetes/kubelet.conf") | any | not) and
      ((.spec.template.spec.files // []) | any(
        .path == "/etc/kubernetes/admin.conf" and
        .permissions == "0600" and
        .contentFrom.secret.name == $externalCAFilesSecret and
        .contentFrom.secret.key == "kubeconfig-admin"
      )) and
      ((.spec.template.spec.files // []) | any(
        .path == "/usr/local/bin/capi-worker-sign.sh" and
        .permissions == "0755" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "worker-script"
      )) and
      ((.spec.template.spec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/capi-signer.env" and
        .permissions == "0600" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "signer-config"
      )) and
      ((.spec.template.spec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/provisioner.key" and
        .permissions == "0600" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "provisioner-key"
      )) and
      ((.spec.template.spec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/provisioner_password" and
        .permissions == "0600" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "provisioner-password"
      )) and
      ((.spec.template.spec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/root_ca.crt" and
        .permissions == "0644" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "root-ca.crt"
      ))
    ' >/dev/null; then
    echo "failed to patch worker template ${worker_template_name} with signer mode" >&2
    exit 1
  fi
}
