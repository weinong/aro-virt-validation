#!/usr/bin/env bash
# =============================================================================
# 06c-upstream-kubevirt-install.sh - Install upstream KubeVirt v1.8.2 directly
#
# This is the diagnostic A/B path documented in issues/2026-05-09.md. We
# install plain upstream KubeVirt (no HCO, no CDI, no SSP) to determine
# whether the QEMU "invalid intercept access type: execute" / vcpu 0 crash
# observed under CNV 4.99 nightly is reproducible with the upstream
# operator/handler/launcher stack at v1.8.2 against the same RHCOS 10
# mshv node.
#
# Diagnostic only. Not a CNV replacement.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.8.2}"

log_info "=== Phase 6c: Upstream KubeVirt ${KUBEVIRT_VERSION} ==="

check_command oc || exit 1
check_command jq || exit 1

oc whoami &>/dev/null || { log_error "Not logged in."; exit 1; }
log_ok "Logged in as $(oc whoami)"

OPERATOR_URL="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
CR_URL="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

log_info "Applying KubeVirt operator (server-side, ${KUBEVIRT_VERSION})..."
oc apply --server-side --force-conflicts -f "${OPERATOR_URL}"

log_info "Waiting for virt-operator deployment to be Available..."
oc rollout status deployment/virt-operator -n kubevirt --timeout=5m

log_info "Applying default KubeVirt CR (will be patched after Deployed)..."
if oc get kubevirt kubevirt -n kubevirt &>/dev/null; then
  log_info "KubeVirt CR already exists; skipping default apply to preserve any patches from a previous run."
else
  oc apply --server-side --force-conflicts -f "${CR_URL}"
fi

log_info "Waiting for KubeVirt CR phase=Deployed (up to 15m)..."
ELAPSED=0
TIMEOUT=900
while true; do
  PHASE="$(oc get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  if [[ "${PHASE}" == "Deployed" ]]; then
    log_ok "KubeVirt is Deployed."
    break
  fi
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    log_error "KubeVirt did not reach phase Deployed within ${TIMEOUT}s. Current phase: ${PHASE}"
    oc get kubevirt kubevirt -n kubevirt -o yaml | tail -50
    exit 1
  fi
  log_info "  KubeVirt phase=${PHASE:-Pending} (${ELAPSED}s/${TIMEOUT}s)"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

log_info "Patching KubeVirt CR to mirror the CNV smoke-run config:"
log_info "  hypervisors=[hyperv-direct], evictionStrategy=None,"
log_info "  featureGates: ConfigurableHypervisor, WithHostModelCPU, HypervStrictCheck."
oc patch kubevirt kubevirt -n kubevirt --type=merge -p '{
  "spec": {
    "configuration": {
      "hypervisors": [{"name": "hyperv-direct"}],
      "evictionStrategy": "None",
      "developerConfiguration": {
        "featureGates": [
          "ConfigurableHypervisor",
          "WithHostModelCPU",
          "HypervStrictCheck",
          "HostDevices"
        ]
      }
    }
  }
}'

log_info "Waiting for KubeVirt CR to settle after patch..."
sleep 10
oc rollout status daemonset/virt-handler -n kubevirt --timeout=5m

log_info "KubeVirt CR snapshot:"
oc get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.phase}{"\n"}'
oc get kubevirt kubevirt -n kubevirt -o jsonpath='{.spec.configuration.hypervisors}{"\n"}'
oc get kubevirt kubevirt -n kubevirt -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}{"\n"}'

log_info "Pods in kubevirt namespace:"
oc get pods -n kubevirt

log_info "Node allocatable on the mshv node:"
MSHV_NODE="$(oc get node -l node-role.kubernetes.io/mshv -o jsonpath='{.items[0].metadata.name}')"
oc get node "${MSHV_NODE}" -o jsonpath='{.status.allocatable}' | jq '. | with_entries(select(.key | test("kubevirt|mshv|kvm|tun|vhost")))'

log_ok "Phase 6c complete. Upstream KubeVirt ${KUBEVIRT_VERSION} is up."
