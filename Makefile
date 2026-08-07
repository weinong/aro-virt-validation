# OpenShift Virtualization Validation Makefile
# Public entrypoint for ARO and self-managed OpenShift validation workflows.

SHELL := /bin/bash

# Configurable variables
REGISTRY        ?= arol1vh
LOCATION        ?= centralus
AZURE_SUBSCRIPTION_NAME ?= L1VH Virt Testing
ARO_RESOURCEGROUP_PREFIX ?= aro-virt-test-rg
ARO_STATE_FILE  ?= .aro.env
ARO_STATE_OVERWRITE ?= false
QUAY_PULLSECRET ?= .quay-pullsecret
SELF_MANAGED_CLUSTER ?=
SELF_MANAGED_BASE_DOMAIN ?=
SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP ?=
RELEASE_IMAGE   ?= quay.io/openshift-release-dev/ocp-release@sha256:1a50a7c21acc0b113aa74c187bec8798cb58481c065a4c5a0e25df6bc46b8815
SSH_PUB_KEY     ?= $(HOME)/.ssh/id_rsa.pub
TOOLS_DIR       ?= ocp-tools
CNV_VERSION     ?= 4.99
TEST_SUITES     ?= compute,network,storage
STORAGE_CLASS   ?= managed-csi
QEMU_RPM_DIR    ?=
CNV_QEMU_IMAGE  ?= localhost/aro-virt-validation/cnv-qemu-launcher:10.1.0-17.el9_8.3
USE_QEMU_3_LAUNCHER ?= false
QEMU_3_LAUNCHER_IMAGE ?=
QEMU_3_PULL_SECRET_FILE ?=
TARGET_OCP_VERSION ?= 4.22.4
SP_CREDENTIAL_DAYS ?= 90

export QEMU_RPM_DIR CNV_QEMU_IMAGE REGISTRY SP_CREDENTIAL_DAYS

# Tool paths
OC                = $(TOOLS_DIR)/oc
OPENSHIFT_INSTALL = $(TOOLS_DIR)/openshift-install

# Script paths
SELF_MANAGED_SCRIPT = ./scripts/self-managed-cluster.sh
QUAY_LOGIN_SCRIPT   = ./scripts/docker-login-quay.sh

# Internal variables
RELEASE_IMAGE_ESC       := $(shell printf '%s' "$(RELEASE_IMAGE)" | tr '/:@' '___')
OC_STAMP                := $(TOOLS_DIR)/.oc.$(RELEASE_IMAGE_ESC).stamp
OPENSHIFT_INSTALL_STAMP := $(TOOLS_DIR)/.openshift-install.$(RELEASE_IMAGE_ESC).stamp

# Colors for output
GREEN  := $(shell printf '\033[0;32m')
YELLOW := $(shell printf '\033[1;33m')
RED    := $(shell printf '\033[0;31m')
NC     := $(shell printf '\033[0m')

.PHONY: help setup-tools check-oc-command check-tools version clean clean-tools \
	check-az-subscription azure-service-principal rotate-service-principal-credential docker-login docker-login-quay docker-login-arol1vh \
	upload-cluster-credential download-cluster-credential cluster-info \
	ocp-up ocp-down \
	upload-quay-pullsecret refresh-quay-pullsecret upload-pull-secret upload-local-secrets download-local-secrets \
	prereqs check-upgrade-target aro-up aro-login aro-disable-machineset-reconcile aro-down upgrade-4.21 upgrade-4.22 upgrade-to-4.22 upgrade-to-4.22.4 techpreview mshv-node cnv-pull-secret \
	cnv-nightly-version cnv-install mshv-hco-patch build-qemu-3-launcher check-qemu-3-publish-image publish-qemu-3-launcher validation-checkup restore-qemu-3-launcher aro-validation-flow ocp-validation-flow

.NOTPARALLEL: aro-validation-flow ocp-validation-flow

