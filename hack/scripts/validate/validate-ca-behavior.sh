#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

require_bin kubectl openssl
NAMESPACE="${NAMESPACE:-default}"

MODE="${1:-}"
if [[ "$MODE" == "--mode" ]]; then
  MODE="${2:-}"
fi
if [[ -z "$MODE" ]]; then
  echo "usage: $0 --mode self-signed|external-ca" >&2
  exit 1
fi

case "$MODE" in
  self-signed)
    CLUSTER_NAME="self-signed-ca-cluster"
    KCP_NAME="self-signed-ca-controlplane"
    WORKER_MD_NAME="self-signed-ca-worker-md-0"
    KUBECONFIG_PATH="${KUBECONFIG_PATH:-$OUT_DIR/self-signed-ca/kubeconfig}"
    RESULTS_DIR="$OUT_DIR/self-signed-ca"

    log "validating self-signed flow: ${CLUSTER_NAME}"
    mkdir -p "$RESULTS_DIR"

    kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-ca" -o yaml > "$RESULTS_DIR/ca-secret.yaml"
    if kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-ca" -o jsonpath='{.data.tls\.key}' | grep -q .; then
      log "PASS: ${CLUSTER_NAME}-ca contains tls.key"
    else
      echo "FAIL: expected tls.key in ${CLUSTER_NAME}-ca" >&2
      exit 1
    fi

    if ! wait_kube_api_ready "$KUBECONFIG_PATH"; then
      echo "FAIL: workload API is not reachable for self-signed flow via $KUBECONFIG_PATH" >&2
      exit 1
    fi
    wait_ha_replicas "$NAMESPACE" "$CLUSTER_NAME" "$KCP_NAME" "$WORKER_MD_NAME" 3 3 90
    wait_workload_nodes_ready "$KUBECONFIG_PATH" 6 60
    wait_cilium_healthy "$KUBECONFIG_PATH" "$RESULTS_DIR/cilium-pods.txt" 30 10

    CP_NODE="$(control_plane_node_from_kubeconfig "$KUBECONFIG_PATH" || true)"
    if [[ -z "$CP_NODE" ]]; then
      echo "FAIL: could not resolve control-plane node" >&2
      exit 1
    fi
    if node_file_exists_via_kubectl_debug "$KUBECONFIG_PATH" "$CP_NODE" /etc/kubernetes/pki/ca.key; then
      log "PASS: control-plane node has /etc/kubernetes/pki/ca.key"
    else
      echo "FAIL: expected /etc/kubernetes/pki/ca.key on $CP_NODE" >&2
      exit 1
    fi

    dump_apiserver_chain_from_kubeconfig "$KUBECONFIG_PATH" "$RESULTS_DIR/apiserver-chain.txt"
    log "stored cert chain results in $RESULTS_DIR/apiserver-chain.txt"
    ;;

  external-ca)
    CLUSTER_NAME="external-ca-cluster"
    KCP_NAME="external-ca-controlplane"
    WORKER_MD_NAME="external-ca-worker-md-0"
    KUBECONFIG_PATH="${KUBECONFIG_PATH:-$OUT_DIR/external-ca/kubeconfig}"
    RESULTS_DIR="$OUT_DIR/external-ca"

    log "validating external-ca: ${CLUSTER_NAME}"
    mkdir -p "$RESULTS_DIR"

    kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-ca" -o yaml > "$RESULTS_DIR/ca-secret.yaml"
    if kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-ca" -o jsonpath='{.data.tls\.key}' | grep -q .; then
      echo "FAIL: ${CLUSTER_NAME}-ca should not contain tls.key" >&2
      exit 1
    fi
    log "PASS: ${CLUSTER_NAME}-ca has tls.crt only"

    if ! wait_kube_api_ready "$KUBECONFIG_PATH"; then
      echo "FAIL: workload API is not reachable for external-ca via $KUBECONFIG_PATH" >&2
      exit 1
    fi
    wait_ha_replicas "$NAMESPACE" "$CLUSTER_NAME" "$KCP_NAME" "$WORKER_MD_NAME" 3 3 90
    wait_workload_nodes_ready "$KUBECONFIG_PATH" 6 60
    wait_cilium_healthy "$KUBECONFIG_PATH" "$RESULTS_DIR/cilium-pods-before-scale.txt" 30 10

    CP_NODE="$(control_plane_node_from_kubeconfig "$KUBECONFIG_PATH" || true)"
    if [[ -z "$CP_NODE" ]]; then
      echo "FAIL: could not resolve control-plane node" >&2
      exit 1
    fi
    if node_file_exists_via_kubectl_debug "$KUBECONFIG_PATH" "$CP_NODE" /etc/kubernetes/pki/ca.key; then
      echo "FAIL: /etc/kubernetes/pki/ca.key should not exist on $CP_NODE" >&2
      exit 1
    fi
    log "PASS: control-plane node has no /etc/kubernetes/pki/ca.key"

    dump_apiserver_chain_from_kubeconfig "$KUBECONFIG_PATH" "$RESULTS_DIR/apiserver-chain.txt"
    if grep -q "issuer=.*kubernetes-ca" "$RESULTS_DIR/apiserver-chain.txt"; then
      log "PASS: apiserver cert issuer includes kubernetes-ca"
    else
      log "WARN: apiserver issuer check inconclusive; inspect $RESULTS_DIR/apiserver-chain.txt"
    fi

    log "scaling worker MachineDeployment to prove no Day-2 CA rotation dependency"
    kubectl -n "$NAMESPACE" patch "machinedeployment/${WORKER_MD_NAME}" --type merge -p '{"spec":{"replicas":4}}'
    wait_ha_replicas "$NAMESPACE" "$CLUSTER_NAME" "$KCP_NAME" "$WORKER_MD_NAME" 3 4 120
    wait_workload_nodes_ready "$KUBECONFIG_PATH" 7 60

    if ! wait_kube_api_ready "$KUBECONFIG_PATH"; then
      echo "FAIL: workload API became unreachable after scale" >&2
      exit 1
    fi
    wait_cilium_healthy "$KUBECONFIG_PATH" "$RESULTS_DIR/cilium-pods-after-scale.txt" 30 10
    kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide > "$RESULTS_DIR/nodes-after-scale.txt"
    log "PASS: worker scaling succeeded"
    ;;

  *)
    echo "unsupported mode: $MODE" >&2
    exit 1
    ;;
esac
