#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/step-ca.sh"

MODE="${1:-${FLOW_MODE:-external-ca}}"
if [[ "$MODE" != "self-signed" && "$MODE" != "external-ca" ]]; then
  echo "unsupported mode: $MODE (expected self-signed|external-ca)" >&2
  exit 1
fi

bundle_dir="$(stepca_bundle_dir bootstrap)"
dns_name="${STEPCA_NAME}.${STEPCA_NAMESPACE}.svc.cluster.local"

stepca_generate_bundle "$bundle_dir" "$dns_name"
stepca_apply_bundle "$MGMT_KUBECONFIG" "$bundle_dir" "$STEPCA_NAMESPACE" "$STEPCA_NAME"

log "bootstrap step-ca deployed in management cluster (mode=$MODE)"