help: ## Show this help message
	@echo "OpenShift Virtualization Validation Makefile"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-28s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "REGISTRY" "Azure registry/key vault name (default: $(REGISTRY))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "LOCATION" "Azure location (default: $(LOCATION))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "AZURE_SUBSCRIPTION_NAME" "Required Azure subscription (default: $(AZURE_SUBSCRIPTION_NAME))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "ARO_RESOURCEGROUP_PREFIX" "Prefix for randomized ARO resource groups (default: $(ARO_RESOURCEGROUP_PREFIX))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "ARO_STATE_FILE" "Local ARO state file (default: $(ARO_STATE_FILE))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "ARO_STATE_OVERWRITE" "Allow aro-up to replace existing ARO state (default: $(ARO_STATE_OVERWRITE))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "QUAY_PULLSECRET" "Local Quay credential file (default: $(QUAY_PULLSECRET))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "SELF_MANAGED_CLUSTER" "Self-managed OpenShift cluster name override"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "SELF_MANAGED_BASE_DOMAIN" "Self-managed OpenShift base domain"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP" "Azure resource group for the base domain DNS zone"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "RELEASE_IMAGE" "OpenShift release image for self-managed tools/cluster"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "TOOLS_DIR" "Directory for extracted tools (default: $(TOOLS_DIR))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "SSH_PUB_KEY" "SSH public key file (default: $(SSH_PUB_KEY))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "CNV_VERSION" "CNV nightly version (default: $(CNV_VERSION))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "TEST_SUITES" "Validation suites (default: $(TEST_SUITES))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "STORAGE_CLASS" "Validation storage class (default: $(STORAGE_CLASS))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "QEMU_RPM_DIR" "External directory containing the eight locked QEMU RPMs"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "CNV_QEMU_IMAGE" "QEMU .3 launcher build/publish tag (default: $(CNV_QEMU_IMAGE))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "TARGET_OCP_VERSION" "Exact OCP target for pinned ARO flow (default: $(TARGET_OCP_VERSION))"
	@printf "  $(YELLOW)%-15s$(NC) %s\n" "SP_CREDENTIAL_DAYS" "Validity of newly appended service principal credentials (default: $(SP_CREDENTIAL_DAYS))"

$(TOOLS_DIR):
	@mkdir -p "$@"

$(OPENSHIFT_INSTALL): $(OPENSHIFT_INSTALL_STAMP)
	@:

$(OC): $(OC_STAMP)
	@:

$(OC_STAMP): | $(TOOLS_DIR) check-oc-command
	@$(MAKE) .pullsecret
	@echo "$(YELLOW)Extracting oc from $(RELEASE_IMAGE)...$(NC)"
	@oc adm release extract --registry-config=.pullsecret --command=oc --from=$(RELEASE_IMAGE) --to $(TOOLS_DIR)
	@chmod +x "$(OC)"
	@rm -f $(TOOLS_DIR)/.oc.*.stamp
	@touch -r "$(OC)" "$(OC_STAMP)"
	@echo "$(GREEN)[OK] Extracted oc to $(TOOLS_DIR)/$(NC)"

$(OPENSHIFT_INSTALL_STAMP): | $(TOOLS_DIR) check-oc-command
	@$(MAKE) .pullsecret
	@echo "$(YELLOW)Extracting openshift-install from $(RELEASE_IMAGE)...$(NC)"
	@oc adm release extract --registry-config=.pullsecret --command=openshift-install --from=$(RELEASE_IMAGE) --to $(TOOLS_DIR) || \
		(echo "$(RED)Error: Could not extract openshift-install from release image$(NC)" && exit 1)
	@chmod +x "$(OPENSHIFT_INSTALL)"
	@rm -f $(TOOLS_DIR)/.openshift-install.*.stamp
	@touch -r "$(OPENSHIFT_INSTALL)" "$(OPENSHIFT_INSTALL_STAMP)"
	@echo "$(GREEN)[OK] Extracted openshift-install to $(TOOLS_DIR)/$(NC)"

setup-tools: $(OC) $(OPENSHIFT_INSTALL) ## Download oc and openshift-install from RELEASE_IMAGE
	@echo "$(GREEN)[OK] Tools setup complete$(NC)"
	@echo "$(YELLOW)Note:$(NC) Add $(TOOLS_DIR) to PATH or use: export PATH=$(PWD)/$(TOOLS_DIR):\$$PATH"

check-oc-command: ## Check if an oc command is available for release extraction
	@which oc > /dev/null || (echo "$(RED)Error: 'oc' command not found. Install OpenShift CLI first.$(NC)" && exit 1)

check-az-subscription: ## Verify az is using the required Azure subscription
	@which az > /dev/null || (echo "$(RED)Error: 'az' command not found. Install Azure CLI first.$(NC)" && exit 1)
	@actual=$$(az account show --query name -o tsv 2>/dev/null || true); \
	if [ "$$actual" != "$(AZURE_SUBSCRIPTION_NAME)" ]; then \
		echo "$(RED)Error: Azure CLI is using subscription '$${actual:-<none>}', expected '$(AZURE_SUBSCRIPTION_NAME)'.$(NC)"; \
		echo "$(YELLOW)Run: az account set --subscription '$(AZURE_SUBSCRIPTION_NAME)'$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)[OK] Azure subscription: $$actual$(NC)"

