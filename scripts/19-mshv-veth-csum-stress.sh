#!/usr/bin/env bash
# =============================================================================
# 19-mshv-veth-csum-stress.sh - Try to trigger the csum_partial GPF using only a
# local veth pair, with NO OVS, NO Geneve, NO overlay and NO physical NIC.
#
# Why: all 11 captured panics contain csum_partial + __skb_checksum + an OVS
# frame (issues/2026-09-09-csum-under-ovs-not-geneve.md). OVS is present in every
# trace, but that may only be because on OVN-Kubernetes essentially all traffic
# traverses it -- the uplink itself is enslaved to br-ex. So "OVS is always
# present" is not evidence that OVS is required.
#
# This isolates the suspected mechanism instead: force the kernel to compute a
# TCP checksum in software over skb page frags, on a path OVS never touches.
# Disabling tx-checksumming on a veth makes the stack call skb_checksum_help ->
# __skb_checksum -> csum_partial, which is exactly captured path 3.
#
#   panic  => OVS is NOT required; software checksumming alone is sufficient,
#             and we have a self-contained reproducer with no networking stack
#             dependencies worth mentioning.
#   no panic => OVS/overlay involvement (or the traffic pattern it produces)
#             matters, which is itself a strong hint.
#
# A negative result is WEAK on its own: the crash rate is heavy-tailed (median
# boot lifetime ~26 min), so a quiet 30 minutes proves little. Run it long.
#
# ⚠️ Intended to panic a node. Do not run where that matters.
#
# Usage:
#   ./scripts/19-mshv-veth-csum-stress.sh run     # stress + watch for resets
#   ./scripts/19-mshv-veth-csum-stress.sh clean   # remove netns/veth
#
# Tunables (env): NODE, DURATION (default 1800), STREAMS (default 32),
#   NS_NAME (default csumstress).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

DURATION="${DURATION:-1800}"
STREAMS="${STREAMS:-32}"
NS_NAME="${NS_NAME:-csumstress}"
POLL="${POLL:-15}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"

oc_() { oc --request-timeout="${REQUEST_TIMEOUT}s" "$@"; }

pick_node() {
  [[ -n "${NODE:-}" ]] && { printf '%s' "${NODE}"; return; }
  oc_ get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[?(@.status.conditions[-1].status=="True")]}{.metadata.name}{"\n"}{end}' \
    | head -1
}

node_boot_id() { oc_ get "node/$1" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null; }

# The whole stress runs inside the node's own namespace so no pod networking,
# no CNI and no OVS vport is involved anywhere in the path.
remote_script() {
  cat <<REMOTE
set -eu
ip netns del ${NS_NAME} 2>/dev/null || true
ip link del ${NS_NAME}0 2>/dev/null || true

ip netns add ${NS_NAME}
ip link add ${NS_NAME}0 type veth peer name ${NS_NAME}1
ip link set ${NS_NAME}1 netns ${NS_NAME}
ip addr add 10.244.240.1/30 dev ${NS_NAME}0
ip link set ${NS_NAME}0 up
ip netns exec ${NS_NAME} ip addr add 10.244.240.2/30 dev ${NS_NAME}1
ip netns exec ${NS_NAME} ip link set ${NS_NAME}1 up
ip netns exec ${NS_NAME} ip link set lo up

# Force SOFTWARE checksumming: with tx-checksumming off the sender must run
# skb_checksum_help -> __skb_checksum -> csum_partial over the payload.
# Keep gso/tso ON so the payload stays in large, page-frag-backed skbs.
for d in ${NS_NAME}0; do
  ethtool -K \$d tx off rx off 2>/dev/null || true
done
ip netns exec ${NS_NAME} ethtool -K ${NS_NAME}1 tx off rx off 2>/dev/null || true

echo "--- offload state (host side) ---"
ethtool -k ${NS_NAME}0 2>/dev/null | grep -E '^(tx-checksumming|rx-checksumming|generic-segmentation-offload|tcp-segmentation-offload)'
echo "--- MTU bumped so segments are large ---"
ip link set ${NS_NAME}0 mtu 9000 || true
ip netns exec ${NS_NAME} ip link set ${NS_NAME}1 mtu 9000 || true

# Sink in the host ns, senders in the netns.
(socat -u TCP-LISTEN:5401,reuseaddr,fork /dev/null &) 2>/dev/null
sleep 2
# Report throughput as we go. Without this a "no reset" result is worthless:
# we could not tell a genuinely stable node from a stress that never ran.
( while true; do
    sleep 30
    b=\$(cat /sys/class/net/${NS_NAME}0/statistics/rx_bytes 2>/dev/null || echo 0)
    echo "PROGRESS t=\${SECONDS}s host_rx_bytes=\$b"
  done ) &
monitor=\$!

end=\$((SECONDS+${DURATION}))
while [ \$SECONDS -lt \$end ]; do
  i=0
  while [ \$i -lt ${STREAMS} ]; do
    ip netns exec ${NS_NAME} socat -u OPEN:/dev/zero TCP:10.244.240.1:5401,nodelay 2>/dev/null &
    i=\$((i+1))
  done
  wait
done
kill \$monitor 2>/dev/null || true
echo "FINAL host_rx_bytes=\$(cat /sys/class/net/${NS_NAME}0/statistics/rx_bytes 2>/dev/null || echo 0)"
REMOTE
}

