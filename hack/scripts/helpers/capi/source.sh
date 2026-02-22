#!/usr/bin/env bash

ensure_capi_repo() {
  mkdir -p "$(dirname "$CAPI_DIR")"
  if [[ ! -d "$CAPI_DIR/.git" ]]; then
    log "cloning cluster-api into $CAPI_DIR"
    git clone https://github.com/kubernetes-sigs/cluster-api.git "$CAPI_DIR"
  fi
}

prepare_capi_source() {
  log "preparing CAPI source at ref $CAPI_REF"
  git -C "$CAPI_DIR" fetch --tags --prune
  git -C "$CAPI_DIR" checkout "$CAPI_REF"
  git -C "$CAPI_DIR" reset --hard "$CAPI_REF"
  git -C "$CAPI_DIR" clean -fd

  if [[ "$APPLY_PATCH" == "true" ]]; then
    if [[ ! -f "$PATCH_FILE" ]]; then
      echo "patch file not found: $PATCH_FILE" >&2
      exit 1
    fi
    if ! git -C "$CAPI_DIR" apply --check "$PATCH_FILE"; then
      echo "patch cannot be applied cleanly to $CAPI_REF: $PATCH_FILE" >&2
      exit 1
    fi
    log "applying patch $(basename "$PATCH_FILE")"
    git -C "$CAPI_DIR" apply "$PATCH_FILE"
  else
    log "building upstream CAPI without local patches"
  fi
}
