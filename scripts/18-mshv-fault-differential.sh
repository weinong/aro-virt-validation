#!/usr/bin/env bash
# =============================================================================
# 18-mshv-fault-differential.sh - Interleaved A/B/C load experiment to isolate
# WHICH property of the traffic triggers the csum_partial GPF panic.
#
# Background (issues/2026-09-08b): the panic is a #GP inside csum_partial's tail
# over-read, reached only via __skb_udp_tunnel_segment. The inference is that the
# Geneve overlay is the only high-volume path that software-checksums payload
# held in page frags, because the uplink advertises:
#     tx-checksum-ip-generic: off [fixed]
#     tx-udp_tnl-segmentation: off [fixed]
#     tx-udp_tnl-csum-segmentation: off [fixed]
# This script tests that inference by varying one property at a time.
#
# Arms:
#   overlay   - cross-node pod-to-pod (Geneve encapsulated, software segmented
#               and software checksummed). The known-crashing configuration.
#   hostnet   - cross-node hostNetwork pod-to-pod. Same NICs, same volume, but NO
#               tunnel: the NIC checksums and segments it. If the inference holds
#               this should NOT crash.
#   nogso     - overlay traffic with gso/gro/tso/tx-gso-list disabled on the OVS
#               and Geneve devices, so large GSO skbs are never segmented in
#               software. If the inference holds this should NOT crash.
#
# ⚠️ Arms are INTERLEAVED in short blocks, not run as one long block each. The
# crash rate drifts on its own (median boot lifetime ~26 min, observed range
# 137 s - 32 h), so sequential blocks confound the arm with the drift. That
# mistake already produced one false "fix" on 2026-09-09.
#
# ⚠️ Nodes are EXPECTED to reboot. Do not run on a cluster you cannot lose.
#
# Usage:
#   ./scripts/18-mshv-fault-differential.sh run     # interleaved experiment
#   ./scripts/18-mshv-fault-differential.sh report  # summarise results so far
#   ./scripts/18-mshv-fault-differential.sh clean
#
# Tunables (env): BLOCK_SECONDS (default 600), ROUNDS (default 6),
#   ARMS (default "overlay hostnet nogso"), STREAMS (default 64), POLL (15).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

NS="${NS:-mshv-fault-diff}"
IMAGE="${IMAGE:-quay.io/openshift/origin-tools:latest}"
BLOCK_SECONDS="${BLOCK_SECONDS:-600}"
ROUNDS="${ROUNDS:-6}"
ARMS="${ARMS:-overlay hostnet nogso}"
STREAMS="${STREAMS:-64}"
PORT="${PORT:-5001}"
HOSTNET_PORT="${HOSTNET_PORT:-5301}"
POLL="${POLL:-15}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"
DEBUG_TIMEOUT="${DEBUG_TIMEOUT:-240}"
OFFLOAD_IFACES="${OFFLOAD_IFACES:-eth0 genev_sys_6081 br-ex ovn-k8s-mp0}"
RESULTS="${RESULTS:-${_REPO_ROOT}/.checkup-runs/fault-differential/results.tsv}"

oc_() { oc --request-timeout="${REQUEST_TIMEOUT}s" "$@"; }

