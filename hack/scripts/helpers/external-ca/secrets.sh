#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/contract.sh"

write_kubeconfig() {
  local out_file="$1"
  local server="$2"
  local ca_crt="$3"
  local user="$4"
  local client_crt="$5"
  local client_key="$6"
  local ca_data

  rm -f "$out_file"
  KUBECONFIG="$out_file" kubectl config set-cluster default \
    --server "$server" \
    --certificate-authority "$ca_crt" \
    --embed-certs=true >/dev/null
  KUBECONFIG="$out_file" kubectl config set-credentials "$user" \
    --client-certificate "$client_crt" \
    --client-key "$client_key" \
    --embed-certs=true >/dev/null
  KUBECONFIG="$out_file" kubectl config set-context default \
    --cluster default \
    --user "$user" >/dev/null
  KUBECONFIG="$out_file" kubectl config use-context default >/dev/null

  ca_data="$(base64 < "$ca_crt" | tr -d '\n')"
  KUBECONFIG="$out_file" kubectl config set clusters.default.certificate-authority-data "$ca_data" >/dev/null
}

labeled_apply() {
  kubectl label --local --overwrite -f - "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o yaml | kubectl apply -f - >/dev/null
}

apply_secrets() {
  local cluster_ca="$BOOTSTRAP_PKI_DIR/cluster-ca.crt"
  local front_ca="$BOOTSTRAP_PKI_DIR/front-proxy-ca.crt"
  local etcd_ca="$BOOTSTRAP_PKI_DIR/etcd-ca.crt"

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-ca" \
    --type Opaque \
    --from-file=tls.crt="$cluster_ca" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-proxy" \
    --type Opaque \
    --from-file=tls.crt="$front_ca" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-etcd" \
    --type Opaque \
    --from-file=tls.crt="$etcd_ca" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-sa" \
    --type Opaque \
    --from-file=tls.crt="$BOOTSTRAP_PKI_DIR/sa.pub" \
    --from-file=tls.key="$BOOTSTRAP_PKI_DIR/sa.key" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-kubeconfig" \
    --type Opaque \
    --from-file=value="$BOOTSTRAP_PKI_DIR/admin.conf" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-apiserver-etcd-client" \
    --type Opaque \
    --from-file=tls.crt="$BOOTSTRAP_PKI_DIR/apiserver-etcd-client.crt" \
    --from-file=tls.key="$BOOTSTRAP_PKI_DIR/apiserver-etcd-client.key" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "$FILES_SECRET_NAME" \
    --type Opaque \
    $(external_ca_contract_from_file_args "$BOOTSTRAP_PKI_DIR") \
    --dry-run=client -o yaml | labeled_apply
}
