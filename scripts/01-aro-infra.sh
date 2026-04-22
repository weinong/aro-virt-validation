#!/usr/bin/env bash
# =============================================================================
# 01-aro-infra.sh - Create ARO cluster with managed identities
#
# Creates:
#   1. Resource group
#   2. Virtual network with master/worker subnets
#   3. 9 user-assigned managed identities
#   4. All required role assignments
#   5. ARO cluster with --enable-managed-identity
#
# Reference: https://learn.microsoft.com/azure/openshift/howto-create-openshift-cluster
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "============================================="
echo " Phase 1: ARO Infrastructure Provisioning"
echo "============================================="

# -----------------------------------------------
# 1. Create Resource Group
# -----------------------------------------------
log_info "Creating resource group: $RESOURCEGROUP in $LOCATION..."
az group create \
    --location "$LOCATION" \
    --name "$RESOURCEGROUP" \
    --output none
log_ok "Resource group created."

# -----------------------------------------------
# 2. Create Virtual Network and Subnets
# -----------------------------------------------
log_info "Creating virtual network: $VNET_NAME ($VNET_CIDR)..."
az network vnet create \
    --resource-group "$RESOURCEGROUP" \
    --name "$VNET_NAME" \
    --address-prefixes "$VNET_CIDR" \
    --output none

log_info "Creating master subnet: $MASTER_SUBNET ($MASTER_SUBNET_CIDR)..."
az network vnet subnet create \
    --resource-group "$RESOURCEGROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$MASTER_SUBNET" \
    --address-prefixes "$MASTER_SUBNET_CIDR" \
    --output none

log_info "Creating worker subnet: $WORKER_SUBNET ($WORKER_SUBNET_CIDR)..."
az network vnet subnet create \
    --resource-group "$RESOURCEGROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$WORKER_SUBNET" \
    --address-prefixes "$WORKER_SUBNET_CIDR" \
    --output none
log_ok "Virtual network and subnets created."

# -----------------------------------------------
# 3. Create 9 User-Assigned Managed Identities
# -----------------------------------------------
IDENTITIES=(
    "$MI_CLUSTER"
    "$MI_CCM"
    "$MI_INGRESS"
    "$MI_MACHINE_API"
    "$MI_DISK_CSI"
    "$MI_CLOUD_NET"
    "$MI_IMAGE_REG"
    "$MI_FILE_CSI"
    "$MI_ARO_OP"
)

log_info "Creating ${#IDENTITIES[@]} user-assigned managed identities..."
for id_name in "${IDENTITIES[@]}"; do
    log_info "  Creating identity: $id_name"
    az identity create \
        --resource-group "$RESOURCEGROUP" \
        --name "$id_name" \
        --output none
done
log_ok "All managed identities created."

# Wait a moment for AAD propagation
log_info "Waiting 30s for identity propagation..."
sleep 30

# -----------------------------------------------
# 4. Create Role Assignments
# -----------------------------------------------
log_info "Creating role assignments..."

# Helper: get principal ID for a managed identity
get_principal_id() {
    az identity show \
        --resource-group "$RESOURCEGROUP" \
        --name "$1" \
        --query principalId -o tsv
}

CLUSTER_PRINCIPAL=$(get_principal_id "$MI_CLUSTER")
CCM_PRINCIPAL=$(get_principal_id "$MI_CCM")
INGRESS_PRINCIPAL=$(get_principal_id "$MI_INGRESS")
MACHINE_API_PRINCIPAL=$(get_principal_id "$MI_MACHINE_API")
CLOUD_NET_PRINCIPAL=$(get_principal_id "$MI_CLOUD_NET")
FILE_CSI_PRINCIPAL=$(get_principal_id "$MI_FILE_CSI")
IMAGE_REG_PRINCIPAL=$(get_principal_id "$MI_IMAGE_REG")
ARO_OP_PRINCIPAL=$(get_principal_id "$MI_ARO_OP")

# Note: disk-csi-driver does not need an explicit role assignment here.
# Its role is assigned automatically by the ARO RP during cluster creation.
# The identity only needs to exist so it can be passed to --assign-platform-workload-identity.

# Role definition IDs (built-in)
ROLE_MI_OPERATOR="ef318e2a-8334-4a05-9e4a-295a196c6a6e"  # Managed Identity Operator

# Operator-specific roles on subnets/VNet
ROLE_CCM_SUBNET="a1f96423-95ce-4224-ab27-4e3dc72facd4"
ROLE_INGRESS_SUBNET="0336e1d3-7a87-462b-b6db-342b63f7802c"
ROLE_MACHINE_API_SUBNET="0358943c-7e01-48ba-8889-02cc51d78637"
ROLE_CLOUD_NET_VNET="be7a6435-15ae-4171-8f30-4a343eff9e8f"
ROLE_FILE_CSI_VNET="0d7aedc0-15fd-4a67-a412-efad370c947e"
ROLE_IMAGE_REG_VNET="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
ROLE_ARO_OP_SUBNET="4436bae4-7702-4c84-919b-c4069ff25ee2"
ROLE_RP_VNET="42f3c60f-e7b1-46d7-ba56-6de681664342"

