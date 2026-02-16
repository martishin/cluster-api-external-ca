#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

require_bin kubectl kind docker openssl go helm git make
log "all required binaries found"

if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not reachable (start Docker and retry)" >&2
  exit 1
fi
log "docker daemon is reachable"

mkdir -p "$OUT_DIR"
mkdir -p "$TMP_WORK_DIR"
log "output directory: $OUT_DIR"
log "temporary work directory: $TMP_WORK_DIR"
