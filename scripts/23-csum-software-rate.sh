#!/usr/bin/env bash
# =============================================================================
# 23-csum-software-rate.sh - Measure the rate of SOFTWARE checksum walks, and
# attribute them to their callers.
#
# This is the evidence for two claims in
# issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md:
#   * ordinary OpenShift traffic runs a *trickle* of software checksums
#     (~12 __skb_checksum/s), NOT a flood -- which refuted an earlier claim
#     that "Azure forces the software path";
#   * every one of those walks comes from the OVN/OVS datapath.
#
# ⚠️ GOTCHA THIS SCRIPT EXISTS TO AVOID:
#   The global ftrace buffer is drained continuously by mshv-trace-stream.service
#   (scripts/21), which reads trace_pipe. Enabling events there and reading
#   /sys/kernel/debug/tracing/trace yields ZERO hits -- silently, including for a
#   known-good positive control. All measurement here happens in a PRIVATE
#   ftrace instance (tracing/instances/<name>) which has its own buffer.
#   Always run `validate` before trusting a `measure` result.
#
# Usage:
#   ./scripts/23-csum-software-rate.sh validate        # prove the probes fire
#   ./scripts/23-csum-software-rate.sh measure [SECS]  # ordinary traffic (20)
#   ./scripts/23-csum-software-rate.sh stacks  [SECS]  # caller attribution (25)
#   ./scripts/23-csum-software-rate.sh clean
#
# Tunables (env): NODE, INSTANCE, REQUEST_TIMEOUT.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

INSTANCE="${INSTANCE:-csumcnt}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"

oc_() { oc --request-timeout="${REQUEST_TIMEOUT}s" "$@"; }

pick_node() {
  [[ -n "${NODE:-}" ]] && { printf '%s' "${NODE}"; return; }
  oc_ get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -1
}

# --request-timeout=0: long inline scripts get truncated by a finite timeout.
on_node() {
  local node="$1"; shift
  oc debug "node/${node}" --quiet --request-timeout=0 \
    -- chroot /host bash -c "$*" 2>&1 |
    grep -avE 'Starting pod|Removing debug|To use host|^Warning|^Pod IP|^If you'
}

# Register kprobes (idempotent) and create the private instance.
setup_snippet() {
  cat <<'SNIP'
T=/sys/kernel/debug/tracing
[ -d "$T" ] || T=/sys/kernel/tracing
I=$T/instances/__INSTANCE__
grep -q '^p:kprobes/kp_help ' $T/kprobe_events 2>/dev/null || \
  echo 'p:kp_help skb_checksum_help' >> $T/kprobe_events 2>/dev/null || true
grep -q '^p:kprobes/kp_skbcsum ' $T/kprobe_events 2>/dev/null || \
  echo 'p:kp_skbcsum __skb_checksum' >> $T/kprobe_events 2>/dev/null || true
mkdir -p $I 2>/dev/null || true
echo 1 > $I/tracing_on
SNIP
}

emit() { setup_snippet | sed "s/__INSTANCE__/${INSTANCE}/"; }

