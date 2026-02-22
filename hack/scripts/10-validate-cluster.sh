#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/env.sh"
source "$SCRIPT_DIR/utils/kube.sh"
source "$SCRIPT_DIR/utils/flow.sh"

MODE="$(mode_from_args "${1:-}")"
cluster_name="$(cluster_name_for_mode "$MODE")"
kcp_name="$(kcp_name_for_mode "$MODE")"
worker_md_name="$(worker_md_for_mode "$MODE")"
namespace="${NAMESPACE:-default}"
kubeconfig_path="$(workload_kubeconfig_for_mode "$MODE")"
results_dir="$(workload_out_dir_for_mode "$MODE")"
source_ca_cert="${STATIC_KUBERNETES_CA_CERT:-$OUT_DIR/workload/material/kubernetes-ca.crt}"
control_plane_replicas=3
worker_replicas=3
expected_total_nodes=$((control_plane_replicas + worker_replicas))

mkdir -p "$results_dir"

if [[ ! -s "$kubeconfig_path" ]]; then
  echo "missing workload kubeconfig: $kubeconfig_path" >&2
  exit 1
fi

collect_cp_hashes() {
  local out_file="$1"
  local node node_name api_key_hash etcd_peer_hash
  : > "$out_file"
  for node in $(kubectl --kubeconfig "$kubeconfig_path" get nodes -l node-role.kubernetes.io/control-plane -o name); do
    node_name="${node#node/}"
    api_key_hash="$(node_file_sha256_via_kubectl_debug "$kubeconfig_path" "$node_name" /etc/kubernetes/pki/apiserver.key)"
    etcd_peer_hash="$(node_file_sha256_via_kubectl_debug "$kubeconfig_path" "$node_name" /etc/kubernetes/pki/etcd/peer.key)"
    printf '%s apiserver=%s etcd-peer=%s\n' "$node_name" "$api_key_hash" "$etcd_peer_hash" >> "$out_file"
  done
}

validate_worker_kubelet_client_certs() {
  local expected_issuer="$1"
  local out_file="$2"
  local worker_nodes node node_name cert_info cert_subject cert_issuer cert_hash
  : > "$out_file"

  worker_nodes="$(kubectl --kubeconfig "$kubeconfig_path" get nodes -l '!node-role.kubernetes.io/control-plane' -o name)"
  if [[ -z "$worker_nodes" ]]; then
    echo "no worker nodes found for kubelet certificate validation" >&2
    exit 1
  fi

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_name="${node#node/}"

    cert_info="$(node_exec_via_kubectl_debug "$kubeconfig_path" "$node_name" '
      client_b64="$(awk "/client-certificate-data:/{print \$2; exit}" /etc/kubernetes/kubelet.conf 2>/dev/null || true)"
      [ -n "$client_b64" ] || { echo "missing client-certificate-data in /etc/kubernetes/kubelet.conf"; exit 1; }
      printf "%s" "$client_b64" | base64 -d | openssl x509 -noout -subject -issuer -fingerprint -sha256 -nameopt RFC2253
    ')"

    cert_subject="$(printf '%s\n' "$cert_info" | awk -F= '/^subject=/{print substr($0,9)}' | tail -n1)"
    cert_issuer="$(printf '%s\n' "$cert_info" | awk -F= '/^issuer=/{print substr($0,8)}' | tail -n1)"
    cert_hash="$(printf '%s\n' "$cert_info" | awk -F= '/^sha256 Fingerprint=/{print $2}' | tail -n1)"

    if [[ -z "$cert_subject" || -z "$cert_issuer" ]]; then
      echo "unable to parse kubelet client certificate on worker node $node_name" >&2
      echo "$cert_info" >&2
      exit 1
    fi
    if [[ "$cert_issuer" != "$expected_issuer" ]]; then
      echo "worker kubelet certificate issuer mismatch for node $node_name: expected '$expected_issuer', got '$cert_issuer'" >&2
      exit 1
    fi
    if [[ "$cert_subject" != *"CN=system:node:${node_name}"* || "$cert_subject" != *"O=system:nodes"* ]]; then
      echo "worker kubelet certificate subject is unexpected for node $node_name: '$cert_subject'" >&2
      exit 1
    fi

    printf '%s subject=%s issuer=%s sha256=%s\n' "$node_name" "$cert_subject" "$cert_issuer" "$cert_hash" >> "$out_file"
  done <<< "$worker_nodes"
}

