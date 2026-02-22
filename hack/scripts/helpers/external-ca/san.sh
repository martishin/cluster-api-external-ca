#!/usr/bin/env bash

trim_csv_lines() {
  tr ',' '\n' | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) print}'
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

host_from_server() {
  local url="$1"
  local authority host

  authority="${url#*://}"
  authority="${authority%%/*}"
  if [[ "$authority" =~ ^\[(.*)\](:[0-9]+)?$ ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$authority" =~ ^([^:]+):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  else
    host="$authority"
  fi
  printf '%s\n' "$host"
}

is_ipv4() {
  local candidate="$1"
  [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  local candidate="$1"
  [[ "$candidate" == *:* ]]
}

render_san_block() {
  local sans_csv="$1"
  local line
  local first=true

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$first" == true ]]; then
      printf 'subjectAltName='
      first=false
    else
      printf ','
    fi

    if is_ipv4 "$line" || is_ipv6 "$line"; then
      printf 'IP:%s' "$line"
    else
      printf 'DNS:%s' "$line"
    fi
  done < <(printf '%s\n' "$sans_csv" | trim_csv_lines | unique_lines)

  if [[ "$first" == false ]]; then
    printf '\n'
  fi
}

build_sans() {
  local defaults="$1"
  local extras="$2"

  {
    printf '%s\n' "$defaults" | trim_csv_lines
    printf '%s\n' "$extras" | trim_csv_lines
  } | unique_lines | paste -sd, -
}
