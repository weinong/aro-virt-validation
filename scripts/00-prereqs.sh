#!/usr/bin/env bash
# =============================================================================
# 00-prereqs.sh - Validate Azure prerequisites for the demo
#
# Checks:
#   1. Azure CLI version >= 2.84.0 (required for managed-identity ARO)
#   2. Required resource providers are registered
#   3. Sufficient DSv5 and Ddsv6 quota in the target region
#   4. Required CLI extensions
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "============================================="
echo " Phase 0: Azure Prerequisites Check"
echo "============================================="

# -----------------------------------------------
# 1. Check target OCP payload for TechPreview validation
# -----------------------------------------------
log_info "Checking target OCP payload guard..."
if [[ -n "${TARGET_OCP_VERSION}" ]]; then
    guard_known_bad_techpreview_payload "${TARGET_OCP_VERSION}" "pre-cluster TechPreviewNoUpgrade validation" || exit 1
    log_ok "  TARGET_OCP_VERSION=${TARGET_OCP_VERSION} is allowed for TechPreview validation"
else
    log_warn "  TARGET_OCP_VERSION is not set."
    log_warn "  Set TARGET_OCP_VERSION to the intended 4.22 payload before creating a cluster for TechPreview/MSHV validation."
    log_warn "  Known-bad payloads such as 4.22.0-rc.3 will still be blocked later by upgrade and TechPreview scripts."
fi

# -----------------------------------------------
# 2. Check Azure CLI version
# -----------------------------------------------
log_info "Checking Azure CLI version..."
check_command az

AZ_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "0.0.0")
AZ_VERSION="${AZ_VERSION:-0.0.0}"
REQUIRED_VERSION="2.84.0"

version_ge() {
    # Returns 0 if $1 >= $2 (semver comparison)
    printf '%s\n%s' "$2" "$1" | sort -V -C
}

if version_ge "$AZ_VERSION" "$REQUIRED_VERSION"; then
    log_ok "Azure CLI version: $AZ_VERSION (>= $REQUIRED_VERSION required)"
else
    log_error "Azure CLI version $AZ_VERSION is below the required $REQUIRED_VERSION"
    log_error "Managed-identity ARO clusters require Azure CLI >= $REQUIRED_VERSION"
    log_error "Run: az upgrade"
    exit 1
fi

# -----------------------------------------------
# 3. Check logged-in subscription
# -----------------------------------------------
log_info "Checking Azure subscription..."
ACCOUNT_NAME=$(az account show --query name -o tsv 2>/dev/null || echo "")
if [[ -z "$ACCOUNT_NAME" ]]; then
    log_error "Not logged in to Azure. Run: az login"
    exit 1
fi
log_ok "Subscription: $ACCOUNT_NAME ($SUBSCRIPTION_ID)"

# -----------------------------------------------
# 4. Register required resource providers
# -----------------------------------------------
PROVIDERS=(
    "Microsoft.RedHatOpenShift"
    "Microsoft.Compute"
    "Microsoft.Storage"
    "Microsoft.Authorization"
    "Microsoft.HybridCompute"          # Azure Arc servers
    "Microsoft.GuestConfiguration"      # Azure Arc guest config
    "Microsoft.HybridConnectivity"      # Azure Arc connectivity
)

