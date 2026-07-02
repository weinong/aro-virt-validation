#!/usr/bin/env bash
# =============================================================================
# 02b-aro-disable-machineset-reconcile.sh - Disable ARO MachineSet reconciliation
#
# This must run after ARO cluster creation/login and before custom MachineSets are
# created, otherwise ARO can revert non-standard MachineSet changes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log_info "=== Phase 2b: Disable ARO MachineSet Reconciliation ==="

check_command oc || exit 1

log_info "Verifying cluster login..."
CURRENT_USER="$(oc whoami 2>/dev/null)" || { log_error "Not logged in."; exit 1; }
log_ok "Logged in as ${CURRENT_USER}"

if ! oc get crd clusters.aro.openshift.io &>/dev/null || ! oc get cluster.aro.openshift.io cluster &>/dev/null; then
  log_info "No ARO cluster custom resource detected; skipping aro.machineset.enabled patch."
  exit 0
fi

CURRENT_VALUE="$(oc get cluster.aro.openshift.io cluster -o jsonpath='{.spec.operatorflags.aro\.machineset\.enabled}' 2>/dev/null || echo '')"
if [[ "${CURRENT_VALUE}" == "false" ]]; then
  log_ok "ARO MachineSet reconciliation is already disabled."
  exit 0
fi

log_info "Disabling ARO MachineSet reconciliation for custom MSHV MachineSets..."
oc patch cluster.aro.openshift.io cluster --type=merge \
  -p '{"spec":{"operatorflags":{"aro.machineset.enabled":"false"}}}'
log_ok "ARO MachineSet reconciliation disabled."