case "$MODE" in
  self-signed)
    log "validating self-signed mode"
    kubectl -n "$namespace" get secret "${cluster_name}-ca" -o yaml > "$results_dir/ca-secret.yaml"
    if ! kubectl -n "$namespace" get secret "${cluster_name}-ca" -o jsonpath='{.data.tls\.key}' | grep -q .; then
      echo "expected tls.key in ${cluster_name}-ca for self-signed mode" >&2
      exit 1
    fi

    wait_kube_api_ready "$kubeconfig_path"
    wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" 3 3 120
    wait_workload_nodes_ready "$kubeconfig_path" 6 120
    wait_cilium_healthy "$kubeconfig_path" "$results_dir/cilium-pods.txt" 30 10

    cp_node="$(control_plane_node_from_kubeconfig "$kubeconfig_path" || true)"
    if [[ -z "$cp_node" ]]; then
      echo "unable to resolve control-plane node for validation" >&2
      exit 1
    fi
    if ! node_file_exists_via_kubectl_debug "$kubeconfig_path" "$cp_node" /etc/kubernetes/pki/ca.key; then
      echo "expected /etc/kubernetes/pki/ca.key on control-plane node in self-signed mode" >&2
      exit 1
    fi

    dump_apiserver_chain_from_kubeconfig "$kubeconfig_path" "$results_dir/apiserver-chain.txt"
    ;;

  external-ca)
    log "validating external-ca mode"
    kubectl -n "$namespace" get secret "${cluster_name}-ca" -o yaml > "$results_dir/ca-secret.yaml"
    if kubectl -n "$namespace" get secret "${cluster_name}-ca" -o jsonpath='{.data.tls\.key}' | grep -q .; then
      echo "${cluster_name}-ca must not contain tls.key in external-ca mode" >&2
      exit 1
    fi

    wait_kube_api_ready "$kubeconfig_path"
    wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$control_plane_replicas" "$worker_replicas" 120
    wait_workload_nodes_ready "$kubeconfig_path" "$expected_total_nodes" 120
    wait_cilium_healthy "$kubeconfig_path" "$results_dir/cilium-pods.txt" 30 10

    cp_node="$(control_plane_node_from_kubeconfig "$kubeconfig_path" || true)"
    if [[ -z "$cp_node" ]]; then
      echo "unable to resolve control-plane node for validation" >&2
      exit 1
    fi
    if node_file_exists_via_kubectl_debug "$kubeconfig_path" "$cp_node" /etc/kubernetes/pki/ca.key; then
      echo "/etc/kubernetes/pki/ca.key must not exist on control-plane nodes in external-ca mode" >&2
      exit 1
    fi

    if [[ ! -f "$source_ca_cert" ]]; then
      echo "missing source CA certificate for fingerprint validation: $source_ca_cert" >&2
      exit 1
    fi

    kubectl -n "$namespace" get secret "${cluster_name}-ca" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$results_dir/cluster-ca.crt"
    source_ca_fp="$(openssl x509 -in "$source_ca_cert" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
    cluster_ca_fp="$(openssl x509 -in "$results_dir/cluster-ca.crt" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
    if [[ "$source_ca_fp" != "$cluster_ca_fp" ]]; then
      echo "external cluster CA fingerprint does not match generated source CA cert" >&2
      exit 1
    fi

    apiserver_issuer="$(issuer_from_apiserver "$kubeconfig_path")"
    cluster_ca_subject="$(openssl x509 -in "$results_dir/cluster-ca.crt" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
    if [[ "$apiserver_issuer" != "$cluster_ca_subject" ]]; then
      echo "apiserver issuer does not match external cluster CA subject" >&2
      exit 1
    fi

    validate_worker_kubelet_client_certs "$cluster_ca_subject" "$results_dir/worker-kubelet-cert-info.txt"

    collect_cp_hashes "$results_dir/control-plane-key-hashes.txt"
    cp_count="$(wc -l < "$results_dir/control-plane-key-hashes.txt" | tr -d ' ')"
    unique_api_keys="$(awk '{print $2}' "$results_dir/control-plane-key-hashes.txt" | cut -d= -f2 | sort -u | wc -l | tr -d ' ')"
    unique_etcd_keys="$(awk '{print $3}' "$results_dir/control-plane-key-hashes.txt" | cut -d= -f2 | sort -u | wc -l | tr -d ' ')"

    if [[ "$cp_count" -lt 3 || "$unique_api_keys" -lt "$cp_count" || "$unique_etcd_keys" -lt "$cp_count" ]]; then
      echo "control-plane key uniqueness check failed (nodes=$cp_count apiserver-unique=$unique_api_keys etcd-unique=$unique_etcd_keys)" >&2
      exit 1
    fi

    dump_apiserver_chain_from_kubeconfig "$kubeconfig_path" "$results_dir/apiserver-chain.txt"
    ;;
esac

log "validation completed for mode=$MODE"