check-tools: ## Check extracted tool versions
	@echo "Checking OpenShift tools..."
	@if [ -x "$(OC)" ]; then \
		echo "$(GREEN)[OK] oc:$(NC) $$($(OC) version --client 2>/dev/null | sed -n '1p' || echo 'version info unavailable')"; \
	else \
		echo "$(RED)✗ oc not found$(NC)"; \
	fi
	@if [ -x "$(OPENSHIFT_INSTALL)" ]; then \
		echo "$(GREEN)[OK] openshift-install:$(NC) $$($(OPENSHIFT_INSTALL) version 2>/dev/null | sed -n '1p' || echo 'version info unavailable')"; \
	else \
		echo "$(RED)✗ openshift-install not found$(NC)"; \
	fi

version: check-tools ## Show Makefile configuration
	@echo "Configuration:"
	@echo "  Location:      $(LOCATION)"
	@echo "  Registry/KV:   $(REGISTRY)"
	@echo "  Release Image: $(RELEASE_IMAGE)"
	@echo "  Tools Dir:     $(TOOLS_DIR)"
	@echo "  Target OCP:    $(TARGET_OCP_VERSION)"

azure-service-principal: check-az-subscription ## Ensure ~/.azure/osServicePrincipal.json exists from Key Vault
	@if [ -f "$$HOME/.azure/osServicePrincipal.json" ]; then \
		echo "$(GREEN)[OK] Service principal file already exists: $$HOME/.azure/osServicePrincipal.json$(NC)"; \
	else \
		echo "$(YELLOW)Service principal file not found. Retrieving from Azure Key Vault...$(NC)"; \
		mkdir -p "$$HOME/.azure"; \
		if az keyvault secret show --name osServicePrincipal --vault-name $(REGISTRY) --query value -o tsv > "$$HOME/.azure/osServicePrincipal.json"; then \
			chmod 600 "$$HOME/.azure/osServicePrincipal.json"; \
			echo "$(GREEN)[OK] Service principal file created: $$HOME/.azure/osServicePrincipal.json$(NC)"; \
		else \
			echo "$(RED)Error: Failed to retrieve service principal from Azure Key Vault.$(NC)"; \
			exit 1; \
		fi; \
	fi

rotate-service-principal-credential: check-az-subscription ## Append and publish a new self-managed installer SP credential
	@./scripts/00a-rotate-service-principal-credential.sh

.pullsecret: | check-az-subscription ## Download self-managed pull secret from Azure Key Vault
	@echo "$(YELLOW)Pull secret file not found. Retrieving from Azure Key Vault...$(NC)"
	@tmp_file=$$(mktemp .pullsecret.XXXXXX); \
	trap 'rm -f "$$tmp_file"' EXIT; \
	if az keyvault secret show --name ocp-pullsecret --vault-name $(REGISTRY) --query value -o tsv > "$$tmp_file"; then \
		mv "$$tmp_file" ".pullsecret"; \
		trap - EXIT; \
		echo "$(GREEN)[OK] Pull secret file created: .pullsecret$(NC)"; \
	else \
		echo "$(RED)Error: Failed to retrieve ocp-pullsecret from Azure Key Vault.$(NC)"; \
		rm -f ".pullsecret"; \
		exit 1; \
	fi

upload-pull-secret: check-az-subscription ## Upload local .pullsecret to Key Vault as ocp-pullsecret
	@if [ ! -f ".pullsecret" ]; then \
		echo "$(RED)Error: .pullsecret not found.$(NC)"; \
		exit 1; \
	fi
	@source ./scripts/env.sh; validate_pull_secret .pullsecret || { \
		echo "$(RED)Error: .pullsecret is not valid pull-secret JSON.$(NC)"; \
		exit 1; \
	}
	@echo "$(YELLOW)Uploading .pullsecret to Key Vault secret ocp-pullsecret...$(NC)"
	@az keyvault secret set --vault-name $(REGISTRY) --name ocp-pullsecret --file .pullsecret > /dev/null
	@echo "$(GREEN)[OK] Uploaded ocp-pullsecret$(NC)"

upload-quay-pullsecret: check-az-subscription ## Upload local Quay credential file to Key Vault
	@if [ ! -f "$(QUAY_PULLSECRET)" ]; then \
		echo "$(RED)Error: $(QUAY_PULLSECRET) not found.$(NC)"; \
		exit 1; \
	fi
	@set -euo pipefail; \
	source ./scripts/env.sh; \
	load_quay_pullsecret "$(QUAY_PULLSECRET)"; \
	: "$${QUAY_USERNAME:?QUAY_USERNAME missing from $(QUAY_PULLSECRET)}"; \
	: "$${QUAY_PASSWORD:?QUAY_PASSWORD missing from $(QUAY_PULLSECRET)}"; \
	echo "$(YELLOW)Uploading $(QUAY_PULLSECRET) to Key Vault secret quay-pullsecret...$(NC)"; \
	az keyvault secret set --vault-name $(REGISTRY) --name quay-pullsecret --file "$(QUAY_PULLSECRET)" > /dev/null; \
	echo "$(GREEN)[OK] Uploaded quay-pullsecret$(NC)"

