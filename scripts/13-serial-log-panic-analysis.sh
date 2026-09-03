#!/usr/bin/env bash
# =============================================================================
# 13-serial-log-panic-analysis.sh - Parse Azure serial-console logs from the
# MSHV/L1VH worker VMs and summarize the guest kernel panics behind the
# "node reboots under load" symptom.
#
# Context:
#   The MSHV workers reboot repeatedly under OpenShift Virtualization load. The
#   in-guest journal never captured a cause because the crash is a
#   "Fatal exception in interrupt" -> immediate panic/reboot, so kmsg only ever
#   reached the emulated serial console. Azure boot-diagnostics serial-console
#   logs DO contain it. This script extracts and tabulates those panics.
#   See issues/2026-09-03-mshv-reboots-are-guest-gso-csum-panics.md
#
# The signature (identical on every event, both nodes):
#   Oops: general protection fault ... RIP: csum_partial+0xe5/0x110
#   path: OVS rx -> geneve_xmit_skb -> GSO segment (skb_udp_tunnel_segment ->
#         tcp_gso_segment -> skb_segment -> __skb_checksum -> csum_partial)
#   Kernel panic - not syncing: Fatal exception in interrupt -> Rebooting in 10s
#
# Usage:
#   ./scripts/13-serial-log-panic-analysis.sh                 # defaults to
#                                                             # ~/Downloads/<vm>.txt
#   ./scripts/13-serial-log-panic-analysis.sh FILE [FILE...]  # explicit files
#
# This script is read-only: it only reads the serial-log text files and prints
# a report to stdout. It does not touch the cluster or Azure.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Default log locations (Azure serial-console downloads), overridable via args.
DEFAULT_LOGS=(
  "${HOME}/Downloads/aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw.txt"
  "${HOME}/Downloads/aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd.txt"
)

LOGS=("$@")
if [[ ${#LOGS[@]} -eq 0 ]]; then
  LOGS=("${DEFAULT_LOGS[@]}")
fi

check_command awk || exit 1

analyze_one() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    log_warn "Serial log not found: ${file} (skipping)"
    return 0
  fi

  local node
  node="$(basename "${file}")"
  node="${node%.txt}"

  log_info "===================================================================="
  log_info "Serial log: ${node}"
  log_info "File:       ${file}"
  log_info "===================================================================="

  # Whole-file counters and a per-panic table, computed in a single awk pass.
  awk '
    function flush(   chain) {
      if (in_panic) {
        chain = (saw_tunnel && saw_geneve) ? "geneve+gso+csum" : \
                (saw_tunnel ? "gso+csum(tunnel)" : \
                (saw_csum ? "csum" : "other"))
        printf("  %-6d | %-14s | %-22s | CPU %-3s %-12s | %s\n",
               ++panic_n, uptime, faultaddr, cpu, comm, chain)
      }
      in_panic = 0; uptime=""; faultaddr=""; rip=""; cpu=""; comm="";
      saw_tunnel=0; saw_geneve=0; saw_csum=0
    }
    /Linux version 6\.12/            { boots++ }
    /Oops: general protection fault/ {
      flush()
      in_panic = 1
      # timestamp like [ 11204.504461]
      if (match($0, /\[[ ]*[0-9]+\.[0-9]+\]/)) {
        uptime = substr($0, RSTART+1, RLENGTH-2); gsub(/ /,"",uptime)
      }
      if (match($0, /address 0x[0-9a-f]+/)) {
        faultaddr = substr($0, RSTART+8, RLENGTH-8)
      }
      gpf++
    }
    in_panic && /CPU: [0-9]+/ {
      if (match($0, /CPU: [0-9]+/)) cpu = substr($0, RSTART+5, RLENGTH-5)
      if (match($0, /Comm: [^ ]+/))  comm = substr($0, RSTART+6, RLENGTH-6)
    }
    in_panic && /RIP: 0010:csum_partial\+0xe5\/0x110/ { saw_csum=1 }
    in_panic && /skb_udp_tunnel_segment/               { saw_tunnel=1 }
    in_panic && /geneve_xmit_skb/                      { saw_geneve=1 }
    /Kernel panic - not syncing: Fatal exception in interrupt/ { panics++ }
    /Rebooting in 10 seconds/ { reboots++; flush() }
    END {
      flush()
      printf("\n")
      printf("  SUMMARY: kernel_boots=%d  gpf_oops=%d  panics=%d  reboots=%d\n",
             boots, gpf, panics, reboots)
    }
  ' "${file}" | {
    # Print a table header before the awk rows (rows start with two spaces).
    printf "  %-6s | %-14s | %-22s | %-16s | %s\n" "PANIC" "UPTIME(s)" "FAULT ADDRESS" "CONTEXT" "CALL CHAIN"
    printf "  %s\n" "------------------------------------------------------------------------------------------"
    cat
  }
  echo
}

for f in "${LOGS[@]}"; do
  analyze_one "${f}"
done

log_ok "Serial-log panic analysis complete."
