#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"

require_bin kubectl kind docker openssl go helm git make rg jq
log "all required binaries found"

if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not reachable (start Docker and retry)" >&2
  exit 1
fi
log "docker daemon is reachable"

ensure_out_dirs
log "output directory: $OUT_DIR"
log "management work directory: $MGMT_WORK_DIR"