$(QUAY_PULLSECRET): | check-az-subscription ## Download local Quay credential file from Key Vault
	@echo "$(YELLOW)Quay credential file not found. Retrieving from Azure Key Vault...$(NC)"
	@if az keyvault secret show --name quay-pullsecret --vault-name $(REGISTRY) --query value -o tsv > "$(QUAY_PULLSECRET)"; then \
		chmod 600 "$(QUAY_PULLSECRET)"; \
		echo "$(GREEN)[OK] Quay credential file created: $(QUAY_PULLSECRET)$(NC)"; \
	else \
		echo "$(RED)Error: Failed to retrieve quay-pullsecret from Azure Key Vault.$(NC)"; \
		rm -f "$(QUAY_PULLSECRET)"; \
		exit 1; \
	fi

refresh-quay-pullsecret: check-az-subscription ## Overwrite local Quay credential file from Key Vault
	@rm -f "$(QUAY_PULLSECRET)"
	@$(MAKE) "$(QUAY_PULLSECRET)"

upload-local-secrets: upload-pull-secret upload-quay-pullsecret ## Upload local pull secret and Quay credentials to Key Vault

download-local-secrets: .pullsecret $(QUAY_PULLSECRET) ## Download local pull secret and Quay credentials from Key Vault

docker-login: docker-login-quay docker-login-arol1vh ## Login to quay.io and the configured ACR

docker-login-quay: $(QUAY_PULLSECRET) ## Login to quay.io using .quay-pullsecret
	@QUAY_PULLSECRET_FILE="$(QUAY_PULLSECRET)" $(QUAY_LOGIN_SCRIPT)

docker-login-arol1vh: check-az-subscription ## Login to the configured Azure Container Registry
	@set -euo pipefail; \
	if command -v docker &>/dev/null; then CONTAINER_CLI=docker; \
	elif command -v podman &>/dev/null; then CONTAINER_CLI=podman; \
	else echo "$(RED)Error: Neither docker nor podman command found.$(NC)"; exit 1; fi; \
	ACCESS_TOKEN=$$(az acr login --name $(REGISTRY) --expose-token --output tsv --query accessToken); \
	LOGIN_SERVER=$$(az acr show --name $(REGISTRY) --query loginServer --output tsv); \
	printf '%s' "$$ACCESS_TOKEN" | "$$CONTAINER_CLI" login "$$LOGIN_SERVER" \
		-u 00000000-0000-0000-0000-000000000000 --password-stdin

ocp-up: setup-tools azure-service-principal .pullsecret ## Create self-managed OpenShift with openshift-install
	@echo "$(YELLOW)Creating self-managed OpenShift cluster...$(NC)"
	@export PATH="$(PWD)/$(TOOLS_DIR):$$PATH"; \
	SSH_PUB_KEY="$(SSH_PUB_KEY)" \
	LOCATION="$(LOCATION)" \
	SELF_MANAGED_CLUSTER="$(SELF_MANAGED_CLUSTER)" \
	SELF_MANAGED_BASE_DOMAIN="$(SELF_MANAGED_BASE_DOMAIN)" \
	SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP="$(SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP)" \
	OPENSHIFT_INSTALL="$(PWD)/$(OPENSHIFT_INSTALL)" \
	$(SELF_MANAGED_SCRIPT) up
	@echo "$(GREEN)[OK] Self-managed cluster creation complete$(NC)"

ocp-down: setup-tools ## Destroy self-managed OpenShift installer cluster
	@echo "$(YELLOW)Destroying self-managed OpenShift cluster...$(NC)"
	@export PATH="$(PWD)/$(TOOLS_DIR):$$PATH"; \
	OPENSHIFT_INSTALL="$(PWD)/$(OPENSHIFT_INSTALL)" \
	$(SELF_MANAGED_SCRIPT) down
	@echo "$(GREEN)[OK] Self-managed cluster destruction complete$(NC)"

