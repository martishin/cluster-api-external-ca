#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

require_bin git make docker kind kubectl

CAPI_REF="${CAPI_REF:-v1.8.8}"
CAPI_VERSION="${CAPI_VERSION:-$CAPI_REF}"
CAPI_DIR="${CAPI_DIR:-$TMP_WORK_DIR/cluster-api}"
PATCH_DIR="$POC_DIR/capi-patches"
APPLY_PATCH="${APPLY_PATCH:-true}"
TAG="${TAG:-external-ca-dev}"
ARCH="${ARCH:-$(go env GOARCH)}"
REGISTRY="${REGISTRY:-gcr.io/k8s-staging-cluster-api}"

mkdir -p "$TMP_WORK_DIR"

case "$APPLY_PATCH" in
  true|false) ;;
  *)
    echo "APPLY_PATCH must be true|false, got: $APPLY_PATCH" >&2
    exit 1
    ;;
esac

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
  applied_or_present=0
  for patch in "$PATCH_DIR"/*.patch; do
    [[ -e "$patch" ]] || continue
    if git apply --check "$patch" >/dev/null 2>&1; then
      log "applying patch $(basename "$patch")"
      git apply "$patch"
      applied_or_present=1
    elif git apply --reverse --check "$patch" >/dev/null 2>&1; then
      log "patch $(basename "$patch") is already applied"
      applied_or_present=1
    else
      echo "patch $(basename "$patch") cannot be applied cleanly to $CAPI_REF; rebase/fix patch first" >&2
      exit 1
    fi
  done
  if [[ "$applied_or_present" -eq 0 ]]; then
    echo "no patch files were applied or detected in $PATCH_DIR" >&2
    exit 1
  fi
else
  log "building upstream CAPI from source ref $CAPI_REF (no local patch applied)"
fi

log "building CAPI controller images with TAG=$TAG ARCH=$ARCH REGISTRY=$REGISTRY"
make REGISTRY="$REGISTRY" ALL_DOCKER_BUILD="core kubeadm-bootstrap kubeadm-control-plane" docker-build TAG="$TAG"
popd >/dev/null

IMAGES=(
  "${REGISTRY}/cluster-api-controller-${ARCH}:${TAG}"
  "${REGISTRY}/kubeadm-bootstrap-controller-${ARCH}:${TAG}"
  "${REGISTRY}/kubeadm-control-plane-controller-${ARCH}:${TAG}"
)

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

log "waiting for CAPI deployments rollout"
kubectl -n capi-system rollout status deployment/capi-controller-manager --timeout=5m
kubectl -n capi-kubeadm-bootstrap-system rollout status deployment/capi-kubeadm-bootstrap-controller-manager --timeout=5m
kubectl -n capi-kubeadm-control-plane-system rollout status deployment/capi-kubeadm-control-plane-controller-manager --timeout=5m

log "CAPI source build + install completed"
