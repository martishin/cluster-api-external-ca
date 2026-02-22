#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/env.sh"
source "$SCRIPT_DIR/utils/kube.sh"
source "$SCRIPT_DIR/utils/flow.sh"
source "$SCRIPT_DIR/utils/stepca.sh"

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
material_dir="${MATERIAL_DIR:-$OUT_DIR/workload/material}"
refresh_script="$POC_DIR/scripts/external-ca/refresh-static-material.sh"
signer_secret="${cluster_name}-step-ca-signer"
external_ca_files_secret="${cluster_name}-external-ca-files"
signer_command="/usr/local/bin/capi-node-sign.sh"
control_plane_replicas=3
worker_replicas=3
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

collect_control_plane_sans() {
  local machine_list machine
  machine_list="$(kubectl -n "$namespace" get machine -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/control-plane" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  {
    echo "localhost"
    echo "127.0.0.1"
    echo "::1"
    if [[ -n "$machine_list" ]]; then
      while IFS= read -r machine; do
        [[ -n "$machine" ]] || continue
        echo "$machine"
        kubectl -n "$namespace" get machine "$machine" -o jsonpath='{range .status.addresses[*]}{.address}{"\n"}{end}' 2>/dev/null || true
      done <<< "$machine_list"
    fi
    kubectl -n "$namespace" get cluster "$cluster_name" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true
  } | awk 'NF' | sort -u | paste -sd, -
}

resolve_kubeconfig_server() {
  local host port
  host="$(kubectl -n "$namespace" get cluster "$cluster_name" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true)"
  port="$(kubectl -n "$namespace" get cluster "$cluster_name" -o jsonpath='{.spec.controlPlaneEndpoint.port}' 2>/dev/null || true)"
  if [[ -n "$host" && -n "$port" ]]; then
    echo "https://${host}:${port}"
  else
    echo "https://127.0.0.1:6443"
  fi
}

refresh_external_bootstrap_material() {
  local server san_list server_host
  server="$(resolve_kubeconfig_server)"
  san_list="$(collect_control_plane_sans)"
  server_host="${server#https://}"
  server_host="${server_host%%:*}"
  san_list="$(
    {
      echo "$san_list" | tr ',' '\n'
      echo "$server_host"
    } | awk 'NF' | sort -u | paste -sd, -
  )"

  CLUSTER_NAME="$cluster_name" \
  NAMESPACE="$namespace" \
  MATERIAL_DIR="$material_dir" \
  KUBECONFIG_SERVER="$server" \
  APISERVER_SANS_EXTRA="$san_list" \
  ETCD_SANS_EXTRA="$san_list" \
  "$refresh_script"
}

run_node_debug_command() {
  local node_name="$1"
  local node_script="$2"
  local debug_namespace="${DEBUG_NAMESPACE:-default}"
  local create_out pod_name phase i

  if ! create_out="$(
    kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" debug "node/${node_name}" \
      --image=busybox:1.36 --profile=general --attach=false -- \
      chroot /host sh -ceu "$node_script" 2>&1
  )"; then
    echo "$create_out" >&2
    return 1
  fi

  pod_name="$(printf '%s\n' "$create_out" | awk '/Creating debugging pod/{print $4}' | tail -n1)"
  if [[ -z "$pod_name" ]]; then
    echo "unable to determine debug pod name for node ${node_name}" >&2
    echo "$create_out" >&2
    return 1
  fi

  for ((i=1; i<=90; i++)); do
    phase="$(kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded|Failed)
        break
        ;;
    esac
    sleep 2
  done

  kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" logs "$pod_name" 2>/dev/null || true
  kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" delete pod "$pod_name" --ignore-not-found >/dev/null 2>&1 || true

  if [[ "$phase" != "Succeeded" ]]; then
    echo "debug command failed on node ${node_name} (phase=${phase:-unknown})" >&2
    return 1
  fi
}

