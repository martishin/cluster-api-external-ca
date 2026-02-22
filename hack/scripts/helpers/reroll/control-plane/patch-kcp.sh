#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shared/patch-jq.sh"

patch_kcp_for_signer_mode() {
  local target_replicas="${1:-3}"
  local kcp_patch_json jq_program

  reroll_require_signer_secret_keys "$namespace" "$signer_secret" \
    provisioner-key provisioner-password root-ca.crt signer-config script worker-script

  jq_program="$(
    cat <<'JQ'
.spec.kubeadmConfigSpec as $cfg
| {
    spec: {
      replicas: $targetReplicas,
      kubeadmConfigSpec: {
        preKubeadmCommands: (
          $cfg.preKubeadmCommands
          | remove_cmd(.; $legacyKillKubeadmCommand)
          | remove_cmd(.; $legacyStopKubeletCommand)
          | remove_cmd(.; $legacyKillKubeadmShortCommand)
          | remove_cmd(.; $legacyRemoveKubeletConfCommand)
          | remove_cmd(.; $legacyRemoveStaleManifestsCommand)
          | remove_cmd(.; $legacyCleanupEtcdDirCommand)
          | ensure_cmd(.; $legacyStopKubeletCommand)
          | ensure_cmd(.; $removeBootstrapKubeletCommand)
          | ensure_cmd(.; $signerCommand)
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
                  | ensure_list_value(.; $ignorePreflightCACrt)
                  | ensure_list_value(.; $ignorePreflightKubeletPort)
                )
              }
            )
          }
        ),
        files: (
          $cfg.files
          | ensure_file(.; "/etc/kubernetes/kubelet.conf"; "0600"; "kubeconfig-kubelet"; $externalCAFilesSecret)
          | ensure_file(.; "/usr/local/bin/capi-node-sign.sh"; "0755"; "script"; $signerSecret)
          | ensure_file(.; "/etc/kubernetes/pki/step/capi-signer.env"; "0600"; "signer-config"; $signerSecret)
          | ensure_file(.; "/etc/kubernetes/pki/step/provisioner.key"; "0600"; "provisioner-key"; $signerSecret)
          | ensure_file(.; "/etc/kubernetes/pki/step/provisioner_password"; "0600"; "provisioner-password"; $signerSecret)
          | ensure_file(.; "/etc/kubernetes/pki/step/root_ca.crt"; "0644"; "root-ca.crt"; $signerSecret)
        )
      }
    }
  }
JQ
  )"

  kcp_patch_json="$(
    kubectl -n "$namespace" get "kubeadmcontrolplane/${kcp_name}" -o json | jq -c \
      --arg signerSecret "$signer_secret" \
      --arg externalCAFilesSecret "$external_ca_files_secret" \
      --arg signerCommand "$signer_command" \
      --arg ignorePreflightKubeletConf "$ignore_preflight_kubelet_conf" \
      --arg ignorePreflightCACrt "$ignore_preflight_ca_crt" \
      --arg ignorePreflightKubeletPort "$ignore_preflight_kubelet_port" \
      --arg legacyKillKubeadmCommand "$legacy_kill_kubeadm_command" \
      --arg removeBootstrapKubeletCommand "$remove_bootstrap_kubelet_command" \
      --arg legacyStopKubeletCommand "$legacy_stop_kubelet_command" \
      --arg legacyKillKubeadmShortCommand "$legacy_kill_kubeadm_short_command" \
      --arg legacyRemoveKubeletConfCommand "$legacy_remove_kubelet_conf_command" \
      --arg legacyRemoveStaleManifestsCommand "$legacy_remove_stale_manifests_command" \
      --arg legacyCleanupEtcdDirCommand "$legacy_cleanup_etcd_dir_command" \
      --argjson targetReplicas "$target_replicas" \
      "$(reroll_jq_patch_common_defs)
${jq_program}"
  )"
  kubectl -n "$namespace" patch "kubeadmcontrolplane/${kcp_name}" --type merge -p "$kcp_patch_json"

  if ! kubectl -n "$namespace" get "kubeadmcontrolplane/${kcp_name}" -o json | jq -e \
    --arg c "$signer_command" \
    --arg externalCAFilesSecret "$external_ca_files_secret" \
    --arg signerSecret "$signer_secret" \
    --arg ignorePreflightKubeletConf "$ignore_preflight_kubelet_conf" \
    --arg ignorePreflightCACrt "$ignore_preflight_ca_crt" \
    --arg ignorePreflightKubeletPort "$ignore_preflight_kubelet_port" \
    --arg legacyKillKubeadmCommand "$legacy_kill_kubeadm_command" \
    --arg removeBootstrapKubeletCommand "$remove_bootstrap_kubelet_command" \
    --arg legacyStopKubeletCommand "$legacy_stop_kubelet_command" \
    --arg legacyKillKubeadmShortCommand "$legacy_kill_kubeadm_short_command" \
    --arg legacyRemoveKubeletConfCommand "$legacy_remove_kubelet_conf_command" \
    --arg legacyRemoveStaleManifestsCommand "$legacy_remove_stale_manifests_command" \
    --arg legacyCleanupEtcdDirCommand "$legacy_cleanup_etcd_dir_command" \
    --argjson targetReplicas "$target_replicas" '
      .spec.replicas == $targetReplicas and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($legacyKillKubeadmCommand) == null) and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($legacyKillKubeadmShortCommand) == null) and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($legacyStopKubeletCommand) != null) and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($removeBootstrapKubeletCommand) != null) and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($legacyRemoveKubeletConfCommand) == null) and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($legacyRemoveStaleManifestsCommand) == null) and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($legacyCleanupEtcdDirCommand) == null) and
      ((.spec.kubeadmConfigSpec.preKubeadmCommands // []) | index($c) != null) and
      ((.spec.kubeadmConfigSpec.joinConfiguration.nodeRegistration.ignorePreflightErrors // []) | index($ignorePreflightKubeletConf) != null) and
      ((.spec.kubeadmConfigSpec.joinConfiguration.nodeRegistration.ignorePreflightErrors // []) | index($ignorePreflightCACrt) != null) and
      ((.spec.kubeadmConfigSpec.joinConfiguration.nodeRegistration.ignorePreflightErrors // []) | index($ignorePreflightKubeletPort) != null) and
      ((.spec.kubeadmConfigSpec.files // []) | any(
        .path == "/etc/kubernetes/kubelet.conf" and
        .permissions == "0600" and
        .contentFrom.secret.name == $externalCAFilesSecret and
        .contentFrom.secret.key == "kubeconfig-kubelet"
      )) and
      ((.spec.kubeadmConfigSpec.files // []) | any(
        .path == "/usr/local/bin/capi-node-sign.sh" and
        .permissions == "0755" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "script"
      )) and
      ((.spec.kubeadmConfigSpec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/capi-signer.env" and
        .permissions == "0600" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "signer-config"
      )) and
      ((.spec.kubeadmConfigSpec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/provisioner.key" and
        .permissions == "0600" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "provisioner-key"
      )) and
      ((.spec.kubeadmConfigSpec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/provisioner_password" and
        .permissions == "0600" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "provisioner-password"
      )) and
      ((.spec.kubeadmConfigSpec.files // []) | any(
        .path == "/etc/kubernetes/pki/step/root_ca.crt" and
        .permissions == "0644" and
        .contentFrom.secret.name == $signerSecret and
        .contentFrom.secret.key == "root-ca.crt"
      ))
    ' >/dev/null; then
    echo "failed to patch KCP with signer mode and target replicas=${target_replicas}" >&2
    exit 1
  fi
}
