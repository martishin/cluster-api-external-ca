#!/usr/bin/env bash

scale_workers() {
  local target_replicas="$1"
  kubectl -n "$namespace" patch "machinedeployment/${worker_md_name}" --type merge -p "{\"spec\":{\"replicas\":${target_replicas}}}"
}

reroll_workers() {
  local target_replicas="$1"
  local worker_machine machine_count
  local expected_nodes=$((control_plane_replicas + target_replicas))

  machine_count="$(kubectl -n "$namespace" get machine -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/deployment-name=${worker_md_name}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$machine_count" -eq 0 ]]; then
    log "worker reroll skipped: no worker machines found"
    return 0
  fi

  while IFS= read -r worker_machine; do
    [[ -n "$worker_machine" ]] || continue
    log "external-ca reroll: replacing worker machine $worker_machine"
    kubectl -n "$namespace" delete machine "$worker_machine"
    wait_ha_replicas "$namespace" "$cluster_name" "$kcp_name" "$worker_md_name" "$control_plane_replicas" "$target_replicas" 135
    wait_workload_nodes_ready "$kubeconfig_path" "$expected_nodes" 135
  done < <(
    kubectl -n "$namespace" get machine \
      -l "cluster.x-k8s.io/cluster-name=${cluster_name},cluster.x-k8s.io/deployment-name=${worker_md_name}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )
}
