# Cluster API External CA Bootstrap PoC

`cluster-api-external-ca` demonstrates how to bootstrap Cluster API workload clusters with the correct external CA from day 0.

This repository includes:

- a CAPI patch bundle (`hack/capi-patches/0001-external-ca-bootstrap.patch`)
- a bootstrap helper (`cmd/capi-bootstrap`)
- a KMSService mock signer over gRPC+mTLS (`cmd/kmsservice-mock`)
- end-to-end scenario workflows for self-signed and external-CA bootstrap paths

## Table Of Contents

- [Goals](#goals)
- [Prerequisites](#prerequisites)
- [Self-Signed Scenario](#self-signed-scenario)
- [External-CA Scenario](#external-ca-scenario)
- [Debug Commands](#debug-commands)
- [Implemented CAPI Changes](#implemented-capi-changes)
- [Local Development](#local-development)
- [Script Index](#script-index)
- [Manual Bootstrap With External CA (Patched CAPI)](#manual-bootstrap-with-external-ca-patched-capi)

## Goals

- validate upstream CAPI does not provide the target external-CA bootstrap behavior
- validate patched CAPI + external signer bootstrap can bring up cluster with CA cert-only secrets
- ensure no Kubernetes CA private key is present on control-plane nodes
- exercise HA shape with 3 control-plane and 3 worker nodes

## Prerequisites

- Go 1.25+
- `docker`
- `kubectl`
- `kind`
- `openssl`
- `helm`

## Self-Signed Scenario

This scenario validates upstream behavior: a cluster bootstraps with self-signed/bootstrap CA material.

### 1) Setup

```bash
make setup-self-signed-ca
```

What setup does:

- recreates local `capi-mgmt` kind management cluster
- builds `clusterctl` from source at `CAPI_VERSION`
- builds and installs upstream CAPI from source (no patch)
- creates a 3-control-plane / 3-worker workload cluster
- installs Cilium and waits for healthy node readiness
- writes runtime/build state under `out/mgmt`

### 2) Validate

```bash
make validate-self-signed-ca
```

`make validate-self-signed-ca` checks:

- CA key exists in `self-signed-ca-cluster-ca` Secret
- CA key exists on the control-plane node (`/etc/kubernetes/pki/ca.key`)
- cluster health checks are green, including Cilium

Expected result:

- command exits with code `0`
- output contains pass checks for CA key presence and healthy Cilium

Results are written under `out/self-signed-ca/` and `out/results/ca-source/`.
`out/results/` stores validation artifacts (cert chains, fingerprints, issuer/subject comparisons, optional manual checks).

### 3) Optional Manual Check

```bash
kubectl -n default get secret self-signed-ca-cluster-ca -o jsonpath='{.data.tls\.key}' | grep -q . && echo "self-signed: tls.key present"
```

Expected result:

- prints `self-signed: tls.key present`

### 4) Clean

```bash
make clean
```

`make clean` removes:

- local kind management cluster (`capi-mgmt`)
- `out` (including `out/mgmt`)

## External-CA Scenario

This scenario validates patched behavior: a cluster bootstraps directly with external CA trust from day 0.

### 1) Setup

```bash
make setup-external-ca
```

What setup does:

- recreates local `capi-mgmt` kind management cluster
- builds `clusterctl` from source at `CAPI_VERSION`
- builds and installs patched CAPI from source using patch `hack/capi-patches/0001-external-ca-bootstrap.patch`
- installs mock external signer stack and KMSService mock
- creates a 3-control-plane / 3-worker workload cluster
- installs Cilium and waits for healthy node readiness
- writes runtime/build state under `out/mgmt`

### 2) Validate

```bash
make validate-external-ca
```

`make validate-external-ca` checks:

- CA key is absent in `external-ca-cluster-ca` Secret
- CA key is absent on the control-plane node (`/etc/kubernetes/pki/ca.key`)
- cluster CA fingerprint matches KMSService CA
- apiserver issuer matches external CA subject
- worker scale-up succeeds and Cilium remains healthy

Expected result:

- command exits with code `0`
- output contains pass checks for CA key absence, fingerprint/issuer match, scale-up success, and healthy Cilium

Results are written under `out/external-ca/` and `out/results/ca-source/`.
`out/results/` stores validation artifacts (cert chains, fingerprints, issuer/subject comparisons, optional manual checks).

### 3) Optional Manual Check

```bash
mkdir -p out/results/manual
kubectl -n default get secret external-ca-cluster-ca -o jsonpath='{.data.tls\.key}' | grep -q . || echo "external-ca: tls.key absent"
kubectl -n default get secret external-ca-cluster-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > out/results/manual/external-cluster-ca.crt
openssl x509 -in out/results/manual/external-cluster-ca.crt -noout -fingerprint -sha256
openssl x509 -in out/kmsservice-mock/kubernetes-ca.crt -noout -fingerprint -sha256
```

Expected result:

- prints `external-ca: tls.key absent`
- the two SHA256 fingerprints are identical

### 4) Clean

```bash
make clean
```

`make clean` removes:

- local kind management cluster (`capi-mgmt`)
- `out` (including `out/mgmt`)

## Debug Commands

Management cluster health and CAPI objects:

```bash
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig get pods -A | grep -E 'capi-|capd-|cert-manager|trust-manager'
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get cluster
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get kcp
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get md
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default get machine
kubectl --kubeconfig out/mgmt/mgmt.kubeconfig -n default describe kcp
```

Workload cluster health:

```bash
# self-signed-ca scenario
WORKLOAD_KUBECONFIG=out/self-signed-ca/kubeconfig

# external-ca scenario
WORKLOAD_KUBECONFIG=out/external-ca/kubeconfig

kubectl --kubeconfig "$WORKLOAD_KUBECONFIG" get nodes
kubectl --kubeconfig "$WORKLOAD_KUBECONFIG" get pods -A
```

## Implemented CAPI Changes

Patch file:

- `hack/capi-patches/0001-external-ca-bootstrap.patch`

Includes:

- `externalCA` API/CRD wiring for CAPBK/KCP types,
- external-CA certificate sets for initial control-plane + join cert handling,
- fail-fast lookup-only behavior in external mode (no CA key auto-generation),
- external-mode kubeconfig wait path (pre-created kubeconfig secret),
- bootstrap file delivery via `contentFrom.secret` (private keys no longer stored directly in KCP spec),
- bootstrap helper reuses existing `<cluster>-sa` secret so repeated runs do not rotate SA signing keys mid-scale,
- CAPD external-ca example manifest.

## Local Development

### 1) List available targets

```bash
make help
```

### 2) Common variables

- `CAPI_VERSION` (default: `v1.8.8`, used both as upstream git ref for source build and for `clusterctl init` provider pinning)
- `KMSSERVICE_MOCK_ADDR` (default: `127.0.0.1:9443`)

Cilium chart version is pinned in scripts to `1.16.7`.

### 3) Run tests

```bash
make test
```

### 4) Validate shell scripts

```bash
make lint-scripts
```

### 5) Verify patch applies to upstream CAPI version

```bash
make patch-check
```

Use a different CAPI version if needed:

```bash
make patch-check CAPI_VERSION=v1.8.8
```

## Script Index

Scripts are organized under `hack/scripts/`.

- `utils/env.sh` - shared environment and generic helpers (`ROOT_DIR`, `OUT_DIR`, `log`, `require_bin`, `ensure_out_dirs`).
- `utils/kube.sh` - shared Kubernetes/CAPI workflow helpers (kubeconfig extraction, readiness waits, CNI install, node/file checks).
- `setup/check-prereqs.sh` - verifies required local binaries and prepares output directory.
- `setup/bootstrap-management-cluster.sh` - creates `capi-mgmt` kind cluster and initializes CAPI providers (pinned version).
- `setup/build-and-install-capi-from-source.sh` - builds CAPI controllers from source (with/without patch), loads images into kind, updates deployments and CRDs.
- `deploy/deploy-self-signed-ca-on-upstream.sh` - deploys the upstream self-signed cluster and converges it to HA.
- `deploy/deploy-external-ca-kmsservice-mock.sh` - deploys external-CA cluster using KMSService gRPC+mTLS mock signer and handles HA scale-up scenario.
- `deploy/run-setup.sh` - main setup orchestrator used by `make setup-self-signed-ca` and `make setup-external-ca`.
- `mock/start-kmsservice-mock.sh` - generates local mTLS assets (if missing) and runs KMSService mock server.
- `mock/install-mock-ca-signer-stack.sh` - installs mock external CA signer stack (cert-manager, trust-manager, mock csrsigner-proxy, mock cert-manager-approver, mock KmsIssuer resources).
- `validate/validate-ca-behavior.sh` - validates self-signed or external-ca post-deploy assertions (secret/node checks, scaling).
- `validate/validate-certificate-lineage.sh` - validates CA source/issuer path after setup (`self-signed` vs `KMSService-mock`).

## Manual Bootstrap With External CA (Patched CAPI)

Use this when you want to bootstrap a workload cluster with your real root-CA chain from day 0 on any management cluster.

### 1) Build and install patched CAPI

```bash
APPLY_PATCH=true CAPI_REF=v1.8.8 TAG=external-ca-dev \
  hack/scripts/setup/build-and-install-capi-from-source.sh
```

This compiles CAPI from source, applies `hack/capi-patches/0001-external-ca-bootstrap.patch`, updates controller images, and reapplies CRDs.

### 2) Apply a workload cluster manifest with external CA enabled

Your `KubeadmControlPlane` must include:

```yaml
spec:
  kubeadmConfigSpec:
    externalCA: true
```

Apply `Cluster`, `KubeadmControlPlane`, and worker `MachineDeployment` objects as usual.

### 3) Pre-provision bootstrap PKI and kubeconfigs via external signer

Run the bootstrap helper after KCP exists:

```bash
go run ./cmd/capi-bootstrap \
  --kubeconfig <mgmt-kubeconfig> \
  --namespace <namespace> \
  --cluster-name <cluster-name> \
  --kcp-name <kcp-name> \
  --server https://<api-endpoint>:6443 \
  --mode kmsservice \
  --kmsservice-endpoint <host:port> \
  --kmsservice-ca-cert <signer-ca.crt> \
  --kmsservice-client-cert <client.crt> \
  --kmsservice-client-key <client.key> \
  --kmsservice-server-name <optional-sni>
```

What this command prepares:

- `<cluster>-ca`, `<cluster>-proxy`, `<cluster>-etcd` with CA cert only
- `<cluster>-kubeconfig` pre-created admin kubeconfig
- `<cluster>-sa` service-account signing keypair
- KCP `files` entries for control-plane leaf certs, keys, and kubeconfigs

### 4) Wait for full cluster convergence

```bash
kubectl -n <namespace> wait --for=condition=Available kcp/<kcp-name> --timeout=60m
kubectl -n <namespace> wait --for=condition=Available machinedeployment/<worker-md-name> --timeout=60m
kubectl -n <namespace> get machines
```

### 5) Validate it is external-CA based (not self-signed bootstrap CA)

```bash
kubectl -n <namespace> get secret <cluster-name>-ca -o jsonpath='{.data.tls\.key}' | grep -q . \
  && echo "unexpected: tls.key present" || echo "ok: no tls.key in <cluster>-ca"
```

```bash
mkdir -p out/results/manual
kubectl -n <namespace> get secret <cluster-name>-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > out/results/manual/cluster-ca.crt
openssl x509 -in out/results/manual/cluster-ca.crt -noout -issuer -subject -fingerprint -sha256
```

Expected outcome:

- cluster CA secret has no CA private key
- control-plane bootstrap uses externally issued cert chain
- API server issuer/chain matches your root-CA trust path from initial deploy

You can also reuse the automated validator in this repo after deployment:

```bash
make validate-external-ca
```
