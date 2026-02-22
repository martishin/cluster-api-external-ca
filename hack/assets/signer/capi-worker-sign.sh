#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/capi-worker-sign.log"
exec >>"$LOG_FILE" 2>&1
echo "[$(date -u +%FT%TZ)] starting worker signer bootstrap"

SIGNER_CONFIG_FILE="/etc/kubernetes/pki/step/capi-signer.env"
if [[ -s "$SIGNER_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SIGNER_CONFIG_FILE"
fi

STEP_VERSION="${STEP_VERSION:-0.28.7}"
PROVISIONER_NAME="${PROVISIONER_NAME:-admin}"
CA_NAMESPACE="${CA_NAMESPACE:-external-ca-system}"
CA_SERVICE_NAME="${CA_SERVICE_NAME:-step-ca}"
CA_SERVICE_PORT="${CA_SERVICE_PORT:-9000}"
CA_HOST="${CA_HOST:-step-ca.external-ca-system.svc.cluster.local}"
LOCAL_CA_PORT="${LOCAL_CA_PORT:-9000}"
PROVISIONER_KEY_FILE="/etc/kubernetes/pki/step/provisioner.key"
PROVISIONER_PASSWORD_FILE="/etc/kubernetes/pki/step/provisioner_password"
STEP_ROOT_CA_FILE="/etc/kubernetes/pki/step/root_ca.crt"
ADMIN_KUBECONFIG="/etc/kubernetes/admin.conf"
CA_CHAIN_FILE="$STEP_ROOT_CA_FILE"
CA_PORT="$CA_SERVICE_PORT"
CA_URL="https://${CA_HOST}:${LOCAL_CA_PORT}"

install_step() {
  if command -v step >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "step cli is missing and curl/tar are unavailable"
    exit 1
  fi

  local arch url tmpdir binpath
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  url="https://dl.step.sm/gh-release/cli/docs-cli-install/v${STEP_VERSION}/step_linux_${STEP_VERSION}_${arch}.tar.gz"
  tmpdir="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmpdir/step.tar.gz"
  tar -xzf "$tmpdir/step.tar.gz" -C "$tmpdir"
  binpath="$(find "$tmpdir" -type f -name step | head -n1)"
  install -m 0755 "$binpath" /usr/local/bin/step
  rm -rf "$tmpdir"
}

ensure_ca_host_alias() {
  grep -v "[[:space:]]${CA_HOST}$" /etc/hosts >/etc/hosts.capi-worker-sign || true
  echo "127.0.0.1 ${CA_HOST}" >> /etc/hosts.capi-worker-sign
  cat /etc/hosts.capi-worker-sign > /etc/hosts
  rm -f /etc/hosts.capi-worker-sign
}

wait_step_ca_ready() {
  local endpoint_ip
  for _ in $(seq 1 120); do
    endpoint_ip="$(kubectl --kubeconfig "$ADMIN_KUBECONFIG" -n "$CA_NAMESPACE" get endpoints "$CA_SERVICE_NAME" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -n "$endpoint_ip" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "step-ca endpoint was not ready in ${CA_NAMESPACE}/${CA_SERVICE_NAME}"
  exit 1
}

start_port_forward() {
  local attempt
  wait_step_ca_ready
  for attempt in $(seq 1 4); do
    kubectl --kubeconfig "$ADMIN_KUBECONFIG" -n "$CA_NAMESPACE" \
      port-forward "service/${CA_SERVICE_NAME}" "${LOCAL_CA_PORT}:${CA_PORT}" --address 127.0.0.1 \
      >/var/log/capi-worker-sign-port-forward.log 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 45); do
      if ! kill -0 "$TUNNEL_PID" >/dev/null 2>&1; then
        break
      fi
      if curl -fsS --cacert "${STEP_ROOT_CA_FILE}" "${CA_URL}/health" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    sleep 2
  done
  echo "step-ca port-forward did not become ready"
  exit 1
}

make_token() {
  local subject="$1"
  shift
  local cmd
  cmd=(step ca token "$subject" \
    --offline \
    --ca-url "$CA_URL" \
    --root "$STEP_ROOT_CA_FILE" \
    --provisioner "$PROVISIONER_NAME" \
    --key "$PROVISIONER_KEY_FILE" \
    --provisioner-password-file "$PROVISIONER_PASSWORD_FILE" \
    --not-after 15m)
  local san
  for san in "$@"; do
    cmd+=(--san "$san")
  done
  "${cmd[@]}"
}

install_step
ensure_ca_host_alias
start_port_forward
trap 'kill "${TUNNEL_PID:-0}" >/dev/null 2>&1 || true' EXIT

node_name="$(hostname -s)"
server_url="$(kubectl --kubeconfig "$ADMIN_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if [[ -z "$server_url" ]]; then
  echo "unable to resolve API server URL from $ADMIN_KUBECONFIG"
  exit 1
fi

mkdir -p /var/lib/kubelet/pki /etc/kubernetes
kubelet_key="/var/lib/kubelet/pki/kubelet-client.key"
kubelet_csr="/var/lib/kubelet/pki/kubelet-client.csr"
kubelet_crt="/var/lib/kubelet/pki/kubelet-client.crt"

csr_template="$(mktemp)"
cat >"$csr_template" <<'EOT'
{
  "subject": {
    "commonName": "{{ .Subject.CommonName }}",
    "organization": ["system:nodes"]
  }
}
EOT
step certificate create "system:node:${node_name}" "$kubelet_csr" "$kubelet_key" \
  --csr \
  --template "$csr_template" \
  --kty RSA \
  --size 2048 \
  --no-password \
  --insecure \
  --force

token="$(make_token "system:node:${node_name}" "${node_name}")"
step ca sign "$kubelet_csr" "$kubelet_crt" \
  --token "$token" \
  --ca-url "$CA_URL" \
  --root "$STEP_ROOT_CA_FILE" \
  --force

chmod 0600 "$kubelet_key"
chmod 0644 "$kubelet_crt"

tmp_kubeconfig="$(mktemp)"
KUBECONFIG="$tmp_kubeconfig" kubectl config set-cluster default \
  --server "$server_url" \
  --certificate-authority "$CA_CHAIN_FILE" \
  --embed-certs=true >/dev/null
KUBECONFIG="$tmp_kubeconfig" kubectl config set-credentials "system:node:${node_name}" \
  --client-certificate "$kubelet_crt" \
  --client-key "$kubelet_key" \
  --embed-certs=true >/dev/null
KUBECONFIG="$tmp_kubeconfig" kubectl config set-context default \
  --cluster default \
  --user "system:node:${node_name}" >/dev/null
KUBECONFIG="$tmp_kubeconfig" kubectl config use-context default >/dev/null
install -m 0600 "$tmp_kubeconfig" /etc/kubernetes/kubelet.conf
rm -f "$tmp_kubeconfig" "$kubelet_csr" "$csr_template"

echo "[$(date -u +%FT%TZ)] worker signer bootstrap finished"
