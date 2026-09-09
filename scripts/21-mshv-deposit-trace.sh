#!/usr/bin/env bash
# =============================================================================
# 21-mshv-deposit-trace.sh - Capture MSHV page deposit/withdraw tracepoints.
#
# The instrumented kernel (...mgns1.el10) adds three tracepoints under the
# mshv_deposit trace system:
#   hv_deposit_pages_block  token, partition_id, node, base_pfn, base_va, count
#   hv_deposit_pages_done   token, partition_id, requested, page_count,
#                           completed, status, ret
#   hv_withdraw_pages       partition_id, completed, status, pfns[]
#
# Purpose: test whether the csum_partial #GP lands on memory that was deposited
# to the hypervisor for a VM and then mishandled when returned to Linux on
# teardown. See issues/2026-09-09b-l1vh-specific-matched-pair.md.
#
# DURABILITY: the ftrace ring buffer lives in memory and is LOST in the panic.
# A snapshotter on the node therefore copies the buffer to disk and fsync()s it,
# so the deposit history survives the crash and the reboot. ftrace_dump_on_oops
# is deliberately NOT used: dumping a large buffer through printk at panic time
# can overflow the log buffer and stall the panic path before kdump runs.
#
# Usage:
#   ./scripts/21-mshv-deposit-trace.sh start [run_id]
#   ./scripts/21-mshv-deposit-trace.sh status
#   ./scripts/21-mshv-deposit-trace.sh fetch [run_id]
#   ./scripts/21-mshv-deposit-trace.sh stop
#
# Tunables (env): NODE, BUF_KB (per-CPU ftrace buffer, default 1024),
#   SNAP_SECONDS (default 3).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

BUF_KB="${BUF_KB:-1024}"
SNAP_SECONDS="${SNAP_SECONDS:-3}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"
TRACE_DIR="/var/log/mshv-deposit"
OUT_DIR="${OUT_DIR:-${_REPO_ROOT}/.checkup-runs/mshv-deposit-trace}"

oc_() { oc --request-timeout="${REQUEST_TIMEOUT}s" "$@"; }

pick_node() {
  [[ -n "${NODE:-}" ]] && { printf '%s' "${NODE}"; return; }
  oc_ get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -1
}

on_node() {
  local node="$1"; shift
  oc debug "node/${node}" --quiet --request-timeout="${REQUEST_TIMEOUT}s" \
    -- chroot /host bash -c "$*" 2>&1 |
    grep -avE 'Starting pod|Removing debug|To use host|^Warning'
}

# Snapshot the ring buffer to disk and fsync it, so the record survives a panic.
snapshotter() {
  cat <<'PY'
import os, time, sys
run = sys.argv[1]
outdir = "/var/log/mshv-deposit/" + run
os.makedirs(outdir, exist_ok=True)
path = outdir + "/trace.log"
interval = float(sys.argv[2])
while True:
    try:
        with open("/sys/kernel/tracing/trace", errors="replace") as fh:
            data = fh.read()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        os.write(fd, data.encode())
        os.fsync(fd)          # durability across the panic is the whole point
        os.close(fd)
    except Exception as exc:
        try:
            with open(outdir + "/snapshot.err", "a") as fh:
                fh.write(f"{time.time()} {exc}\n")
        except Exception:
            pass
    time.sleep(interval)
PY
}

