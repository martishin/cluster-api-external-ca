#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

require_bin git make docker kind kubectl

CAPI_REF="${CAPI_REF:-v1.8.8}"
CAPI_VERSION="${CAPI_VERSION:-$CAPI_REF}"
CAPI_DIR="${CAPI_DIR:-$ROOT_DIR/bin/cluster-api}"
PATCH_DIR="$POC_DIR/capi-patches"
APPLY_PATCH="${APPLY_PATCH:-true}"
TAG="${TAG:-external-ca-dev}"
ARCH="${ARCH:-$(go env GOARCH)}"
REGISTRY="${REGISTRY:-gcr.io/k8s-staging-cluster-api}"
IMAGE_CACHE_BASE_DIR="${IMAGE_CACHE_BASE_DIR:-$ROOT_DIR/bin/capi-images/$CAPI_REF/$TAG/$ARCH}"
PATCH_BUNDLE_HASH="upstream"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-}"
patch_files=()

mkdir -p "$MGMT_WORK_DIR"
mkdir -p "$(dirname "$CAPI_DIR")"

case "$APPLY_PATCH" in
  true|false) ;;
  *)
    echo "APPLY_PATCH must be true|false, got: $APPLY_PATCH" >&2
    exit 1
    ;;
esac

if [[ "$APPLY_PATCH" == "true" ]]; then
  mapfile -t patch_files < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | sort)
  if [[ "${#patch_files[@]}" -eq 0 ]]; then
    echo "no patch files were detected in $PATCH_DIR" >&2
    exit 1
  fi

  PATCH_BUNDLE_HASH="$(
    {
      for patch in "${patch_files[@]}"; do
        printf '%s  %s\n' "$(git hash-object "$patch")" "$(basename "$patch")"
      done
    } | git hash-object --stdin
  )"
fi

if [[ -z "$IMAGE_CACHE_DIR" ]]; then
  IMAGE_CACHE_DIR="$IMAGE_CACHE_BASE_DIR/$PATCH_BUNDLE_HASH"
fi
mkdir -p "$IMAGE_CACHE_DIR"

if [[ ! -d "$CAPI_DIR/.git" ]]; then
  log "cloning cluster-api into $CAPI_DIR"
  git clone https://github.com/kubernetes-sigs/cluster-api.git "$CAPI_DIR"
fi

pushd "$CAPI_DIR" >/dev/null
log "checking out $CAPI_REF"
git fetch --tags --prune
git checkout "$CAPI_REF"
git reset --hard "$CAPI_REF"
git clean -fd

if [[ "$APPLY_PATCH" == "true" ]]; then
  for patch in "${patch_files[@]}"; do
    if git apply --check "$patch" >/dev/null 2>&1; then
      log "applying patch $(basename "$patch")"
      git apply "$patch"
    elif git apply --reverse --check "$patch" >/dev/null 2>&1; then
      log "patch $(basename "$patch") is already applied"
    else
      echo "patch $(basename "$patch") cannot be applied cleanly to $CAPI_REF; rebase/fix patch first" >&2
      exit 1
    fi
  done
else
  log "building upstream CAPI from source ref $CAPI_REF (no local patch applied)"
fi

IMAGES=(
  "${REGISTRY}/cluster-api-controller-${ARCH}:${TAG}"
  "${REGISTRY}/kubeadm-bootstrap-controller-${ARCH}:${TAG}"
  "${REGISTRY}/kubeadm-control-plane-controller-${ARCH}:${TAG}"
)

IMAGE_ARCHIVES=(
  "$IMAGE_CACHE_DIR/cluster-api-controller-${ARCH}.tar"
  "$IMAGE_CACHE_DIR/kubeadm-bootstrap-controller-${ARCH}.tar"
  "$IMAGE_CACHE_DIR/kubeadm-control-plane-controller-${ARCH}.tar"
)

cache_complete=true
for archive in "${IMAGE_ARCHIVES[@]}"; do
  if [[ ! -s "$archive" ]]; then
    cache_complete=false
    break
  fi
done

if [[ "$cache_complete" == "true" ]]; then
  log "found cached CAPI images in $IMAGE_CACHE_DIR; loading into docker"
  for archive in "${IMAGE_ARCHIVES[@]}"; do
    docker load -i "$archive" >/dev/null
  done
else
  if compgen -G "$IMAGE_CACHE_DIR/*.tar" >/dev/null; then
    log "image cache in $IMAGE_CACHE_DIR is incomplete; rebuilding and refreshing cache"
  else
    log "image cache is empty in $IMAGE_CACHE_DIR; building CAPI images"
  fi

  log "building CAPI controller images with TAG=$TAG ARCH=$ARCH REGISTRY=$REGISTRY"
  make REGISTRY="$REGISTRY" ALL_DOCKER_BUILD="core kubeadm-bootstrap kubeadm-control-plane" docker-build TAG="$TAG"

  log "saving built images to $IMAGE_CACHE_DIR"
  for i in "${!IMAGES[@]}"; do
    docker save -o "${IMAGE_ARCHIVES[$i]}" "${IMAGES[$i]}"
  done

  # Ensure images are available in docker even after refresh.
  for image in "${IMAGES[@]}"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      echo "failed to prepare image: $image" >&2
      exit 1
    fi
  done
fi
popd >/dev/null

for image in "${IMAGES[@]}"; do
  log "loading $image into kind cluster capi-mgmt"
  kind load docker-image "$image" --name capi-mgmt
