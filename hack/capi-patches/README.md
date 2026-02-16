# CAPI patch bundle

Patch files in this directory are applied by:

- `hack/scripts/setup/build-and-install-capi-from-source.sh`

The script clones `kubernetes-sigs/cluster-api` at `v1.8.8` by default and applies:

- `0001-external-ca-bootstrap.patch`

If you need a different CAPI base ref:

```bash
CAPI_REF=<tag-or-commit> hack/scripts/setup/build-and-install-capi-from-source.sh
```

If patch apply fails on a different ref, rebase the patch to that ref first.