rotate_existing_node_etcd_certs() {
  local node_name="$1"
  local server_crt_b64 server_key_b64 peer_crt_b64 peer_key_b64 node_script

  server_crt_b64="$(base64 < "$material_dir/etcd-server.crt" | tr -d '\n')"
  server_key_b64="$(base64 < "$material_dir/etcd-server.key" | tr -d '\n')"
  peer_crt_b64="$(base64 < "$material_dir/etcd-peer.crt" | tr -d '\n')"
  peer_key_b64="$(base64 < "$material_dir/etcd-peer.key" | tr -d '\n')"

  node_script="$(cat <<EOF
set -eu
mkdir -p /etc/kubernetes/pki/etcd
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/server.crt
${server_crt_b64}
EOC
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/server.key
${server_key_b64}
EOC
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/peer.crt
${peer_crt_b64}
EOC
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/peer.key
${peer_key_b64}
EOC
chmod 0644 /etc/kubernetes/pki/etcd/server.crt /etc/kubernetes/pki/etcd/peer.crt
chmod 0600 /etc/kubernetes/pki/etcd/server.key /etc/kubernetes/pki/etcd/peer.key
if [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
  mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.capi-rotate
  sleep 8
  mv /etc/kubernetes/manifests/etcd.yaml.capi-rotate /etc/kubernetes/manifests/etcd.yaml
fi
echo "rotated etcd certs on ${node_name}"
EOF
)"

  run_node_debug_command "$node_name" "$node_script"
}

prepare_existing_control_plane_for_join() {
  local node_list node_name
  node_list="$(kubectl --kubeconfig "$kubeconfig_path" get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "$node_list" ]]; then
    echo "no control-plane nodes found in workload cluster to rotate etcd certs" >&2
    return 1
  fi

  while IFS= read -r node_name; do
    [[ -n "$node_name" ]] || continue
    log "rotating etcd certs on existing control-plane node: $node_name"
    rotate_existing_node_etcd_certs "$node_name"
  done <<< "$node_list"
}

wait_cp_ready_with_refresh() {
  local target="$1"
  local expected_nodes="$2"
  local expected_workers="$3"
  local i ready_cp
  for ((i=1; i<=90; i++)); do
    ready_cp="$(kubectl -n "$namespace" get "kubeadmcontrolplane/${kcp_name}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "$ready_cp" == "$target" ]]; then
      wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$target" "$expected_workers" 120
      wait_workload_nodes_ready "$kubeconfig_path" "$expected_nodes" 120
      return 0
    fi
    refresh_external_bootstrap_material
    sleep 20
  done
  return 1
}