upload-cluster-credential: check-az-subscription ## Upload self-managed kubeadmin credentials to Key Vault
	@if [ ! -f "installer/auth/kubeadmin-password" ] || [ ! -f "installer/auth/kubeconfig" ]; then \
		echo "$(YELLOW)Cluster credentials not found or incomplete. Skipping upload.$(NC)"; \
	else \
		set -euo pipefail; \
		echo "$(YELLOW)Uploading cluster credentials to Azure Key Vault...$(NC)"; \
		az keyvault secret set --vault-name $(REGISTRY) --name kubeadmin-password --file installer/auth/kubeadmin-password > /dev/null; \
		az keyvault secret set --vault-name $(REGISTRY) --name kubeconfig --file installer/auth/kubeconfig > /dev/null; \
		echo "$(GREEN)[OK] Uploaded kubeadmin-password and kubeconfig$(NC)"; \
	fi

download-cluster-credential: check-az-subscription ## Download self-managed kubeadmin credentials from Key Vault
	@set -euo pipefail; \
	echo "$(YELLOW)Downloading cluster credentials from Azure Key Vault...$(NC)"; \
	mkdir -p installer/auth; \
	rm -f installer/auth/kubeadmin-password installer/auth/kubeconfig; \
	az keyvault secret download --vault-name $(REGISTRY) --name kubeadmin-password --file installer/auth/kubeadmin-password > /dev/null; \
	az keyvault secret download --vault-name $(REGISTRY) --name kubeconfig --file installer/auth/kubeconfig > /dev/null; \
	chmod 600 installer/auth/kubeadmin-password installer/auth/kubeconfig; \
	echo "$(GREEN)[OK] Downloaded kubeadmin-password and kubeconfig$(NC)"

cluster-info: ## Display self-managed cluster access information
	@if [ ! -f "installer/auth/kubeadmin-password" ] || [ ! -f "installer/auth/kubeconfig" ]; then \
		$(MAKE) download-cluster-credential; \
	fi
	@echo "$(YELLOW)export KUBECONFIG=$(PWD)/installer/auth/kubeconfig$(NC)"
	@echo "api endpoint: $$(sed -n 's/^[[:space:]]*server:[[:space:]]*//p' installer/auth/kubeconfig | sed -n '1p')"
	@echo "username: kubeadmin"
	@if [ "$${SHOW_PASSWORD:-false}" = "true" ]; then \
		echo "password: $$(cat installer/auth/kubeadmin-password)"; \
	else \
		echo "password: <hidden; run SHOW_PASSWORD=true make cluster-info to print>"; \
	fi
	@KUBECONFIG=$(PWD)/installer/auth/kubeconfig oc version || true

prereqs: ## Run local/Azure prerequisite checks
	@./scripts/00-prereqs.sh

check-upgrade-target: check-az-subscription ## Verify exact TARGET_OCP_VERSION is available before creating ARO
	@TARGET_OCP_VERSION=$(TARGET_OCP_VERSION) LOCATION=$(LOCATION) ./scripts/02a-check-upgrade-target.sh

aro-up: check-az-subscription .pullsecret ## Create an ARO validation cluster with a randomized resource group unless RESOURCEGROUP is set
	@set -euo pipefail; \
	if [ -f "$(ARO_STATE_FILE)" ] && [ "$(ARO_STATE_OVERWRITE)" != "true" ]; then \
		echo "$(RED)Error: $(ARO_STATE_FILE) already exists. Run 'make aro-down' first, or set ARO_STATE_OVERWRITE=true.$(NC)"; \
		exit 1; \
	fi; \
	if [ -n "$${RESOURCEGROUP:-}" ]; then \
		rg="$$RESOURCEGROUP"; \
	else \
		suffix=$$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c4 2>/dev/null || true); \
		if [ -z "$$suffix" ]; then suffix=$$(date +%s | tail -c 5); fi; \
		rg="$(ARO_RESOURCEGROUP_PREFIX)-$$suffix"; \
	fi; \
	cluster="$${CLUSTER:-aro-virt-test}"; \
	location="$${LOCATION:-$(LOCATION)}"; \
	printf 'RESOURCEGROUP=%q\nCLUSTER=%q\nLOCATION=%q\n' "$$rg" "$$cluster" "$$location" > "$(ARO_STATE_FILE)"; \
	chmod 600 "$(ARO_STATE_FILE)"; \
	echo "$(YELLOW)Using ARO resource group: $$rg$(NC)"; \
	echo "$(YELLOW)Wrote ARO state to $(ARO_STATE_FILE)$(NC)"; \
	RESOURCEGROUP="$$rg" CLUSTER="$$cluster" LOCATION="$$location" ./scripts/00-prereqs.sh; \
	RESOURCEGROUP="$$rg" CLUSTER="$$cluster" LOCATION="$$location" ./scripts/01-aro-infra.sh