# Scope paths
MI_SCOPE_PREFIX="/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCEGROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities"
VNET_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCEGROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"
MASTER_SCOPE="${VNET_SCOPE}/subnets/${MASTER_SUBNET}"
WORKER_SCOPE="${VNET_SCOPE}/subnets/${WORKER_SUBNET}"
ROLE_DEF_PREFIX="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions"

# --- 4a. Cluster identity -> Managed Identity Operator over each operator identity ---
OPERATOR_IDENTITIES=("$MI_ARO_OP" "$MI_CCM" "$MI_INGRESS" "$MI_MACHINE_API" "$MI_DISK_CSI" "$MI_CLOUD_NET" "$MI_IMAGE_REG" "$MI_FILE_CSI")

log_info "  Assigning Managed Identity Operator role to cluster identity..."
for op_id in "${OPERATOR_IDENTITIES[@]}"; do
    az role assignment create \
        --assignee-object-id "$CLUSTER_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --role "${ROLE_DEF_PREFIX}/${ROLE_MI_OPERATOR}" \
        --scope "${MI_SCOPE_PREFIX}/${op_id}" \
        --output none 2>/dev/null || true
done

# --- 4b. cloud-controller-manager -> subnets ---
log_info "  Assigning cloud-controller-manager roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    az role assignment create \
        --assignee-object-id "$CCM_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --role "${ROLE_DEF_PREFIX}/${ROLE_CCM_SUBNET}" \
        --scope "$SUBNET_SCOPE" \
        --output none 2>/dev/null || true
done

# --- 4c. ingress -> subnets ---
log_info "  Assigning ingress roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    az role assignment create \
        --assignee-object-id "$INGRESS_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --role "${ROLE_DEF_PREFIX}/${ROLE_INGRESS_SUBNET}" \
        --scope "$SUBNET_SCOPE" \
        --output none 2>/dev/null || true
done

# --- 4d. machine-api -> subnets ---
log_info "  Assigning machine-api roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    az role assignment create \
        --assignee-object-id "$MACHINE_API_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --role "${ROLE_DEF_PREFIX}/${ROLE_MACHINE_API_SUBNET}" \
        --scope "$SUBNET_SCOPE" \
        --output none 2>/dev/null || true
done

# --- 4e. cloud-network-config -> VNet ---
log_info "  Assigning cloud-network-config role..."
az role assignment create \
    --assignee-object-id "$CLOUD_NET_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE_DEF_PREFIX}/${ROLE_CLOUD_NET_VNET}" \
    --scope "$VNET_SCOPE" \
    --output none 2>/dev/null || true

# --- 4f. file-csi-driver -> VNet ---
log_info "  Assigning file-csi-driver role..."
az role assignment create \
    --assignee-object-id "$FILE_CSI_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE_DEF_PREFIX}/${ROLE_FILE_CSI_VNET}" \
    --scope "$VNET_SCOPE" \
    --output none 2>/dev/null || true

# --- 4g. image-registry -> VNet ---
log_info "  Assigning image-registry role..."
az role assignment create \
    --assignee-object-id "$IMAGE_REG_PRINCIPAL" \
    --assignee-principal-type ServicePrincipal \
    --role "${ROLE_DEF_PREFIX}/${ROLE_IMAGE_REG_VNET}" \
    --scope "$VNET_SCOPE" \
    --output none 2>/dev/null || true

# --- 4h. aro-operator -> subnets ---
log_info "  Assigning aro-operator roles..."
for SUBNET_SCOPE in "$MASTER_SCOPE" "$WORKER_SCOPE"; do
    az role assignment create \
        --assignee-object-id "$ARO_OP_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --role "${ROLE_DEF_PREFIX}/${ROLE_ARO_OP_SUBNET}" \
        --scope "$SUBNET_SCOPE" \
        --output none 2>/dev/null || true
done

# --- 4i. Azure Red Hat OpenShift RP first-party SP -> VNet ---
log_info "  Assigning ARO RP first-party service principal role..."
ARO_RP_SP_OID=$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query '[0].id' -o tsv 2>/dev/null || echo "")
if [[ -n "$ARO_RP_SP_OID" ]]; then
    az role assignment create \
        --assignee-object-id "$ARO_RP_SP_OID" \
        --assignee-principal-type ServicePrincipal \
        --role "${ROLE_DEF_PREFIX}/${ROLE_RP_VNET}" \
        --scope "$VNET_SCOPE" \
        --output none 2>/dev/null || true
    log_ok "  ARO RP SP role assigned."
else
    log_warn "  Could not find 'Azure Red Hat OpenShift RP' service principal."
    log_warn "  This may mean the Microsoft.RedHatOpenShift provider isn't registered."
fi

log_ok "All role assignments created."

# -----------------------------------------------
# 5. Get available ARO versions and create cluster
# -----------------------------------------------
log_info "Fetching available ARO versions in $LOCATION..."
ARO_VERSIONS=$(az aro get-versions --location "$LOCATION" -o json 2>/dev/null || echo "[]")
echo "$ARO_VERSIONS" | python3 -c "
import sys, json
versions = json.load(sys.stdin)
if versions:
    print('Available versions:')
    for v in sorted(versions, reverse=True):
        print(f'  {v}')