patch_kcp_for_signer_mode() {
  local target_replicas="${1:-3}"
  local tmp_script tmp_worker_script tmp_key tmp_root tmp_password kcp_patch_json
  tmp_script="$(mktemp)"
  tmp_worker_script="$(mktemp)"
  tmp_key="$(mktemp)"
  tmp_root="$(mktemp)"
  tmp_password="$(mktemp)"
  trap 'rm -f "$tmp_script" "$tmp_worker_script" "$tmp_key" "$tmp_root" "$tmp_password"' RETURN

  if ! kubectl -n "$namespace" get secret "$signer_secret" >/dev/null 2>&1; then
    echo "missing signer secret in management namespace: $signer_secret (run 07-deploy-workload-step-ca first)" >&2
    exit 1
  fi
  kubectl -n "$namespace" get secret "$signer_secret" -o jsonpath='{.data.provisioner-key}' | base64 -d > "$tmp_key"
  kubectl -n "$namespace" get secret "$signer_secret" -o jsonpath='{.data.provisioner-password}' | base64 -d > "$tmp_password"
  kubectl -n "$namespace" get secret "$signer_secret" -o jsonpath='{.data.root-ca\.crt}' | base64 -d > "$tmp_root"
  if [[ ! -s "$tmp_key" ]]; then
    echo "secret $signer_secret does not contain provisioner-key" >&2
    exit 1
  fi
  if [[ ! -s "$tmp_password" ]]; then
    echo "secret $signer_secret does not contain provisioner-password" >&2
    exit 1
  fi
  if [[ ! -s "$tmp_root" ]]; then
    echo "secret $signer_secret does not contain root-ca.crt" >&2
    exit 1
  fi

  cat > "$tmp_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/capi-node-sign.log"
exec >>"\$LOG_FILE" 2>&1
echo "[\$(date -u +%FT%TZ)] starting node signer bootstrap"

STEP_VERSION="0.28.7"
PROVISIONER_NAME="${STEPCA_PROVISIONER}"
PROVISIONER_KEY_FILE="/etc/kubernetes/pki/step/provisioner.key"
PROVISIONER_PASSWORD_FILE="/etc/kubernetes/pki/step/provisioner_password"
STEP_ROOT_CA_FILE="/etc/kubernetes/pki/step/root_ca.crt"
ADMIN_KUBECONFIG="/etc/kubernetes/admin.conf"
CA_HOST="${STEPCA_NAME}.${STEPCA_NAMESPACE}.svc.cluster.local"
CA_PORT="${STEPCA_PORT}"
LOCAL_CA_PORT="${STEPCA_PORT}"
CA_URL="https://\${CA_HOST}:\${LOCAL_CA_PORT}"

install_step() {
  if command -v step >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "step cli is missing and curl/tar are unavailable"
    exit 1
  fi

  local arch url tmpdir binpath
  case "\$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported architecture: \$(uname -m)"; exit 1 ;;
  esac
  url="https://dl.step.sm/gh-release/cli/docs-cli-install/v\${STEP_VERSION}/step_linux_\${STEP_VERSION}_\${arch}.tar.gz"
  tmpdir="\$(mktemp -d)"
  curl -fsSL "\$url" -o "\$tmpdir/step.tar.gz"
  tar -xzf "\$tmpdir/step.tar.gz" -C "\$tmpdir"
  binpath="\$(find "\$tmpdir" -type f -name step | head -n1)"
  install -m 0755 "\$binpath" /usr/local/bin/step
  rm -rf "\$tmpdir"
}

ensure_ca_host_alias() {
  grep -v "[[:space:]]\${CA_HOST}\$" /etc/hosts >/etc/hosts.capi-node-sign || true
  echo "127.0.0.1 \${CA_HOST}" >> /etc/hosts.capi-node-sign
  cat /etc/hosts.capi-node-sign > /etc/hosts
  rm -f /etc/hosts.capi-node-sign
}

wait_step_ca_ready() {
  local endpoint_ip
  for _ in \$(seq 1 120); do
    endpoint_ip="\$(kubectl --kubeconfig "\$ADMIN_KUBECONFIG" -n "${STEPCA_NAMESPACE}" get endpoints "${STEPCA_NAME}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -n "\$endpoint_ip" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "step-ca endpoint was not ready in ${STEPCA_NAMESPACE}/${STEPCA_NAME}"
  exit 1
}

start_port_forward() {
  local attempt
  wait_step_ca_ready
  for attempt in \$(seq 1 4); do
    kubectl --kubeconfig "\$ADMIN_KUBECONFIG" -n "${STEPCA_NAMESPACE}" \
      port-forward "service/${STEPCA_NAME}" "\${LOCAL_CA_PORT}:\${CA_PORT}" --address 127.0.0.1 \
      >/var/log/capi-node-sign-port-forward.log 2>&1 &
    TUNNEL_PID=\$!
    for _ in \$(seq 1 45); do
      if ! kill -0 "\$TUNNEL_PID" >/dev/null 2>&1; then
        break
      fi
      if curl -fsS --cacert "\${STEP_ROOT_CA_FILE}" "\${CA_URL}/health" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    kill "\$TUNNEL_PID" >/dev/null 2>&1 || true
    wait "\$TUNNEL_PID" 2>/dev/null || true
    sleep 2
  done
  echo "step-ca port-forward did not become ready"
  exit 1
}

uniq_sans() {
  awk 'NF && !seen[\$0]++'
}

make_token() {
  local subject="\$1"
  shift
  local cmd
  cmd=(step ca token "\$subject" \
    --offline \
    --ca-url "\$CA_URL" \
    --root "\$STEP_ROOT_CA_FILE" \
    --provisioner "\$PROVISIONER_NAME" \
    --key "\$PROVISIONER_KEY_FILE" \
    --provisioner-password-file "\$PROVISIONER_PASSWORD_FILE" \
    --not-after 15m)
  local san
  for san in "\$@"; do
    cmd+=(--san "\$san")
  done
  "\${cmd[@]}"
}

issue_cert() {
  local subject="\$1"
  local crt_path="\$2"
  local key_path="\$3"
  shift 3
  local token
  token="\$(make_token "\$subject" "\$@")"
  step ca certificate "\$subject" "\$crt_path" "\$key_path" \
    --token "\$token" \
    --ca-url "\$CA_URL" \
    --root "\$STEP_ROOT_CA_FILE" \
    --force
  chmod 0644 "\$crt_path"
  chmod 0600 "\$key_path"
}

mkdir -p /etc/kubernetes/pki/etcd /etc/kubernetes/pki/step
install_step
ensure_ca_host_alias
start_port_forward
trap 'kill "\${TUNNEL_PID:-0}" >/dev/null 2>&1 || true' EXIT

node_name="\$(hostname -s)"
endpoint_host="\$(kubectl --kubeconfig "\$ADMIN_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed -E 's#^https?://([^/:]+).*#\\1#' || true)"

