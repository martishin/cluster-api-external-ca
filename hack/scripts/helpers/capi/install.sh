#!/usr/bin/env bash

load_images_into_kind() {
  local image
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    load_cached_image_if_needed "$image"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      echo "required image is missing locally: $image" >&2
      echo "run with OPERATION=build-install or set FORCE_REBUILD=true" >&2
      echo "expected cache tar: $(image_tar_path "$image")" >&2
      exit 1
    fi
    log "loading image into kind: $image"
    kind load docker-image "$image" --name capi-mgmt
  done < <(capi_image_list)
}

ensure_capi_namespaces_present() {
  local ns
  for ns in capi-system capi-kubeadm-bootstrap-system capi-kubeadm-control-plane-system capd-system; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      echo "required namespace missing: $ns" >&2
      echo "run hack/scripts/setup/bootstrap-management-cluster.sh first" >&2
      exit 1
    fi
  done
}

patch_external_ca_crd_schemas() {
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
}

install_capi_images() {
  load_images_into_kind
  ensure_capi_namespaces_present

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
    patch_external_ca_crd_schemas
  fi

  log "waiting for CAPI deployments rollout"
  kubectl -n capi-system rollout status deployment/capi-controller-manager --timeout=5m
  kubectl -n capi-kubeadm-bootstrap-system rollout status deployment/capi-kubeadm-bootstrap-controller-manager --timeout=5m
  kubectl -n capi-kubeadm-control-plane-system rollout status deployment/capi-kubeadm-control-plane-controller-manager --timeout=5m
}
