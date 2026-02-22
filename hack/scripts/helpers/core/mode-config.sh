#!/usr/bin/env bash

MODE_CFG_MODE=""
MODE_CFG_CLUSTER_NAME=""
MODE_CFG_KCP_NAME=""
MODE_CFG_WORKER_MD_NAME=""
MODE_CFG_MANIFEST=""
MODE_CFG_WORKLOAD_OUT_DIR=""
MODE_CFG_WORKLOAD_KUBECONFIG=""
MODE_CFG_APPLY_PATCH=""
MODE_CFG_TAG=""
MODE_CFG_INITIAL_CONTROL_PLANE_REPLICAS=""
MODE_CFG_CONTROL_PLANE_REPLICAS=""
MODE_CFG_WORKER_REPLICAS=""

mode_from_args() {
  local mode="${1:-${FLOW_MODE:-}}"
  if [[ -z "$mode" ]]; then
    echo "missing mode: expected self-signed or external-ca" >&2
    return 1
  fi
  case "$mode" in
    self-signed|external-ca) ;;
    *)
      echo "unsupported mode: $mode (expected self-signed|external-ca)" >&2
      return 1
      ;;
  esac
  echo "$mode"
}

mode_config() {
  local mode
  mode="$(mode_from_args "${1:-}")"

  MODE_CFG_MODE="$mode"
  MODE_CFG_WORKLOAD_OUT_DIR="$OUT_DIR/workload"
  MODE_CFG_WORKLOAD_KUBECONFIG="$MODE_CFG_WORKLOAD_OUT_DIR/kubeconfig"
  MODE_CFG_INITIAL_CONTROL_PLANE_REPLICAS="${INITIAL_CONTROL_PLANE_REPLICAS:-1}"
  MODE_CFG_CONTROL_PLANE_REPLICAS="${CONTROL_PLANE_REPLICAS:-3}"
  MODE_CFG_WORKER_REPLICAS="${WORKER_REPLICAS:-3}"

  case "$mode" in
    self-signed)
      MODE_CFG_CLUSTER_NAME="self-signed-ca-cluster"
      MODE_CFG_KCP_NAME="self-signed-ca-controlplane"
      MODE_CFG_WORKER_MD_NAME="self-signed-ca-worker-md-0"
      MODE_CFG_MANIFEST="$OUT_DIR/workload/manifests/self-signed-cluster.yaml"
      MODE_CFG_APPLY_PATCH="false"
      MODE_CFG_TAG="external-ca-upstream-dev"
      ;;
    external-ca)
      MODE_CFG_CLUSTER_NAME="external-ca-cluster"
      MODE_CFG_KCP_NAME="external-ca-controlplane"
      MODE_CFG_WORKER_MD_NAME="external-ca-worker-md-0"
      MODE_CFG_MANIFEST="$OUT_DIR/workload/manifests/external-ca-cluster.yaml"
      MODE_CFG_APPLY_PATCH="true"
      MODE_CFG_TAG="external-ca-dev"
      ;;
  esac
}

cluster_name_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_CLUSTER_NAME"
}

kcp_name_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_KCP_NAME"
}

worker_md_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_WORKER_MD_NAME"
}

manifest_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_MANIFEST"
}

workload_out_dir_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_WORKLOAD_OUT_DIR"
}

workload_kubeconfig_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_WORKLOAD_KUBECONFIG"
}

initial_control_plane_replicas_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_INITIAL_CONTROL_PLANE_REPLICAS"
}

control_plane_replicas_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_CONTROL_PLANE_REPLICAS"
}

worker_replicas_for_mode() {
  mode_config "$1"
  echo "$MODE_CFG_WORKER_REPLICAS"
}
