#!/usr/bin/env bash

capi_image_list() {
  cat <<IMAGES
${REGISTRY}/cluster-api-controller-${ARCH}:${TAG}
${REGISTRY}/kubeadm-bootstrap-controller-${ARCH}:${TAG}
${REGISTRY}/kubeadm-control-plane-controller-${ARCH}:${TAG}
IMAGES
}

image_tar_path() {
  local image="$1"
  local name
  name="${image##*/}"
  name="${name%%:*}"
  echo "$IMAGE_CACHE_DIR/${name}.tar"
}

load_cached_image_if_needed() {
  local image="$1"
  local tar_path
  tar_path="$(image_tar_path "$image")"

  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$tar_path" ]]; then
    log "loading cached image tar: $tar_path"
    docker load -i "$tar_path" >/dev/null
  fi
}

cache_images_to_tar() {
  local image tar_path
  mkdir -p "$IMAGE_CACHE_DIR"
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    tar_path="$(image_tar_path "$image")"
    log "caching image tar: $tar_path"
    docker save "$image" -o "$tar_path"
  done < <(capi_image_list)
}

ensure_image_cache_backfill() {
  local image tar_path
  mkdir -p "$IMAGE_CACHE_DIR"
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    tar_path="$(image_tar_path "$image")"
    if [[ ! -f "$tar_path" ]] && docker image inspect "$image" >/dev/null 2>&1; then
      log "backfilling missing image tar cache for $image"
      docker save "$image" -o "$tar_path"
    fi
  done < <(capi_image_list)
}

build_capi_images() {
  local should_build=true image

  if [[ "$FORCE_REBUILD" == "true" ]]; then
    log "force rebuild enabled (FORCE_REBUILD=true)"
  elif [[ "$SKIP_BUILD_IF_PRESENT" == "true" ]]; then
    while IFS= read -r image; do
      [[ -n "$image" ]] || continue
      load_cached_image_if_needed "$image"
    done < <(capi_image_list)

    should_build=false
    while IFS= read -r image; do
      [[ -n "$image" ]] || continue
      if ! docker image inspect "$image" >/dev/null 2>&1; then
        should_build=true
        break
      fi
    done < <(capi_image_list)
  fi

  if [[ "$should_build" == "true" ]]; then
    log "building CAPI controller images (tag=$TAG arch=$ARCH)"
    (
      cd "$CAPI_DIR"
      make REGISTRY="$REGISTRY" ALL_DOCKER_BUILD="core kubeadm-bootstrap kubeadm-control-plane" docker-build TAG="$TAG"
    )
    cache_images_to_tar
  else
    log "skipping build: controller images already present for tag=$TAG arch=$ARCH"
    ensure_image_cache_backfill
  fi
}
