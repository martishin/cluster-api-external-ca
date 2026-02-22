#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/env.sh"
source "$SCRIPT_DIR/utils/flow.sh"
source "$SCRIPT_DIR/utils/stepca.sh"

MODE="$(mode_from_args "${1:-}")"
cluster_name="$(cluster_name_for_mode "$MODE")"
cluster_namespace="${NAMESPACE:-default}"
workload_kubeconfig="$(workload_kubeconfig_for_mode "$MODE")"
provisioner_key_file=""

if [[ ! -s "$workload_kubeconfig" ]]; then
  echo "workload kubeconfig not found: $workload_kubeconfig (run 06-provision-cluster first)" >&2
  exit 1
fi

bootstrap_bundle="$(stepca_bundle_dir bootstrap)"
workload_bundle="$(stepca_bundle_dir workload)"
provisioner_password_file="$workload_bundle/provisioner_password.txt"
if [[ ! -d "$bootstrap_bundle" ]]; then
  echo "bootstrap step-ca bundle is missing: $bootstrap_bundle" >&2
  exit 1
fi

if [[ ! -d "$workload_bundle" ]]; then
  mkdir -p "$(dirname "$workload_bundle")"
  cp -R "$bootstrap_bundle" "$workload_bundle"
fi
if [[ ! -s "$provisioner_password_file" && -s "$workload_bundle/secrets/provisioner_password" ]]; then
  provisioner_password_file="$workload_bundle/secrets/provisioner_password"
fi

provisioner_key_file="$workload_bundle/provisioner-${STEPCA_PROVISIONER}.jwk"
if [[ ! -s "$provisioner_key_file" ]]; then
  require_bin jq docker
  encrypted_key="$(jq -r --arg p "$STEPCA_PROVISIONER" '.authority.provisioners[] | select(.name == $p) | .encryptedKey' "$workload_bundle/config/ca.json")"
  if [[ -z "$encrypted_key" || "$encrypted_key" == "null" ]]; then
    echo "unable to locate encrypted provisioner key for provisioner=$STEPCA_PROVISIONER" >&2
    exit 1
  fi
  provisioner_password_rel="${provisioner_password_file#$workload_bundle/}"
  provisioner_password_container="/home/step/${provisioner_password_rel}"
  printf '%s' "$encrypted_key" | docker run --rm -i \
    -u "$(id -u):$(id -g)" \
    -v "$workload_bundle:/home/step" \
    -e STEPPATH=/home/step \
    "$STEP_CLI_IMAGE" sh -ceu \
    "step crypto jwe decrypt --password-file \"$provisioner_password_container\"" > "$provisioner_key_file"
  chmod 0600 "$provisioner_key_file"
fi

log "deploying workload step-ca to cluster=$cluster_name"
stepca_apply_bundle "$workload_kubeconfig" "$workload_bundle" "$STEPCA_NAMESPACE" "$STEPCA_NAME"

log "creating workload signer auth secret contract object"
kubectl --kubeconfig "$workload_kubeconfig" -n "$STEPCA_NAMESPACE" create secret generic step-ca-bootstrap-client \
  --from-file=ca.crt="$workload_bundle/certs/root_ca.crt" \
  --from-file=tls.crt="$workload_bundle/certs/intermediate_ca.crt" \
  --from-file=tls.key="$workload_bundle/secrets/intermediate_ca_key" \
  --from-file=provisioner-password="$provisioner_password_file" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$workload_kubeconfig" apply -f -

if [[ "$MODE" == "external-ca" ]]; then
  log "creating management-side signer auth secret for external-ca flow"
  kubectl -n "$cluster_namespace" create secret generic "${cluster_name}-step-ca-bootstrap-client" \
    --from-file=ca.crt="$workload_bundle/certs/root_ca.crt" \
    --from-file=tls.crt="$workload_bundle/certs/intermediate_ca.crt" \
    --from-file=tls.key="$workload_bundle/secrets/intermediate_ca_key" \
    --from-file=provisioner-password="$provisioner_password_file" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$cluster_namespace" create secret generic "${cluster_name}-step-ca-signer" \
    --from-file=provisioner-key="$provisioner_key_file" \
    --from-file=provisioner-password="$provisioner_password_file" \
    --from-file=root-ca.crt="$workload_bundle/certs/root_ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

log "workload step-ca deployment completed for mode=$MODE"
