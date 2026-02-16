#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

CAPI_VERSION="${CAPI_VERSION:-v1.8.8}"

require_bin clusterctl
CLUSTERCTL_BIN="$(command -v clusterctl)"
log "using clusterctl from PATH: $CLUSTERCTL_BIN"

if ! kind get clusters | grep -qx capi-mgmt; then
  log "creating kind management cluster capi-mgmt"
  kind create cluster --name capi-mgmt --config "$POC_DIR/env/kind-mgmt.yaml" --kubeconfig "$MGMT_KUBECONFIG"
else
  log "kind cluster capi-mgmt already exists"
fi

log "writing kind kubeconfig to $MGMT_KUBECONFIG"
mkdir -p "$(dirname "$MGMT_KUBECONFIG")"
kind get kubeconfig --name capi-mgmt > "$MGMT_KUBECONFIG"

if kubectl get ns capi-system >/dev/null 2>&1; then
  log "CAPI core namespace already exists; skipping clusterctl init"
else
  log "initializing CAPI providers pinned to ${CAPI_VERSION} (core/bootstrap/controlplane/infrastructure-docker)"
  "$CLUSTERCTL_BIN" init \
    --core "cluster-api:${CAPI_VERSION}" \
    --bootstrap "kubeadm:${CAPI_VERSION}" \
    --control-plane "kubeadm:${CAPI_VERSION}" \
    --infrastructure "docker:${CAPI_VERSION}"
fi

log "provider pods status"
kubectl get pods -A | grep -E 'capi-|capd-' || true
