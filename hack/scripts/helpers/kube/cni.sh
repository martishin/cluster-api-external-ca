#!/usr/bin/env bash

install_workload_cni() {
  local kubeconfig="$1"
  local timeout="${2:-20m}"
  local cilium_chart_version="1.16.7"
  local cilium_operator_replicas="${CILIUM_OPERATOR_REPLICAS:-1}"
  local i

  log "installing workload CNI: cilium (chart v${cilium_chart_version}, operator replicas=${cilium_operator_replicas})"
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  for ((i=1; i<=6; i++)); do
    if helm --kubeconfig "$kubeconfig" upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      --version "$cilium_chart_version" \
      --set ipam.mode=kubernetes \
      --set kubeProxyReplacement=false \
      --set operator.replicas="$cilium_operator_replicas" \
      --wait --timeout "$timeout"; then
      break
    fi
    if [[ "$i" -eq 6 ]]; then
      echo "FAIL: unable to install cilium after retries" >&2
      return 1
    fi
    log "cilium install failed (attempt ${i}/6), retrying in 10s"
    sleep 10
  done
  kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status daemonset/cilium --timeout="$timeout"
  kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status deployment/cilium-operator --timeout="$timeout"
}

assert_cilium_healthy() {
  local kubeconfig="$1"
  local results_file="${2:-}"
  local ds_ready ds_desired op_available ds_state

  ds_state="$(
    kubectl --kubeconfig "$kubeconfig" -n kube-system get daemonset cilium \
      -o jsonpath='{.status.numberReady} {.status.desiredNumberScheduled}' 2>/dev/null || true
  )"
  if [[ -z "${ds_state// }" ]]; then
    echo "FAIL: unable to read cilium daemonset status" >&2
    return 1
  fi
  read -r ds_ready ds_desired <<<"$ds_state"
  op_available="$(kubectl --kubeconfig "$kubeconfig" -n kube-system get deployment cilium-operator \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  op_available="${op_available:-0}"

  if [[ "${ds_desired:-0}" -eq 0 || "${ds_ready:-0}" -ne "${ds_desired:-0}" ]]; then
    echo "FAIL: cilium daemonset not healthy (ready=${ds_ready:-0} desired=${ds_desired:-0})" >&2
    return 1
  fi
  if [[ "${op_available:-0}" -lt 1 ]]; then
    echo "FAIL: cilium-operator has no available replicas" >&2
    return 1
  fi

  if [[ -n "$results_file" ]]; then
    mkdir -p "$(dirname "$results_file")"
    kubectl --kubeconfig "$kubeconfig" -n kube-system get pods -l k8s-app=cilium -o wide > "$results_file"
  fi
  log "PASS: cilium is healthy (daemonset ${ds_ready}/${ds_desired}, operator available=${op_available})"
}

wait_cilium_healthy() {
  local kubeconfig="$1"
  local results_file="${2:-}"
  local attempts="${3:-30}"
  local sleep_seconds="${4:-10}"
  local i

  for ((i=1; i<=attempts; i++)); do
    if assert_cilium_healthy "$kubeconfig" "$results_file"; then
      return 0
    fi
    if [[ "$i" -eq "$attempts" ]]; then
      echo "FAIL: cilium did not become healthy within retry window" >&2
      return 1
    fi
    log "waiting for cilium health (attempt ${i}/${attempts}), retrying in ${sleep_seconds}s"
    sleep "$sleep_seconds"
  done
}
