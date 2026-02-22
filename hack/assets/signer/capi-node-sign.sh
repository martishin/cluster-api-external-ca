#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/capi-node-sign.log"
exec >>"$LOG_FILE" 2>&1
echo "[$(date -u +%FT%TZ)] starting node signer bootstrap"

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
  grep -v "[[:space:]]${CA_HOST}$" /etc/hosts >/etc/hosts.capi-node-sign || true
  echo "127.0.0.1 ${CA_HOST}" >> /etc/hosts.capi-node-sign
  cat /etc/hosts.capi-node-sign > /etc/hosts
  rm -f /etc/hosts.capi-node-sign
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
      >/var/log/capi-node-sign-port-forward.log 2>&1 &
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

uniq_sans() {
  awk 'NF && !seen[$0]++'
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

issue_cert() {
  local subject="$1"
  local crt_path="$2"
  local key_path="$3"
  shift 3
  local token
  token="$(make_token "$subject" "$@")"
  step ca certificate "$subject" "$crt_path" "$key_path" \
    --token "$token" \
    --ca-url "$CA_URL" \
    --root "$STEP_ROOT_CA_FILE" \
    --force
  chmod 0644 "$crt_path"
  chmod 0600 "$key_path"
}

mkdir -p /etc/kubernetes/pki/etcd /etc/kubernetes/pki/step
install_step
ensure_ca_host_alias
start_port_forward
trap 'kill "${TUNNEL_PID:-0}" >/dev/null 2>&1 || true' EXIT

node_name="$(hostname -s)"
endpoint_host="$(kubectl --kubeconfig "$ADMIN_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed -E 's#^https?://([^/:]+).*#\1#' || true)"

mapfile -t node_ips < <(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF')

mapfile -t apiserver_sans < <(
  {
    printf '%s\n' "kubernetes" "kubernetes.default" "kubernetes.default.svc" "kubernetes.default.svc.cluster.local" "10.96.0.1" "localhost" "127.0.0.1" "::1"
    printf '%s\n' "$node_name"
    [[ -n "$endpoint_host" ]] && printf '%s\n' "$endpoint_host"
    printf '%s\n' "${node_ips[@]}"
  } | uniq_sans
)

mapfile -t etcd_sans < <(
  {
    printf '%s\n' "localhost" "127.0.0.1" "::1"
    printf '%s\n' "$node_name"
    printf '%s\n' "${node_ips[@]}"
  } | uniq_sans
)

issue_cert "kube-apiserver" "/etc/kubernetes/pki/apiserver.crt" "/etc/kubernetes/pki/apiserver.key" "${apiserver_sans[@]}"
issue_cert "kube-etcd" "/etc/kubernetes/pki/etcd/server.crt" "/etc/kubernetes/pki/etcd/server.key" "${etcd_sans[@]}"
issue_cert "kube-etcd-peer" "/etc/kubernetes/pki/etcd/peer.crt" "/etc/kubernetes/pki/etcd/peer.key" "${etcd_sans[@]}"

echo "[$(date -u +%FT%TZ)] node signer bootstrap finished"
