.PHONY: help prereqs \
	setup-self-signed-ca validate-self-signed-ca \
	setup-external-ca validate-external-ca \
	e2e-self-signed-ca e2e-external-ca \
	test lint-scripts patch-check \
	clean clean-kind clean-out

CAPI_VERSION ?= v1.8.8
KMSSERVICE_MOCK_ADDR ?= 127.0.0.1:9443

help: ## Show available targets
	@awk 'BEGIN {FS=":.*## "}; /^[a-zA-Z0-9_.-]+:.*## / {printf "%-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

prereqs: ## Check local prerequisites
	hack/scripts/setup/check-prereqs.sh

setup-self-signed-ca: prereqs ## Setup upstream self-signed CA flow (no validation)
	SETUP_MODE=upstream \
	CAPI_REF=$(CAPI_VERSION) \
	CAPI_VERSION=$(CAPI_VERSION) \
	hack/scripts/deploy/run-setup.sh

validate-self-signed-ca: ## Validate self-signed CA scenario
	hack/scripts/validate/validate-ca-behavior.sh --mode self-signed
	EXPECTED_MODE=self-signed hack/scripts/validate/validate-certificate-lineage.sh

setup-external-ca: prereqs ## Setup patched external-CA flow (no validation)
	SETUP_MODE=patched \
	CAPI_REF=$(CAPI_VERSION) \
	CAPI_VERSION=$(CAPI_VERSION) \
	KMSSERVICE_MOCK_ADDR=$(KMSSERVICE_MOCK_ADDR) \
	hack/scripts/deploy/run-setup.sh

validate-external-ca: ## Validate external-CA scenario
	hack/scripts/validate/validate-ca-behavior.sh --mode external-ca
	EXPECTED_MODE=external-ca hack/scripts/validate/validate-certificate-lineage.sh

e2e-self-signed-ca: ## Convenience flow: clean + setup-self-signed-ca + validate-self-signed-ca + clean
	@set -e; \
	status=0; \
	$(MAKE) clean || status=$$?; \
	if [ $$status -eq 0 ]; then $(MAKE) setup-self-signed-ca || status=$$?; fi; \
	if [ $$status -eq 0 ]; then $(MAKE) validate-self-signed-ca || status=$$?; fi; \
	$(MAKE) clean || true; \
	exit $$status

e2e-external-ca: ## Convenience flow: clean + setup-external-ca + validate-external-ca + clean
	@set -e; \
	status=0; \
	$(MAKE) clean || status=$$?; \
	if [ $$status -eq 0 ]; then $(MAKE) setup-external-ca || status=$$?; fi; \
	if [ $$status -eq 0 ]; then $(MAKE) validate-external-ca || status=$$?; fi; \
	$(MAKE) clean || true; \
	exit $$status

test: ## Run Go tests
	go test ./...

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
