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
	@set -e; \
	CAPI_VERSION=$(CAPI_VERSION) hack/scripts/01-deploy-kind.sh; \
	CAPI_VERSION=$(CAPI_VERSION) FLOW_MODE=self-signed hack/scripts/02-build-capi-images.sh; \
	CAPI_VERSION=$(CAPI_VERSION) FLOW_MODE=self-signed hack/scripts/03-install-capi.sh; \
	FLOW_MODE=self-signed hack/scripts/04-deploy-bootstrap-step-ca.sh; \
	FLOW_MODE=self-signed hack/scripts/06-provision-cluster.sh; \
	FLOW_MODE=self-signed hack/scripts/07-deploy-workload-step-ca.sh

setup-external-ca: prereqs patch-check ## Setup external-CA flow (patched, no validation)
	@set -e; \
	CAPI_VERSION=$(CAPI_VERSION) hack/scripts/01-deploy-kind.sh; \
	CAPI_VERSION=$(CAPI_VERSION) FLOW_MODE=external-ca hack/scripts/02-build-capi-images.sh; \
	CAPI_VERSION=$(CAPI_VERSION) FLOW_MODE=external-ca hack/scripts/03-install-capi.sh; \
	FLOW_MODE=external-ca hack/scripts/04-deploy-bootstrap-step-ca.sh; \
	FLOW_MODE=external-ca hack/scripts/05-prepare-bootstrap-secrets.sh; \
	FLOW_MODE=external-ca hack/scripts/06-provision-cluster.sh; \
	FLOW_MODE=external-ca hack/scripts/07-deploy-workload-step-ca.sh; \
	FLOW_MODE=external-ca hack/scripts/08-reroll-control-plane.sh; \
	FLOW_MODE=external-ca hack/scripts/09-reroll-workers.sh

validate-self-signed-ca: ## Validate self-signed CA scenario (upstream)
	FLOW_MODE=self-signed hack/scripts/10-validate-cluster.sh

validate-external-ca: ## Validate external-CA scenario (patched)
	FLOW_MODE=external-ca hack/scripts/10-validate-cluster.sh

test-self-signed-ca: ## One-command self-signed CA test (clean + setup + validate)
	@set -e; \
	$(MAKE) clean; \
	$(MAKE) setup-self-signed-ca; \
	$(MAKE) validate-self-signed-ca

test-external-ca: ## One-command external-CA test (clean + setup + validate)
	@set -e; \
	$(MAKE) clean; \
	$(MAKE) setup-external-ca; \
	$(MAKE) validate-external-ca

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
