#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/external-ca/san.sh"
source "$SCRIPT_DIR/../helpers/external-ca/pki.sh"
source "$SCRIPT_DIR/../helpers/external-ca/secrets.sh"

require_bin kubectl openssl awk sort base64

CLUSTER_NAME="${CLUSTER_NAME:-external-ca-cluster}"
NAMESPACE="${NAMESPACE:-default}"
FILES_SECRET_NAME="${FILES_SECRET_NAME:-${CLUSTER_NAME}-external-ca-files}"
BOOTSTRAP_PKI_DIR="${BOOTSTRAP_PKI_DIR:-$OUT_DIR/workload/bootstrap-pki}"
KUBECONFIG_SERVER="${KUBECONFIG_SERVER:-https://${CLUSTER_NAME}-lb:6443}"
KUBELET_AUTH_USER="${KUBELET_AUTH_USER:-kubernetes-admin}"
APISERVER_SANS_EXTRA="${APISERVER_SANS_EXTRA:-}"
ETCD_SANS_EXTRA="${ETCD_SANS_EXTRA:-}"

mkdir -p "$BOOTSTRAP_PKI_DIR"

cluster_endpoint_host="$(host_from_server "$KUBECONFIG_SERVER")"

apiserver_default_sans='kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local,10.96.0.1,localhost,127.0.0.1,::1'
etcd_default_sans='localhost,127.0.0.1,::1'

APISERVER_SANS="$(build_sans "$apiserver_default_sans" "${APISERVER_SANS_EXTRA},${cluster_endpoint_host}")"
ETCD_SANS="$(build_sans "$etcd_default_sans" "${ETCD_SANS_EXTRA}")"

log "preparing static external-ca bootstrap PKI for cluster=$CLUSTER_NAME namespace=$NAMESPACE"
log "bootstrap PKI dir: $BOOTSTRAP_PKI_DIR"
log "kubeconfig server: $KUBECONFIG_SERVER"
log "apiserver SANs: $APISERVER_SANS"
log "etcd SANs: $ETCD_SANS"

ensure_ca "cluster-ca" "kubernetes-ca"
ensure_ca "front-proxy-ca" "kubernetes-front-proxy-ca"
ensure_ca "etcd-ca" "etcd-ca"
ensure_sa

sign_leaf "apiserver" "cluster-ca" "kube-apiserver" "" "serverAuth" "$APISERVER_SANS"
sign_leaf "apiserver-kubelet-client" "cluster-ca" "kube-apiserver-kubelet-client" "system:masters" "clientAuth"
sign_leaf "front-proxy-client" "front-proxy-ca" "front-proxy-client" "" "clientAuth"
sign_leaf "apiserver-etcd-client" "etcd-ca" "kube-apiserver-etcd-client" "system:masters" "clientAuth"
sign_leaf "etcd-server" "etcd-ca" "kube-etcd" "" "serverAuth,clientAuth" "$ETCD_SANS"
sign_leaf "etcd-peer" "etcd-ca" "kube-etcd-peer" "" "serverAuth,clientAuth" "$ETCD_SANS"
sign_leaf "etcd-healthcheck-client" "etcd-ca" "kube-etcd-healthcheck-client" "" "clientAuth"
sign_leaf "admin" "cluster-ca" "kubernetes-admin" "system:masters" "clientAuth"
sign_leaf "super-admin" "cluster-ca" "kubernetes-super-admin" "system:masters" "clientAuth"
sign_leaf "controller-manager" "cluster-ca" "system:kube-controller-manager" "system:kube-controller-manager" "clientAuth"
sign_leaf "scheduler" "cluster-ca" "system:kube-scheduler" "system:kube-scheduler" "clientAuth"

write_kubeconfig "$BOOTSTRAP_PKI_DIR/admin.conf" "$KUBECONFIG_SERVER" "$BOOTSTRAP_PKI_DIR/cluster-ca.crt" "kubernetes-admin" "$BOOTSTRAP_PKI_DIR/admin.crt" "$BOOTSTRAP_PKI_DIR/admin.key"
write_kubeconfig "$BOOTSTRAP_PKI_DIR/kubelet.conf" "$KUBECONFIG_SERVER" "$BOOTSTRAP_PKI_DIR/cluster-ca.crt" "$KUBELET_AUTH_USER" "$BOOTSTRAP_PKI_DIR/admin.crt" "$BOOTSTRAP_PKI_DIR/admin.key"
write_kubeconfig "$BOOTSTRAP_PKI_DIR/super-admin.conf" "$KUBECONFIG_SERVER" "$BOOTSTRAP_PKI_DIR/cluster-ca.crt" "kubernetes-super-admin" "$BOOTSTRAP_PKI_DIR/super-admin.crt" "$BOOTSTRAP_PKI_DIR/super-admin.key"
write_kubeconfig "$BOOTSTRAP_PKI_DIR/controller-manager.conf" "https://127.0.0.1:6443" "$BOOTSTRAP_PKI_DIR/cluster-ca.crt" "system:kube-controller-manager" "$BOOTSTRAP_PKI_DIR/controller-manager.crt" "$BOOTSTRAP_PKI_DIR/controller-manager.key"
write_kubeconfig "$BOOTSTRAP_PKI_DIR/scheduler.conf" "https://127.0.0.1:6443" "$BOOTSTRAP_PKI_DIR/cluster-ca.crt" "system:kube-scheduler" "$BOOTSTRAP_PKI_DIR/scheduler.crt" "$BOOTSTRAP_PKI_DIR/scheduler.key"

apply_secrets

mkdir -p "$OUT_DIR/workload/bootstrap-pki"
cp "$BOOTSTRAP_PKI_DIR/cluster-ca.crt" "$OUT_DIR/workload/bootstrap-pki/kubernetes-ca.crt"

cleanup_temp_files

log "static external-ca secrets refreshed successfully"
