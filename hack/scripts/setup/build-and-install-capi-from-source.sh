#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/cache.sh"
source "$SCRIPT_DIR/../helpers/capi/source.sh"
source "$SCRIPT_DIR/../helpers/capi/build.sh"
source "$SCRIPT_DIR/../helpers/capi/install.sh"

require_bin git make docker kind kubectl go jq

CAPI_REF="${CAPI_REF:-v1.8.8}"
CAPI_VERSION="${CAPI_VERSION:-$CAPI_REF}"
CAPI_DIR="${CAPI_DIR:-$ROOT_DIR/bin/cluster-api}"
PATCH_FILE="${PATCH_FILE:-$POC_DIR/capi-patches/0001-external-ca-bootstrap.patch}"
APPLY_PATCH="${APPLY_PATCH:-true}"
ARCH="${ARCH:-$(go env GOARCH)}"
REGISTRY="${REGISTRY:-gcr.io/k8s-staging-cluster-api}"
OPERATION="${OPERATION:-build-install}" # build | install | build-install
SKIP_BUILD_IF_PRESENT="${SKIP_BUILD_IF_PRESENT:-true}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
IMAGE_CACHE_ROOT="${IMAGE_CACHE_ROOT:-$ROOT_DIR/bin/capi-images}"

case "$OPERATION" in
  build|install|build-install) ;;
  *)
    echo "OPERATION must be build|install|build-install, got: $OPERATION" >&2
    exit 1
    ;;
esac

case "$SKIP_BUILD_IF_PRESENT" in
  true|false) ;;
  *)
    echo "SKIP_BUILD_IF_PRESENT must be true|false, got: $SKIP_BUILD_IF_PRESENT" >&2
    exit 1
    ;;
esac

case "$FORCE_REBUILD" in
  true|false) ;;
  *)
    echo "FORCE_REBUILD must be true|false, got: $FORCE_REBUILD" >&2
    exit 1
    ;;
esac

case "$APPLY_PATCH" in
  true)
    TAG="${TAG:-external-ca-dev}"
    ;;
  false)
    TAG="${TAG:-external-ca-upstream-dev}"
    ;;
  *)
    echo "APPLY_PATCH must be true|false, got: $APPLY_PATCH" >&2
    exit 1
    ;;
esac

CACHE_BUCKET="$(capi_cache_bucket "$CAPI_REF" "$APPLY_PATCH" "$PATCH_FILE")"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-$IMAGE_CACHE_ROOT/$CAPI_REF/$CACHE_BUCKET}"

mkdir -p "$MGMT_WORK_DIR"

ensure_capi_repo
prepare_capi_source

if [[ "$OPERATION" == "build" || "$OPERATION" == "build-install" ]]; then
  build_capi_images
fi

if [[ "$OPERATION" == "install" || "$OPERATION" == "build-install" ]]; then
  install_capi_images
fi

log "CAPI operation completed (operation=$OPERATION mode=$APPLY_PATCH ref=$CAPI_VERSION)"
