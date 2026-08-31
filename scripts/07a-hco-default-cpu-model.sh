#!/usr/bin/env bash
# =============================================================================
# 07a-hco-default-cpu-model.sh - Set a cluster-default CPU model in the HCO
#
# Sets spec.virtualization.virtualMachineOptions.defaultCPUModel on the
# HyperConverged CR (propagates to KubeVirt spec.configuration.cpuModel). This is
# the cluster default CPU model for VMs that do not specify one.
#
# A named CPU model is only schedulable if virt-handler advertises it as a node
# label `cpu-model.node.kubevirt.io/<model>=true` on the nodes where VMs run.
# Setting a model that is NOT advertised makes every VMI unschedulable (see
# issues/2026-04-23.md, where `cpuModel: qemu64-v1` broke scheduling). This
# script therefore refuses to set a model that is not advertised on all the
# nodes that run virtualization workloads (the mshv nodes).
#
# Usage:
#   ./scripts/07a-hco-default-cpu-model.sh            # default model: Nehalem
#   DEFAULT_CPU_MODEL=Haswell ./scripts/07a-hco-default-cpu-model.sh
#   ./scripts/07a-hco-default-cpu-model.sh --unset    # remove the default
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
# Conservative baseline that any modern x86 CPU supports; a good fit under the
# nested MSHV/L1VH hypervisor where exposed CPU features may be limited.
DEFAULT_CPU_MODEL="${DEFAULT_CPU_MODEL:-Nehalem}"
# Nodes that run virt workloads. Script 07 pins workloads to the mshv role.
VIRT_NODE_SELECTOR="${VIRT_NODE_SELECTOR:-node-role.kubernetes.io/mshv}"

check_command oc || exit 1
check_command jq || exit 1

log_info "=== Phase 7a: HCO default CPU model ==="
oc whoami >/dev/null 2>&1 || { log_error "Not logged in."; exit 1; }

HCO_NAME="$(oc get hco -n "${CNV_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
[[ -n "${HCO_NAME}" ]] || { log_error "No HyperConverged CR found in ${CNV_NAMESPACE}."; exit 1; }

if [[ "${1:-}" == "--unset" ]]; then
  log_info "Removing spec.virtualization.virtualMachineOptions.defaultCPUModel from ${HCO_NAME}..."
  oc patch hco "${HCO_NAME}" -n "${CNV_NAMESPACE}" --type=json \
    -p '[{"op":"remove","path":"/spec/virtualization/virtualMachineOptions/defaultCPUModel"}]' 2>/dev/null \
    || log_ok "defaultCPUModel was not set."
  exit 0
fi

# --- Preflight: the model must be advertised on every virt workload node -------
mapfile -t VIRT_NODES < <(oc get nodes -l "${VIRT_NODE_SELECTOR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ "${#VIRT_NODES[@]}" -ge 1 ]] || { log_error "No nodes match ${VIRT_NODE_SELECTOR}."; exit 1; }

LABEL="cpu-model.node.kubevirt.io/${DEFAULT_CPU_MODEL}"
missing=()
for node in "${VIRT_NODES[@]}"; do
  advertised="$(oc get node "${node}" -o jsonpath="{.metadata.labels.cpu-model\.node\.kubevirt\.io/${DEFAULT_CPU_MODEL}}" 2>/dev/null || echo '')"
  if [[ "${advertised}" != "true" ]]; then
    missing+=("${node}")
  fi
done
if [[ "${#missing[@]}" -gt 0 ]]; then
  log_error "CPU model '${DEFAULT_CPU_MODEL}' is NOT advertised (${LABEL}=true) on: ${missing[*]}"
  log_error "Setting it would make VMIs unschedulable. Pick a model advertised on all virt nodes, e.g.:"
  oc get node "${VIRT_NODES[0]}" -o json | jq -r '.metadata.labels | keys[] | select(test("cpu-model.node.kubevirt.io/")) | sub("cpu-model.node.kubevirt.io/";"")' | sort | tr '\n' ' '
  echo
  exit 1
fi
log_ok "CPU model '${DEFAULT_CPU_MODEL}' is advertised on all ${#VIRT_NODES[@]} virt node(s)."

# --- Apply -------------------------------------------------------------------
log_info "Setting defaultCPUModel=${DEFAULT_CPU_MODEL} on ${HCO_NAME}..."
oc patch hco "${HCO_NAME}" -n "${CNV_NAMESPACE}" --type=merge \
  -p "{\"spec\":{\"virtualization\":{\"virtualMachineOptions\":{\"defaultCPUModel\":\"${DEFAULT_CPU_MODEL}\"}}}}"

# --- Verify propagation to KubeVirt ------------------------------------------
log_info "Waiting for KubeVirt to reconcile spec.configuration.cpuModel..."
TIMEOUT=180
ELAPSED=0
while true; do
  KV_MODEL="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n "${CNV_NAMESPACE}" \
    -o jsonpath='{.spec.configuration.cpuModel}' 2>/dev/null || echo '')"
  if [[ "${KV_MODEL}" == "${DEFAULT_CPU_MODEL}" ]]; then
    log_ok "KubeVirt spec.configuration.cpuModel=${KV_MODEL}."
    break
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    log_error "KubeVirt did not reconcile cpuModel within ${TIMEOUT}s (current: '${KV_MODEL}')."
    exit 1
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

log_ok "Phase 7a complete. Default CPU model is ${DEFAULT_CPU_MODEL}."
