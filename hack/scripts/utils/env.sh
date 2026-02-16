#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
POC_DIR="$ROOT_DIR/hack"
OUT_DIR="$ROOT_DIR/out"
OUT_BIN_DIR="${OUT_BIN_DIR:-$OUT_DIR/bin}"
TMP_WORK_DIR="${TMP_WORK_DIR:-$OUT_DIR/mgmt}"
MGMT_KUBECONFIG="${MGMT_KUBECONFIG:-$TMP_WORK_DIR/mgmt.kubeconfig}"

export PATH="$OUT_BIN_DIR:$PATH"
export OUT_BIN_DIR
export TMP_WORK_DIR
export MGMT_KUBECONFIG
if [[ -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG="$MGMT_KUBECONFIG"
fi

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

require_bin() {
  local bin
  for bin in "$@"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "missing required binary: $bin" >&2
      exit 1
    fi
  done
}

ensure_out_dirs() {
  mkdir -p "$OUT_DIR/results" "$OUT_BIN_DIR"
}
