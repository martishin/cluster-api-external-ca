#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"

pattern='^(self-signed-ca-cluster|external-ca-cluster)(-|$)'

mapfile -t capd_containers < <(docker ps -a --format '{{.Names}}' | rg "$pattern" || true)
if (( ${#capd_containers[@]} > 0 )); then
  log "removing stale CAPD workload containers: ${#capd_containers[@]}"
  docker rm -f "${capd_containers[@]}" >/dev/null
fi

mapfile -t capd_networks < <(docker network ls --format '{{.Name}}' | rg "$pattern" || true)
if (( ${#capd_networks[@]} > 0 )); then
  log "removing stale CAPD workload networks: ${#capd_networks[@]}"
  docker network rm "${capd_networks[@]}" >/dev/null 2>&1 || true
fi