cmd_start() {
  local node run_id
  node="$(pick_node)"
  run_id="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
  [[ -n "${node}" ]] || { log_error "no node"; exit 1; }

  log_info "enabling mshv_deposit tracepoints on ${node} (run ${run_id})"
  # base64 the helper rather than nesting heredocs: a heredoc inside a command
  # substitution inside another heredoc silently produced an empty file.
  local snap_b64
  snap_b64="$(snapshotter | base64 -w0)"

  local script
  script="set -e
T=/sys/kernel/tracing
[ -d \"\$T/events/mshv_deposit\" ] || { echo 'MISSING: mshv_deposit tracepoints (wrong kernel?)'; exit 2; }
echo ${BUF_KB} > \$T/buffer_size_kb 2>/dev/null || true
echo 0 > \$T/tracing_on
echo > \$T/trace
echo 1 > \$T/events/mshv_deposit/enable
echo 1 > \$T/tracing_on
mkdir -p ${TRACE_DIR}/${run_id}
systemctl stop mshv-deposit-snap.service 2>/dev/null || true
printf '%s' '${snap_b64}' | base64 -d > ${TRACE_DIR}/mshv-snap.py
systemd-run --unit=mshv-deposit-snap --collect --quiet \
  /usr/bin/python3 ${TRACE_DIR}/mshv-snap.py ${run_id} ${SNAP_SECONDS}
sleep 6
echo \"enabled=\$(cat \$T/events/mshv_deposit/enable)\"
echo \"tracing_on=\$(cat \$T/tracing_on)\"
echo \"buffer_size_kb=\$(cat \$T/buffer_size_kb)\"
echo \"unit=\$(systemctl is-active mshv-deposit-snap.service 2>/dev/null)\"
echo \"snapshot_bytes=\$(stat -c %s ${TRACE_DIR}/${run_id}/trace.log 2>/dev/null || echo MISSING)\"
"
  local out; out="$(on_node "${node}" "${script}")"
  printf '%s\n' "${out}" | sed 's/^/  /'
  # The only signal that matters: is the snapshot actually on disk?
  if grep -q 'snapshot_bytes=MISSING' <<< "${out}"; then
    log_error "snapshotter is not writing; tracing would produce nothing"
    return 1
  fi
  log_ok "tracing started; snapshots at ${TRACE_DIR}/${run_id}/trace.log on ${node}"
}

cmd_status() {
  local node; node="$(pick_node)"
  on_node "${node}" '
    T=/sys/kernel/tracing
    echo "enabled=$(cat $T/events/mshv_deposit/enable 2>/dev/null)"
    echo "tracing_on=$(cat $T/tracing_on 2>/dev/null)"
    echo "snapshotter_unit=$(systemctl is-active mshv-deposit-snap.service 2>/dev/null)"
    for d in '"${TRACE_DIR}"'/*/; do
      [ -f "$d/trace.log" ] || continue
      echo "$d $(grep -c hv_deposit_pages_block "$d/trace.log" 2>/dev/null || echo 0) deposit-blocks, $(grep -c hv_withdraw_pages "$d/trace.log" 2>/dev/null || echo 0) withdraws"
    done' | sed 's/^/  /'
}

cmd_fetch() {
  local node run_id dir
  node="$(pick_node)"
  mkdir -p "${OUT_DIR}"
  for run_id in $(on_node "${node}" "ls -1 ${TRACE_DIR} 2>/dev/null | grep -v mshv-snap"); do
    run_id="$(tr -d '\r' <<< "${run_id}")"
    [[ -n "${run_id}" ]] || continue
    dir="${OUT_DIR}/${node}-${run_id}"
    mkdir -p "${dir}"
    oc debug "node/${node}" --quiet --request-timeout="${REQUEST_TIMEOUT}s" \
      -- chroot /host cat "${TRACE_DIR}/${run_id}/trace.log" > "${dir}/trace.log" 2>/dev/null || true
    if [[ -s "${dir}/trace.log" ]]; then
      log_ok "fetched ${dir}/trace.log ($(wc -l < "${dir}/trace.log") lines)"
    else
      rm -rf "${dir}"
    fi
  done
}

cmd_stop() {
  local node; node="$(pick_node)"
  on_node "${node}" '
    systemctl stop mshv-deposit-snap.service 2>/dev/null || true
    echo 0 > /sys/kernel/tracing/events/mshv_deposit/enable 2>/dev/null || true
    echo 0 > /sys/kernel/tracing/tracing_on 2>/dev/null || true
    echo stopped' | sed 's/^/  /'
  log_ok "tracing stopped on ${node}"
}

case "${1:-status}" in
  start)  shift; cmd_start "${1:-}" ;;
  status) cmd_status ;;
  fetch)  cmd_fetch ;;
  stop)   cmd_stop ;;
  *) log_error "Unknown action '${1}'. Use: start|status|fetch|stop"; exit 1 ;;
esac