cmd_validate() {
  local node; node="$(pick_node)"
  log_info "positive control on ${node}: veth with tx offload OFF must produce hits"
  log_warn "pushes ~13 MB over a veth pair; small but nonzero panic risk on L1VH"
  on_node "${node}" "$(emit)
echo 1 > \$I/events/kprobes/kp_help/enable
echo 1 > \$I/events/kprobes/kp_skbcsum/enable
ip netns add csumval 2>/dev/null || true
ip link add vv0 type veth peer name vv1 2>/dev/null || true
ip link set vv1 netns csumval 2>/dev/null || true
ip addr add 10.99.9.1/24 dev vv0 2>/dev/null || true; ip link set vv0 up
ip netns exec csumval ip addr add 10.99.9.2/24 dev vv1 2>/dev/null || true
ip netns exec csumval ip link set vv1 up
ethtool -K vv0 tx off rx off >/dev/null 2>&1 || true
ip netns exec csumval ethtool -K vv1 tx off rx off >/dev/null 2>&1 || true
echo > \$I/trace
ip netns exec csumval timeout 4 socat -u TCP-LISTEN:9099,reuseaddr - 2>/dev/null | wc -c > /tmp/rxbytes &
sleep 0.5
timeout 3 dd if=/dev/zero bs=64K count=200 2>/dev/null | timeout 3 socat -u - TCP:10.99.9.2:9099 2>/dev/null || true
sleep 1
echo \"bytes transferred : \$(cat /tmp/rxbytes 2>/dev/null)\"
echo \"skb_checksum_help : \$(grep -ac kp_help \$I/trace)\"
echo \"__skb_checksum    : \$(grep -ac kp_skbcsum \$I/trace)\"
echo 0 > \$I/events/kprobes/kp_help/enable
echo 0 > \$I/events/kprobes/kp_skbcsum/enable
ip link del vv0 2>/dev/null || true; ip netns del csumval 2>/dev/null || true"
  log_ok "non-zero counts above mean the probes fire and 'measure' can be trusted"
}

cmd_measure() {
  local secs="${1:-20}" node; node="$(pick_node)"
  log_info "measuring software checksums under ORDINARY traffic on ${node} for ${secs}s"
  on_node "${node}" "$(emit)
echo 1 > \$I/events/kprobes/kp_help/enable
echo 1 > \$I/events/kprobes/kp_skbcsum/enable
echo > \$I/trace
sleep ${secs}
h=\$(grep -ac kp_help \$I/trace); s=\$(grep -ac kp_skbcsum \$I/trace)
echo \"window_seconds    : ${secs}\"
echo \"skb_checksum_help : \$h  (\$(awk \"BEGIN{printf \\\"%.1f\\\", \$h/${secs}}\")/s)\"
echo \"__skb_checksum    : \$s  (\$(awk \"BEGIN{printf \\\"%.1f\\\", \$s/${secs}}\")/s)\"
echo '--- top comms ---'
grep -a kp_skbcsum \$I/trace | sed -E 's/^ *([^ ]+)-[0-9]+.*/\1/' | sort | uniq -c | sort -rn | head -6
echo 0 > \$I/events/kprobes/kp_help/enable
echo 0 > \$I/events/kprobes/kp_skbcsum/enable"
}

cmd_stacks() {
  local secs="${1:-25}" node; node="$(pick_node)"
  log_info "attributing skb_checksum_help callers on ${node} for ${secs}s"
  on_node "${node}" "$(emit)
echo > \$I/trace
echo 1 > \$I/options/stacktrace 2>/dev/null || true
echo 1 > \$I/events/kprobes/kp_help/enable
sleep ${secs}
echo 0 > \$I/events/kprobes/kp_help/enable
echo 0 > \$I/options/stacktrace 2>/dev/null || true
echo '--- call paths into skb_checksum_help ---'
grep -aA14 kp_help \$I/trace | grep -aoE '=> [a-z_0-9]+' | sort | uniq -c | sort -rn | head -22"
}

cmd_clean() {
  local node; node="$(pick_node)"
  on_node "${node}" "T=/sys/kernel/debug/tracing; [ -d \$T ] || T=/sys/kernel/tracing
I=\$T/instances/${INSTANCE}
[ -d \$I ] && { echo 0 > \$I/tracing_on; rmdir \$I 2>/dev/null; }
echo '' > \$T/kprobe_events 2>/dev/null || true
echo cleaned"
  log_ok "removed instance ${INSTANCE} and kprobes on ${node}"
}

case "${1:-}" in
  validate) shift; cmd_validate ;;
  measure)  shift; cmd_measure "${1:-20}" ;;
  stacks)   shift; cmd_stacks "${1:-25}" ;;
  clean)    cmd_clean ;;
  *) sed -n '2,28p' "$0"; exit 1 ;;
esac
