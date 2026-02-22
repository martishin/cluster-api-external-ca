#!/usr/bin/env bash

STEP_CLI_IMAGE="${STEP_CLI_IMAGE:-smallstep/step-cli:0.28.7}"
STEP_CA_IMAGE="${STEP_CA_IMAGE:-smallstep/step-ca:0.27.4}"
STEPCA_NAMESPACE="${STEPCA_NAMESPACE:-external-ca-system}"
STEPCA_NAME="${STEPCA_NAME:-step-ca}"
STEPCA_PORT="${STEPCA_PORT:-9000}"
STEPCA_PROVISIONER="${STEPCA_PROVISIONER:-admin}"
STEPCA_X509_TEMPLATE_CSR_PASSTHROUGH='{{ toJson .Insecure.CR }}'

stepca_bundle_dir() {
  local role="${1:-bootstrap}"
  echo "$OUT_DIR/step-ca/$role"
}

stepca_patch_provisioner_template() {
  local ca_json="$1"
  local tmp_json

  if [[ ! -s "$ca_json" ]]; then
    echo "missing step-ca config file: $ca_json" >&2
    return 1
  fi

  require_bin jq
  tmp_json="$(mktemp)"
  jq \
    --arg provisioner "$STEPCA_PROVISIONER" \
    --arg template "$STEPCA_X509_TEMPLATE_CSR_PASSTHROUGH" '
      .authority.provisioners |= map(
        if .name == $provisioner then
          .options = (
            (.options // {}) + {
              x509: ((.options.x509 // {}) + {template: $template})
            }
          )
        else
          .
        end
      )
    ' "$ca_json" > "$tmp_json"
  mv "$tmp_json" "$ca_json"
}

stepca_generate_bundle() {
  local bundle_dir="$1"
  local dns_name="${2:-${STEPCA_NAME}.${STEPCA_NAMESPACE}.svc.cluster.local}"

  mkdir -p "$bundle_dir"
  if [[ -s "$bundle_dir/config/ca.json" && -s "$bundle_dir/certs/intermediate_ca.crt" && -s "$bundle_dir/secrets/intermediate_ca_key" ]]; then
    stepca_patch_provisioner_template "$bundle_dir/config/ca.json"
    if [[ -s "$bundle_dir/password.txt" ]]; then
      mkdir -p "$bundle_dir/secrets"
      [[ -s "$bundle_dir/secrets/password" ]] || cp "$bundle_dir/password.txt" "$bundle_dir/secrets/password"
    fi
    if [[ -s "$bundle_dir/provisioner_password.txt" ]]; then
      mkdir -p "$bundle_dir/secrets"
      [[ -s "$bundle_dir/secrets/provisioner_password" ]] || cp "$bundle_dir/provisioner_password.txt" "$bundle_dir/secrets/provisioner_password"
    fi
    log "step-ca bundle already exists: $bundle_dir"
    return 0
  fi

  require_bin docker openssl

  log "generating step-ca bundle at $bundle_dir (dns=$dns_name)"
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"

  openssl rand -hex 24 > "$bundle_dir/password.txt"
  openssl rand -hex 24 > "$bundle_dir/provisioner_password.txt"
  mkdir -p "$bundle_dir/secrets"
  cp "$bundle_dir/password.txt" "$bundle_dir/secrets/password"
  cp "$bundle_dir/provisioner_password.txt" "$bundle_dir/secrets/provisioner_password"
  chmod 0600 "$bundle_dir/password.txt" "$bundle_dir/provisioner_password.txt"
  chmod 0600 "$bundle_dir/secrets/password" "$bundle_dir/secrets/provisioner_password"

  docker run --rm \
    -u "$(id -u):$(id -g)" \
    -e STEPPATH=/home/step \
    -v "$bundle_dir:/home/step" \
    "$STEP_CLI_IMAGE" \
    sh -ceu "
      step ca init \
        --name 'CAPI External CA' \
        --dns '$dns_name' \
        --address ':${STEPCA_PORT}' \
        --provisioner '${STEPCA_PROVISIONER}' \
        --password-file /home/step/password.txt \
        --provisioner-password-file /home/step/provisioner_password.txt \
        --with-ca-url 'https://${dns_name}:${STEPCA_PORT}' \
        --deployment-type standalone
    "

  stepca_patch_provisioner_template "$bundle_dir/config/ca.json"
}

stepca_apply_bundle() {
  local kubeconfig="$1"
  local bundle_dir="$2"
  local namespace="${3:-$STEPCA_NAMESPACE}"
  local app_name="${4:-$STEPCA_NAME}"
  local password_file provisioner_password_file manifest_template

  require_bin kubectl

  if [[ ! -s "$bundle_dir/config/ca.json" ]]; then
    echo "missing step-ca config: $bundle_dir/config/ca.json" >&2
    return 1
  fi
  password_file="$bundle_dir/secrets/password"
  if [[ ! -s "$password_file" ]]; then
    password_file="$bundle_dir/password.txt"
  fi
  provisioner_password_file="$bundle_dir/secrets/provisioner_password"
  if [[ ! -s "$provisioner_password_file" ]]; then
    provisioner_password_file="$bundle_dir/provisioner_password.txt"
  fi

  kubectl --kubeconfig "$kubeconfig" create namespace "$namespace" --dry-run=client -o yaml | kubectl --kubeconfig "$kubeconfig" apply -f -

  kubectl --kubeconfig "$kubeconfig" -n "$namespace" create configmap "${app_name}-config" \
    --from-file=ca.json="$bundle_dir/config/ca.json" \
    --dry-run=client -o yaml | kubectl --kubeconfig "$kubeconfig" apply -f -

  kubectl --kubeconfig "$kubeconfig" -n "$namespace" create secret generic "${app_name}-files" \
    --from-file=root_ca.crt="$bundle_dir/certs/root_ca.crt" \
    --from-file=intermediate_ca.crt="$bundle_dir/certs/intermediate_ca.crt" \
    --from-file=intermediate_ca_key="$bundle_dir/secrets/intermediate_ca_key" \
    --from-file=password="$password_file" \
    --from-file=provisioner-password="$provisioner_password_file" \
    --dry-run=client -o yaml | kubectl --kubeconfig "$kubeconfig" apply -f -

  manifest_template="$POC_DIR/manifests/templates/step-ca.yaml"
  if [[ ! -s "$manifest_template" ]]; then
    echo "missing step-ca manifest template: $manifest_template" >&2
    return 1
  fi

  sed \
    -e "s|__STEPCA_NAME__|${app_name}|g" \
    -e "s|__STEPCA_NAMESPACE__|${namespace}|g" \
    -e "s|__STEPCA_PORT__|${STEPCA_PORT}|g" \
    -e "s|__STEPCA_IMAGE__|${STEP_CA_IMAGE}|g" \
    "$manifest_template" | kubectl --kubeconfig "$kubeconfig" apply -f -

  kubectl --kubeconfig "$kubeconfig" -n "$namespace" rollout status "deployment/${app_name}" --timeout=5m
}
