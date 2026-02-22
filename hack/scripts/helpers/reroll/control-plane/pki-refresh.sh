#!/usr/bin/env bash

collect_control_plane_sans() {
  local machine_list machine
  machine_list="$(kubectl -n "$namespace" get machine -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/control-plane" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  {
    echo "localhost"
    echo "127.0.0.1"
    echo "::1"
    if [[ -n "$machine_list" ]]; then
      while IFS= read -r machine; do
        [[ -n "$machine" ]] || continue
        echo "$machine"
        kubectl -n "$namespace" get machine "$machine" -o jsonpath='{range .status.addresses[*]}{.address}{"\n"}{end}' 2>/dev/null || true
      done <<< "$machine_list"
    fi
    kubectl -n "$namespace" get cluster "$cluster_name" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true
  } | awk 'NF' | sort -u | paste -sd, -
}

resolve_kubeconfig_server() {
  local host port
  host="$(kubectl -n "$namespace" get cluster "$cluster_name" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true)"
  port="$(kubectl -n "$namespace" get cluster "$cluster_name" -o jsonpath='{.spec.controlPlaneEndpoint.port}' 2>/dev/null || true)"
  if [[ -n "$host" && -n "$port" ]]; then
    echo "https://${host}:${port}"
  else
    echo "https://127.0.0.1:6443"
  fi
}

refresh_external_bootstrap_material() {
  local server san_list server_host
  server="$(resolve_kubeconfig_server)"
  san_list="$(collect_control_plane_sans)"
  server_host="${server#https://}"
  server_host="${server_host%%:*}"
  san_list="$(
    {
      echo "$san_list" | tr ',' '\n'
      echo "$server_host"
    } | awk 'NF' | sort -u | paste -sd, -
  )"

  CLUSTER_NAME="$cluster_name" \
  NAMESPACE="$namespace" \
  BOOTSTRAP_PKI_DIR="$bootstrap_pki_dir" \
  KUBECONFIG_SERVER="$server" \
  APISERVER_SANS_EXTRA="$san_list" \
  ETCD_SANS_EXTRA="$san_list" \
  "$refresh_script"
}

wait_cp_ready_with_refresh() {
  local target="$1"
  local expected_nodes="$2"
  local expected_workers="$3"
  local i ready_cp

  for ((i=1; i<=90; i++)); do
    ready_cp="$(kubectl -n "$namespace" get "kubeadmcontrolplane/${kcp_name}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "$ready_cp" == "$target" ]]; then
      wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$target" "$expected_workers" 120
      wait_workload_nodes_ready "$kubeconfig_path" "$expected_nodes" 120
      return 0
    fi
    refresh_external_bootstrap_material
    sleep 20
  done
  return 1
}