cmd_run() {
  local node; node="$(pick_node)"
  [[ -n "${node}" ]] || { log_error "no Ready mshv node"; exit 1; }
  local before; before="$(node_boot_id "${node}")"
  [[ -n "${before}" ]] || { log_error "could not read boot ID of ${node}"; exit 1; }

  log_warn "Stressing SOFTWARE checksum on a veth pair on ${node} (no OVS, no overlay)."
  log_info "boot before: ${before}   duration=${DURATION}s streams=${STREAMS}"

  local out="${_REPO_ROOT}/.checkup-runs/veth-csum-stress"
  mkdir -p "${out}"

  # Run the stress detached; the debug pod dies with the node if it panics.
  ( timeout "$(( DURATION + 120 ))" oc debug "node/${node}" --quiet \
      --request-timeout=0 -- chroot /host bash -c "$(remote_script)" \
      > "${out}/stress-${node}.log" 2>&1 || true ) &
  local stress_pid=$!

  local start elapsed now resets=0
  start="$(date +%s)"
  while :; do
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= DURATION )) && break
    sleep "${POLL}"
    now="$(node_boot_id "${node}")"
    if [[ -n "${now}" && "${now}" != "${before}" ]]; then
      resets=$(( resets + 1 ))
      log_warn "RESET on ${node} at t=${elapsed}s -- veth-only software checksum reproduced a reset"
      before="${now}"
    fi
  done
  kill "${stress_pid}" 2>/dev/null || true

  log_info "==== RESULT: resets=${resets} over ${DURATION}s (no OVS in the path) ===="
  if (( resets > 0 )); then
    log_ok "Reset WITHOUT OVS/overlay. Check the captured panic to confirm it is csum_partial:"
    log_ok "  bash scripts/16-mshv-kdump.sh collect"
  else
    log_warn "No reset. WEAK evidence only: the background crash rate is heavy-tailed,"
    log_warn "so a quiet window of this length is unremarkable even if the mechanism is real."
  fi
  printf '%s\tnode=%s\tduration=%s\tstreams=%s\tresets=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${node}" "${DURATION}" "${STREAMS}" "${resets}" \
    >> "${out}/results.tsv"
}

cmd_clean() {
  local node; node="$(pick_node)"
  [[ -n "${node}" ]] || return 0
  oc debug "node/${node}" --quiet --request-timeout="${REQUEST_TIMEOUT}s" -- chroot /host bash -c "
    pkill -f 'TCP-LISTEN:5401' 2>/dev/null || true
    ip netns del ${NS_NAME} 2>/dev/null || true
    ip link del ${NS_NAME}0 2>/dev/null || true
    echo cleaned" 2>&1 | grep -avE 'Starting pod|Removing debug|To use host|^Warning' || true
  log_ok "cleaned veth/netns on ${node}"
}

case "${1:-run}" in
  run)   cmd_run ;;
  clean) cmd_clean ;;
  *) log_error "Unknown action '${1}'. Use: run|clean"; exit 1 ;;
esac
