#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

ensure_out_dirs
CLUSTER_NAME="external-ca-cluster"
KCP_NAME="external-ca-controlplane"
KMSSERVICE_MOCK_ADDR="${KMSSERVICE_MOCK_ADDR:-127.0.0.1:9443}"
KMSSERVICE_ENDPOINT="${KMSSERVICE_ENDPOINT:-${KMSSERVICE_MOCK_ADDR}}"
KMSSERVICE_MTLS_CERT_DIR="${KMSSERVICE_MTLS_CERT_DIR:-$OUT_DIR/kmsservice-mtls}"
KMSSERVICE_CA_CERT="$KMSSERVICE_MTLS_CERT_DIR/ca.crt"
KMSSERVICE_CLIENT_CERT="$KMSSERVICE_MTLS_CERT_DIR/client.crt"
KMSSERVICE_CLIENT_KEY="$KMSSERVICE_MTLS_CERT_DIR/client.key"
KMSSERVICE_SERVER_NAME="${KMSSERVICE_SERVER_NAME:-localhost}"
KUBECONFIG_SERVER="${KUBECONFIG_SERVER:-}"
NAMESPACE="default"
INITIAL_CP_REPLICAS=1
TARGET_CP_REPLICAS=3
TARGET_WORKER_REPLICAS=3

cleanup_stale_kmsservice_mock() {
  local pids
  pids="$(pgrep -f "kmsservice-mock --addr ${KMSSERVICE_MOCK_ADDR}" || true)"
  if [[ -z "$pids" ]]; then
    return 0
  fi

  log "killing stale kmsservice-mock processes for ${KMSSERVICE_MOCK_ADDR}: ${pids//$'\n'/,}"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done <<< "$pids"
  sleep 1

  pids="$(pgrep -f "kmsservice-mock --addr ${KMSSERVICE_MOCK_ADDR}" || true)"
  if [[ -n "$pids" ]]; then
    log "force-killing stale kmsservice-mock processes: ${pids//$'\n'/,}"
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      kill -9 "$pid" >/dev/null 2>&1 || true
    done <<< "$pids"
  fi
}

collect_control_plane_sans() {
  local machine_list machine
  machine_list="$(kubectl -n "$NAMESPACE" get machine -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME},cluster.x-k8s.io/control-plane" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  {
    echo "localhost"
    echo "127.0.0.1"
    echo "::1"
    if [[ -n "$machine_list" ]]; then
      while IFS= read -r machine; do
        [[ -n "$machine" ]] || continue
        echo "$machine"
        kubectl -n "$NAMESPACE" get machine "$machine" -o jsonpath='{range .status.addresses[*]}{.address}{"\n"}{end}' 2>/dev/null || true
      done <<< "$machine_list"
    fi
    kubectl -n "$NAMESPACE" get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true
  } | awk 'NF' | sort -u | paste -sd, -
}

resolve_kubeconfig_server() {
  local host port
  host="$(kubectl -n "$NAMESPACE" get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true)"
  port="$(kubectl -n "$NAMESPACE" get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.controlPlaneEndpoint.port}' 2>/dev/null || true)"
  if [[ -n "$host" && -n "$port" ]]; then
    echo "https://${host}:${port}"
    return 0
  fi
  return 1
}

wait_for_kubeconfig_server() {
  local attempts="${1:-60}"
  local sleep_seconds="${2:-2}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if server="$(resolve_kubeconfig_server)"; then
      echo "$server"
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

apply_bootstrap_material() {
  local san_list
  local server
  local server_host
  local cmd
  if [[ -n "$KUBECONFIG_SERVER" ]]; then
    server="$KUBECONFIG_SERVER"
  else
    if ! server="$(wait_for_kubeconfig_server 90 2)"; then
      echo "FAIL: cluster controlPlaneEndpoint is not available, cannot set kubeconfig server" >&2
      exit 1
    fi
  fi
  san_list="$(collect_control_plane_sans)"
  server_host="${server#https://}"
  server_host="${server_host%%:*}"
  san_list="$(
    {
      echo "$san_list" | tr ',' '\n'
      echo "$server_host"
    } | awk 'NF' | sort -u | paste -sd, -
  )"
  log "refreshing apiserver/etcd cert SAN list: $san_list"
  log "using bootstrap kubeconfig server: $server"

  cmd=(
    go run "$ROOT_DIR/cmd/capi-bootstrap"
    --kubeconfig "$MGMT_KUBECONFIG"
    --namespace "$NAMESPACE"
    --cluster-name "$CLUSTER_NAME"
    --kcp-name "$KCP_NAME"
    --server "$server"
    --mode kmsservice
    --kmsservice-endpoint "$KMSSERVICE_ENDPOINT"
    --kmsservice-ca-cert "$KMSSERVICE_CA_CERT"
    --kmsservice-client-cert "$KMSSERVICE_CLIENT_CERT"
    --kmsservice-client-key "$KMSSERVICE_CLIENT_KEY"
    --apiserver-san "$san_list"
    --etcd-san "$san_list"
  )
  if [[ -n "$KMSSERVICE_SERVER_NAME" ]]; then
    cmd+=(--kmsservice-server-name "$KMSSERVICE_SERVER_NAME")
  fi
  "${cmd[@]}"
}

