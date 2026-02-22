#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"

require_bin kubectl openssl awk sort base64

CLUSTER_NAME="${CLUSTER_NAME:-external-ca-cluster}"
NAMESPACE="${NAMESPACE:-default}"
FILES_SECRET_NAME="${FILES_SECRET_NAME:-${CLUSTER_NAME}-external-ca-files}"
MATERIAL_DIR="${MATERIAL_DIR:-$OUT_DIR/workload/material}"
KUBECONFIG_SERVER="${KUBECONFIG_SERVER:-https://${CLUSTER_NAME}-lb:6443}"
KUBELET_AUTH_USER="${KUBELET_AUTH_USER:-kubernetes-admin}"
APISERVER_SANS_EXTRA="${APISERVER_SANS_EXTRA:-}"
ETCD_SANS_EXTRA="${ETCD_SANS_EXTRA:-}"

mkdir -p "$MATERIAL_DIR"

trim_csv_lines() {
  tr ',' '\n' | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) print}'
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

host_from_server() {
  local url="$1"
  local authority host

  authority="${url#*://}"
  authority="${authority%%/*}"
  if [[ "$authority" =~ ^\[(.*)\](:[0-9]+)?$ ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$authority" =~ ^([^:]+):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  else
    host="$authority"
  fi
  printf '%s\n' "$host"
}

is_ipv4() {
  local candidate="$1"
  [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  local candidate="$1"
  [[ "$candidate" == *:* ]]
}

render_san_block() {
  local sans_csv="$1"
  local line
  local first=true

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$first" == true ]]; then
      printf 'subjectAltName='
      first=false
    else
      printf ','
    fi

    if is_ipv4 "$line" || is_ipv6 "$line"; then
      printf 'IP:%s' "$line"
    else
      printf 'DNS:%s' "$line"
    fi
  done < <(printf '%s\n' "$sans_csv" | trim_csv_lines | unique_lines)

  if [[ "$first" == false ]]; then
    printf '\n'
  fi
}

ca_req_config() {
  local cn="$1"
  local cfg="$2"
  cat > "$cfg" <<CFG
[ req ]
default_md = sha256
prompt = no
distinguished_name = dn
x509_extensions = v3_ca

[ dn ]
CN = ${cn}

[ v3_ca ]
basicConstraints = critical,CA:TRUE,pathlen:1
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
CFG
}

leaf_req_config() {
  local eku="$1"
  local sans_csv="$2"
  local cfg="$3"

  {
    cat <<CFG
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=${eku}
CFG
    render_san_block "$sans_csv"
  } > "$cfg"
}

ensure_ca() {
  local prefix="$1"
  local cn="$2"
  local crt="$MATERIAL_DIR/${prefix}.crt"
  local key="$MATERIAL_DIR/${prefix}.key"
  local cfg="$MATERIAL_DIR/${prefix}-ca.cnf"

  if [[ -s "$crt" && -s "$key" ]]; then
    return 0
  fi

  ca_req_config "$cn" "$cfg"
  openssl req -x509 -new -nodes -newkey rsa:4096 \
    -days 3650 \
    -config "$cfg" \
    -keyout "$key" \
    -out "$crt" >/dev/null 2>&1
}

load_sa_from_cluster_if_missing() {
  local sa_pub="$MATERIAL_DIR/sa.pub"
  local sa_key="$MATERIAL_DIR/sa.key"

  if [[ -s "$sa_pub" && -s "$sa_key" ]]; then
    return 0
  fi

  if kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-sa" >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-sa" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$sa_pub"
    kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-sa" -o jsonpath='{.data.tls\.key}' | base64 -d > "$sa_key"
  fi
}

ensure_sa() {
  local sa_pub="$MATERIAL_DIR/sa.pub"
  local sa_key="$MATERIAL_DIR/sa.key"

  load_sa_from_cluster_if_missing
  if [[ -s "$sa_pub" && -s "$sa_key" ]]; then
    return 0
  fi

  openssl genrsa -out "$sa_key" 2048 >/dev/null 2>&1
  openssl rsa -in "$sa_key" -pubout -out "$sa_pub" >/dev/null 2>&1
}

subject_for() {
  local cn="$1"
  local org="${2:-}"

  if [[ -n "$org" ]]; then
    printf '/CN=%s/O=%s\n' "$cn" "$org"
  else
    printf '/CN=%s\n' "$cn"
  fi
}

sign_leaf() {
  local out_prefix="$1"
  local ca_prefix="$2"
  local cn="$3"
  local org="${4:-}"
  local eku="$5"
  local sans_csv="${6:-}"

  local key="$MATERIAL_DIR/${out_prefix}.key"
  local csr="$MATERIAL_DIR/${out_prefix}.csr"
  local crt="$MATERIAL_DIR/${out_prefix}.crt"
  local ext="$MATERIAL_DIR/${out_prefix}.ext"
  local ca_crt="$MATERIAL_DIR/${ca_prefix}.crt"
  local ca_key="$MATERIAL_DIR/${ca_prefix}.key"
  local serial="$MATERIAL_DIR/${ca_prefix}.srl"

  leaf_req_config "$eku" "$sans_csv" "$ext"
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$key" \
    -out "$csr" \
    -subj "$(subject_for "$cn" "$org")" >/dev/null 2>&1

  openssl x509 -req -in "$csr" \
    -CA "$ca_crt" -CAkey "$ca_key" \
    -CAserial "$serial" -CAcreateserial \
    -out "$crt" \
    -days 365 \
    -extfile "$ext" >/dev/null 2>&1
}

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

  # kubectl config set-cluster embeds only the first cert block; force full chain bytes.
  ca_data="$(base64 < "$ca_crt" | tr -d '\n')"
  KUBECONFIG="$out_file" kubectl config set clusters.default.certificate-authority-data "$ca_data" >/dev/null
}

labeled_apply() {
  kubectl label --local --overwrite -f - "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o yaml | kubectl apply -f - >/dev/null
}

apply_secrets() {
  local cluster_ca="$MATERIAL_DIR/cluster-ca.crt"
  local front_ca="$MATERIAL_DIR/front-proxy-ca.crt"
  local etcd_ca="$MATERIAL_DIR/etcd-ca.crt"

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
    --from-file=tls.crt="$MATERIAL_DIR/sa.pub" \
    --from-file=tls.key="$MATERIAL_DIR/sa.key" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-kubeconfig" \
    --type Opaque \
    --from-file=value="$MATERIAL_DIR/admin.conf" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "${CLUSTER_NAME}-apiserver-etcd-client" \
    --type Opaque \
    --from-file=tls.crt="$MATERIAL_DIR/apiserver-etcd-client.crt" \
    --from-file=tls.key="$MATERIAL_DIR/apiserver-etcd-client.key" \
    --dry-run=client -o yaml | labeled_apply

  kubectl -n "$NAMESPACE" create secret generic "$FILES_SECRET_NAME" \
    --type Opaque \
    --from-file=pki-ca-crt="$MATERIAL_DIR/cluster-ca.crt" \
    --from-file=pki-front-proxy-ca-crt="$MATERIAL_DIR/front-proxy-ca.crt" \
    --from-file=pki-etcd-ca-crt="$MATERIAL_DIR/etcd-ca.crt" \
    --from-file=pki-sa-pub="$MATERIAL_DIR/sa.pub" \
    --from-file=pki-sa-key="$MATERIAL_DIR/sa.key" \
    --from-file=pki-apiserver-crt="$MATERIAL_DIR/apiserver.crt" \
    --from-file=pki-apiserver-key="$MATERIAL_DIR/apiserver.key" \
    --from-file=pki-apiserver-kubelet-client-crt="$MATERIAL_DIR/apiserver-kubelet-client.crt" \
    --from-file=pki-apiserver-kubelet-client-key="$MATERIAL_DIR/apiserver-kubelet-client.key" \
    --from-file=pki-front-proxy-client-crt="$MATERIAL_DIR/front-proxy-client.crt" \
    --from-file=pki-front-proxy-client-key="$MATERIAL_DIR/front-proxy-client.key" \
    --from-file=pki-apiserver-etcd-client-crt="$MATERIAL_DIR/apiserver-etcd-client.crt" \
    --from-file=pki-apiserver-etcd-client-key="$MATERIAL_DIR/apiserver-etcd-client.key" \
    --from-file=pki-etcd-server-crt="$MATERIAL_DIR/etcd-server.crt" \
    --from-file=pki-etcd-server-key="$MATERIAL_DIR/etcd-server.key" \
    --from-file=pki-etcd-peer-crt="$MATERIAL_DIR/etcd-peer.crt" \
    --from-file=pki-etcd-peer-key="$MATERIAL_DIR/etcd-peer.key" \
    --from-file=pki-etcd-healthcheck-client-crt="$MATERIAL_DIR/etcd-healthcheck-client.crt" \
    --from-file=pki-etcd-healthcheck-client-key="$MATERIAL_DIR/etcd-healthcheck-client.key" \
    --from-file=kubeconfig-admin="$MATERIAL_DIR/admin.conf" \
    --from-file=kubeconfig-kubelet="$MATERIAL_DIR/kubelet.conf" \
    --from-file=kubeconfig-super-admin="$MATERIAL_DIR/super-admin.conf" \
    --from-file=kubeconfig-controller-manager="$MATERIAL_DIR/controller-manager.conf" \
    --from-file=kubeconfig-scheduler="$MATERIAL_DIR/scheduler.conf" \
    --dry-run=client -o yaml | labeled_apply
}

cleanup_temp_files() {
  rm -f \
    "$MATERIAL_DIR"/*.csr \
    "$MATERIAL_DIR"/*.ext \
    "$MATERIAL_DIR"/*-ca.cnf
}

build_sans() {
  local defaults="$1"
  local extras="$2"

  {
    printf '%s\n' "$defaults" | trim_csv_lines
    printf '%s\n' "$extras" | trim_csv_lines
  } | unique_lines | paste -sd, -
}

cluster_endpoint_host="$(host_from_server "$KUBECONFIG_SERVER")"

apiserver_default_sans='kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster.local,10.96.0.1,localhost,127.0.0.1,::1'
etcd_default_sans='localhost,127.0.0.1,::1'

APISERVER_SANS="$(build_sans "$apiserver_default_sans" "${APISERVER_SANS_EXTRA},${cluster_endpoint_host}")"
ETCD_SANS="$(build_sans "$etcd_default_sans" "${ETCD_SANS_EXTRA}")"

log "preparing static external-ca material for cluster=$CLUSTER_NAME namespace=$NAMESPACE"
log "material dir: $MATERIAL_DIR"
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

write_kubeconfig "$MATERIAL_DIR/admin.conf" "$KUBECONFIG_SERVER" "$MATERIAL_DIR/cluster-ca.crt" "kubernetes-admin" "$MATERIAL_DIR/admin.crt" "$MATERIAL_DIR/admin.key"
write_kubeconfig "$MATERIAL_DIR/kubelet.conf" "$KUBECONFIG_SERVER" "$MATERIAL_DIR/cluster-ca.crt" "$KUBELET_AUTH_USER" "$MATERIAL_DIR/admin.crt" "$MATERIAL_DIR/admin.key"
write_kubeconfig "$MATERIAL_DIR/super-admin.conf" "$KUBECONFIG_SERVER" "$MATERIAL_DIR/cluster-ca.crt" "kubernetes-super-admin" "$MATERIAL_DIR/super-admin.crt" "$MATERIAL_DIR/super-admin.key"
write_kubeconfig "$MATERIAL_DIR/controller-manager.conf" "https://127.0.0.1:6443" "$MATERIAL_DIR/cluster-ca.crt" "system:kube-controller-manager" "$MATERIAL_DIR/controller-manager.crt" "$MATERIAL_DIR/controller-manager.key"
write_kubeconfig "$MATERIAL_DIR/scheduler.conf" "https://127.0.0.1:6443" "$MATERIAL_DIR/cluster-ca.crt" "system:kube-scheduler" "$MATERIAL_DIR/scheduler.crt" "$MATERIAL_DIR/scheduler.key"

apply_secrets

mkdir -p "$OUT_DIR/workload/material"
cp "$MATERIAL_DIR/cluster-ca.crt" "$OUT_DIR/workload/material/kubernetes-ca.crt"

cleanup_temp_files

log "static external-ca secrets refreshed successfully"
