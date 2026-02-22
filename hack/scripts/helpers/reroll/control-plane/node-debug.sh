#!/usr/bin/env bash

run_node_debug_command() {
  local node_name="$1"
  local node_script="$2"
  local debug_namespace="${DEBUG_NAMESPACE:-default}"
  local create_out pod_name phase i

  if ! create_out="$(
    kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" debug "node/${node_name}" \
      --image=busybox:1.36 --profile=general --attach=false -- \
      chroot /host sh -ceu "$node_script" 2>&1
  )"; then
    echo "$create_out" >&2
    return 1
  fi

  pod_name="$(printf '%s\n' "$create_out" | awk '/Creating debugging pod/{print $4}' | tail -n1)"
  if [[ -z "$pod_name" ]]; then
    echo "unable to determine debug pod name for node ${node_name}" >&2
    echo "$create_out" >&2
    return 1
  fi

  for ((i=1; i<=90; i++)); do
    phase="$(kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded|Failed)
        break
        ;;
    esac
    sleep 2
  done

  kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" logs "$pod_name" 2>/dev/null || true
  kubectl --kubeconfig "$kubeconfig_path" -n "$debug_namespace" delete pod "$pod_name" --ignore-not-found >/dev/null 2>&1 || true

  if [[ "$phase" != "Succeeded" ]]; then
    echo "debug command failed on node ${node_name} (phase=${phase:-unknown})" >&2
    return 1
  fi
}

rotate_existing_node_etcd_certs() {
  local node_name="$1"
  local server_crt_b64 server_key_b64 peer_crt_b64 peer_key_b64 node_script

  server_crt_b64="$(base64 < "$bootstrap_pki_dir/etcd-server.crt" | tr -d '\n')"
  server_key_b64="$(base64 < "$bootstrap_pki_dir/etcd-server.key" | tr -d '\n')"
  peer_crt_b64="$(base64 < "$bootstrap_pki_dir/etcd-peer.crt" | tr -d '\n')"
  peer_key_b64="$(base64 < "$bootstrap_pki_dir/etcd-peer.key" | tr -d '\n')"

  node_script="$(cat <<EOFNER
set -eu
mkdir -p /etc/kubernetes/pki/etcd
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/server.crt
${server_crt_b64}
EOC
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/server.key
${server_key_b64}
EOC
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/peer.crt
${peer_crt_b64}
EOC
cat <<'EOC' | base64 -d > /etc/kubernetes/pki/etcd/peer.key
${peer_key_b64}
EOC
chmod 0644 /etc/kubernetes/pki/etcd/server.crt /etc/kubernetes/pki/etcd/peer.crt
chmod 0600 /etc/kubernetes/pki/etcd/server.key /etc/kubernetes/pki/etcd/peer.key
if [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
  mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.capi-rotate
  sleep 8
  mv /etc/kubernetes/manifests/etcd.yaml.capi-rotate /etc/kubernetes/manifests/etcd.yaml
fi
echo "rotated etcd certs on ${node_name}"
EOFNER
)"

  run_node_debug_command "$node_name" "$node_script"
}

prepare_existing_control_plane_for_join() {
  local node_list node_name
  node_list="$(kubectl --kubeconfig "$kubeconfig_path" get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "$node_list" ]]; then
    echo "no control-plane nodes found in workload cluster to rotate etcd certs" >&2
    return 1
  fi

  while IFS= read -r node_name; do
    [[ -n "$node_name" ]] || continue
    log "rotating etcd certs on existing control-plane node: $node_name"
    rotate_existing_node_etcd_certs "$node_name"
  done <<< "$node_list"
}
