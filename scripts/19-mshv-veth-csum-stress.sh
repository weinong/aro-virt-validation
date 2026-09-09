#!/usr/bin/env bash
# =============================================================================
# 19-mshv-veth-csum-stress.sh - Minimal reproducer for the csum_partial GPF.
#
# Creates a veth pair in a fresh netns, disables tx-checksumming so the sender
# must run skb_checksum_help -> __skb_checksum -> csum_partial, and drives bulk
# TCP. No OVS, no Geneve, no overlay, no physical NIC, no CNV.
# See issues/2026-09-09-csum-under-ovs-not-geneve.md.
#
# DATA HANDLING (deliberate design):
#   * The node writes telemetry to a file ON DISK (/var/log/csumstress/), which
#     survives the panic and the reboot. That is the authoritative record.
#   * Everything is copied down verbatim into a per-run directory; nothing is
#     parsed inline. A bad parser costs a re-run of `20-analyze-stress-runs.py`
#     (seconds), never a re-run of the experiment (up to 15 minutes).
#   * Run directories are never overwritten.
#
# ⚠️ Intended to panic the node. Do not run where that matters.
#
# Usage:
#   ./scripts/19-mshv-veth-csum-stress.sh run
#   ./scripts/19-mshv-veth-csum-stress.sh fetch   # pull on-node telemetry after a reboot
#   ./scripts/19-mshv-veth-csum-stress.sh clean
#
# Tunables (env): NODE, DURATION (900), STREAMS (32), POLL (10), NS_NAME.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

DURATION="${DURATION:-900}"
STREAMS="${STREAMS:-32}"
NS_NAME="${NS_NAME:-csumstress}"
POLL="${POLL:-10}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"
RUNS_DIR="${RUNS_DIR:-${_REPO_ROOT}/.checkup-runs/veth-csum-stress}"
# On-node, on-disk so it survives the panic and the reboot.
NODE_TELEMETRY="/var/log/csumstress"

oc_() { oc --request-timeout="${REQUEST_TIMEOUT}s" "$@"; }

pick_node() {
  [[ -n "${NODE:-}" ]] && { printf '%s' "${NODE}"; return; }
  oc_ get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -1
}

node_boot_id() { oc_ get "node/$1" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null; }

# Long-running commands must NOT carry --request-timeout: it bounds the whole
# streamed command and silently truncated earlier runs at 30s.
on_node_long() {
  local node="$1"; shift
  oc debug "node/${node}" --quiet --request-timeout=0 -- chroot /host bash -c "$*"
}
on_node() {
  local node="$1"; shift
  oc debug "node/${node}" --quiet --request-timeout="${REQUEST_TIMEOUT}s" \
    -- chroot /host bash -c "$*" 2>/dev/null |
    grep -avE 'Starting pod|Removing debug|To use host|^Warning'
}

remote_stress() {
  local run_id="$1"
  cat <<REMOTE
set -u
tel=${NODE_TELEMETRY}/${run_id}
mkdir -p "\$tel"
exec 3>"\$tel/telemetry.tsv"

log() { printf '%s\n' "\$*" >&3; sync; }

log "# run_id=${run_id} streams=${STREAMS} duration=${DURATION}"
log "# node=\$(hostname) kernel=\$(uname -r) boot_id=\$(cat /proc/sys/kernel/random/boot_id)"
log "# l1vh=\$(dmesg 2>/dev/null | grep -c 'running as L1VH partition') mshv_root=\$(grep -c '^mshv_root' /proc/modules)"
log "# nokaslr=\$(grep -c nokaslr /proc/cmdline) uptime_at_start=\$(cut -d' ' -f1 /proc/uptime)"

ip netns del ${NS_NAME} 2>/dev/null || true
ip link del ${NS_NAME}0 2>/dev/null || true
ip netns add ${NS_NAME}
ip link add ${NS_NAME}0 type veth peer name ${NS_NAME}1
ip link set ${NS_NAME}1 netns ${NS_NAME}
ip addr add 10.244.240.1/30 dev ${NS_NAME}0
ip link set ${NS_NAME}0 up mtu 9000
ip netns exec ${NS_NAME} ip addr add 10.244.240.2/30 dev ${NS_NAME}1
ip netns exec ${NS_NAME} ip link set ${NS_NAME}1 up mtu 9000
ip netns exec ${NS_NAME} ip link set lo up

# Force SOFTWARE checksum on transmit.
ethtool -K ${NS_NAME}0 tx off rx off >/dev/null 2>&1 || true
ip netns exec ${NS_NAME} ethtool -K ${NS_NAME}1 tx off rx off >/dev/null 2>&1 || true
ethtool -k ${NS_NAME}0 2>/dev/null | grep -E '^(tx-checksumming|rx-checksumming|generic-segmentation-offload|tcp-segmentation-offload)' \
  | while read -r l; do log "# offload \$l"; done

(socat -u TCP-LISTEN:5401,reuseaddr,fork /dev/null &) 2>/dev/null
sleep 2

# Sample cumulative counters every second. This is the record that decides
# whether the fault is volume-driven, so it is flushed on every line.
( while true; do
    printf 'SAMPLE\t%s\t%s\t%s\n' \
      "\$(cut -d' ' -f1 /proc/uptime)" \
      "\$(cat /sys/class/net/${NS_NAME}0/statistics/rx_bytes 2>/dev/null || echo 0)" \
      "\$(cat /sys/class/net/${NS_NAME}0/statistics/rx_packets 2>/dev/null || echo 0)" >&3
    sync
    sleep 1
  done ) &
monitor=\$!

log "# load_start_uptime=\$(cut -d' ' -f1 /proc/uptime)"
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
log "# clean_exit uptime=\$(cut -d' ' -f1 /proc/uptime)"
REMOTE
}

