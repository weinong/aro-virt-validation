#!/usr/bin/env bash
# =============================================================================
# Shared environment variables for the OpenShift Virtualization + Azure Arc demo
# Source this file from each script: source "$(dirname "$0")/env.sh"
# =============================================================================

# Credentials file lives at the repo root (gitignored by .arc-sp-creds*.json)
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Local overrides ---
if [[ -f "${_REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${_REPO_ROOT}/.env"
  set +a
fi

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

# Target OCP payload used before enabling TechPreviewNoUpgrade for MSHV/RHCOS 10.
# 4.22.0-rc.3 and older 4.22 pre-release payloads are blocked by a known
# TechPreview CR-before-CRD issue in this validation path.
export TARGET_OCP_VERSION="${TARGET_OCP_VERSION:-4.22.4}"

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

is_known_bad_techpreview_payload() {
  local version="$1"
  if [[ "${version}" =~ ^4\.22\.0-(ec|rc)\.([0-9]+)$ ]]; then
    local pre_release_kind="${BASH_REMATCH[1]}"
    local pre_release_number="${BASH_REMATCH[2]}"
    [[ "${pre_release_kind}" == "ec" || "${pre_release_number}" -le 3 ]]
    return
  fi
  return 1
}

guard_known_bad_techpreview_payload() {
  local version="$1"
  local context="${2:-TechPreviewNoUpgrade validation}"
  local allow="${ALLOW_KNOWN_BAD_TECHPREVIEW_PAYLOAD:-false}"

  if is_known_bad_techpreview_payload "${version}"; then
    if [[ "${allow}" == "true" ]]; then
      log_warn "Bypassing known-bad payload guard for ${version}. This is for investigation only."
      return 0
    fi
    log_error "Payload ${version} is blocked for ${context}."
    log_error "Known issue: 4.22.0-rc.3 and older 4.22 pre-release payloads can fail applying CRIOCredentialProviderConfig before its CRD is served."
    log_error "Use a newer 4.22 payload before enabling TechPreviewNoUpgrade."
    log_error "Set ALLOW_KNOWN_BAD_TECHPREVIEW_PAYLOAD=true only to deliberately reproduce/document this issue."
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

# Load QUAY_USERNAME and QUAY_PASSWORD from a simple KEY=VALUE file without
# evaluating it as shell. Only these two keys are accepted.
load_quay_pullsecret() {
  local file="$1"
  local line key value first last
  local found_username=false
  local found_password=false

  if [[ ! -f "$file" ]]; then
    log_error "Quay credential file not found: $file"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" != *=* ]]; then
      log_error "Invalid line in $file. Expected KEY=VALUE."
      return 2
    fi

    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$key" != "QUAY_USERNAME" && "$key" != "QUAY_PASSWORD" ]]; then
      log_error "Unexpected key '$key' in $file. Only QUAY_USERNAME and QUAY_PASSWORD are allowed."
      return 2
    fi

    if [[ "${#value}" -ge 2 ]]; then
      first="${value:0:1}"
      last="${value: -1}"
      if [[ "$first" == "$last" && ( "$first" == "'" || "$first" == '"' ) ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    case "$key" in
      QUAY_USERNAME)
        QUAY_USERNAME="$value"
        found_username=true
        ;;
      QUAY_PASSWORD)
        QUAY_PASSWORD="$value"
        found_password=true
        ;;
    esac
  done < "$file"

  if [[ "$found_username" != "true" || "$found_password" != "true" ]]; then
    log_error "QUAY_USERNAME and QUAY_PASSWORD must both be set in $file."
    return 3
  fi

  export QUAY_USERNAME QUAY_PASSWORD
}
