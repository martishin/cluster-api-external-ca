#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/env.sh"
source "$SCRIPT_DIR/utils/kube.sh"

require_bin kind kubectl docker

resolve_docker_socket_path() {
  local default_sock="/var/run/docker.sock"
  local resolved=""
  local link_target=""

  if [[ -L "$default_sock" ]]; then
    link_target="$(readlink "$default_sock" || true)"
    if [[ -n "$link_target" ]]; then
      if [[ "$link_target" = /* ]]; then
        resolved="$link_target"
      else
        resolved="$(cd "$(dirname "$default_sock")" && cd "$(dirname "$link_target")" && pwd)/$(basename "$link_target")"
      fi
    fi
  fi

  if [[ -z "$resolved" ]]; then
    resolved="$default_sock"
  fi

  if [[ ! -S "$resolved" ]]; then
    echo "docker socket not found: $resolved" >&2
    return 1
  fi

  printf '%s\n' "$resolved"
}

log "resetting local management kind cluster"
kind delete cluster --name capi-mgmt >/dev/null 2>&1 || true
"$POC_DIR/scripts/setup/cleanup-local-capd-artifacts.sh"

rm -rf "$MGMT_WORK_DIR"
mkdir -p "$MGMT_WORK_DIR"

docker_socket_host_path="$(resolve_docker_socket_path)"
kind_config="$(mktemp)"
trap 'rm -f "$kind_config"' EXIT
sed "s|hostPath: /var/run/docker.sock|hostPath: ${docker_socket_host_path}|g" "$POC_DIR/env/kind-mgmt.yaml" > "$kind_config"

log "creating kind management cluster capi-mgmt"
kind create cluster --name capi-mgmt --config "$kind_config" --kubeconfig "$MGMT_KUBECONFIG"

log "writing management kubeconfig to $MGMT_KUBECONFIG"
kind get kubeconfig --name capi-mgmt > "$MGMT_KUBECONFIG"

log "kind management cluster is ready"
