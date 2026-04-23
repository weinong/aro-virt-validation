#!/usr/bin/env bash
# =============================================================================
# Phase 8 — Patch HCO for MSHV (hyperv-direct) support
#
# Applies the kubevirt jsonpatch annotation to enable:
#   - ConfigurableHypervisor + hyperv-direct hypervisor
#   - Required feature gates
#   - qemu64-v1 CPU model
#   - evictionStrategy: None
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log_info "=== Phase 8: Patch HCO for MSHV ==="

check_command oc || exit 1

log_info "Verifying cluster login..."
oc whoami &>/dev/null || { log_error "Not logged in."; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Annotate HCO with kubevirt jsonpatch
# ---------------------------------------------------------------------------
HCO_NAME="$(oc get hco -n openshift-cnv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -z "${HCO_NAME}" ]] && { log_error "No HyperConverged CR found in openshift-cnv."; exit 1; }
log_ok "Found HCO: ${HCO_NAME}"

JSONPATCH='[
  {
    "op": "add",
    "path": "/spec/configuration/developerConfiguration/featureGates",
    "value": ["ConfigurableHypervisor", "CPUManager", "Snapshot", "HotplugVolumes", "ExpandDisks", "HostDevices", "VMExport", "KubevirtSeccompProfile", "VMPersistentState", "InstancetypeReferencePolicy", "WithHostModelCPU", "HypervStrictCheck"]
  },
  {
    "op": "add",
    "path": "/spec/configuration/hypervisorConfiguration",
    "value": { "name": "hyperv-direct" }
  },
  {
    "op": "add",
    "path": "/spec/configuration/evictionStrategy",
    "value": "None"
  },
  {
    "op": "replace",
    "path": "/spec/configuration/obsoleteCPUModels/qemu64",
    "value": false
  },
  {
    "op": "replace",
    "path": "/spec/configuration/obsoleteCPUModels/qemu64-v1",
    "value": false
  },
  {
    "op": "add",
    "path": "/spec/configuration/cpuModel",
    "value": "qemu64-v1"
  }
]'

log_info "Applying kubevirt jsonpatch annotation to HCO..."
oc annotate hco "${HCO_NAME}" -n openshift-cnv --overwrite \
  "kubevirt.kubevirt.io/jsonpatch=${JSONPATCH}"

log_ok "HCO annotated."

# ---------------------------------------------------------------------------
# Step 2: Check if KubeVirt CRD supports hypervisorConfiguration
# ---------------------------------------------------------------------------
HAS_HV_FIELD="$(oc get crd kubevirts.kubevirt.io -o json 2>/dev/null | \
  python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    props=d['spec']['versions'][0]['schema']['openAPIV3Schema']['properties']['spec']['properties']['configuration']['properties']
    print('true' if 'hypervisorConfiguration' in props else 'false')
except (KeyError, IndexError):
    print('false')
" 2>/dev/null || echo "false")"

if [[ "${HAS_HV_FIELD}" == "false" ]]; then
  log_warn "KubeVirt CRD does NOT have hypervisorConfiguration field."
  log_warn "The hyperv-direct setting in the jsonpatch will be silently ignored."
  log_warn "Other settings (feature gates, cpuModel, evictionStrategy) are still applied."
  log_warn "See issues/2026-04-23.md for details."
else
  # Wait for KubeVirt to reconcile the hypervisorConfiguration
  log_info "Waiting for KubeVirt to reconcile (up to 5 min)..."
  TIMEOUT=300
  ELAPSED=0
  while true; do
    HV_NAME="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
      -o jsonpath='{.spec.configuration.hypervisorConfiguration.name}' 2>/dev/null || echo "")"
    if [[ "${HV_NAME}" == "hyperv-direct" ]]; then
      log_ok "KubeVirt CR shows hypervisorConfiguration.name=hyperv-direct"
      break
    fi
    if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
      log_error "Timeout waiting for KubeVirt reconciliation."
      log_info "Current KubeVirt config:"
      oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o yaml | grep -A 20 'configuration:' || true
      exit 1
    fi
    log_info "  Waiting for reconciliation... (${ELAPSED}s)"
    sleep 15
    ELAPSED=$((ELAPSED + 15))
  done
fi

# Verify feature gates were applied (these work regardless of CRD support for hypervisorConfiguration)
log_info "Verifying feature gates..."
FG="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || echo "[]")"
if echo "${FG}" | grep -q '"ConfigurableHypervisor"'; then
  log_ok "ConfigurableHypervisor feature gate is set."
else
  log_error "ConfigurableHypervisor feature gate NOT found."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: Verify virt-handler pods are restarted and ready
# ---------------------------------------------------------------------------
log_info "Waiting for virt-handler pods to be ready..."
oc rollout status daemonset/virt-handler -n openshift-cnv --timeout=300s 2>/dev/null || \
  log_warn "virt-handler rollout did not complete in 300s."

# Show final config
log_info "KubeVirt feature gates:"
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null | jq '.' 2>/dev/null || true

log_info "KubeVirt hypervisor config:"
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.hypervisorConfiguration}' 2>/dev/null | jq '.' 2>/dev/null || true

log_info "KubeVirt CPU model:"
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.cpuModel}' 2>/dev/null
echo

log_ok "Phase 8 complete. MSHV configuration applied."
