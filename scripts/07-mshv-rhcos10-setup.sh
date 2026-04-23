#!/usr/bin/env bash
# =============================================================================
# Phase 7 — Set up MSHV (hyperv-direct) node with RHCOS 10
#
# This script:
#   1. Enables TechPreviewNoUpgrade featureset (IRREVERSIBLE)
#   2. Waits for the rhel-10 OS stream to become available
#   3. Creates a dedicated "mshv" MachineConfigPool with rhel-10
#   4. Creates a machineset with Standard_D192ds_v6 + L1VH tag
#   5. Waits for the node to boot into RHCOS 10 with L1VH partition
#
# Prerequisites:
#   - oc logged in as kube:admin
#   - OCP 4.21+ payload that includes rhel-coreos-10 image
#   - Sufficient Azure quota for Standard_D192ds_v6 (192 vCPUs)
#
# Idempotent: safe to re-run.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

MSHV_VM_SIZE="${MSHV_VM_SIZE:-Standard_D192ds_v6}"
MSHV_DISK_SIZE_GB="${MSHV_DISK_SIZE_GB:-256}"
MSHV_ZONE="${MSHV_ZONE:-1}"

log_info "=== Phase 7: MSHV Node Setup with RHCOS 10 ==="

check_command oc || exit 1
check_command jq || exit 1

log_info "Verifying cluster login..."
CURRENT_USER="$(oc whoami 2>/dev/null)" || { log_error "Not logged in."; exit 1; }
log_ok "Logged in as ${CURRENT_USER}"

# ---------------------------------------------------------------------------
# Step 1: Enable TechPreviewNoUpgrade
# ---------------------------------------------------------------------------
CURRENT_FS="$(oc get featuregate/cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo "")"
if [[ "${CURRENT_FS}" == "TechPreviewNoUpgrade" ]]; then
  log_ok "TechPreviewNoUpgrade already enabled."
else
  log_warn "Enabling TechPreviewNoUpgrade — this is IRREVERSIBLE."
  log_warn "The cluster will no longer be eligible for minor version upgrades."
  oc patch featuregate/cluster --type merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
  log_ok "TechPreviewNoUpgrade enabled."
fi

# ---------------------------------------------------------------------------
# Step 2: Wait for OSImageStream CRD and rhel-10 stream
# ---------------------------------------------------------------------------
log_info "Waiting for OSImageStream CRD and rhel-10 stream (up to 5 min)..."
TIMEOUT=300
ELAPSED=0
while true; do
  if oc get osimagestreams/cluster &>/dev/null; then
    RHEL10="$(oc get osimagestreams/cluster -o json | jq -r '.status.availableStreams[]? | select(.name=="rhel-10") | .name' 2>/dev/null || echo "")"
    if [[ "${RHEL10}" == "rhel-10" ]]; then
      log_ok "rhel-10 OS stream is available."
      break
    fi
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    log_error "Timeout waiting for rhel-10 OS stream."
    log_info "Ensure the OCP payload includes the rhel-coreos-10 image."
    exit 1
  fi
  log_info "  Waiting... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

# ---------------------------------------------------------------------------
# Step 3: Create the mshv MachineConfigPool
# ---------------------------------------------------------------------------
if oc get mcp mshv &>/dev/null; then
  log_ok "MachineConfigPool 'mshv' already exists."
else
  log_info "Creating MachineConfigPool 'mshv' with rhel-10 osImageStream..."
  cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: mshv
spec:
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values: [worker, mshv]
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/mshv: ""
  osImageStream:
    name: rhel-10
EOF
  log_ok "MachineConfigPool 'mshv' created."
fi

# ---------------------------------------------------------------------------
# Step 4: Create the MSHV machineset
# ---------------------------------------------------------------------------
# Find the cluster ID from an existing machineset
EXISTING_MS="$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[0].metadata.name}')"
CLUSTER_ID="$(oc get machineset "${EXISTING_MS}" -n openshift-machine-api \
  -o jsonpath='{.metadata.labels.machine\.openshift\.io/cluster-api-cluster}')"
NEW_MS_NAME="${CLUSTER_ID}-worker-mshv-${LOCATION}${MSHV_ZONE}"

if oc get machineset "${NEW_MS_NAME}" -n openshift-machine-api &>/dev/null; then
  log_ok "Machineset ${NEW_MS_NAME} already exists."
  CURRENT_REPLICAS="$(oc get machineset "${NEW_MS_NAME}" -n openshift-machine-api -o jsonpath='{.spec.replicas}')"
  if [[ "${CURRENT_REPLICAS}" -eq 0 ]]; then
    log_info "Scaling ${NEW_MS_NAME} to 1..."
    oc scale machineset "${NEW_MS_NAME}" -n openshift-machine-api --replicas=1
  fi
