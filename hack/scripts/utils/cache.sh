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

# Backward compatible wrapper to support existing callsites while key format
# migrates to source identity only.
capi_cache_key_raw() {
  local capi_ref apply_patch patch_file

  if [[ $# -eq 3 ]]; then
    capi_ref="$1"
    apply_patch="$2"
    patch_file="$3"
  elif [[ $# -eq 4 ]]; then
    # Old format without mode/tag.
    capi_ref="$2"
    apply_patch="$3"
    patch_file="$4"
  elif [[ $# -eq 6 ]]; then
    # Old format with mode/tag.
    capi_ref="$3"
    apply_patch="$5"
    patch_file="$6"
  else
    echo "capi_cache_key_raw expects 3, 4, or 6 args, got: $#" >&2
    return 1
  fi

  capi_source_key_raw "$capi_ref" "$apply_patch" "$patch_file"
}

capi_cache_id() {
  local raw
  raw="$(capi_cache_key_raw "$@")" || return 1
  printf '%s' "$raw" | git hash-object --stdin
}
