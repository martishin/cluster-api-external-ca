#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/mode-config.sh"

MODE="$(mode_from_args "${1:-}")"
mode_config "$MODE"
CAPI_VERSION="${CAPI_VERSION:-v1.8.8}"

APPLY_PATCH="${MODE_CFG_APPLY_PATCH}"
TAG="${TAG:-$MODE_CFG_TAG}"

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
