#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../helpers/core/env.sh"
source "$SCRIPT_DIR/../helpers/core/mode-config.sh"

MODE="$(mode_from_args "${1:-}")"
ACTION="${2:-setup}"
CAPI_VERSION="${CAPI_VERSION:-v1.8.8}"

run_setup() {
  CAPI_VERSION="$CAPI_VERSION" "$SCRIPT_DIR/../steps/01-deploy-kind.sh" "$MODE"
  CAPI_VERSION="$CAPI_VERSION" FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/02-build-capi-images.sh" "$MODE"
  CAPI_VERSION="$CAPI_VERSION" FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/03-install-capi.sh" "$MODE"
  FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/04-deploy-bootstrap-step-ca.sh" "$MODE"

  if [[ "$MODE" == "external-ca" ]]; then
    FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/05-prepare-bootstrap-secrets.sh" "$MODE"
  fi

  FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/06-provision-cluster.sh" "$MODE"
  FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/07-deploy-workload-step-ca.sh" "$MODE"

  if [[ "$MODE" == "external-ca" ]]; then
    FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/08-reroll-control-plane.sh" "$MODE"
    FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/09-reroll-workers.sh" "$MODE"
  fi
}

run_validate() {
  FLOW_MODE="$MODE" "$SCRIPT_DIR/../steps/10-validate-cluster.sh" "$MODE"
}

case "$ACTION" in
  setup)
    run_setup
    ;;
  validate)
    run_validate
    ;;
  test)
    make clean
    run_setup
    run_validate
    ;;
  *)
    echo "usage: $0 <self-signed|external-ca> <setup|validate|test>" >&2
    exit 1
    ;;
esac
