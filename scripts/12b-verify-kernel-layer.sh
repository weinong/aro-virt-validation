#!/usr/bin/env bash
# =============================================================================
# 12b-verify-kernel-layer.sh - Verify the custom kernel layer on the mshv node
#
# Confirms that the mshv node booted the on-cluster layered image and that the
# custom kernel is running, then re-runs the MSHV/L1VH host checks from
# scripts/04-mshv-node-setup.sh. A custom kernel that lacks MSHV support will
# break /dev/mshv and the mshv_root module; this script surfaces that so it can
# be documented under issues/ rather than worked around.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

MSHV_MCP_NAME="${MSHV_MCP_NAME:-mshv}"
MOC_NAME="${MOC_NAME:-${MSHV_MCP_NAME}}"
# Substring expected in `uname -r` / rpm-ostree output. Optional; when empty the
# script only checks that a layered image is in use.
EXPECTED_KERNEL="${EXPECTED_KERNEL:-}"

check_command oc || exit 1
check_command jq || exit 1

oc whoami >/dev/null 2>&1 || { log_error "Not logged in."; exit 1; }

log_info "Confirming a custom kernel layer is applied to the ${MSHV_MCP_NAME:-mshv} pool..."
MSHV_MCP_NAME="${MSHV_MCP_NAME:-mshv}"
CURRENT_IMAGE=""
# On-cluster path: MachineOSConfig exposes the built image pull spec.
if oc get machineosconfig "${MOC_NAME}" &>/dev/null; then
  CURRENT_IMAGE="$(oc get machineosconfig "${MOC_NAME}" -o jsonpath='{.status.currentImagePullSpec}' 2>/dev/null || echo '')"
fi
# Out-of-cluster path: the mshv rendered MachineConfig carries the osImageURL.
if [[ -z "${CURRENT_IMAGE}" ]]; then
  RENDERED_MC="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.spec.configuration.name}' 2>/dev/null || echo '')"
  if [[ -n "${RENDERED_MC}" ]]; then
    CURRENT_IMAGE="$(oc get mc "${RENDERED_MC}" -o jsonpath='{.spec.osImageURL}' 2>/dev/null || echo '')"
  fi
fi
if [[ -z "${CURRENT_IMAGE}" ]]; then
  log_error "No custom layered image found (neither MachineOSConfig ${MOC_NAME} nor an mshv osImageURL)."
  log_error "Run scripts/12-rhcos-kernel-layer.sh apply (on-cluster) or scripts/12c-rhcos-kernel-layer-out-of-cluster.sh apply first."
  exit 1
fi
log_ok "Layered image: ${CURRENT_IMAGE}"

NODE_NAME="$(oc get nodes -l node-role.kubernetes.io/mshv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
[[ -n "${NODE_NAME}" ]] || { log_error "No node with node-role.kubernetes.io/mshv found."; exit 1; }
log_info "Verifying kernel and MSHV state on ${NODE_NAME}..."

oc debug "node/${NODE_NAME}" -- chroot /host bash -c '
  set -euo pipefail
  echo "=== rpm-ostree status ==="
  rpm-ostree status
  echo "=== kernel ==="
  uname -r
  echo "=== MSHV host state ==="
  test -e /dev/mshv
  test -e /dev/vhost-net
  grep -q "^mshv_root" /proc/modules
  test -f /etc/modules-load.d/mshv-root.conf
  grep -q "running as L1VH partition" /var/log/dmesg 2>/dev/null || dmesg | grep "running as L1VH partition" >/dev/null
  # Confirm the node actually booted a layered (unverified-registry) image.
  rpm-ostree status | grep -q "ostree-unverified-registry:"
' | tee "/tmp/mshv-kernel-verify-${NODE_NAME}.log"

if [[ -n "${EXPECTED_KERNEL}" ]]; then
  if grep -q "${EXPECTED_KERNEL}" "/tmp/mshv-kernel-verify-${NODE_NAME}.log"; then
    log_ok "Running kernel matches EXPECTED_KERNEL=${EXPECTED_KERNEL}."
  else
    log_error "Running kernel does not match EXPECTED_KERNEL=${EXPECTED_KERNEL}."
    exit 1
  fi
fi

log_ok "Custom kernel layer verified on ${NODE_NAME}; MSHV/L1VH host state intact."
