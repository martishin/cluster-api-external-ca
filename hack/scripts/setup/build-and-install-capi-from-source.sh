#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"
source "$SCRIPT_DIR/../utils/cache.sh"

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
mkdir -p "$(dirname "$CAPI_DIR")"

if [[ ! -d "$CAPI_DIR/.git" ]]; then
  log "cloning cluster-api into $CAPI_DIR"
  git clone https://github.com/kubernetes-sigs/cluster-api.git "$CAPI_DIR"
fi

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

IMAGES=(
  "${REGISTRY}/cluster-api-controller-${ARCH}:${TAG}"
  "${REGISTRY}/kubeadm-bootstrap-controller-${ARCH}:${TAG}"
  "${REGISTRY}/kubeadm-control-plane-controller-${ARCH}:${TAG}"
)

image_tar_path() {
  local image="$1"
  local name
  name="${image##*/}"
  name="${name%%:*}"
  echo "$IMAGE_CACHE_DIR/${name}.tar"
}

cache_images_to_tar() {
  mkdir -p "$IMAGE_CACHE_DIR"
  local image tar_path
  for image in "${IMAGES[@]}"; do
    tar_path="$(image_tar_path "$image")"
    log "caching image tar: $tar_path"
    docker save "$image" -o "$tar_path"
  done
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

if [[ "$OPERATION" == "build" || "$OPERATION" == "build-install" ]]; then
  should_build=true

  if [[ "$FORCE_REBUILD" == "true" ]]; then
    log "force rebuild enabled (FORCE_REBUILD=true)"
  elif [[ "$SKIP_BUILD_IF_PRESENT" == "true" ]]; then
    for image in "${IMAGES[@]}"; do
      load_cached_image_if_needed "$image"
    done
    should_build=false
    for image in "${IMAGES[@]}"; do
      if ! docker image inspect "$image" >/dev/null 2>&1; then
        should_build=true
        break
      fi
    done
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
    mkdir -p "$IMAGE_CACHE_DIR"
    for image in "${IMAGES[@]}"; do
      if [[ ! -f "$(image_tar_path "$image")" ]] && docker image inspect "$image" >/dev/null 2>&1; then
        log "backfilling missing image tar cache for $image"
        docker save "$image" -o "$(image_tar_path "$image")"
      fi
    done
  fi
fi

if [[ "$OPERATION" == "install" || "$OPERATION" == "build-install" ]]; then
  for image in "${IMAGES[@]}"; do
    load_cached_image_if_needed "$image"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      echo "required image is missing locally: $image" >&2
      echo "run with OPERATION=build-install or set FORCE_REBUILD=true" >&2
      echo "expected cache tar: $(image_tar_path "$image")" >&2
      exit 1
    fi
    log "loading image into kind: $image"
    kind load docker-image "$image" --name capi-mgmt
  done

  for ns in capi-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system capd-system; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      echo "required namespace missing: $ns" >&2
      echo "run hack/scripts/setup/bootstrap-management-cluster.sh first" >&2
      exit 1
    fi
  done

  log "updating CAPI deployments to local images"
  kubectl -n capi-system set image deployment/capi-controller-manager \
    manager="${REGISTRY}/cluster-api-controller-${ARCH}:${TAG}"
  kubectl -n capi-kubeadm-bootstrap-system set image deployment/capi-kubeadm-bootstrap-controller-manager \
    manager="${REGISTRY}/kubeadm-bootstrap-controller-${ARCH}:${TAG}"
  kubectl -n capi-kubeadm-control-plane-system set image deployment/capi-kubeadm-control-plane-controller-manager \
    manager="${REGISTRY}/kubeadm-control-plane-controller-${ARCH}:${TAG}"

  log "re-applying CABPK/KCP CRDs from local CAPI source"
  kubectl apply -f "$CAPI_DIR/bootstrap/kubeadm/config/crd/bases/bootstrap.cluster.x-k8s.io_kubeadmconfigs.yaml"
  kubectl apply -f "$CAPI_DIR/bootstrap/kubeadm/config/crd/bases/bootstrap.cluster.x-k8s.io_kubeadmconfigtemplates.yaml"
  kubectl apply -f "$CAPI_DIR/controlplane/kubeadm/config/crd/bases/controlplane.cluster.x-k8s.io_kubeadmcontrolplanes.yaml"
  kubectl apply -f "$CAPI_DIR/controlplane/kubeadm/config/crd/bases/controlplane.cluster.x-k8s.io_kubeadmcontrolplanetemplates.yaml"

  if [[ "$APPLY_PATCH" == "true" ]]; then
    log "ensuring externalCA schema exists in v1beta1 CRDs"
    kubectl get crd kubeadmconfigs.bootstrap.cluster.x-k8s.io -o json | jq '
      .spec.versions |= map(
        if .name=="v1beta1" then
          .schema.openAPIV3Schema.properties.spec.properties.externalCA = {
            "description":"ExternalCA enables External CA mode of kubeadm.",
            "type":"boolean"
          }
        else . end
      )' | kubectl apply -f -

    kubectl get crd kubeadmconfigtemplates.bootstrap.cluster.x-k8s.io -o json | jq '
      .spec.versions |= map(
        if .name=="v1beta1" then
          .schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.externalCA = {
            "description":"ExternalCA enables External CA mode of kubeadm.",
            "type":"boolean"
          }
        else . end
      )' | kubectl apply -f -

    kubectl get crd kubeadmcontrolplanes.controlplane.cluster.x-k8s.io -o json | jq '
      .spec.versions |= map(
        if .name=="v1beta1" then
          .schema.openAPIV3Schema.properties.spec.properties.kubeadmConfigSpec.properties.externalCA = {
            "description":"ExternalCA enables External CA mode of kubeadm.",
            "type":"boolean"
          }
        else . end
      )' | kubectl apply -f -

    kubectl get crd kubeadmcontrolplanetemplates.controlplane.cluster.x-k8s.io -o json | jq '
      .spec.versions |= map(
        if .name=="v1beta1" then
          .schema.openAPIV3Schema.properties.spec.properties.template.properties.spec.properties.kubeadmConfigSpec.properties.externalCA = {
            "description":"ExternalCA enables External CA mode of kubeadm.",
            "type":"boolean"
          }
        else . end
      )' | kubectl apply -f -
  fi

  log "waiting for CAPI deployments rollout"
  kubectl -n capi-system rollout status deployment/capi-controller-manager --timeout=5m
  kubectl -n capi-kubeadm-bootstrap-system rollout status deployment/capi-kubeadm-bootstrap-controller-manager --timeout=5m
  kubectl -n capi-kubeadm-control-plane-system rollout status deployment/capi-kubeadm-control-plane-controller-manager --timeout=5m
fi

log "CAPI operation completed (operation=$OPERATION mode=$APPLY_PATCH ref=$CAPI_VERSION)"