mapfile -t node_ips < <(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF')

mapfile -t apiserver_sans < <(
  {
    printf '%s\n' "kubernetes" "kubernetes.default" "kubernetes.default.svc" "kubernetes.default.svc.cluster.local" "10.96.0.1" "localhost" "127.0.0.1" "::1"
    printf '%s\n' "\$node_name"
    [[ -n "\$endpoint_host" ]] && printf '%s\n' "\$endpoint_host"
    printf '%s\n' "\${node_ips[@]}"
  } | uniq_sans
)

mapfile -t etcd_sans < <(
  {
    printf '%s\n' "localhost" "127.0.0.1" "::1"
    printf '%s\n' "\$node_name"
    printf '%s\n' "\${node_ips[@]}"
  } | uniq_sans
)

issue_cert "kube-apiserver" "/etc/kubernetes/pki/apiserver.crt" "/etc/kubernetes/pki/apiserver.key" "\${apiserver_sans[@]}"
issue_cert "kube-etcd" "/etc/kubernetes/pki/etcd/server.crt" "/etc/kubernetes/pki/etcd/server.key" "\${etcd_sans[@]}"
issue_cert "kube-etcd-peer" "/etc/kubernetes/pki/etcd/peer.crt" "/etc/kubernetes/pki/etcd/peer.key" "\${etcd_sans[@]}"

echo "[\$(date -u +%FT%TZ)] node signer bootstrap finished"
EOF

  cat > "$tmp_worker_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/capi-worker-sign.log"
exec >>"\$LOG_FILE" 2>&1
echo "[\$(date -u +%FT%TZ)] starting worker signer bootstrap"

STEP_VERSION="0.28.7"
PROVISIONER_NAME="${STEPCA_PROVISIONER}"
PROVISIONER_KEY_FILE="/etc/kubernetes/pki/step/provisioner.key"
PROVISIONER_PASSWORD_FILE="/etc/kubernetes/pki/step/provisioner_password"
STEP_ROOT_CA_FILE="/etc/kubernetes/pki/step/root_ca.crt"
ADMIN_KUBECONFIG="/etc/kubernetes/admin.conf"
CA_CHAIN_FILE="\$STEP_ROOT_CA_FILE"
CA_HOST="${STEPCA_NAME}.${STEPCA_NAMESPACE}.svc.cluster.local"
CA_PORT="${STEPCA_PORT}"
LOCAL_CA_PORT="${STEPCA_PORT}"
CA_URL="https://\${CA_HOST}:\${LOCAL_CA_PORT}"

install_step() {
  if command -v step >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "step cli is missing and curl/tar are unavailable"
    exit 1
  fi

  local arch url tmpdir binpath
  case "\$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported architecture: \$(uname -m)"; exit 1 ;;
  esac
  url="https://dl.step.sm/gh-release/cli/docs-cli-install/v\${STEP_VERSION}/step_linux_\${STEP_VERSION}_\${arch}.tar.gz"
  tmpdir="\$(mktemp -d)"
  curl -fsSL "\$url" -o "\$tmpdir/step.tar.gz"
  tar -xzf "\$tmpdir/step.tar.gz" -C "\$tmpdir"
  binpath="\$(find "\$tmpdir" -type f -name step | head -n1)"
  install -m 0755 "\$binpath" /usr/local/bin/step
  rm -rf "\$tmpdir"
}

ensure_ca_host_alias() {
  grep -v "[[:space:]]\${CA_HOST}\$" /etc/hosts >/etc/hosts.capi-worker-sign || true
  echo "127.0.0.1 \${CA_HOST}" >> /etc/hosts.capi-worker-sign
  cat /etc/hosts.capi-worker-sign > /etc/hosts
  rm -f /etc/hosts.capi-worker-sign
}

wait_step_ca_ready() {
  local endpoint_ip
  for _ in \$(seq 1 120); do
    endpoint_ip="\$(kubectl --kubeconfig "\$ADMIN_KUBECONFIG" -n "${STEPCA_NAMESPACE}" get endpoints "${STEPCA_NAME}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -n "\$endpoint_ip" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "step-ca endpoint was not ready in ${STEPCA_NAMESPACE}/${STEPCA_NAME}"
  exit 1
}

start_port_forward() {
  local attempt
  wait_step_ca_ready
  for attempt in \$(seq 1 4); do
    kubectl --kubeconfig "\$ADMIN_KUBECONFIG" -n "${STEPCA_NAMESPACE}" \
      port-forward "service/${STEPCA_NAME}" "\${LOCAL_CA_PORT}:\${CA_PORT}" --address 127.0.0.1 \
      >/var/log/capi-worker-sign-port-forward.log 2>&1 &
    TUNNEL_PID=\$!
    for _ in \$(seq 1 45); do
      if ! kill -0 "\$TUNNEL_PID" >/dev/null 2>&1; then
        break
      fi
      if curl -fsS --cacert "\${STEP_ROOT_CA_FILE}" "\${CA_URL}/health" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    kill "\$TUNNEL_PID" >/dev/null 2>&1 || true
    wait "\$TUNNEL_PID" 2>/dev/null || true
    sleep 2
  done
  echo "step-ca port-forward did not become ready"
  exit 1
}

make_token() {
  local subject="\$1"
  shift
  local cmd
  cmd=(step ca token "\$subject" \
    --offline \
    --ca-url "\$CA_URL" \
    --root "\$STEP_ROOT_CA_FILE" \
    --provisioner "\$PROVISIONER_NAME" \
    --key "\$PROVISIONER_KEY_FILE" \
    --provisioner-password-file "\$PROVISIONER_PASSWORD_FILE" \
    --not-after 15m)
  local san
  for san in "\$@"; do
    cmd+=(--san "\$san")
  done
  "\${cmd[@]}"
}

install_step
ensure_ca_host_alias
start_port_forward
trap 'kill "\${TUNNEL_PID:-0}" >/dev/null 2>&1 || true' EXIT

node_name="\$(hostname -s)"
server_url="\$(kubectl --kubeconfig "\$ADMIN_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if [[ -z "\$server_url" ]]; then
  echo "unable to resolve API server URL from \$ADMIN_KUBECONFIG"
  exit 1
fi

mkdir -p /var/lib/kubelet/pki /etc/kubernetes
kubelet_key="/var/lib/kubelet/pki/kubelet-client.key"
kubelet_csr="/var/lib/kubelet/pki/kubelet-client.csr"
kubelet_crt="/var/lib/kubelet/pki/kubelet-client.crt"

csr_template="\$(mktemp)"
cat >"\$csr_template" <<'EOT'
{
  "subject": {
    "commonName": "{{ .Subject.CommonName }}",
    "organization": ["system:nodes"]
  }
}
EOT
step certificate create "system:node:\${node_name}" "\$kubelet_csr" "\$kubelet_key" \
  --csr \
  --template "\$csr_template" \
  --kty RSA \
  --size 2048 \
  --no-password \
  --insecure \
  --force

token="\$(make_token "system:node:\${node_name}" "\${node_name}")"
step ca sign "\$kubelet_csr" "\$kubelet_crt" \
  --token "\$token" \
  --ca-url "\$CA_URL" \
  --root "\$STEP_ROOT_CA_FILE" \
  --force

chmod 0600 "\$kubelet_key"
chmod 0644 "\$kubelet_crt"

tmp_kubeconfig="\$(mktemp)"
KUBECONFIG="\$tmp_kubeconfig" kubectl config set-cluster default \
  --server "\$server_url" \
  --certificate-authority "\$CA_CHAIN_FILE" \
  --embed-certs=true >/dev/null
KUBECONFIG="\$tmp_kubeconfig" kubectl config set-credentials "system:node:\${node_name}" \
  --client-certificate "\$kubelet_crt" \
  --client-key "\$kubelet_key" \
  --embed-certs=true >/dev/null
KUBECONFIG="\$tmp_kubeconfig" kubectl config set-context default \
  --cluster default \
  --user "system:node:\${node_name}" >/dev/null
KUBECONFIG="\$tmp_kubeconfig" kubectl config use-context default >/dev/null
install -m 0600 "\$tmp_kubeconfig" /etc/kubernetes/kubelet.conf
rm -f "\$tmp_kubeconfig" "\$kubelet_csr" "\$csr_template"

echo "[\$(date -u +%FT%TZ)] worker signer bootstrap finished"
EOF

  chmod 0755 "$tmp_script"
  chmod 0755 "$tmp_worker_script"
  kubectl -n "$namespace" create secret generic "$signer_secret" \
    --from-file=provisioner-key="$tmp_key" \
    --from-file=provisioner-password="$tmp_password" \
    --from-file=root-ca.crt="$tmp_root" \
    --from-file=script="$tmp_script" \
    --from-file=worker-script="$tmp_worker_script" \
    --dry-run=client -o yaml | kubectl apply -f -

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
      --argjson targetReplicas "$target_replicas" '
        def ensure_cmd($arr; $cmd):
          ($arr // []) as $base |
          if ($base | index($cmd)) == null then $base + [$cmd] else $base end;
        def ensure_list_value($arr; $value):
          ($arr // []) as $base |
          if ($base | index($value)) == null then $base + [$value] else $base end;
        def remove_cmd($arr; $cmd):
          ($arr // []) | map(select(. != $cmd));
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
                  | ensure_file(.; "/etc/kubernetes/pki/step/provisioner.key"; "0600"; "provisioner-key"; $signerSecret)
                  | ensure_file(.; "/etc/kubernetes/pki/step/provisioner_password"; "0600"; "provisioner-password"; $signerSecret)
                  | ensure_file(.; "/etc/kubernetes/pki/step/root_ca.crt"; "0644"; "root-ca.crt"; $signerSecret)
                )
              }
            }
          }'
  )"
  kubectl -n "$namespace" patch "kubeadmcontrolplane/${kcp_name}" --type merge -p "$kcp_patch_json"

  if ! kubectl -n "$namespace" get "kubeadmcontrolplane/${kcp_name}" -o json | jq -e \
    --arg c "$signer_command" \
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
      ((.spec.kubeadmConfigSpec.files // []) | map(.path == "/etc/kubernetes/kubelet.conf") | any) and
      ((.spec.kubeadmConfigSpec.files // []) | map(.path == "/usr/local/bin/capi-node-sign.sh") | any) and
      ((.spec.kubeadmConfigSpec.files // []) | map(.path == "/etc/kubernetes/pki/step/provisioner.key") | any) and
      ((.spec.kubeadmConfigSpec.files // []) | map(.path == "/etc/kubernetes/pki/step/provisioner_password") | any) and
      ((.spec.kubeadmConfigSpec.files // []) | map(.path == "/etc/kubernetes/pki/step/root_ca.crt") | any)
    ' >/dev/null; then
    echo "failed to patch KCP with signer mode and target replicas=${target_replicas}" >&2
    exit 1
  fi
}

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
