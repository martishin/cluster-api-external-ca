# capi-bootstrap

PoC bootstrap helper for Cluster API + kubeadm `externalCA` mode.

## What it does

- Generates required PKI artifacts in `mock-ca` mode or `kmsservice` mode.
- Creates/updates the following management-cluster Secrets:
  - `<cluster>-ca` (CA cert only)
  - `<cluster>-proxy` (CA cert only)
  - `<cluster>-etcd` (CA cert only)
  - `<cluster>-sa` (service-account keypair)
  - `<cluster>-kubeconfig` (admin kubeconfig)
- Patches `KubeadmControlPlane`:
  - `spec.kubeadmConfigSpec.externalCA=true`
  - injects all required files into `spec.kubeadmConfigSpec.files` via `contentFrom.secret`
  - ensures `/etc/kubernetes/pki/etcd` directory is created via `preKubeadmCommands`
  - keeps private keys out of the KCP spec body (stored in `<cluster>-external-ca-files` Secret)

## Usage

```bash
go run ./cmd/capi-bootstrap \
  --kubeconfig ./mgmt.kubeconfig \
  --namespace default \
  --cluster-name my-cluster \
  --kcp-name controlplane \
  --mode mock-ca \
  --apiserver-san localhost,127.0.0.1 \
  --etcd-san localhost,127.0.0.1
```

`kmsservice` mode example:

```bash
go run ./cmd/capi-bootstrap \
  --kubeconfig ./mgmt.kubeconfig \
  --namespace default \
  --cluster-name my-cluster \
  --kcp-name controlplane \
  --mode kmsservice \
  --kmsservice-endpoint 127.0.0.1:9443 \
  --kmsservice-ca-cert out/kmsservice-mtls/ca.crt \
  --kmsservice-client-cert out/kmsservice-mtls/client.crt \
  --kmsservice-client-key out/kmsservice-mtls/client.key \
  --kmsservice-server-name localhost \
  --apiserver-san localhost,127.0.0.1 \
  --etcd-san localhost,127.0.0.1
```

Optional flags:

- `--context <name>`: kubeconfig context override.
- `--output-dir <dir>`: local output directory for generated artifacts (default: `out`).
- `--apiserver-san`: extra apiserver SANs (comma-separated).
- `--server https://<host>:6443`: force kubeconfig server URL.
  - If omitted, the tool reads `Cluster.spec.controlPlaneEndpoint`.
  - If that field is empty, the command fails and asks you to provide `--server`.
- `--etcd-san`: extra etcd server/peer SANs (comma-separated).
- `--dry-run`: render/generate without writing to cluster.
- `--cleanup`: remove generated sensitive local artifacts (for example `*.key`, kubeconfig/conf files) from local output dir after successful apply.
- `--kmsservice-endpoint`, `--kmsservice-ca-cert`, `--kmsservice-client-cert`, `--kmsservice-client-key`: required for `--mode kmsservice`.
- `--kmsservice-server-name`: optional TLS server-name override.

## Notes

- `kmsservice` mode uses remote CSR signing and never requires CA private keys in the bootstrap tool.
- For strict multi-control-plane etcd SAN handling, integrate node-aware CSR signing/profile selection in production `kmsservice`.
