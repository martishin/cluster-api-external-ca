#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/env.sh"
source "$SCRIPT_DIR/utils/flow.sh"

MODE="$(mode_from_args "${1:-}")"
CAPI_VERSION="${CAPI_VERSION:-v1.8.8}"

case "$MODE" in
  self-signed)
    APPLY_PATCH=false
    TAG="${TAG:-external-ca-upstream-dev}"
    ;;
  external-ca)
    APPLY_PATCH=true
    TAG="${TAG:-external-ca-dev}"
    ;;
esac

log "initializing CAPI providers in management cluster"
APPLY_PATCH="$APPLY_PATCH" \
PATCH_FILE="$POC_DIR/capi-patches/0001-external-ca-bootstrap.patch" \
TAG="$TAG" \
CAPI_VERSION="$CAPI_VERSION" \
CAPI_REF="${CAPI_REF:-$CAPI_VERSION}" \
"$POC_DIR/scripts/setup/bootstrap-management-cluster.sh"

log "installing built CAPI images for mode=$MODE"
APPLY_PATCH="$APPLY_PATCH" \
TAG="$TAG" \
CAPI_REF="${CAPI_REF:-$CAPI_VERSION}" \
CAPI_VERSION="$CAPI_VERSION" \
OPERATION=install \
"$POC_DIR/scripts/setup/build-and-install-capi-from-source.sh"
