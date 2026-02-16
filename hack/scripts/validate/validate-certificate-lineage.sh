#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

require_bin kubectl openssl base64 sed awk
ensure_out_dirs

NS="${NS:-default}"
EXTERNAL_CLUSTER_NAME="${EXTERNAL_CLUSTER_NAME:-external-ca-cluster}"
EXTERNAL_KUBECONFIG="${EXTERNAL_KUBECONFIG:-$OUT_DIR/external-ca/kubeconfig}"
KMSSERVICE_KUBERNETES_CA_CERT="${KMSSERVICE_KUBERNETES_CA_CERT:-$OUT_DIR/kmsservice-mock/kubernetes-ca.crt}"
RESULTS_DIR="${RESULTS_DIR:-$OUT_DIR/results/ca-source}"
EXPECTED_MODE="${EXPECTED_MODE:-auto}" # auto|self-signed|external-ca

case "$EXPECTED_MODE" in
  auto|self-signed|external-ca) ;;
  *)
    echo "unsupported EXPECTED_MODE: $EXPECTED_MODE (expected auto|self-signed|external-ca)" >&2
    exit 1
    ;;
esac

mkdir -p "$RESULTS_DIR"

require_expected_mode() {
  local detected_mode="$1"
  if [[ "$EXPECTED_MODE" != "auto" && "$EXPECTED_MODE" != "$detected_mode" ]]; then
    echo "FAIL: detected mode is '$detected_mode', but EXPECTED_MODE is '$EXPECTED_MODE'" >&2
    exit 1
  fi
}

has_external_cluster_secret() {
  kubectl -n "$NS" get secret "${EXTERNAL_CLUSTER_NAME}-ca" >/dev/null 2>&1
}

has_self_signed_cluster_secret() {
  kubectl -n "$NS" get secret "self-signed-ca-cluster-ca" >/dev/null 2>&1
}

secret_has_tls_key() {
  kubectl -n "$NS" get secret "${EXTERNAL_CLUSTER_NAME}-ca" -o jsonpath='{.data.tls\.key}' | grep -q .
}

external_ca_crt_from_secret() {
  local out_file="$1"
  kubectl -n "$NS" get secret "${EXTERNAL_CLUSTER_NAME}-ca" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$out_file"
}

sha256_fp() {
  local cert_file="$1"
  openssl x509 -in "$cert_file" -noout -fingerprint -sha256 | awk -F= '{print $2}'
}

subject_rfc2253() {
  local cert_file="$1"
  openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'
}

ensure_self_signed_kubeconfig() {
  local self_signed="${OUT_DIR}/self-signed-ca/kubeconfig"
  if [[ -f "$self_signed" ]]; then
    echo "$self_signed"
    return 0
  fi

  local fallback="$RESULTS_DIR/self-signed-ca-cluster.kubeconfig"
  if write_kubeconfig_from_secret "$NS" "self-signed-ca-cluster" "$fallback" 30 2; then
    echo "$fallback"
    return 0
  fi
  return 1
}

ensure_external_kubeconfig() {
  if [[ -f "$EXTERNAL_KUBECONFIG" ]]; then
    echo "$EXTERNAL_KUBECONFIG"
    return 0
  fi

  local fallback="$RESULTS_DIR/${EXTERNAL_CLUSTER_NAME}.kubeconfig"
  if write_kubeconfig_from_secret "$NS" "$EXTERNAL_CLUSTER_NAME" "$fallback" 30 2; then
    echo "$fallback"
    return 0
  fi

  return 1
}

if ! has_external_cluster_secret; then
  if has_self_signed_cluster_secret; then
    require_expected_mode "self-signed"
    log "detected upstream self-signed flow (self-signed-ca-cluster)"
    if ! kubectl -n "$NS" get secret self-signed-ca-cluster-ca -o jsonpath='{.data.tls\.key}' | grep -q .; then
      echo "FAIL: expected tls.key in self-signed-ca-cluster-ca" >&2
      exit 1
    fi
    log "PASS: self-signed-ca-cluster-ca contains tls.key"

    self_signed_kubeconfig="$(ensure_self_signed_kubeconfig || true)"
    if [[ -z "${self_signed_kubeconfig:-}" ]]; then
      echo "missing self-signed kubeconfig; run make setup-self-signed-ca first" >&2
      exit 1
    fi
    if ! wait_kube_api_ready "$self_signed_kubeconfig"; then
      echo "FAIL: self-signed workload API is not reachable via $self_signed_kubeconfig" >&2
      exit 1
    fi
    cp_node="$(control_plane_node_from_kubeconfig "$self_signed_kubeconfig" || true)"
    if [[ -z "$cp_node" ]]; then
      echo "FAIL: could not resolve control-plane node from $self_signed_kubeconfig" >&2
      exit 1
    fi
    if node_file_exists_via_kubectl_debug "$self_signed_kubeconfig" "$cp_node" /etc/kubernetes/pki/ca.key; then
      log "PASS: control-plane node has /etc/kubernetes/pki/ca.key"
    else
      echo "FAIL: expected /etc/kubernetes/pki/ca.key on $cp_node" >&2
      exit 1
    fi
    kubectl -n "$NS" get secret self-signed-ca-cluster-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$RESULTS_DIR/self-signed-ca-cluster-ca.crt"
    openssl x509 -in "$RESULTS_DIR/self-signed-ca-cluster-ca.crt" -noout -subject -issuer > "$RESULTS_DIR/upstream-ca-subject-issuer.txt"
    log "verification complete for upstream self-signed flow; results stored in $RESULTS_DIR"
    exit 0
  fi

  if [[ -f "$OUT_DIR/results/upstream-external-ca-rejected.txt" ]]; then
    if [[ "$EXPECTED_MODE" != "auto" ]]; then
      echo "FAIL: found only upstream externalCA rejection results, but EXPECTED_MODE is '$EXPECTED_MODE'" >&2
      exit 1
    fi
    log "PASS: upstream flow results found: externalCA field rejected by upstream CAPI"
    cp "$OUT_DIR/results/upstream-external-ca-rejected.txt" "$RESULTS_DIR/upstream-external-ca-rejected.txt"
    exit 0
  fi
  echo "missing secret ${EXTERNAL_CLUSTER_NAME}-ca in namespace ${NS}" >&2
  echo "run make setup-self-signed-ca or make setup-external-ca first" >&2
  exit 1
