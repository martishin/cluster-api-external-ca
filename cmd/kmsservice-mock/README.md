# kmsservice-mock

Minimal KMSService mock server using **gRPC + mTLS**.

## Methods

- `GetCA` (returns CA cert PEM)
- `SignCSR` (signs CSR PEM with selected CA)

Supported CA names:

- `kubernetes-ca`
- `kubernetes-front-proxy-ca`
- `etcd-ca`

## Signing constraints

`SignCSR` only signs CSRs that match built-in profiles:

- `kubernetes-ca`
  - `kube-apiserver` (requires SANs)
  - `kube-apiserver-kubelet-client` (requires org `system:masters`, SANs not allowed)
  - `kubernetes-admin` (requires org `system:masters`, SANs not allowed)
  - `system:kube-controller-manager` (requires org `system:kube-controller-manager`, SANs not allowed)
  - `system:kube-scheduler` (requires org `system:kube-scheduler`, SANs not allowed)
- `kubernetes-front-proxy-ca`
  - `front-proxy-client` (SANs not allowed)
- `etcd-ca`
  - `kube-apiserver-etcd-client` (requires org `system:masters`, SANs not allowed)
  - `kube-etcd` (requires SANs)
  - `kube-etcd-peer` (requires SANs)
  - `kube-etcd-healthcheck-client` (SANs not allowed)

If CA/CN/org/SANs do not match the profile, the mock returns `InvalidArgument`.

## Run

```bash
go run ./cmd/kmsservice-mock \
  --addr 127.0.0.1:9443 \
  --state-dir out/kmsservice-mock \
  --server-cert out/kmsservice-mtls/server.crt \
  --server-key out/kmsservice-mtls/server.key \
  --client-ca out/kmsservice-mtls/ca.crt \
  --allowed-client-cn bootstrap-client
```

Generate certs and run the mock with:

```bash
hack/scripts/mock/start-kmsservice-mock.sh
```
