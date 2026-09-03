#!/usr/bin/env bash
# =============================================================================
# 14-mshv-nic-offload-capture.sh - Capture NIC offload / overlay config from the
# MSHV/L1VH worker nodes for the guest GSO/checksum panic investigation.
#
# Why: the nodes reboot from a guest kernel GPF at csum_partial+0xe5/0x110 while
# GSO-segmenting a Geneve(UDP-tunnel) packet on the OVS TX path (see
# issues/2026-09-03-mshv-reboots-are-guest-gso-csum-panics.md). The advertised
# offload feature set of the Azure MANA VF / hv_netvsc uplink and the Geneve
# tunnel device is a prime suspect. This script records that state.
#
# This script is READ-ONLY against the cluster: it runs `oc debug node` and
# reads ethtool/ip/journal state. It changes nothing. Output is written to
# .checkup-runs/nic-offload-<node>-<timestamp>.txt and echoed to stdout.
#
# Usage:
#   ./scripts/14-mshv-nic-offload-capture.sh                 # all mshv nodes
#   ./scripts/14-mshv-nic-offload-capture.sh NODE [NODE...]  # specific nodes
#
# Prereqs: oc logged in (KUBECONFIG) as cluster admin.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

OUT_DIR="${_REPO_ROOT}/.checkup-runs"
mkdir -p "${OUT_DIR}"

# Interfaces of interest on an OVN-Kubernetes + Azure-accelerated-networking node:
#   eth0            - hv_netvsc synthetic uplink
#   enP*            - MANA accelerated-networking VF (failover slave of eth0)
#   br-ex           - OVN external bridge (uplink into OVS)
#   genev_sys_6081  - Geneve tunnel netdev (overlay encap; the crash path)
#   ovn-k8s-mp0     - OVN management port
IFACES_DEFAULT="eth0 br-ex genev_sys_6081 ovn-k8s-mp0"

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"
DEBUG_TIMEOUT="${DEBUG_TIMEOUT:-180}"

# Resolve target nodes.
NODES=("$@")
if [[ ${#NODES[@]} -eq 0 ]]; then
  mapfile -t NODES < <(oc get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    --request-timeout="${REQUEST_TIMEOUT}s")
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
  log_error "No MSHV nodes found (label node-role.kubernetes.io/mshv)."
  exit 1
fi

# The remote capture script. Discovers the MANA VF dynamically and dumps offload
# state for every interface of interest.
read -r -d '' REMOTE <<'REMOTE_EOF' || true
set +e
echo "=== uname / uptime ==="
uname -r; uptime
echo
echo "=== boot history (crash reboots show as unclean) ==="
journalctl --list-boots --no-pager 2>/dev/null | tail -12
echo
# Discover the MANA VF (failover slave of eth0): a physical/PCI enP* device.
VF="$(ls -1 /sys/class/net | grep -E '^enP' | head -1)"
echo "=== discovered MANA VF: ${VF:-<none>} ==="
echo
for ifc in eth0 ${VF} br-ex genev_sys_6081 ovn-k8s-mp0; do
  [ -z "$ifc" ] && continue
  if [ ! -e "/sys/class/net/$ifc" ]; then
    echo "### $ifc: not present"; echo; continue
  fi
  echo "########## $ifc ##########"
  echo "--- ip -d link ---"
  ip -d link show "$ifc" 2>&1 | head -6
  echo "--- ethtool -k (offload features; focus: tx/gso/gro/tso/tx-udp_tnl-*/tx-checksum*) ---"
  ethtool -k "$ifc" 2>&1 | grep -iE 'generic-segmentation|generic-receive|tcp-segmentation|udp-fragmentation|tx-udp|tx-checksum|scatter-gather|rx-gro|tx-gso|large-receive|tx-tcp' 
  echo
done
echo "=== ethtool -S eth0 (err/drop/gso counters) ==="
ethtool -S eth0 2>/dev/null | grep -iE 'err|drop|gso|csum|discard' | head -30
echo
VFNAME="$(ls -1 /sys/class/net | grep -E '^enP' | head -1)"
if [ -n "$VFNAME" ]; then
  echo "=== ethtool -S $VFNAME (MANA VF err/drop counters) ==="
  ethtool -S "$VFNAME" 2>/dev/null | grep -iE 'err|drop|gso|csum|discard|cqe' | head -30
fi
echo
echo "=== recent MANA / TX-queue warnings in kernel log ==="
journalctl -k --no-pager 2>/dev/null | grep -iE 'selects TX queue|mana|hv_netvsc' | tail -15
REMOTE_EOF

for node in "${NODES[@]}"; do
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="${OUT_DIR}/nic-offload-${node}-${ts}.txt"
  log_info "Capturing NIC/offload state from ${node} -> ${out}"
  {
    echo "# NIC/offload capture"
    echo "# node: ${node}"
    echo "# time: ${ts}"
    echo "# interfaces of interest: ${IFACES_DEFAULT} + discovered MANA VF"
    echo
    timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --request-timeout="${REQUEST_TIMEOUT}s" \
      -- chroot /host bash -c "${REMOTE}" 2>&1 \
      | grep -avE 'Starting pod|Removing debug pod|To use host|Warning: metadata|^Warning:'
  } | tee "${out}"
  echo
done

log_ok "NIC/offload capture complete. Files in ${OUT_DIR}/nic-offload-*.txt"
