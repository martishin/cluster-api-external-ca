#!/usr/bin/env bash

reroll_jq_patch_common_defs() {
  cat <<'JQ'
def ensure_cmd($arr; $cmd):
  ($arr // []) as $base |
  if ($base | index($cmd)) == null then $base + [$cmd] else $base end;
def ensure_list_value($arr; $value):
  ($arr // []) as $base |
  if ($base | index($value)) == null then $base + [$value] else $base end;
def remove_cmd($arr; $cmd):
  ($arr // []) | map(select(. != $cmd));
def ensure_file($arr; $path; $perm; $key; $secret):
  ($arr // []) as $base |
  if ($base | map(.path == $path) | any) then
    $base | map(
      if .path == $path then
        . + {
          path: $path,
          owner: "root:root",
          permissions: $perm,
          contentFrom: {secret: {name: $secret, key: $key}}
        }
      else . end
    )
  else
    $base + [{
      path: $path,
      owner: "root:root",
      permissions: $perm,
      contentFrom: {secret: {name: $secret, key: $key}}
    }]
  end;
def remove_file($arr; $path):
  ($arr // []) | map(select(.path != $path));
JQ
}

reroll_require_signer_secret_keys() {
  local namespace="$1"
  local secret_name="$2"
  shift 2

  local key expr
  if [[ "$#" -eq 0 ]]; then
    echo "internal error: reroll signer key list is empty" >&2
    return 1
  fi

  if ! kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
    echo "missing signer secret in management namespace: $secret_name (run 07-deploy-workload-step-ca first)" >&2
    return 1
  fi

  expr=""
  for key in "$@"; do
    if [[ -n "$expr" ]]; then
      expr+=" and "
    fi
    expr+="(.data[\"$key\"] != null)"
  done

  if ! kubectl -n "$namespace" get secret "$secret_name" -o json | jq -e "$expr" >/dev/null; then
    echo "signer secret is missing required keys: $secret_name" >&2
    return 1
  fi
}
