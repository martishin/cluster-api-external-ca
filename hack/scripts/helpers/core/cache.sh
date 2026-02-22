#!/usr/bin/env bash

cache_root_dir() {
  echo "${BUILD_CACHE_DIR:-$ROOT_DIR/bin/cache}"
}

cache_patch_hash() {
  local apply_patch="$1"
  local patch_file="$2"

  if [[ "$apply_patch" != "true" ]]; then
    echo "none"
    return 0
  fi
  if [[ ! -f "$patch_file" ]]; then
    echo "missing patch file for cache key: $patch_file" >&2
    return 1
  fi

  git hash-object "$patch_file"
}

capi_patch_hash() {
  local apply_patch="$1"
  local patch_file="$2"
  cache_patch_hash "$apply_patch" "$patch_file"
}

capi_cache_bucket() {
  local _capi_ref="$1"
  local apply_patch="$2"
  local patch_file="$3"
  local patch_hash

  if [[ "$apply_patch" == "true" ]]; then
    patch_hash="$(capi_patch_hash "$apply_patch" "$patch_file")" || return 1
    echo "patched/${patch_hash}"
    return 0
  fi
  echo "upstream"
}

capi_source_key_raw() {
  local capi_ref="$1"
  local apply_patch="$2"
  local patch_file="$3"
  local patch_hash

  patch_hash="$(cache_patch_hash "$apply_patch" "$patch_file")" || return 1

  cat <<EOF
capi_ref=$capi_ref
apply_patch=$apply_patch
patch_hash=$patch_hash
EOF
}

capi_source_id() {
  local raw
  raw="$(capi_source_key_raw "$@")" || return 1
  printf '%s' "$raw" | git hash-object --stdin
}