fi

EXTERNAL_CA_CRT="$RESULTS_DIR/${EXTERNAL_CLUSTER_NAME}-ca.crt"
external_ca_crt_from_secret "$EXTERNAL_CA_CRT"

if secret_has_tls_key; then
  if [[ "$EXPECTED_MODE" == "external-ca" ]]; then
    echo "FAIL: detected upstream CA-key mode, but EXPECTED_MODE is 'external-ca'" >&2
    exit 1
  fi
  log "detected upstream CA path (tls.key present in ${EXTERNAL_CLUSTER_NAME}-ca)"
  log "PASS: ${EXTERNAL_CLUSTER_NAME}-ca contains tls.key"

  external_kubeconfig="$(ensure_external_kubeconfig || true)"
  if [[ -z "${external_kubeconfig:-}" ]]; then
    echo "missing kubeconfig for control-plane key check: $EXTERNAL_KUBECONFIG" >&2
    echo "run make setup-self-signed-ca first" >&2
    exit 1
  fi
  if ! wait_kube_api_ready "$external_kubeconfig"; then
    echo "FAIL: workload API is not reachable via $external_kubeconfig" >&2
    exit 1
  fi

  cp_node="$(control_plane_node_from_kubeconfig "$external_kubeconfig" || true)"
  if [[ -z "$cp_node" ]]; then
    echo "FAIL: could not resolve control-plane node from $external_kubeconfig" >&2
    exit 1
  fi
  if node_file_exists_via_kubectl_debug "$external_kubeconfig" "$cp_node" /etc/kubernetes/pki/ca.key; then
    log "PASS: control-plane node has /etc/kubernetes/pki/ca.key"
  else
    echo "FAIL: expected /etc/kubernetes/pki/ca.key on $cp_node" >&2
    exit 1
  fi

  openssl x509 -in "$EXTERNAL_CA_CRT" -noout -subject -issuer > "$RESULTS_DIR/upstream-ca-subject-issuer.txt"
  log "verification complete for upstream flow; results stored in $RESULTS_DIR"
  exit 0
fi

require_expected_mode "external-ca"
log "detected external CA path (no tls.key in ${EXTERNAL_CLUSTER_NAME}-ca)"
log "PASS: ${EXTERNAL_CLUSTER_NAME}-ca has no tls.key"

if [[ ! -f "$KMSSERVICE_KUBERNETES_CA_CERT" ]]; then
  echo "missing KMSService kubernetes CA cert: $KMSSERVICE_KUBERNETES_CA_CERT" >&2
  echo "run make setup-external-ca first" >&2
  exit 1
fi
external_kubeconfig="$(ensure_external_kubeconfig || true)"
if [[ -z "${external_kubeconfig:-}" ]]; then
  echo "missing external cluster kubeconfig: $EXTERNAL_KUBECONFIG" >&2
  echo "run make setup-external-ca first" >&2
  exit 1
fi
if ! wait_kube_api_ready "$external_kubeconfig"; then
  echo "FAIL: external workload API is not reachable via $external_kubeconfig" >&2
  exit 1
fi

kmsservice_fp="$(sha256_fp "$KMSSERVICE_KUBERNETES_CA_CERT")"
external_fp="$(sha256_fp "$EXTERNAL_CA_CRT")"
{
  echo "kmsservice_fp=$kmsservice_fp"
  echo "external_fp=$external_fp"
} > "$RESULTS_DIR/fingerprints.txt"

if [[ "$external_fp" != "$kmsservice_fp" ]]; then
  echo "FAIL: external cluster CA does not match KMSService CA" >&2
  exit 1
fi
log "PASS: external cluster CA matches KMSService CA"

cp_node="$(control_plane_node_from_kubeconfig "$external_kubeconfig" || true)"
if [[ -z "$cp_node" ]]; then
  echo "FAIL: could not resolve control-plane node from $external_kubeconfig" >&2
  exit 1
fi
if node_file_exists_via_kubectl_debug "$external_kubeconfig" "$cp_node" /etc/kubernetes/pki/ca.key; then
  echo "FAIL: /etc/kubernetes/pki/ca.key should not exist on $cp_node" >&2
  exit 1
fi
log "PASS: control-plane node has no /etc/kubernetes/pki/ca.key"

apiserver_issuer="$(issuer_from_apiserver "$external_kubeconfig")"
external_ca_subject="$(subject_rfc2253 "$EXTERNAL_CA_CRT")"
{
  echo "apiserver_issuer=$apiserver_issuer"
  echo "external_ca_subject=$external_ca_subject"
} > "$RESULTS_DIR/apiserver-issuer.txt"

if [[ "$apiserver_issuer" != "$external_ca_subject" ]]; then
  echo "FAIL: apiserver issuer does not match external CA subject" >&2
  exit 1
fi
log "PASS: apiserver issuer matches external CA subject"
log "verification complete for external-ca flow; results stored in $RESULTS_DIR"
