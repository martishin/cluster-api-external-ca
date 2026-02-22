# Cluster API External CA PoC

This repository tests a patch for Cluster API `v1.8.8` that enables external CA:

1. `self-signed` (upstream CAPI, no patch),
2. `external-ca` (patched CAPI + pre-generated external bootstrap PKI).

## Run Locally

```bash
make test-self-signed-ca
make test-external-ca
```

Or run setup/validate separately:

```bash
make setup-self-signed-ca
make validate-self-signed-ca

make setup-external-ca
make validate-external-ca
```

## Debug Commands

Management cluster (kind + CAPI controllers):

```bash
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig get pods -A | grep -E 'capi-|capd-|cert-manager|step-ca' || true
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get cluster
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get kcp
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get md
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get machine
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default describe kcp
```

Workload cluster:

```bash
kubectl --kubeconfig out/workload/kubeconfig get nodes -o wide
kubectl --kubeconfig out/workload/kubeconfig get pods -A
kubectl --kubeconfig out/workload/kubeconfig get csr
```

Node-level certificate spot checks:

```bash
# pick any control-plane node from the workload cluster
CP_NODE="$(kubectl --kubeconfig "$WORKLOAD_KUBECONFIG" get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')"

# check if CA key exists on that node
kubectl --kubeconfig "$WORKLOAD_KUBECONFIG" debug "node/$CP_NODE" --image=busybox:1.36 --quiet -- \
  chroot /host ls -l /etc/kubernetes/pki/ca.key

# inspect apiserver cert issuer/subject on that node
kubectl --kubeconfig "$WORKLOAD_KUBECONFIG" debug "node/$CP_NODE" --image=busybox:1.36 --quiet -- \
  chroot /host openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -issuer -subject
```

## Execution Flow

1. Deploy kind management cluster with `1` control-plane + `1` worker node.
2. Build CAPI artifacts for pinned version (`v1.8.8`).
3. Install CAPI into management cluster.
4. Deploy bootstrap step-ca into management cluster.
5. Provision workload cluster in external-ca mode with initial `1` control-plane node (bootstrap PKI signed by management step-ca).
6. Scale workload workers to `3` (still using bootstrap-signed PKI).
7. Deploy workload step-ca to workload cluster.
8. Reroll control-plane to `3` replicas so new control-plane leaf certs are signed through workload signer flow.
9. Reroll workers so worker kubelet client certs are signed through workload signer flow.
10. Validate control-plane and worker certificate lineage/subjects/uniqueness.

## Validation Summary

- `self-signed`: expects CA key behavior from upstream kubeadm/CAPI.
- `external-ca`: expects no CA private key in `<cluster>-ca`, no `/etc/kubernetes/pki/ca.key` on control-plane nodes, expected CA lineage, unique control-plane leaf key hashes after reroll, and worker kubelet client certs signed by the
  external CA with `CN=system:node:<node>` and `O=system:nodes`.

## References

- Cluster API repo: https://github.com/kubernetes-sigs/cluster-api/
- Cluster API book: https://cluster-api.sigs.k8s.io/
