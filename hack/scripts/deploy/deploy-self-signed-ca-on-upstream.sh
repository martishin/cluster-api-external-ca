#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

ensure_out_dirs
CLUSTER_NAME="${CLUSTER_NAME:-self-signed-ca-cluster}"
NAMESPACE="${NAMESPACE:-default}"
KUBECONFIG_OUT="$OUT_DIR/self-signed-ca/kubeconfig"
KCP_NAME="${KCP_NAME:-self-signed-ca-controlplane}"
WORKER_MD_NAME="${WORKER_MD_NAME:-self-signed-ca-worker-md-0}"
INITIAL_CP_REPLICAS="${INITIAL_CP_REPLICAS:-1}"
INITIAL_WORKER_REPLICAS="${INITIAL_WORKER_REPLICAS:-3}"
TARGET_CP_REPLICAS="${TARGET_CP_REPLICAS:-3}"
TARGET_WORKER_REPLICAS="${TARGET_WORKER_REPLICAS:-3}"

log "deploying self-signed manifest against upstream CAPI (expected self-signed CA bootstrap)"
for i in {1..18}; do
  if kubectl apply -f "$POC_DIR/manifests/self-signed-ca-cluster.yaml"; then
    break
  fi
  if [[ "$i" -eq 18 ]]; then
    echo "FAIL: unable to apply self-signed manifest after retries" >&2
    exit 1
  fi
  log "self-signed manifest apply failed (attempt $i/18), retrying in 10s"
  sleep 10
done

log "forcing initial bootstrap shape cp=${INITIAL_CP_REPLICAS}, workers=${INITIAL_WORKER_REPLICAS}"
kubectl -n "$NAMESPACE" patch "kubeadmcontrolplane/${KCP_NAME}" --type merge -p "{\"spec\":{\"replicas\":${INITIAL_CP_REPLICAS}}}"
kubectl -n "$NAMESPACE" patch "machinedeployment/${WORKER_MD_NAME}" --type merge -p "{\"spec\":{\"replicas\":${INITIAL_WORKER_REPLICAS}}}"

wait_cluster_ready "$CLUSTER_NAME" 30m

if ! write_kubeconfig_from_secret "$NAMESPACE" "$CLUSTER_NAME" "$KUBECONFIG_OUT"; then
  echo "FAIL: unable to write kubeconfig from secret ${CLUSTER_NAME}-kubeconfig" >&2
  exit 1
fi

log "waiting for workload API authentication readiness"
if ! wait_workload_api_authenticated "$KUBECONFIG_OUT" 90 5; then
  echo "FAIL: workload API auth did not become ready for kubeconfig ${KUBECONFIG_OUT}" >&2
  exit 1
fi

install_workload_cni "$KUBECONFIG_OUT" 20m

log "scaling self-signed cluster to HA target cp=${TARGET_CP_REPLICAS}, workers=${TARGET_WORKER_REPLICAS}"
kubectl -n "$NAMESPACE" patch "kubeadmcontrolplane/${KCP_NAME}" --type merge -p "{\"spec\":{\"replicas\":${TARGET_CP_REPLICAS}}}"
kubectl -n "$NAMESPACE" patch "machinedeployment/${WORKER_MD_NAME}" --type merge -p "{\"spec\":{\"replicas\":${TARGET_WORKER_REPLICAS}}}"
wait_ha_replicas "$NAMESPACE" "$CLUSTER_NAME" "$KCP_NAME" "$WORKER_MD_NAME" "$TARGET_CP_REPLICAS" "$TARGET_WORKER_REPLICAS" 135

wait_workload_nodes_ready "$KUBECONFIG_OUT" "$((TARGET_CP_REPLICAS + TARGET_WORKER_REPLICAS))" 90
log "self-signed cluster setup complete; kubeconfig at $KUBECONFIG_OUT"
