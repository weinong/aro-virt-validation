#!/usr/bin/env bash
# =============================================================================
# Phase 6 — Scale down existing machinesets and create D192ds_v6 machineset
#            for MSHV (hyperv-direct) validation
#
# Idempotent: safe to re-run.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

MSHV_VM_SIZE="Standard_D192ds_v6"
MSHV_DISK_SIZE_GB=256

log_info "=== Phase 6: MSHV Machineset Setup ==="

check_command oc || exit 1
check_command jq || exit 1

log_info "Verifying cluster login..."
CURRENT_USER="$(oc whoami 2>/dev/null)" || { log_error "Not logged in."; exit 1; }
log_ok "Logged in as ${CURRENT_USER}"

# ---------------------------------------------------------------------------
# Step 1: Scale down all existing worker machinesets to 0
# ---------------------------------------------------------------------------
log_info "Scaling down existing worker machinesets to 0..."
EXISTING_MS="$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[*].metadata.name}')"
for ms in ${EXISTING_MS}; do
  CURRENT_REPLICAS="$(oc get machineset "${ms}" -n openshift-machine-api -o jsonpath='{.spec.replicas}')"
  if [[ "${CURRENT_REPLICAS}" -eq 0 ]]; then
    log_ok "  ${ms} already at 0 replicas"
  else
    log_info "  Scaling ${ms} from ${CURRENT_REPLICAS} to 0..."
    oc scale machineset "${ms}" -n openshift-machine-api --replicas=0
  fi
done

# ---------------------------------------------------------------------------
# Step 2: Create new machineset with D192ds_v6 (zone 1 only, 1 replica)
# ---------------------------------------------------------------------------
# Use the first existing machineset as a template
TEMPLATE_MS="$(echo "${EXISTING_MS}" | awk '{print $1}')"
CLUSTER_ID="$(oc get machineset "${TEMPLATE_MS}" -n openshift-machine-api \
  -o jsonpath='{.metadata.labels.machine\.openshift\.io/cluster-api-cluster}')"

NEW_MS_NAME="${CLUSTER_ID}-worker-mshv-centralus1"

if oc get machineset "${NEW_MS_NAME}" -n openshift-machine-api &>/dev/null; then
  log_ok "Machineset ${NEW_MS_NAME} already exists."
  CURRENT_REPLICAS="$(oc get machineset "${NEW_MS_NAME}" -n openshift-machine-api -o jsonpath='{.spec.replicas}')"
  if [[ "${CURRENT_REPLICAS}" -eq 0 ]]; then
    log_info "Scaling ${NEW_MS_NAME} to 1..."
    oc scale machineset "${NEW_MS_NAME}" -n openshift-machine-api --replicas=1
  else
    log_ok "Already has ${CURRENT_REPLICAS} replicas."
  fi
else
  log_info "Creating machineset ${NEW_MS_NAME} with ${MSHV_VM_SIZE}..."

  # Export template and modify
  oc get machineset "${TEMPLATE_MS}" -n openshift-machine-api -o json \
    | jq --arg name "${NEW_MS_NAME}" \
         --arg vmSize "${MSHV_VM_SIZE}" \
         --arg clusterId "${CLUSTER_ID}" \
         --argjson diskSize "${MSHV_DISK_SIZE_GB}" \
    '
    del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
        .metadata.generation, .status, .metadata.annotations) |
    .metadata.name = $name |
    .spec.replicas = 1 |
    .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.spec.providerSpec.value.vmSize = $vmSize |
    .spec.template.spec.providerSpec.value.osDisk.diskSizeGB = $diskSize |
    .spec.template.spec.providerSpec.value.zone = "1"
    ' | oc apply -f - 2>&1

  log_ok "Machineset ${NEW_MS_NAME} created."
fi

# ---------------------------------------------------------------------------
# Step 3: Wait for old machines to drain and delete
# ---------------------------------------------------------------------------
log_info "Waiting for old machines to terminate..."
for ms in ${EXISTING_MS}; do
  while true; do
    READY="$(oc get machineset "${ms}" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
    READY="${READY:-0}"
    if [[ "${READY}" -eq 0 ]]; then
      log_ok "  ${ms}: all machines terminated."
      break
    fi
    log_info "  ${ms}: ${READY} machines still running, waiting 30s..."
    sleep 30
  done
done

# ---------------------------------------------------------------------------
# Step 4: Wait for new node to be Ready
# ---------------------------------------------------------------------------
log_info "Waiting for ${NEW_MS_NAME} machine to provision and join..."
TIMEOUT=1800  # 30 minutes
ELAPSED=0
while true; do
  READY="$(oc get machineset "${NEW_MS_NAME}" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
  READY="${READY:-0}"
  if [[ "${READY}" -ge 1 ]]; then
    log_ok "New node is Ready."
    break
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    log_error "Timeout waiting for new node after ${TIMEOUT}s."
    oc get machines -n openshift-machine-api -o wide
    exit 1
  fi
  log_info "  Waiting for node... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

# Show final state
log_info "Final machineset state:"
oc get machinesets -n openshift-machine-api -o wide
log_info "Worker nodes:"
oc get nodes -l node-role.kubernetes.io/worker -o wide

log_ok "Phase 6 complete. MSHV machineset is ready."
