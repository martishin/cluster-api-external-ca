#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

SETUP_MODE="${SETUP_MODE:-upstream}" # one of: upstream, patched
export KUBECONFIG="$MGMT_KUBECONFIG"

case "$SETUP_MODE" in
  upstream|patched) ;;
  *)
    echo "unsupported SETUP_MODE: $SETUP_MODE (expected upstream|patched)" >&2
    exit 1
    ;;
esac

cleanup_stale_capd_resources() {
  if kind get clusters | grep -qx capi-mgmt; then
    log "cleaning up stale CAPD resources from previous runs via kubectl"
    kind get kubeconfig --name capi-mgmt > "$MGMT_KUBECONFIG" || true
    export KUBECONFIG="$MGMT_KUBECONFIG"
    kubectl -n default delete cluster self-signed-ca-cluster external-ca-cluster --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n default wait --for=delete cluster/self-signed-ca-cluster --timeout=10m >/dev/null 2>&1 || true
    kubectl -n default wait --for=delete cluster/external-ca-cluster --timeout=10m >/dev/null 2>&1 || true
  fi
}

reset_management_cluster() {
  log "resetting kind management cluster for clean setup isolation"
  cleanup_stale_capd_resources
  kind delete cluster --name capi-mgmt >/dev/null 2>&1 || true
  "$POC_DIR/scripts/setup/cleanup-local-capd-artifacts.sh"
  rm -rf "$OUT_DIR/results" "$OUT_DIR/external-ca" "$OUT_DIR/self-signed-ca"
  rm -rf "$MGMT_WORK_DIR"
  mkdir -p "$MGMT_WORK_DIR"
}

"$POC_DIR/scripts/setup/check-prereqs.sh"
reset_management_cluster

log "bootstrapping management cluster"
"$POC_DIR/scripts/setup/bootstrap-management-cluster.sh"

if [[ "$SETUP_MODE" == "upstream" ]]; then
  log "building and installing upstream CAPI from source"
  APPLY_PATCH=false TAG="external-ca-upstream-dev" CAPI_REF="${CAPI_REF:-v1.8.8}" CAPI_VERSION="${CAPI_VERSION:-v1.8.8}" \
    "$POC_DIR/scripts/setup/build-and-install-capi-from-source.sh"

  log "deploying upstream self-signed workload cluster"
  "$POC_DIR/scripts/deploy/deploy-self-signed-ca-on-upstream.sh"
fi

if [[ "$SETUP_MODE" == "patched" ]]; then
  log "building and installing patched CAPI from source"
  APPLY_PATCH=true TAG="external-ca-dev" CAPI_REF="${CAPI_REF:-v1.8.8}" CAPI_VERSION="${CAPI_VERSION:-v1.8.8}" \
    "$POC_DIR/scripts/setup/build-and-install-capi-from-source.sh"

  log "installing mock external signer stack"
  CLUSTER_NAME=external-ca-cluster "$POC_DIR/scripts/mock/install-mock-ca-signer-stack.sh"

  log "deploying external-ca cluster with kmsservice gRPC+mTLS mock"
  "$POC_DIR/scripts/deploy/deploy-external-ca-kmsservice-mock.sh"
fi

log "setup flow completed successfully (mode=$SETUP_MODE)"
