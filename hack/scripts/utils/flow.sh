#!/usr/bin/env bash

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

cluster_name_for_mode() {
  case "$1" in
    self-signed) echo "self-signed-ca-cluster" ;;
    external-ca) echo "external-ca-cluster" ;;
  esac
}

kcp_name_for_mode() {
  case "$1" in
    self-signed) echo "self-signed-ca-controlplane" ;;
    external-ca) echo "external-ca-controlplane" ;;
  esac
}

worker_md_for_mode() {
  case "$1" in
    self-signed) echo "self-signed-ca-worker-md-0" ;;
    external-ca) echo "external-ca-worker-md-0" ;;
  esac
}

manifest_for_mode() {
  case "$1" in
    self-signed) echo "$POC_DIR/manifests/self-signed-ca-cluster.yaml" ;;
    external-ca) echo "$POC_DIR/manifests/external-ca-cluster.yaml" ;;
  esac
}

workload_out_dir_for_mode() {
  echo "$OUT_DIR/workload"
}

workload_kubeconfig_for_mode() {
  local out_dir
  out_dir="$(workload_out_dir_for_mode "$1")"
  echo "$out_dir/kubeconfig"
}