log "applying external-ca cluster manifest"
kubectl apply -f "$POC_DIR/manifests/external-ca-cluster.yaml"

log "waiting for KCP object"
if ! wait_for_kcp_object "$NAMESPACE" "$KCP_NAME" 60 5; then
  echo "FAIL: kubeadmcontrolplane/${KCP_NAME} was not created in namespace ${NAMESPACE}" >&2
  exit 1
fi

log "forcing initial control-plane replicas=${INITIAL_CP_REPLICAS} for first bootstrap"
kubectl -n "$NAMESPACE" patch "kubeadmcontrolplane/${KCP_NAME}" --type merge -p "{\"spec\":{\"replicas\":${INITIAL_CP_REPLICAS}}}"

cleanup_stale_kmsservice_mock

log "starting kmsservice-mock in background"
KMSSERVICE_MOCK_ADDR="$KMSSERVICE_MOCK_ADDR" KMSSERVICE_MTLS_CERT_DIR="$KMSSERVICE_MTLS_CERT_DIR" "$POC_DIR/scripts/mock/start-kmsservice-mock.sh" >"$OUT_DIR/kmsservice-mock.log" 2>&1 &
KMS_PID=$!
cleanup() {
  kill "$KMS_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in {1..60}; do
  if (echo >"/dev/tcp/${KMSSERVICE_MOCK_ADDR%:*}/${KMSSERVICE_MOCK_ADDR##*:}") >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! (echo >"/dev/tcp/${KMSSERVICE_MOCK_ADDR%:*}/${KMSSERVICE_MOCK_ADDR##*:}") >/dev/null 2>&1; then
  echo "kmsservice-mock grpc endpoint ${KMSSERVICE_MOCK_ADDR} is not reachable" >&2
  exit 1
fi

apply_bootstrap_material

wait_cluster_ready "$CLUSTER_NAME" 30m

if ! write_kubeconfig_from_secret "$NAMESPACE" "$CLUSTER_NAME" "$OUT_DIR/external-ca/kubeconfig"; then
  echo "FAIL: unable to write kubeconfig from secret ${CLUSTER_NAME}-kubeconfig" >&2
  exit 1
fi

log "waiting for workload API authentication readiness"
if ! wait_workload_api_authenticated "$OUT_DIR/external-ca/kubeconfig" 90 5; then
  echo "FAIL: workload API auth did not become ready for kubeconfig $OUT_DIR/external-ca/kubeconfig" >&2
  exit 1
fi

install_workload_cni "$OUT_DIR/external-ca/kubeconfig" 20m

apply_bootstrap_material

log "scaling control-plane to ${TARGET_CP_REPLICAS} replicas for HA"
kubectl -n "$NAMESPACE" patch "kubeadmcontrolplane/${KCP_NAME}" --type merge -p "{\"spec\":{\"replicas\":${TARGET_CP_REPLICAS}}}"

log "iteratively refreshing bootstrap material while control-plane scales"
for _ in {1..90}; do
  ready_cp="$(kubectl -n "$NAMESPACE" get "kubeadmcontrolplane/${KCP_NAME}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "$ready_cp" == "$TARGET_CP_REPLICAS" ]]; then
    break
  fi
  apply_bootstrap_material
  sleep 20
done

log "waiting for target HA replica counts"
wait_ha_replicas "$NAMESPACE" "$CLUSTER_NAME" "$KCP_NAME" "${CLUSTER_NAME}-worker-md-0" "$TARGET_CP_REPLICAS" "$TARGET_WORKER_REPLICAS" 135

wait_workload_nodes_ready "$OUT_DIR/external-ca/kubeconfig" "$((TARGET_CP_REPLICAS + TARGET_WORKER_REPLICAS))" 90
kubectl --kubeconfig "$OUT_DIR/external-ca/kubeconfig" get nodes -o wide

log "kmsservice-mock flow completed"
