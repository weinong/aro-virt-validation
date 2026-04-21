#!/usr/bin/env bash
# =============================================================================
# Shared environment variables for the OpenShift Virtualization + Azure Arc demo
# Source this file from each script: source "$(dirname "$0")/env.sh"
# =============================================================================

# --- Azure / ARO settings ---
export LOCATION="${LOCATION:-centralus}"
export RESOURCEGROUP="${RESOURCEGROUP:-aro-virt-test-rg}"
export CLUSTER="${CLUSTER:-aro-virt-test}"
export VNET_NAME="${VNET_NAME:-aro-vnet}"
export VNET_CIDR="${VNET_CIDR:-10.0.0.0/22}"
export MASTER_SUBNET="${MASTER_SUBNET:-master}"
export MASTER_SUBNET_CIDR="${MASTER_SUBNET_CIDR:-10.0.0.0/23}"
export WORKER_SUBNET="${WORKER_SUBNET:-worker}"
export WORKER_SUBNET_CIDR="${WORKER_SUBNET_CIDR:-10.0.2.0/23}"

# Worker VM size: must be Dsv5 or Dsv6 with >= 8 cores for OpenShift Virtualization
export WORKER_VM_SIZE="${WORKER_VM_SIZE:-Standard_D8s_v5}"
export WORKER_COUNT="${WORKER_COUNT:-3}"
export WORKER_DISK_SIZE_GB="${WORKER_DISK_SIZE_GB:-128}"

# --- Managed Identity names (9 required for managed-identity ARO) ---
export MI_CLUSTER="aro-cluster"
export MI_CCM="cloud-controller-manager"
export MI_INGRESS="ingress"
export MI_MACHINE_API="machine-api"
export MI_DISK_CSI="disk-csi-driver"
export MI_CLOUD_NET="cloud-network-config"
export MI_IMAGE_REG="image-registry"
export MI_FILE_CSI="file-csi-driver"
export MI_ARO_OP="aro-operator"

# Credentials file lives at the repo root (gitignored by .arc-sp-creds*.json)
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- KubeVirt VM settings ---
export VM_NAME="${VM_NAME:-rhel9-arc-demo}"
export VM_NAMESPACE="${VM_NAMESPACE:-default}"

# --- Validate resource names (guard against injection via env overrides) ---
for _var_name in CLUSTER RESOURCEGROUP VM_NAME VM_NAMESPACE; do
  _var_val="${!_var_name}"
  if [[ -n "$_var_val" && ! "$_var_val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[ERROR] Invalid characters in $_var_name='$_var_val'. Only [a-zA-Z0-9._-] allowed." >&2
    exit 1
  fi
done
unset _var_name _var_val

# --- Derived values (populated at runtime) ---
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null)}"

# --- Helper functions ---
log_info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
log_ok() { echo -e "\033[0;32m[OK]\033[0m    $*"; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

check_command() {
  if ! command -v "$1" &>/dev/null; then
    log_error "Required command '$1' not found. Please install it first."
    return 1
  fi
}

# Validate a Red Hat pull secret file.
# Usage: validate_pull_secret <file_path>
# Returns 0 if valid, 1 if missing, 2 if invalid.
validate_pull_secret() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  if ! command -v python3 &>/dev/null; then
    log_warn "  python3 not found — cannot validate pull-secret content"
    return 0 # can't validate, assume OK
  fi
  if python3 -c "
import sys, json
with open(sys.argv[1]) as f:
    d = json.load(f)
assert 'auths' in d
" "$file" 2>/dev/null; then
    return 0
  else
    return 2
  fi
}
