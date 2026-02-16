#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

ADDR="${KMSSERVICE_MOCK_ADDR:-127.0.0.1:9443}"
STATE_DIR="${KMSSERVICE_MOCK_STATE_DIR:-$OUT_DIR/kmsservice-mock}"
CERT_DIR="${KMSSERVICE_MTLS_CERT_DIR:-$OUT_DIR/kmsservice-mtls}"
SERVER_CN="${KMSSERVICE_SERVER_CN:-kmsservice-mock}"
CLIENT_CN="${KMSSERVICE_CLIENT_CN:-bootstrap-client}"

mkdir -p "$STATE_DIR" "$CERT_DIR"

CA_KEY="$CERT_DIR/ca.key"
CA_CRT="$CERT_DIR/ca.crt"
SERVER_KEY="$CERT_DIR/server.key"
SERVER_CRT="$CERT_DIR/server.crt"
CLIENT_KEY="$CERT_DIR/client.key"
CLIENT_CRT="$CERT_DIR/client.crt"

if [[ ! -f "$CA_CRT" || ! -f "$CA_KEY" ]]; then
  log "generating kmsservice mTLS CA"
  openssl req -x509 -nodes -newkey rsa:4096 \
    -keyout "$CA_KEY" -out "$CA_CRT" -days 3650 \
    -subj "/CN=kmsservice-mtls-ca" >/dev/null 2>&1
fi

if [[ ! -f "$SERVER_CRT" || ! -f "$SERVER_KEY" ]]; then
  log "generating kmsservice server cert"
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$SERVER_KEY" -out "$CERT_DIR/server.csr" \
    -subj "/CN=$SERVER_CN" >/dev/null 2>&1
  cat > "$CERT_DIR/server-ext.cnf" <<CFG
subjectAltName=DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
CFG
  openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$SERVER_CRT" -days 365 \
    -extfile "$CERT_DIR/server-ext.cnf" >/dev/null 2>&1
fi

if [[ ! -f "$CLIENT_CRT" || ! -f "$CLIENT_KEY" ]]; then
  log "generating kmsservice client cert"
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$CLIENT_KEY" -out "$CERT_DIR/client.csr" \
    -subj "/CN=$CLIENT_CN" >/dev/null 2>&1
  cat > "$CERT_DIR/client-ext.cnf" <<CFG
extendedKeyUsage=clientAuth
CFG
  openssl x509 -req -in "$CERT_DIR/client.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$CLIENT_CRT" -days 365 \
    -extfile "$CERT_DIR/client-ext.cnf" >/dev/null 2>&1
fi

SERVER_CERT="$CERT_DIR/server.crt"
SERVER_KEY="$CERT_DIR/server.key"
CLIENT_CA="$CERT_DIR/ca.crt"

log "starting kmsservice-mock on $ADDR"
log "state dir: $STATE_DIR"

exec go run "$ROOT_DIR/cmd/kmsservice-mock" \
  --addr "$ADDR" \
  --state-dir "$STATE_DIR" \
  --server-cert "$SERVER_CERT" \
  --server-key "$SERVER_KEY" \
  --client-ca "$CLIENT_CA" \
  --allowed-client-cn "$CLIENT_CN"
