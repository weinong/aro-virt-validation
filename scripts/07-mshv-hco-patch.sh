#!/usr/bin/env bash
# =============================================================================
# 07-mshv-hco-patch.sh - Patch HCO for MSHV (hyperv-direct) support
#
# Applies the kubevirt jsonpatch annotation to enable:
#   - ConfigurableHypervisor + hyperv-direct hypervisor
#   - Required feature gates
#   - evictionStrategy: None
#
# VMs are constrained to mshv nodes by the hyperv-direct device requirement
# (devices.kubevirt.io/mshv), NOT by a workload nodePlacement nodeSelector. See
# issues/2026-08-31c-checkup-node-schedulable.md for why pinning virt-handler to
# mshv breaks the ocp-virt-validation-checkup.
#
# NOTE: Do NOT set cpuModel (e.g. qemu64-v1) — it causes a nodeSelector
# mismatch because virt-handler does not advertise virtual CPU model labels.
# See issues/2026-04-23.md for details.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log_info "=== Phase 7: Patch HCO for MSHV ==="

check_command oc || exit 1
check_command jq || exit 1

log_info "Verifying cluster login..."
oc whoami &>/dev/null || { log_error "Not logged in."; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Configure HCO and annotate it with the kubevirt jsonpatch
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
    "path": "/spec/configuration/hypervisors",
    "value": [ { "name": "hyperv-direct" } ]
  },
  {
    "op": "add",
    "path": "/spec/configuration/evictionStrategy",
    "value": "None"
  }
]'

log_info "Applying kubevirt jsonpatch annotation to HCO..."
oc annotate hco "${HCO_NAME}" -n openshift-cnv --overwrite \
  "kubevirt.kubevirt.io/jsonpatch=${JSONPATCH}"

log_ok "HCO annotated."

# NOTE: We intentionally do NOT restrict virt workload placement to the mshv role
# via spec.deployment.nodePlacements. Under the hyperv-direct hypervisor every
# virt-launcher pod requests the `devices.kubevirt.io/mshv` device plugin
# resource, which only the mshv nodes advertise, so VMs are already constrained
# to mshv nodes by scheduling. Pinning virt-handler to mshv additionally leaves
# the other worker nodes without `kubevirt.io/schedulable=true`, which makes the
# ocp-virt-validation-checkup BeforeSuite (WaitForWorkerNodesSchedulable, which
# requires EVERY non-control-plane node to be schedulable) time out with
# "Ran 0 of N specs". See issues/2026-08-31c-checkup-node-schedulable.md.
# If a previous run pinned workloads to mshv, clear it so virt-handler runs on
# all workers.
if oc get hco "${HCO_NAME}" -n openshift-cnv -o jsonpath='{.spec.deployment.nodePlacements.workload}' 2>/dev/null | grep -q 'mshv'; then
  log_info "Clearing legacy mshv-only workload nodePlacement so virt-handler runs on all workers..."
  oc patch hco "${HCO_NAME}" -n openshift-cnv --type=json \
    -p '[{"op":"remove","path":"/spec/deployment/nodePlacements/workload"}]' 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 2: Check if KubeVirt CRD supports hypervisors field
# ---------------------------------------------------------------------------
HAS_HV_FIELD="$(oc get crd kubevirts.kubevirt.io -o json 2>/dev/null \
  | jq -r 'any(.spec.versions[]?.schema.openAPIV3Schema.properties.spec.properties.configuration.properties; has("hypervisors"))' 2>/dev/null || echo "false")"

if [[ "${HAS_HV_FIELD}" == "false" ]]; then
  log_warn "KubeVirt CRD does NOT have hypervisors field."
  log_warn "The hyperv-direct setting in the jsonpatch will be silently ignored."
  log_warn "Other settings (feature gates, evictionStrategy) are still applied."
else
  # Wait for KubeVirt to reconcile the hypervisors array
  log_info "Waiting for KubeVirt to reconcile (up to 5 min)..."
  TIMEOUT=300
  ELAPSED=0
  while true; do
    HV_NAME="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
      -o jsonpath='{.spec.configuration.hypervisors[0].name}' 2>/dev/null || echo "")"
    if [[ "${HV_NAME}" == "hyperv-direct" ]]; then
      log_ok "KubeVirt CR shows hypervisors[0].name=hyperv-direct"
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

# Verify feature gates were applied (these work regardless of CRD support for hypervisors)
log_info "Verifying feature gates..."
FG="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || echo "[]")"
if echo "${FG}" | grep -q '"ConfigurableHypervisor"'; then
  log_ok "ConfigurableHypervisor feature gate is set."
else
  log_error "ConfigurableHypervisor feature gate NOT found."
  exit 1
fi

log_info "Verifying VMs are constrained to MSHV nodes by the mshv device requirement..."
# Under hyperv-direct, virt-launcher requests devices.kubevirt.io/mshv, which
# only mshv nodes advertise -- this (not a nodePlacement nodeSelector) is what
# keeps VMs on mshv nodes. Confirm the mshv node advertises the device.
MSHV_NODE="$(oc get nodes -l node-role.kubernetes.io/mshv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
[[ -n "${MSHV_NODE}" ]] || { log_error "No mshv node found."; exit 1; }
MSHV_DEV="$(oc get node "${MSHV_NODE}" -o jsonpath='{.status.allocatable.devices\.kubevirt\.io/mshv}' 2>/dev/null || echo '')"
if [[ -n "${MSHV_DEV}" && "${MSHV_DEV}" != "0" ]]; then
  log_ok "mshv node advertises devices.kubevirt.io/mshv=${MSHV_DEV} (VMs schedule here)."
else
  log_error "mshv node does not advertise devices.kubevirt.io/mshv; hyperv-direct VMs cannot schedule."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: Verify virt-handler runs on the mshv node (and, by design, all workers
# so the validation checkup's all-nodes-schedulable BeforeSuite can pass).
# ---------------------------------------------------------------------------
log_info "Waiting for virt-handler pods to be ready..."
if ! oc rollout status daemonset/virt-handler -n openshift-cnv --timeout=300s; then
  log_error "virt-handler rollout did not complete in 300s."
  exit 1
fi
VIRT_HANDLER_STATUS="$(oc get daemonset/virt-handler -n openshift-cnv -o json)"
if ! jq -e '.status.desiredNumberScheduled > 0 and .status.numberReady == .status.desiredNumberScheduled' \
  <<< "${VIRT_HANDLER_STATUS}" >/dev/null; then
  log_error "virt-handler pods are not all ready."
  exit 1
fi
if [[ "$(oc get pods -n openshift-cnv -l kubevirt.io=virt-handler --field-selector spec.nodeName="${MSHV_NODE}" -o name 2>/dev/null | wc -l)" -lt 1 ]]; then
  log_error "No virt-handler pod is running on the mshv node ${MSHV_NODE}."
  exit 1
fi
log_ok "virt-handler is ready (including on the mshv node ${MSHV_NODE})."

# Show final config
log_info "KubeVirt feature gates:"
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null | jq '.' 2>/dev/null || true

log_info "KubeVirt hypervisors:"
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.hypervisors}' 2>/dev/null | jq '.' 2>/dev/null || true

log_ok "Phase 7 complete. MSHV configuration applied."
