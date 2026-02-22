.PHONY: help prereqs patch-check \
	setup-self-signed-ca setup-external-ca \
	validate-self-signed-ca validate-external-ca \
	test-self-signed-ca test-external-ca \
	lint-scripts clean clean-kind clean-out

CAPI_VERSION ?= v1.8.8

help: ## Show available targets
	@awk 'BEGIN {FS=":.*## "}; /^[a-zA-Z0-9_.-]+:.*## / {printf "%-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

prereqs: ## Check local prerequisites
	hack/scripts/setup/check-prereqs.sh

setup-self-signed-ca: prereqs ## Setup self-signed CA flow (upstream, no validation)
	CAPI_VERSION=$(CAPI_VERSION) hack/scripts/run/pipeline.sh self-signed setup

setup-external-ca: prereqs patch-check ## Setup external-CA flow (patched, no validation)
	CAPI_VERSION=$(CAPI_VERSION) hack/scripts/run/pipeline.sh external-ca setup

validate-self-signed-ca: ## Validate self-signed CA scenario (upstream)
	hack/scripts/run/pipeline.sh self-signed validate

validate-external-ca: ## Validate external-CA scenario (patched)
	hack/scripts/run/pipeline.sh external-ca validate

test-self-signed-ca: prereqs ## One-command self-signed CA test (clean + setup + validate)
	CAPI_VERSION=$(CAPI_VERSION) hack/scripts/run/pipeline.sh self-signed test

test-external-ca: prereqs patch-check ## One-command external-CA test (clean + setup + validate)
	CAPI_VERSION=$(CAPI_VERSION) hack/scripts/run/pipeline.sh external-ca test

lint-scripts: ## Validate shell scripts syntax
	find hack/scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n

patch-check: ## Verify CAPI patch applies cleanly to upstream $(CAPI_VERSION)
	@set -e; \
	CAPI_REF=$${CAPI_REF:-$(CAPI_VERSION)}; \
	PATCH_FILE="$(CURDIR)/hack/capi-patches/0001-external-ca-bootstrap.patch"; \
	TMP_DIR=$$(mktemp -d); \
	trap 'rm -rf "$$TMP_DIR"' EXIT; \
	git clone --depth 1 --branch $$CAPI_REF https://github.com/kubernetes-sigs/cluster-api.git $$TMP_DIR/cluster-api >/dev/null 2>&1; \
	git -C $$TMP_DIR/cluster-api apply --check "$$PATCH_FILE"; \
	echo "Patch check passed for $$CAPI_REF";

clean-kind: ## Delete kind management cluster
	hack/scripts/setup/cleanup-local-capd-artifacts.sh
	KUBECONFIG=out/mgmt/mgmt.kubeconfig kind delete cluster --name capi-mgmt || true

clean-out: ## Remove generated PoC artifacts
	rm -rf out

clean: clean-kind clean-out ## Cleanup cluster and generated artifacts
