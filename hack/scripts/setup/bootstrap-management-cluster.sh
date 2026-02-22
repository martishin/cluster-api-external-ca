#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"
source "$SCRIPT_DIR/../utils/cache.sh"

CAPI_VERSION="${CAPI_VERSION:-v1.8.8}"
CAPI_REF="${CAPI_REF:-$CAPI_VERSION}"
CAPI_DIR="${CAPI_DIR:-$ROOT_DIR/bin/cluster-api}"
APPLY_PATCH="${APPLY_PATCH:-false}"
PATCH_FILE="${PATCH_FILE:-$POC_DIR/capi-patches/0001-external-ca-bootstrap.patch}"
CLUSTERCTL_CACHE_ROOT="${CLUSTERCTL_CACHE_ROOT:-$ROOT_DIR/bin/clusterctl}"

case "$APPLY_PATCH" in
  true|false) ;;
  *)
    echo "APPLY_PATCH must be true|false, got: $APPLY_PATCH" >&2
    exit 1
    ;;
esac

require_bin git make go

ensure_clusterctl() {
  local bin cache_dir source_id cache_bucket cached_bin
  bin="$OUT_BIN_DIR/clusterctl-${CAPI_VERSION}"
  cache_dir=""
  mkdir -p "$OUT_BIN_DIR" "$(dirname "$CAPI_DIR")"

  if [[ ! -d "$CAPI_DIR/.git" ]]; then
    log "cloning cluster-api source into $CAPI_DIR"
    git clone https://github.com/kubernetes-sigs/cluster-api.git "$CAPI_DIR"
  fi

  log "preparing clusterctl from source ref ${CAPI_REF}"
  git -C "$CAPI_DIR" fetch --tags --prune
  git -C "$CAPI_DIR" checkout "$CAPI_REF"
  git -C "$CAPI_DIR" reset --hard "$CAPI_REF"
  git -C "$CAPI_DIR" clean -fd
  source_id="$(capi_source_id "$CAPI_REF" "$APPLY_PATCH" "$PATCH_FILE")"
  cache_bucket="$(capi_cache_bucket "$CAPI_REF" "$APPLY_PATCH" "$PATCH_FILE")"
  cache_dir="$CLUSTERCTL_CACHE_ROOT/$CAPI_REF/$cache_bucket"
  mkdir -p "$cache_dir"
  cached_bin="$cache_dir/clusterctl"

  if [[ "${FORCE_REBUILD_CLUSTERCTL:-false}" != "true" && -x "$cached_bin" ]]; then
    log "using cached clusterctl binary source_id=${source_id}"
  else
    log "building clusterctl for source_id=${source_id}"
    (cd "$CAPI_DIR" && make clusterctl)
    cp "$CAPI_DIR/bin/clusterctl" "$cached_bin"
    chmod +x "$cached_bin"
  fi

  cp "$cached_bin" "$bin"
  cp "$cached_bin" "$OUT_BIN_DIR/clusterctl"
  chmod +x "$bin" "$OUT_BIN_DIR/clusterctl"

  CLUSTERCTL_BIN="$bin"
}

CLUSTERCTL_BIN=""
ensure_clusterctl
log "using pinned clusterctl: $CLUSTERCTL_BIN"

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