mshv_nodes() {
  oc_ get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

node_boot_id() {
  oc_ get "node/$1" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null
}

node_ready() {
  [[ "$(oc_ get "node/$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

apply_offload() {
  local node="$1" onoff="$2"
  timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --quiet \
    --request-timeout="${REQUEST_TIMEOUT}s" -- chroot /host bash -c '
      for ifc in '"${OFFLOAD_IFACES}"'; do
        [ -e "/sys/class/net/$ifc" ] || continue
        ethtool -K "$ifc" gso '"${onoff}"' gro '"${onoff}"' tso '"${onoff}"' \
          tx-gso-list '"${onoff}"' >/dev/null 2>&1
      done
      for ifc in '"${OFFLOAD_IFACES}"'; do
        [ -e "/sys/class/net/$ifc" ] || continue
        printf "%s:gso=%s " "$ifc" "$(ethtool -k "$ifc" 2>/dev/null | awk "/^generic-segmentation-offload/{print \$2}")"
      done; echo' 2>/dev/null | grep -avE 'Starting pod|Removing debug|To use host|^Warning' || true
}

# ethtool -K is not persistent and OVS/NetworkManager can revert it, so the arm
# is only meaningful if we re-assert and re-read it during the block.
offload_state() {
  local node="$1"
  timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --quiet \
    --request-timeout="${REQUEST_TIMEOUT}s" -- chroot /host bash -c '
      for ifc in '"${OFFLOAD_IFACES}"'; do
        [ -e "/sys/class/net/$ifc" ] || continue
        printf "%s=%s," "$ifc" "$(ethtool -k "$ifc" 2>/dev/null | awk "/^generic-segmentation-offload/{print \$2}")"
      done; echo' 2>/dev/null | grep -avE 'Starting pod|Removing debug|To use host|^Warning' | tr -d '\r' || true
}

ensure_ns() {
  oc_ create ns "${NS}" --dry-run=client -o yaml | oc_ apply -f - >/dev/null
  oc_ label ns "${NS}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true
}

stop_load() {
  oc_ -n "${NS}" delete pod sink flood --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
}

# $1 server node, $2 client node, $3 arm
start_load() {
  local server_node="$1" client_node="$2" arm="$3"
  stop_load
  local host_net=false port="${PORT}"
  if [[ "${arm}" == "hostnet" ]]; then
    host_net=true
    port="${HOSTNET_PORT}"
  fi

  cat <<YAML | oc_ apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: sink, namespace: ${NS}, labels: {app: mshv-diff}}
spec:
  nodeName: ${server_node}
  hostNetwork: ${host_net}
  restartPolicy: Always
  containers:
  - name: sink
    image: ${IMAGE}
    command: ["bash","-c","socat -u TCP-LISTEN:${port},reuseaddr,fork /dev/null"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities: {drop: ["ALL"]}
      seccompProfile: {type: RuntimeDefault}
YAML
  oc_ -n "${NS}" wait --for=condition=Ready pod/sink --timeout=180s >/dev/null || {
    log_warn "sink not Ready; skipping block"; return 1; }
  local sink_ip
  sink_ip="$(oc_ -n "${NS}" get pod sink -o jsonpath='{.status.podIP}')"
  [[ -n "${sink_ip}" ]] || { log_warn "no sink IP; skipping block"; return 1; }

  cat <<YAML | oc_ apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: flood, namespace: ${NS}, labels: {app: mshv-diff}}
spec:
  nodeName: ${client_node}
  hostNetwork: ${host_net}
  restartPolicy: Always
  containers:
  - name: flood
    image: ${IMAGE}
    command: ["bash","-c","end=\$((SECONDS+${BLOCK_SECONDS})); while [ \$SECONDS -lt \$end ]; do for i in \$(seq 1 ${STREAMS}); do socat -u OPEN:/dev/zero TCP:${sink_ip}:${port},nodelay & done; wait; done"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities: {drop: ["ALL"]}
      seccompProfile: {type: RuntimeDefault}
YAML
  oc_ -n "${NS}" wait --for=condition=Ready pod/flood --timeout=180s >/dev/null || \
    log_warn "flood not Ready yet (its node may be mid-crash); continuing"
  log_info "  ${arm}: sink=${server_node} flood=${client_node} ${sink_ip}:${port} streams=${STREAMS}"
  return 0
}

run_block() {
  local arm="$1" round="$2"
  local nodes=(); mapfile -t nodes < <(mshv_nodes)
  if [[ ${#nodes[@]} -lt 2 ]]; then
    log_warn "need 2 mshv nodes, found ${#nodes[@]}; waiting"
    sleep 60; return 0
  fi
  local server="${nodes[0]}" client="${nodes[1]}" n
  for n in "${nodes[@]}"; do
    node_ready "${n}" || { log_warn "${n} not Ready; waiting for the pool to settle"; sleep 90; return 0; }
  done

  # nogso must be (re-)applied every block: a reboot restores the defaults.
  local offload_before="n/a"
  if [[ "${arm}" == "nogso" ]]; then
    for n in "${nodes[@]}"; do apply_offload "${n}" off >/dev/null; done
    offload_before="$(offload_state "${client}")"
  elif [[ "${arm}" == "overlay" || "${arm}" == "hostnet" ]]; then
    for n in "${nodes[@]}"; do apply_offload "${n}" on >/dev/null; done
    offload_before="$(offload_state "${client}")"
  fi

  declare -A boot
  for n in "${nodes[@]}"; do boot[$n]="$(node_boot_id "$n")"; done

  log_info "round ${round} arm=${arm} (${BLOCK_SECONDS}s) offload[client]=${offload_before}"
  start_load "${server}" "${client}" "${arm}" || { stop_load; return 0; }

  local start elapsed resets=0 now
  start="$(date +%s)"
  while :; do
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= BLOCK_SECONDS )) && break
    sleep "${POLL}"
    for n in "${nodes[@]}"; do
      now="$(node_boot_id "$n")"
      if [[ -n "${now}" && -n "${boot[$n]}" && "${now}" != "${boot[$n]}" ]]; then
        resets=$(( resets + 1 ))
        log_warn "  RESET on ${n} at t=${elapsed}s (arm=${arm})"
        boot[$n]="${now}"
      fi
    done
  done

  local offload_after="n/a"
  [[ "${arm}" == "n/a" ]] || offload_after="$(offload_state "${client}")"
  stop_load

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${round}" "${arm}" "${BLOCK_SECONDS}" \
    "${resets}" "${offload_before}" "${offload_after}" >> "${RESULTS}"
  log_info "  -> resets=${resets} offload_after=${offload_after}"
}

cmd_run() {
  mkdir -p "$(dirname "${RESULTS}")"
  [[ -s "${RESULTS}" ]] || printf 'utc\tround\tarm\tseconds\tresets\toffload_before\toffload_after\n' > "${RESULTS}"
  ensure_ns
  local round arm
  for round in $(seq 1 "${ROUNDS}"); do
    for arm in ${ARMS}; do
      run_block "${arm}" "${round}"
      # Collect dump artefacts promptly: node-local /var/crash is destroyed when
      # MachineHealthCheck replaces a repeatedly-crashing node.
      bash "${SCRIPT_DIR}/16-mshv-kdump.sh" collect >/dev/null 2>&1 || true
    done
    cmd_report
  done
  stop_load
  log_ok "experiment complete; results in ${RESULTS}"
}

cmd_report() {
  [[ -s "${RESULTS}" ]] || { log_warn "no results yet"; return 0; }
  log_info "==== resets per arm ===="
  awk -F'\t' 'NR>1 {sec[$3]+=$4; res[$3]+=$5; n[$3]++}
    END {printf "  %-10s %8s %8s %10s %14s\n","ARM","BLOCKS","SECONDS","RESETS","RESETS/HOUR";
         for (a in res) printf "  %-10s %8d %8d %10d %14.2f\n", a, n[a], sec[a], res[a], res[a]*3600/sec[a]}' "${RESULTS}"
}

cmd_clean() {
  oc_ delete ns "${NS}" --ignore-not-found --timeout=180s >/dev/null 2>&1 || true
  local n
  for n in $(mshv_nodes); do apply_offload "${n}" on >/dev/null 2>&1 || true; done
  log_ok "removed ${NS} and restored offloads"
}

case "${1:-run}" in
  run)    cmd_run ;;
  report) cmd_report ;;
  clean)  cmd_clean ;;
  *) log_error "Unknown action '${1}'. Use: run|report|clean"; exit 1 ;;
esac