done

log "ensuring providers are installed"
for ns in capi-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system capd-system; do
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "required namespace missing: $ns" >&2
    echo "run setup/bootstrap-management-cluster.sh first" >&2
    exit 1
  fi
done
log "CAPI namespaces present; skipping provider init in this script"

log "updating controller images to local build tag=$TAG"
kubectl -n capi-system set image deployment/capi-controller-manager \
  manager="${REGISTRY}/cluster-api-controller-${ARCH}:${TAG}"
kubectl -n capi-kubeadm-bootstrap-system set image deployment/capi-kubeadm-bootstrap-controller-manager \
  manager="${REGISTRY}/kubeadm-bootstrap-controller-${ARCH}:${TAG}"
kubectl -n capi-kubeadm-control-plane-system set image deployment/capi-kubeadm-control-plane-controller-manager \
  manager="${REGISTRY}/kubeadm-control-plane-controller-${ARCH}:${TAG}"

if [[ ! -d "$CAPI_DIR/bootstrap/kubeadm/config/crd/bases" || ! -d "$CAPI_DIR/controlplane/kubeadm/config/crd/bases" ]]; then
  echo "local CAPI CRDs not found in CAPI_DIR=$CAPI_DIR" >&2
  exit 1
fi
log "applying CRDs from local CAPI source tree"
kubectl apply -f "$CAPI_DIR/bootstrap/kubeadm/config/crd/bases/bootstrap.cluster.x-k8s.io_kubeadmconfigs.yaml"
kubectl apply -f "$CAPI_DIR/bootstrap/kubeadm/config/crd/bases/bootstrap.cluster.x-k8s.io_kubeadmconfigtemplates.yaml"
kubectl apply -f "$CAPI_DIR/controlplane/kubeadm/config/crd/bases/controlplane.cluster.x-k8s.io_kubeadmcontrolplanes.yaml"
kubectl apply -f "$CAPI_DIR/controlplane/kubeadm/config/crd/bases/controlplane.cluster.x-k8s.io_kubeadmcontrolplanetemplates.yaml"

# Ensure externalCA is exposed on v1beta1 schemas. Some patch hunks can land only in
# deprecated CRD versions, while workload manifests use v1beta1.
ensure_externalca_v1beta1_schema() {
  local crd="$1"
  local jsonpath_suffix="$2"
  local patch_suffix="$3"
  local idx existing

  idx="$(kubectl get crd "$crd" -o go-template='{{range $i,$v := .spec.versions}}{{if eq $v.name "v1beta1"}}{{$i}}{{end}}{{end}}')"
  if [[ -z "$idx" ]]; then
    echo "v1beta1 version not found in CRD: $crd" >&2
    exit 1
  fi

  existing="$(kubectl get crd "$crd" -o jsonpath="{.spec.versions[$idx].schema.openAPIV3Schema${jsonpath_suffix}.type}" 2>/dev/null || true)"
  if [[ "$existing" == "boolean" ]]; then
    log "externalCA already present in $crd v1beta1 schema"
    return 0
  fi

  kubectl patch crd "$crd" --type='json' -p "[{\"op\":\"add\",\"path\":\"/spec/versions/$idx/schema/openAPIV3Schema${patch_suffix}\",\"value\":{\"type\":\"boolean\"}}]" >/dev/null

  existing="$(kubectl get crd "$crd" -o jsonpath="{.spec.versions[$idx].schema.openAPIV3Schema${jsonpath_suffix}.type}" 2>/dev/null || true)"
  if [[ "$existing" != "boolean" ]]; then
    echo "failed to ensure externalCA in $crd v1beta1 schema" >&2
    exit 1
  fi
  log "added externalCA to $crd v1beta1 schema"
}

ensure_externalca_v1beta1_schema \
  "kubeadmconfigs.bootstrap.cluster.x-k8s.io" \
  ".properties.spec.properties.externalCA" \
  "/properties/spec/properties/externalCA"
ensure_externalca_v1beta1_schema \
  "kubeadmconfigtemplates.bootstrap.cluster.x-k8s.io" \
  ".properties.spec.properties.template.properties.spec.properties.externalCA" \
  "/properties/spec/properties/template/properties/spec/properties/externalCA"
ensure_externalca_v1beta1_schema \
  "kubeadmcontrolplanes.controlplane.cluster.x-k8s.io" \
  ".properties.spec.properties.kubeadmConfigSpec.properties.externalCA" \
  "/properties/spec/properties/kubeadmConfigSpec/properties/externalCA"
ensure_externalca_v1beta1_schema \
  "kubeadmcontrolplanetemplates.controlplane.cluster.x-k8s.io" \
  ".properties.spec.properties.template.properties.spec.properties.kubeadmConfigSpec.properties.externalCA" \
  "/properties/spec/properties/template/properties/spec/properties/kubeadmConfigSpec/properties/externalCA"

log "waiting for CAPI deployments rollout"
kubectl -n capi-system rollout status deployment/capi-controller-manager --timeout=5m
kubectl -n capi-kubeadm-bootstrap-system rollout status deployment/capi-kubeadm-bootstrap-controller-manager --timeout=5m
kubectl -n capi-kubeadm-control-plane-system rollout status deployment/capi-kubeadm-control-plane-controller-manager --timeout=5m

log "CAPI source build + install completed"