log_info "Checking resource provider registrations..."
for provider in "${PROVIDERS[@]}"; do
    STATE=$(az provider show -n "$provider" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$STATE" == "Registered" ]]; then
        log_ok "  $provider: Registered"
    else
        log_warn "  $provider: $STATE - registering now..."
        az provider register -n "$provider" --wait
        log_ok "  $provider: Registered"
    fi
done

# -----------------------------------------------
# 5. Check DSv5 quota in target region
# -----------------------------------------------
log_info "Checking DSv5 family vCPU quota in $LOCATION..."
QUOTA_INFO=$(az vm list-usage -l "$LOCATION" \
    --query "[?contains(name.value, 'standardDSv5Family')]" -o json 2>/dev/null)

CURRENT_USAGE=$(echo "$QUOTA_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['currentValue'] if d else 0)" 2>/dev/null || echo "0")
LIMIT=$(echo "$QUOTA_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['limit'] if d else 0)" 2>/dev/null || echo "0")
AVAILABLE=$((LIMIT - CURRENT_USAGE))

# Need: 3 master (8 cores each) = 24 + 3 workers (8 cores each) = 24 + 8 bootstrap = 56
# After install bootstrap freed: steady state = 48, but peak = 56
REQUIRED_CORES=56

log_info "  DSv5 quota: $CURRENT_USAGE / $LIMIT used, $AVAILABLE available"
if [[ "$AVAILABLE" -ge "$REQUIRED_CORES" ]]; then
    log_ok "  Sufficient quota ($AVAILABLE available >= $REQUIRED_CORES required)"
else
    log_warn "  Insufficient DSv5 quota: $AVAILABLE available, need $REQUIRED_CORES"
    log_warn "  Request a quota increase at: https://aka.ms/ProdportalCRP/?#create/Microsoft.Support/Parameters/"
    log_warn "  Or use: az quota update"
    log_warn "  See: https://learn.microsoft.com/azure/quotas/per-vm-quota-requests"
fi

# -----------------------------------------------
# 5b. Check Ddsv6 quota for MSHV validation node
# -----------------------------------------------
log_info "Checking Ddsv6 family vCPU quota in $LOCATION..."
MSHV_QUOTA_INFO=$(az vm list-usage -l "$LOCATION" \
    --query "[?contains(name.value, 'standardDDSv6Family') || contains(name.value, 'standardDdsv6Family')]" -o json 2>/dev/null)

MSHV_CURRENT_USAGE=$(echo "$MSHV_QUOTA_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['currentValue'] if d else 0)" 2>/dev/null || echo "0")
MSHV_LIMIT=$(echo "$MSHV_QUOTA_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['limit'] if d else 0)" 2>/dev/null || echo "0")
MSHV_AVAILABLE=$((MSHV_LIMIT - MSHV_CURRENT_USAGE))
MSHV_REQUIRED_CORES=192

log_info "  Ddsv6 quota: $MSHV_CURRENT_USAGE / $MSHV_LIMIT used, $MSHV_AVAILABLE available"
if [[ "$MSHV_AVAILABLE" -ge "$MSHV_REQUIRED_CORES" ]]; then
    log_ok "  Sufficient MSHV quota ($MSHV_AVAILABLE available >= $MSHV_REQUIRED_CORES required)"
else
    log_warn "  Insufficient Ddsv6 quota for Standard_D192ds_v6: $MSHV_AVAILABLE available, need $MSHV_REQUIRED_CORES"
    log_warn "  Request a quota increase for the Ddsv6 family before running MSHV validation."
fi

# -----------------------------------------------
# 6. Check for oc / kubectl (informational)
# -----------------------------------------------
log_info "Checking for OpenShift CLI tools (optional at this stage)..."
if command -v oc &>/dev/null; then
    log_ok "  oc: $(oc version --client 2>/dev/null | head -1)"
else
    log_warn "  oc: not found - will be needed in Phase 2+"
    log_warn "  Install from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
fi

if command -v virtctl &>/dev/null; then
    log_ok "  virtctl: found"
else
    log_warn "  virtctl: not found - will be needed in Phase 3+"
    log_warn "  Download the appropriate binary from:"
    log_warn "    https://github.com/kubevirt/kubevirt/releases/latest"
    log_warn "  Or after OpenShift Virt is installed:"
    log_warn "    oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged -o jsonpath='{.spec.links}'"
fi

# -----------------------------------------------
# 7. Check for .pullsecret
# -----------------------------------------------
log_info "Checking for Red Hat pull secret..."
PULL_SECRET_FILE="${SCRIPT_DIR}/../.pullsecret"
validate_pull_secret "$PULL_SECRET_FILE"
rc=$?
if [[ $rc -eq 0 && -f "$PULL_SECRET_FILE" ]]; then
    log_ok "  .pullsecret: found and valid"
elif [[ $rc -eq 2 ]]; then
    log_warn "  .pullsecret: found but does not appear valid (expected JSON with 'auths' key)"
    log_warn "  Re-download from: https://console.redhat.com/openshift/install/azure/aro-provisioned"
else
    log_warn "  .pullsecret: not found in repo root"
    log_warn "  Run: make .pullsecret"
fi

echo ""
log_ok "============================================="
log_ok " Prerequisites check complete!"
log_ok "============================================="