aro-login: check-az-subscription check-oc-command ## Log in to the ARO cluster from local ARO state
	@set -euo pipefail; \
	override_rg="$${RESOURCEGROUP:-}"; \
	override_cluster="$${CLUSTER:-}"; \
	if [ -f "$(ARO_STATE_FILE)" ]; then \
		set -a; source "$(ARO_STATE_FILE)"; set +a; \
	fi; \
	if [ -n "$$override_rg" ]; then RESOURCEGROUP="$$override_rg"; fi; \
	if [ -n "$$override_cluster" ]; then CLUSTER="$$override_cluster"; fi; \
	: "$${RESOURCEGROUP:?RESOURCEGROUP is required. Set it or run aro-up first to create $(ARO_STATE_FILE).}"; \
	cluster="$${CLUSTER:-aro-virt-test}"; \
	echo "$(YELLOW)Logging in to ARO cluster $$cluster in resource group $$RESOURCEGROUP...$(NC)"; \
	api_server=$$(az aro show --resource-group "$$RESOURCEGROUP" --name "$$cluster" --query apiserverProfile.url -o tsv); \
	username=$$(az aro list-credentials --resource-group "$$RESOURCEGROUP" --name "$$cluster" --query kubeadminUsername -o tsv); \
	password=$$(az aro list-credentials --resource-group "$$RESOURCEGROUP" --name "$$cluster" --query kubeadminPassword -o tsv); \
	oc login "$$api_server" -u "$$username" -p "$$password"; \
	echo "$(GREEN)[OK] Logged in to $$cluster$(NC)"

aro-disable-machineset-reconcile: ## Disable ARO MachineSet reconciliation for custom MSHV MachineSets
	@./scripts/02b-aro-disable-machineset-reconcile.sh

aro-down: check-az-subscription ## Delete the ARO cluster and resource group from local ARO state
	@set -euo pipefail; \
	override_rg="$${RESOURCEGROUP:-}"; \
	override_cluster="$${CLUSTER:-}"; \
	if [ -f "$(ARO_STATE_FILE)" ]; then \
		set -a; source "$(ARO_STATE_FILE)"; set +a; \
	fi; \
	if [ -n "$$override_rg" ]; then RESOURCEGROUP="$$override_rg"; fi; \
	if [ -n "$$override_cluster" ]; then CLUSTER="$$override_cluster"; fi; \
	: "$${RESOURCEGROUP:?RESOURCEGROUP is required. Set it or run aro-up first to create $(ARO_STATE_FILE).}"; \
	cluster="$${CLUSTER:-aro-virt-test}"; \
	echo "$(YELLOW)Deleting ARO cluster $$cluster in resource group $$RESOURCEGROUP...$(NC)"; \
	if az aro show --resource-group "$$RESOURCEGROUP" --name "$$cluster" > /dev/null 2>&1; then \
		az aro delete --resource-group "$$RESOURCEGROUP" --name "$$cluster" --yes; \
	else \
		echo "$(YELLOW)ARO cluster $$cluster not found in $$RESOURCEGROUP; continuing with resource group delete.$(NC)"; \
	fi; \
	echo "$(YELLOW)Deleting resource group $$RESOURCEGROUP...$(NC)"; \
	if [ "$$(az group exists --name "$$RESOURCEGROUP")" = "true" ]; then \
		az group delete --name "$$RESOURCEGROUP" --yes; \
	else \
		echo "$(YELLOW)Resource group $$RESOURCEGROUP not found; treating cleanup as complete.$(NC)"; \
	fi; \
	rm -f "$(ARO_STATE_FILE)"; \
	echo "$(GREEN)[OK] Deleted ARO resource group $$RESOURCEGROUP$(NC)"

upgrade-4.21: ## Upgrade current cluster one hop to OCP 4.21
	@./scripts/02-upgrade-cluster.sh 4.21

upgrade-4.22: ## Upgrade current cluster one hop to OCP 4.22
	@./scripts/02-upgrade-cluster.sh 4.22

upgrade-to-4.22: ## Upgrade current cluster one minor at a time until OCP 4.22
	@set -euo pipefail; \
	current=$$(oc get clusterversion version -o jsonpath='{.status.desired.version}'); \
	minor=$$(printf '%s' "$$current" | cut -d. -f2); \
	if ! [[ "$$minor" =~ ^[0-9]+$$ ]]; then \
		echo "$(RED)Error: Could not parse current OCP minor from '$$current'.$(NC)"; \
		exit 1; \
	fi; \
	while [ "$$minor" -lt 22 ]; do \
		next=$$((minor + 1)); \
		case "$$next" in \
			21) $(MAKE) upgrade-4.21 ;; \
			22) $(MAKE) upgrade-4.22 ;; \
			*) ./scripts/02-upgrade-cluster.sh "4.$$next" ;; \
		esac; \
		current=$$(oc get clusterversion version -o jsonpath='{.status.desired.version}'); \
		minor=$$(printf '%s' "$$current" | cut -d. -f2); \
	done; \
	echo "$(GREEN)[OK] Cluster is at OCP $$current$(NC)"

