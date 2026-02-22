#!/usr/bin/env bash

external_ca_contract_file() {
  echo "${EXTERNAL_CA_CONTRACT_FILE:-$POC_DIR/contracts/external-ca-files.contract.tsv}"
}

external_ca_contract_entries() {
  local contract_file
  contract_file="$(external_ca_contract_file)"
  if [[ ! -s "$contract_file" ]]; then
    echo "missing external-ca contract file: $contract_file" >&2
    return 1
  fi
  awk -F'\t' 'NF >= 4 && $1 !~ /^[[:space:]]*#/ {print $1"\t"$2"\t"$3"\t"$4}' "$contract_file"
}

external_ca_contract_from_file_args() {
  local material_dir="$1"
  local key material_rel _target _perm
  while IFS=$'\t' read -r key material_rel _target _perm; do
    [[ -n "$key" ]] || continue
    printf '%s\n' "--from-file=${key}=${material_dir}/${material_rel}"
  done < <(external_ca_contract_entries)
}

external_ca_contract_kcp_files_yaml() {
  local secret_name="$1"
  local key _material_rel target perm

  while IFS=$'\t' read -r key _material_rel target perm; do
    [[ -n "$key" ]] || continue
    cat <<YAML
    - path: ${target}
      owner: root:root
      permissions: "${perm}"
      contentFrom:
        secret:
          name: ${secret_name}
          key: ${key}
YAML
  done < <(external_ca_contract_entries)
}