cmd_run() {
  local node; node="$(pick_node)"
  [[ -n "${node}" ]] || { log_error "no node"; exit 1; }
  local run_id; run_id="$(date -u +%Y%m%dT%H%M%SZ)-${node##*-}-s${STREAMS}"
  local dir="${RUNS_DIR}/${run_id}"
  mkdir -p "${dir}"

  local before; before="$(node_boot_id "${node}")"
  [[ -n "${before}" ]] || { log_error "cannot read boot ID of ${node}"; exit 1; }

  # Facts about the machine, recorded before anything can crash.
  on_node "${node}" 'printf "kernel\t%s\n" "$(uname -r)";
     printf "l1vh\t%s\n" "$(dmesg 2>/dev/null | grep -c "running as L1VH partition")";
     printf "mshv_root\t%s\n" "$(grep -c "^mshv_root" /proc/modules)";
     printf "nokaslr\t%s\n" "$(grep -c nokaslr /proc/cmdline)";
     printf "nproc\t%s\n" "$(nproc)";
     printf "memtotal_kb\t%s\n" "$(awk "/MemTotal/{print \$2}" /proc/meminfo)"' \
    > "${dir}/node-facts.tsv" 2>/dev/null || true

  {
    printf 'run_id\t%s\nnode\t%s\nstreams\t%s\nduration\t%s\nboot_before\t%s\nstarted_utc\t%s\n' \
      "${run_id}" "${node}" "${STREAMS}" "${DURATION}" "${before}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat "${dir}/node-facts.tsv" 2>/dev/null
  } > "${dir}/meta.tsv"

  log_info "run ${run_id}"
  log_info "  node=${node} streams=${STREAMS} duration=${DURATION}s"
  grep -aE '^(kernel|l1vh|mshv_root|nokaslr)' "${dir}/node-facts.tsv" 2>/dev/null | sed 's/^/  /' || true

  ( timeout "$(( DURATION + 180 ))" bash -c "$(declare -f on_node_long); on_node_long '${node}' \"\$1\"" _ \
      "$(remote_stress "${run_id}")" > "${dir}/stress-stdout.log" 2>&1 || true ) &
  local stress_pid=$!

  # Poll from outside; every observation is appended immediately.
  printf 'utc\tuptime_s\tboot_id\tready\n' > "${dir}/poll.tsv"
  local start elapsed now ready
  start="$(date +%s)"
  while :; do
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= DURATION )) && break
    now="$(node_boot_id "${node}")"
    ready="$(oc_ get "node/${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${elapsed}" "${now:-unknown}" "${ready:-unknown}" \
      >> "${dir}/poll.tsv"
    sleep "${POLL}"
  done
  kill "${stress_pid}" 2>/dev/null || true

  printf 'ended_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${dir}/meta.tsv"
  log_info "waiting for ${node} to be Ready so on-node telemetry can be fetched..."
  local waited=0
  while (( waited < 900 )); do
    [[ "$(oc_ get "node/${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && break
    sleep 20; waited=$(( waited + 20 ))
  done
  fetch_telemetry "${node}" "${run_id}" "${dir}"
  log_ok "raw data in ${dir}"
  log_info "analyse with: python3 scripts/20-analyze-stress-runs.py"
}

fetch_telemetry() {
  local node="$1" run_id="$2" dir="$3"
  oc debug "node/${node}" --quiet --request-timeout="${REQUEST_TIMEOUT}s" \
    -- chroot /host cat "${NODE_TELEMETRY}/${run_id}/telemetry.tsv" \
    > "${dir}/telemetry.tsv" 2>/dev/null || true
  if [[ -s "${dir}/telemetry.tsv" ]]; then
    log_ok "fetched on-node telemetry ($(wc -l < "${dir}/telemetry.tsv") lines)"
  else
    log_warn "no on-node telemetry retrieved (node may still be down)"
    rm -f "${dir}/telemetry.tsv"
  fi
}

cmd_fetch() {
  local node; node="$(pick_node)"
  local dir run_id
  for dir in "${RUNS_DIR}"/*/; do
    [[ -f "${dir}/telemetry.tsv" ]] && continue
    run_id="$(basename "${dir}")"
    fetch_telemetry "${node}" "${run_id}" "${dir%/}"
  done
}

cmd_clean() {
  local node; node="$(pick_node)"
  [[ -n "${node}" ]] || return 0
  on_node "${node}" "pkill -f 'TCP-LISTEN:5401' 2>/dev/null || true
    ip netns del ${NS_NAME} 2>/dev/null || true
    ip link del ${NS_NAME}0 2>/dev/null || true
    echo cleaned" || true
  log_ok "cleaned ${node}"
}

case "${1:-run}" in
  run)   cmd_run ;;
  fetch) cmd_fetch ;;
  clean) cmd_clean ;;
  *) log_error "Unknown action '${1}'. Use: run|fetch|clean"; exit 1 ;;
esac