upgrade-to-4.22.4: ## Upgrade current cluster exactly to OCP 4.22.4
	@set -euo pipefail; \
	target_version='4.22.4'; \
	if ! [[ "$$target_version" =~ ^4\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$$ ]]; then \
		echo "$(RED)Error: TARGET_OCP_VERSION must be an exact OCP version, got '$$target_version'.$(NC)"; \
		exit 1; \
	fi; \
	override_rg="$${RESOURCEGROUP:-}"; \
	override_cluster="$${CLUSTER:-}"; \
	override_location="$${LOCATION:-}"; \
	if [ -f "$(ARO_STATE_FILE)" ]; then set -a; source "$(ARO_STATE_FILE)"; set +a; fi; \
	if [ -n "$$override_rg" ]; then RESOURCEGROUP="$$override_rg"; fi; \
	if [ -n "$$override_cluster" ]; then CLUSTER="$$override_cluster"; fi; \
	if [ -n "$$override_location" ]; then LOCATION="$$override_location"; fi; \
	current=$$(oc get clusterversion version -o jsonpath='{.status.history[0].version}'); \
	state=$$(oc get clusterversion version -o jsonpath='{.status.history[0].state}'); \
	if [ "$$state" != "Completed" ]; then \
		echo "$(RED)Error: ClusterVersion state is $$state for version $$current. Wait for the upgrade to complete before continuing.$(NC)"; \
		exit 1; \
	fi; \
	current_minor=$$(printf '%s' "$$current" | cut -d. -f2); \
	target_minor=$$(printf '%s' "$$target_version" | cut -d. -f2); \
	if ! [[ "$$current_minor" =~ ^[0-9]+$$ && "$$target_minor" =~ ^[0-9]+$$ ]]; then \
		echo "$(RED)Error: Could not parse current or target OCP minor. current=$$current target=$$target_version$(NC)"; \
		exit 1; \
	fi; \
	while [ "$$current_minor" -lt "$$target_minor" ]; do \
		next=$$((current_minor + 1)); \
		if [ "$$next" -eq "$$target_minor" ]; then \
			RESOURCEGROUP="$${RESOURCEGROUP:-}" CLUSTER="$${CLUSTER:-}" LOCATION="$${LOCATION:-}" ./scripts/02-upgrade-cluster.sh "$$target_version"; \
		else \
			RESOURCEGROUP="$${RESOURCEGROUP:-}" CLUSTER="$${CLUSTER:-}" LOCATION="$${LOCATION:-}" ./scripts/02-upgrade-cluster.sh "4.$$next"; \
		fi; \
		current=$$(oc get clusterversion version -o jsonpath='{.status.history[0].version}'); \
		state=$$(oc get clusterversion version -o jsonpath='{.status.history[0].state}'); \
		if [ "$$state" != "Completed" ]; then \
			echo "$(RED)Error: ClusterVersion state is $$state for version $$current. Wait for the upgrade to complete before continuing.$(NC)"; \
			exit 1; \
		fi; \
		current_minor=$$(printf '%s' "$$current" | cut -d. -f2); \
	done; \
	if [ "$$current" != "$$target_version" ]; then \
		RESOURCEGROUP="$${RESOURCEGROUP:-}" CLUSTER="$${CLUSTER:-}" LOCATION="$${LOCATION:-}" ./scripts/02-upgrade-cluster.sh "$$target_version"; \
	fi

techpreview: ## Enable and verify TechPreviewNoUpgrade
	@./scripts/03-techpreview-setup.sh

mshv-node: ## Create and verify the declarative MSHV node
	@./scripts/04-mshv-node-setup.sh

cnv-pull-secret: ## Add quay.io/openshift-cnv auth to cluster pull secret
	@QUAY_PULLSECRET_FILE="$(QUAY_PULLSECRET)" ./scripts/05-cnv-pull-secret.sh

cnv-nightly-version: export CNV_VERSION := $(CNV_VERSION)
cnv-nightly-version: ## Print the latest CNV, KubeVirt, and QEMU versions
	@./scripts/06a-cnv-nightly-version.sh

cnv-install: ## Install CNV nightly operator and HyperConverged CR
	@CNV_VERSION=$(CNV_VERSION) ./scripts/06-cnv-install.sh

