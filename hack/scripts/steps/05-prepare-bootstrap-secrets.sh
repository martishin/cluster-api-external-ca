#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/mode-config.sh"
source "$SCRIPT_DIR/../helpers/core/step-ca.sh"

MODE="$(mode_from_args "${1:-}")"
if [[ "$MODE" != "external-ca" ]]; then
  log "bootstrap secret preparation is not required for mode=$MODE"
  exit 0
fi

require_bin kubectl cp openssl

cluster_name="$(cluster_name_for_mode "$MODE")"
namespace="${NAMESPACE:-default}"
bootstrap_pki_dir="${BOOTSTRAP_PKI_DIR:-$OUT_DIR/workload/bootstrap-pki}"
refresh_script="$POC_DIR/scripts/setup/external-ca-bootstrap-pki.sh"
bundle_dir="$(stepca_bundle_dir bootstrap)"
ca_password_file="$bundle_dir/secrets/password"
intermediate_key_file="$bundle_dir/secrets/intermediate_ca_key"
intermediate_crt_file="$bundle_dir/certs/intermediate_ca.crt"
root_crt_file="$bundle_dir/certs/root_ca.crt"

if [[ ! -s "$intermediate_crt_file" || ! -s "$intermediate_key_file" || ! -s "$root_crt_file" ]]; then
  echo "missing bootstrap step-ca bundle files in $bundle_dir" >&2
  exit 1
fi
if [[ ! -s "$ca_password_file" ]]; then
  ca_password_file="$bundle_dir/password.txt"
fi
if [[ ! -s "$ca_password_file" ]]; then
  echo "missing step-ca password file in bundle: $bundle_dir" >&2
  exit 1
fi

mkdir -p "$bootstrap_pki_dir"
build_ca_chain_file() {
  local out_file="$1"
  cp "$intermediate_crt_file" "$out_file"
}

build_ca_chain_file "$bootstrap_pki_dir/cluster-ca.crt"
build_ca_chain_file "$bootstrap_pki_dir/front-proxy-ca.crt"
build_ca_chain_file "$bootstrap_pki_dir/etcd-ca.crt"

for key_file in cluster-ca.key front-proxy-ca.key etcd-ca.key; do
  openssl pkey -in "$intermediate_key_file" -passin "file:$ca_password_file" -out "$bootstrap_pki_dir/$key_file" >/dev/null 2>&1
done

log "creating external-ca bootstrap secrets from step-ca generated intermediate CA"
bootstrap_server_default="https://${cluster_name}-lb:6443"
CLUSTER_NAME="$cluster_name" \
NAMESPACE="$namespace" \
BOOTSTRAP_PKI_DIR="$bootstrap_pki_dir" \
KUBECONFIG_SERVER="${KUBECONFIG_SERVER:-$bootstrap_server_default}" \
"$refresh_script"

log "external-ca bootstrap PKI secrets are ready for cluster=$cluster_name namespace=$namespace"