else
  log_info "Creating machineset ${NEW_MS_NAME} with ${MSHV_VM_SIZE}..."
  oc get machineset "${EXISTING_MS}" -n openshift-machine-api -o json \
    | jq --arg name "${NEW_MS_NAME}" \
         --arg vmSize "${MSHV_VM_SIZE}" \
         --argjson diskSize "${MSHV_DISK_SIZE_GB}" \
         --arg zone "${MSHV_ZONE}" \
    '
      del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
          .metadata.generation, .status, .metadata.annotations) |
      .metadata.name = $name |
      .spec.replicas = 1 |
      .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $name |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
      .spec.template.spec.providerSpec.value.vmSize = $vmSize |
      .spec.template.spec.providerSpec.value.osDisk.diskSizeGB = $diskSize |
      .spec.template.spec.providerSpec.value.zone = $zone |
      .spec.template.spec.providerSpec.value.tags = {
        "platformsettings.host_environment.nodefeatures.hierarchicalvirtualizationv1": "True"
      } |
      .spec.template.spec.metadata.labels."node-role.kubernetes.io/mshv" = "" |
      .spec.template.spec.metadata.labels."node-role.kubernetes.io/worker" = ""
    ' | oc apply -f - 2>&1
  log_ok "Machineset ${NEW_MS_NAME} created."
fi

# ---------------------------------------------------------------------------
# Step 5: Wait for the machine to be Running
# ---------------------------------------------------------------------------
log_info "Waiting for MSHV machine to provision and join (up to 30 min)..."
TIMEOUT=1800
ELAPSED=0
while true; do
  READY="$(oc get machineset "${NEW_MS_NAME}" -n openshift-machine-api \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
  READY="${READY:-0}"
  if [[ "${READY}" -ge 1 ]]; then
    log_ok "MSHV machine is Running."
    break
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    log_error "Timeout waiting for MSHV machine after ${TIMEOUT}s."
    oc get machines -n openshift-machine-api -o wide
    exit 1
  fi
  log_info "  Waiting... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

# ---------------------------------------------------------------------------
# Step 6: Wait for the mshv MCP to finish updating (RHCOS 10 rollout)
# ---------------------------------------------------------------------------
log_info "Waiting for mshv MCP to finish RHCOS 10 rollout (up to 20 min)..."
TIMEOUT=1200
ELAPSED=0
while true; do
  UPDATED="$(oc get mcp mshv -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "")"
  UPDATING="$(oc get mcp mshv -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "")"
  if [[ "${UPDATED}" == "True" && "${UPDATING}" == "False" ]]; then
    log_ok "mshv MCP updated — RHCOS 10 is active."
    break
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    log_error "Timeout waiting for mshv MCP rollout."
    oc get mcp mshv -o yaml
    exit 1
  fi
  log_info "  MCP: updated=${UPDATED} updating=${UPDATING} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

# ---------------------------------------------------------------------------
# Step 7: Verify L1VH partition
# ---------------------------------------------------------------------------
NODE_NAME="$(oc get machines -n openshift-machine-api \
  -l machine.openshift.io/cluster-api-machineset="${NEW_MS_NAME}" \
  -o jsonpath='{.items[0].status.nodeRef.name}')"

log_info "Verifying L1VH partition on node ${NODE_NAME}..."
L1VH="$(oc debug "node/${NODE_NAME}" -- chroot /host dmesg 2>&1 | grep -c 'running as L1VH partition' || echo "0")"

if [[ "${L1VH}" -gt 0 ]]; then
  log_ok "Node is running in L1VH partition mode."
else
  log_warn "L1VH partition NOT detected in dmesg. The Azure host may not support it."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_info "============================================"
log_info "  MSHV Node Summary"
log_info "============================================"
oc get node "${NODE_NAME}" -o wide 2>&1 | head -2
echo
log_info "  Machineset: ${NEW_MS_NAME}"
log_info "  VM Size:    ${MSHV_VM_SIZE}"
log_info "  MCP:        mshv (rhel-10)"
log_info "  L1VH:       $(if [[ "${L1VH}" -gt 0 ]]; then echo "Yes"; else echo "No"; fi)"
log_info "============================================"

log_ok "Phase 7 complete."