mshv-hco-patch: ## Enable hyperv-direct through HCO annotation
	@./scripts/07-mshv-hco-patch.sh

build-qemu-3-launcher: ## Build and verify the diagnostic QEMU .3 virt-launcher image locally
	@./scripts/09a-build-cnv-qemu-launcher.sh
	@./scripts/09b-verify-cnv-qemu-launcher.sh

check-qemu-3-publish-image:
	@set -euo pipefail; \
	image="$${CNV_QEMU_IMAGE}"; \
	registry="$${image%%/*}"; \
	if [[ "$$image" == *@* || ! "$$image" =~ ^[^/]+/.+:[^/:]+$$ \
		|| ( "$$registry" != "localhost" && "$$registry" != *.* && "$$registry" != *:* ) ]]; then \
		echo "$(RED)Error: CNV_QEMU_IMAGE must include a registry, repository, and tag, got '$$image'.$(NC)"; \
		exit 1; \
	fi

publish-qemu-3-launcher: check-qemu-3-publish-image ## Build, verify, push, and print the digest-pinned QEMU .3 image
	@$(MAKE) --no-print-directory build-qemu-3-launcher
	@set -euo pipefail; \
	image="$${CNV_QEMU_IMAGE}"; \
	repository="$${image%:*}"; \
	digest_file=$$(mktemp); \
	trap 'rm -f "$$digest_file"' EXIT; \
	podman push --digestfile="$$digest_file" "$$image"; \
	digest=$$(<"$$digest_file"); \
	if [[ ! "$$digest" =~ ^sha256:[0-9a-f]{64}$$ ]]; then \
		echo "$(RED)Error: podman returned an invalid image digest: '$$digest'.$(NC)"; \
		exit 1; \
	fi; \
	printf 'QEMU_3_LAUNCHER_IMAGE=%s@%s\n' "$$repository" "$$digest"

validation-checkup: ## Run ocp-virt-validation-checkup
	@QUAY_PULLSECRET_FILE="$(QUAY_PULLSECRET)" TEST_SUITES=$(TEST_SUITES) STORAGE_CLASS=$(STORAGE_CLASS) \
		USE_QEMU_3_LAUNCHER="$(USE_QEMU_3_LAUNCHER)" \
		QEMU_3_LAUNCHER_IMAGE="$(QEMU_3_LAUNCHER_IMAGE)" \
		QEMU_3_PULL_SECRET_FILE="$(QEMU_3_PULL_SECRET_FILE)" \
		./scripts/08-cnv-validation-checkup.sh

restore-qemu-3-launcher: ## Explicitly restore the shipped CNV virt-launcher after a QEMU .3 validation run
	@./scripts/09d-virt-launcher-image-override.sh restore

aro-validation-flow: ## Run the full ARO validation flow sequentially
	@TARGET_OCP_VERSION=4.22.4 $(MAKE) check-upgrade-target
	@$(MAKE) aro-up
	@$(MAKE) aro-login
	@$(MAKE) aro-disable-machineset-reconcile
	@$(MAKE) upgrade-to-4.22.4
	@$(MAKE) techpreview
	@$(MAKE) mshv-node
	@$(MAKE) cnv-pull-secret
	@$(MAKE) cnv-install
	@$(MAKE) mshv-hco-patch
	@$(MAKE) validation-checkup

ocp-validation-flow: ## Run the full self-managed OCP validation flow sequentially
	@$(MAKE) ocp-up
	@$(MAKE) cluster-info
	@KUBECONFIG="$(PWD)/installer/auth/kubeconfig" $(MAKE) techpreview
	@KUBECONFIG="$(PWD)/installer/auth/kubeconfig" $(MAKE) mshv-node
	@KUBECONFIG="$(PWD)/installer/auth/kubeconfig" $(MAKE) cnv-pull-secret
	@KUBECONFIG="$(PWD)/installer/auth/kubeconfig" $(MAKE) cnv-install
	@KUBECONFIG="$(PWD)/installer/auth/kubeconfig" $(MAKE) mshv-hco-patch
	@KUBECONFIG="$(PWD)/installer/auth/kubeconfig" $(MAKE) validation-checkup

clean-tools: ## Remove extracted OpenShift tools
	@echo "$(YELLOW)Removing tools directory $(TOOLS_DIR)...$(NC)"
	@rm -rf $(TOOLS_DIR)
	@echo "$(GREEN)[OK] Tools cleaned$(NC)"

clean: ## Remove generated self-managed installer state
	@echo "$(YELLOW)Removing installer directory...$(NC)"
	@rm -rf installer
	@echo "$(GREEN)[OK] Installer state cleaned$(NC)"
