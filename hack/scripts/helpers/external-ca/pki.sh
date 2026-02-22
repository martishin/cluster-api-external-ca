#!/usr/bin/env bash

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
  local crt="$BOOTSTRAP_PKI_DIR/${prefix}.crt"
  local key="$BOOTSTRAP_PKI_DIR/${prefix}.key"
  local cfg="$BOOTSTRAP_PKI_DIR/${prefix}-ca.cnf"

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
  local sa_pub="$BOOTSTRAP_PKI_DIR/sa.pub"
  local sa_key="$BOOTSTRAP_PKI_DIR/sa.key"

  if [[ -s "$sa_pub" && -s "$sa_key" ]]; then
    return 0
  fi

  if kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-sa" >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-sa" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$sa_pub"
    kubectl -n "$NAMESPACE" get secret "${CLUSTER_NAME}-sa" -o jsonpath='{.data.tls\.key}' | base64 -d > "$sa_key"
  fi
}

ensure_sa() {
  local sa_pub="$BOOTSTRAP_PKI_DIR/sa.pub"
  local sa_key="$BOOTSTRAP_PKI_DIR/sa.key"

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

  local key="$BOOTSTRAP_PKI_DIR/${out_prefix}.key"
  local csr="$BOOTSTRAP_PKI_DIR/${out_prefix}.csr"
  local crt="$BOOTSTRAP_PKI_DIR/${out_prefix}.crt"
  local ext="$BOOTSTRAP_PKI_DIR/${out_prefix}.ext"
  local ca_crt="$BOOTSTRAP_PKI_DIR/${ca_prefix}.crt"
  local ca_key="$BOOTSTRAP_PKI_DIR/${ca_prefix}.key"
  local serial="$BOOTSTRAP_PKI_DIR/${ca_prefix}.srl"

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

cleanup_temp_files() {
  rm -f \
    "$BOOTSTRAP_PKI_DIR"/*.csr \
    "$BOOTSTRAP_PKI_DIR"/*.ext \
    "$BOOTSTRAP_PKI_DIR"/*-ca.cnf
}
