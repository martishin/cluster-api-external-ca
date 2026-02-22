#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/mode-config.sh"
source "$SCRIPT_DIR/../helpers/core/cache.sh"

MODE="$(mode_from_args "${1:-}")"
mode_config "$MODE"
CAPI_VERSION="${CAPI_VERSION:-v1.8.8}"
CAPI_REF="${CAPI_REF:-$CAPI_VERSION}"
ARCH="${ARCH:-$(go env GOARCH)}"
cache_dir="$(cache_root_dir)"

APPLY_PATCH="${MODE_CFG_APPLY_PATCH}"
TAG="${TAG:-$MODE_CFG_TAG}"

cache_key="$(capi_source_key_raw "$CAPI_REF" "$APPLY_PATCH" "$POC_DIR/capi-patches/0001-external-ca-bootstrap.patch")"
cache_id="$(capi_source_id "$CAPI_REF" "$APPLY_PATCH" "$POC_DIR/capi-patches/0001-external-ca-bootstrap.patch")"
cache_stamp="$cache_dir/capi-build-${cache_id}.stamp"

mkdir -p "$cache_dir"
if [[ "${FORCE_REBUILD:-}" != "true" ]]; then
  if [[ -f "$cache_stamp" ]]; then
    FORCE_REBUILD=false
  else
    FORCE_REBUILD=true
    log "capi build cache miss (id=$cache_id); forcing rebuild"
  fi
fi

log "building CAPI images for mode=$MODE capi=$CAPI_VERSION patch=$APPLY_PATCH force_rebuild=$FORCE_REBUILD"
APPLY_PATCH="$APPLY_PATCH" \
TAG="$TAG" \
CAPI_REF="$CAPI_REF" \
CAPI_VERSION="$CAPI_VERSION" \
FORCE_REBUILD="$FORCE_REBUILD" \
OPERATION=build \
"$POC_DIR/scripts/setup/build-and-install-capi-from-source.sh"

printf '%s' "$cache_key" > "$cache_stamp"