else:
    print('No versions available (or command not supported in this CLI version)')
"

# Pick the latest 4.18+ version (required for OpenShift Virtualization)
ARO_VERSION=$(echo "$ARO_VERSIONS" | python3 -c "
import sys, json
versions = sorted(json.load(sys.stdin), reverse=True)
for v in versions:
    major, minor = v.split('.')[:2]
    if int(major) >= 4 and int(minor) >= 18:
        print(v)
        break
" 2>/dev/null || echo "")

if [[ -z "$ARO_VERSION" ]]; then
    log_error "No ARO version >= 4.18 found. OpenShift Virtualization requires 4.18+."
    log_error "Available versions: $ARO_VERSIONS"
    exit 1
fi

log_ok "Selected ARO version: $ARO_VERSION"

# -----------------------------------------------
# 6. Create the ARO cluster
# -----------------------------------------------
log_info "Creating ARO cluster '$CLUSTER' (this takes 30-45 minutes)..."
log_info "  Version: $ARO_VERSION"
log_info "  Worker VM size: $WORKER_VM_SIZE"
log_info "  Worker count: $WORKER_COUNT"

CREATE_CMD=(
    az aro create
    --resource-group "$RESOURCEGROUP"
    --name "$CLUSTER"
    --vnet "$VNET_NAME"
    --master-subnet "$MASTER_SUBNET"
    --worker-subnet "$WORKER_SUBNET"
    --worker-vm-size "$WORKER_VM_SIZE"
    --worker-count "$WORKER_COUNT"
    --worker-vm-disk-size-gb "$WORKER_DISK_SIZE_GB"
    --version "$ARO_VERSION"
    --enable-managed-identity
    --assign-cluster-identity "$MI_CLUSTER"
    --assign-platform-workload-identity "$MI_FILE_CSI" "$MI_FILE_CSI"
    --assign-platform-workload-identity "$MI_CCM" "$MI_CCM"
    --assign-platform-workload-identity "$MI_INGRESS" "$MI_INGRESS"
    --assign-platform-workload-identity "$MI_IMAGE_REG" "$MI_IMAGE_REG"
    --assign-platform-workload-identity "$MI_MACHINE_API" "$MI_MACHINE_API"
    --assign-platform-workload-identity "$MI_CLOUD_NET" "$MI_CLOUD_NET"
    --assign-platform-workload-identity "$MI_ARO_OP" "$MI_ARO_OP"
    --assign-platform-workload-identity "$MI_DISK_CSI" "$MI_DISK_CSI"
)

# Validate pull secret (required for OperatorHub / OpenShift Virtualization)
PULL_SECRET_FILE="${SCRIPT_DIR}/../.pull-secret.txt"
validate_pull_secret "$PULL_SECRET_FILE"
rc=$?
if [[ $rc -eq 1 ]]; then
    log_error ".pull-secret.txt not found in repo root."
    log_error "This is required for OpenShift Virtualization (OperatorHub access)."
    log_error "Download from: https://console.redhat.com/openshift/install/azure/aro-provisioned"
    exit 1
elif [[ $rc -eq 2 ]]; then
    log_error ".pull-secret.txt does not appear to be a valid Red Hat pull secret."
    log_error "Expected a JSON file containing an 'auths' key."
    log_error "Re-download from: https://console.redhat.com/openshift/install/azure/aro-provisioned"
    exit 1
fi

log_ok "  .pull-secret.txt validated"
CREATE_CMD+=(--pull-secret "@${PULL_SECRET_FILE}")

"${CREATE_CMD[@]}"

log_ok "ARO cluster '$CLUSTER' created successfully!"

# -----------------------------------------------
# 7. Retrieve cluster credentials and API server URL
# -----------------------------------------------
log_info "Retrieving cluster credentials..."
CREDENTIALS=$(az aro list-credentials --resource-group "$RESOURCEGROUP" --name "$CLUSTER" -o json)
API_SERVER=$(az aro show --resource-group "$RESOURCEGROUP" --name "$CLUSTER" --query apiserverProfile.url -o tsv)
CONSOLE_URL=$(az aro show --resource-group "$RESOURCEGROUP" --name "$CLUSTER" --query consoleProfile.url -o tsv)

echo ""
log_ok "============================================="
log_ok " ARO Cluster Ready!"
log_ok "============================================="
log_ok "  API Server:  $API_SERVER"
log_ok "  Console:     $CONSOLE_URL"
log_ok "  Username:    $(echo "$CREDENTIALS" | python3 -c 'import sys,json; print(json.load(sys.stdin)["kubeadminUsername"])')"
log_ok "  Password:    (retrieve with: az aro list-credentials -g $RESOURCEGROUP -n $CLUSTER)"
log_ok ""
log_ok "  Login with:  oc login $API_SERVER -u kubeadmin -p <password>"
log_ok "============================================="
