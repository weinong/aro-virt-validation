#!/usr/bin/env bash
# =============================================================================
# 15-mshv-offload-isolation-test.sh - DIAGNOSTIC INTERVENTION (not a fix).
#
# Goal: test whether the guest kernel GSO/checksum panic that reboots the MSHV
# nodes (GPF at csum_partial+0xe5/0x110 while GSO-segmenting a Geneve/UDP-tunnel
# packet on the OVS TX path — see
# issues/2026-09-03-mshv-reboots-are-guest-gso-csum-panics.md) is triggered by
# the software GSO/GRO offload path on the OVN overlay uplink.
#
# It drives sustained cross-node (Geneve-encapsulated) TCP load between two pods
# pinned to the two MSHV nodes, and detects node resets by watching the kernel
# boot count. With MITIGATE=true it first disables GRO/GSO/TSO and fraglist-GSO
# (tx-gso-list) on the uplink + Geneve devices, so you can compare reboot rate
# with vs. without the offload path.
#
# ⚠️ This is a TEST, NOT A FIX:
#   * In baseline mode it is EXPECTED to reboot the MSHV nodes (that is the
#     signal we are measuring). Do not run on a cluster you cannot afford to
#     reboot.
#   * The `ethtool -K` changes are non-persistent and OVS/NetworkManager may
#     revert them on the next network reconfigure. `revert` restores defaults.
#   * A "no reboot with mitigation" result CONFIRMS the trigger but does not fix
#     the underlying kernel bug — that stays open for the upstream report.
#
# Usage:
#   ./scripts/15-mshv-offload-isolation-test.sh status          # boots + offload
#   ./scripts/15-mshv-offload-isolation-test.sh mitigate        # disable offloads
#   ./scripts/15-mshv-offload-isolation-test.sh revert          # restore offloads
#   ./scripts/15-mshv-offload-isolation-test.sh load            # drive load only
#   MITIGATE=true ./scripts/15-mshv-offload-isolation-test.sh run   # mitigate+load
#   ./scripts/15-mshv-offload-isolation-test.sh run             # baseline+load
#   ./scripts/15-mshv-offload-isolation-test.sh clean           # remove test ns
#
# Tunables (env): DURATION (s, default 900), STREAMS (default 48),
#   POLL (reset-poll seconds, default 15),
#   NS (default ovn-mshv-isolation), IMAGE (default origin-tools).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

NS="${NS:-ovn-mshv-isolation}"
IMAGE="${IMAGE:-quay.io/openshift/origin-tools:latest}"
DURATION="${DURATION:-900}"
POLL="${POLL:-15}"
STREAMS="${STREAMS:-48}"
PORT="${PORT:-5001}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"
DEBUG_TIMEOUT="${DEBUG_TIMEOUT:-180}"
MITIGATE="${MITIGATE:-false}"

# Devices whose software GSO/GRO path is under test.
OFFLOAD_IFACES="${OFFLOAD_IFACES:-eth0 genev_sys_6081 br-ex ovn-k8s-mp0}"

mshv_nodes() {
  oc get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    --request-timeout="${REQUEST_TIMEOUT}s"
}

# Kubelet-reported boot ID; it changes on every boot.
#
# This replaces a `journalctl --list-boots | wc -l` boot COUNT. That count is
# capped by journal rotation: on a node that has already crashed many times the
# oldest boot is vacuumed as each new one is appended, so the count stays pinned
# (observed stuck at 70) and real resets were reported as `resets=0`. Reading the
# boot ID from the API also avoids one `oc debug` pod per node per poll.
node_boot_id() {
  local node="$1"
  oc get "node/${node}" -o jsonpath='{.status.nodeInfo.bootID}' \
    --request-timeout="${REQUEST_TIMEOUT}s" 2>/dev/null
}

# Records any boot-ID change since the last poll. Updates the caller's boot_id
# and resets maps (bash dynamic scoping).
check_for_resets() {
  local elapsed="$1"; shift
  local n now
  for n in "$@"; do
    now="$(node_boot_id "$n")"
    [[ -n "${now}" && "${now}" != "${boot_id[$n]}" ]] || continue
    resets[$n]=$(( resets[$n] + 1 ))
    log_warn "RESET DETECTED on ${n}: boot ${boot_id[$n]} -> ${now} at t=${elapsed}s (MITIGATE=${MITIGATE})"
    boot_id[$n]="${now}"
  done
}

node_offload_state() {
  local node="$1"
  timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --request-timeout="${REQUEST_TIMEOUT}s" \
    -- chroot /host bash -c '
      for ifc in '"${OFFLOAD_IFACES}"'; do
        [ -e "/sys/class/net/$ifc" ] || continue
        printf "%-16s " "$ifc"
        ethtool -k "$ifc" 2>/dev/null | grep -iE "^generic-segmentation|^generic-receive|^tcp-segmentation|tx-gso-list|tx-udp-segmentation" | tr "\n" " "
        echo
      done' 2>/dev/null \
    | grep -avE 'Starting pod|Removing debug|To use host|Warning'
}

apply_offload() {
  local node="$1" onoff="$2"
  log_info "Setting GSO/GRO/TSO/gso-list=${onoff} on ${node} (${OFFLOAD_IFACES})"
  timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --request-timeout="${REQUEST_TIMEOUT}s" \
    -- chroot /host bash -c '
      for ifc in '"${OFFLOAD_IFACES}"'; do
        [ -e "/sys/class/net/$ifc" ] || continue
        out=$(ethtool -K "$ifc" gso '"${onoff}"' gro '"${onoff}"' tso '"${onoff}"' \
          tx-gso-list '"${onoff}"' tx-udp-segmentation '"${onoff}"' 2>&1)
        echo "  $ifc: ${out:-ok}"
      done' 2>&1 \
    | grep -avE 'Starting pod|Removing debug|To use host|Warning' || true
}

cmd_status() {
  log_info "MSHV nodes: boot IDs + offload state"
  local n
  for n in $(mshv_nodes); do
    log_info "---- ${n} ----"
    echo "  current boot ID: $(node_boot_id "${n}")"
    node_offload_state "${n}" | sed 's/^/  /'
  done
}

cmd_mitigate() { local n; for n in $(mshv_nodes); do apply_offload "${n}" off; done; log_ok "Offloads disabled (non-persistent)."; }
cmd_revert()   { local n; for n in $(mshv_nodes); do apply_offload "${n}" on;  done; log_ok "Offloads restored to on (defaults)."; }
cmd_clean() {
  oc delete ns "${NS}" --ignore-not-found --timeout=180s >/dev/null 2>&1 || true
  log_ok "Removed namespace ${NS}."
}

deploy_load_pods() {
  local server_node="$1" client_node="$2"
  oc create ns "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label ns "${NS}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

  # Pods from an earlier run are usually dead (their node crashed) and their spec
  # is immutable, so `oc apply` cannot revive them and the readiness wait would
  # block on a corpse. Remove them first so a rerun is idempotent.
  oc -n "${NS}" delete pod sink flood --ignore-not-found --timeout=120s >/dev/null 2>&1 || true

  # Sink server: accept many parallel TCP streams and discard.
  cat <<YAML | oc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: sink
  namespace: ${NS}
  labels: {app: mshv-iso}
spec:
  nodeName: ${server_node}
  restartPolicy: Always
  containers:
  - name: sink
    image: ${IMAGE}
    command: ["bash","-c","socat -u TCP-LISTEN:${PORT},reuseaddr,fork /dev/null"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities: {drop: ["ALL"]}
      seccompProfile: {type: RuntimeDefault}
YAML
  oc -n "${NS}" wait --for=condition=Ready pod/sink --timeout=180s >/dev/null
  SINK_IP="$(oc -n "${NS}" get pod sink -o jsonpath='{.status.podIP}')"
  log_info "sink pod on ${server_node} at ${SINK_IP}:${PORT}"

  # Load client: STREAMS parallel bulk /dev/zero senders -> forces GSO segmentation
  # on egress into the Geneve overlay (cross-node = encapsulated).
  cat <<YAML | oc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: flood
  namespace: ${NS}
  labels: {app: mshv-iso}
spec:
  nodeName: ${client_node}
  restartPolicy: Always
  containers:
  - name: flood
    image: ${IMAGE}
    command: ["bash","-c","end=\$((SECONDS+${DURATION})); while [ \$SECONDS -lt \$end ]; do for i in \$(seq 1 ${STREAMS}); do socat -u OPEN:/dev/zero TCP:${SINK_IP}:${PORT},nodelay & done; wait; done"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities: {drop: ["ALL"]}
      seccompProfile: {type: RuntimeDefault}
YAML
  oc -n "${NS}" wait --for=condition=Ready pod/flood --timeout=180s >/dev/null || \
    log_warn "flood pod not Ready yet (its node may have already crashed); continuing."
  log_info "flood pod on ${client_node} driving ${STREAMS} streams for ${DURATION}s"
}

cmd_load() {
  local nodes=(); mapfile -t nodes < <(mshv_nodes)
  if [[ ${#nodes[@]} -lt 2 ]]; then
    log_error "Need 2 MSHV nodes; found ${#nodes[@]}."; exit 1
  fi
  local server_node="${nodes[0]}" client_node="${nodes[1]}"

  if [[ "${MITIGATE}" == "true" ]]; then
    log_warn "MITIGATE=true: disabling offloads on both MSHV nodes before load."
    cmd_mitigate
  else
    log_warn "Baseline mode: offloads ON. Nodes are EXPECTED to reboot if the hypothesis holds."
  fi

  declare -A boot_id resets
  local n
  for n in "${nodes[@]}"; do
    boot_id[$n]="$(node_boot_id "$n")"
    resets[$n]=0
    if [[ -z "${boot_id[$n]}" ]]; then
      log_error "Could not read the boot ID of ${n}; resets on it cannot be detected."
      exit 1
    fi
    log_info "before: ${n} boot=${boot_id[$n]}"
  done

  deploy_load_pods "${server_node}" "${client_node}"

  log_info "Driving load for ${DURATION}s (polling for resets every ${POLL}s)..."
  local start elapsed
  start="$(date +%s)"
  while :; do
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= DURATION )) && break
    sleep "${POLL}"
    check_for_resets "${elapsed}" "${nodes[@]}"
  done
  check_for_resets "${DURATION}" "${nodes[@]}"

  log_info "==== RESULT (MITIGATE=${MITIGATE}, DURATION=${DURATION}s, STREAMS=${STREAMS}) ===="
  local total=0
  for n in "${nodes[@]}"; do
    log_info "  ${n}: resets=${resets[$n]} (current boot ${boot_id[$n]:-<unreadable>})"
    total=$(( total + resets[$n] ))
  done
  log_info "  total resets observed during test: ${total}"
  log_info "  NOTE: this counts observed boot-ID CHANGES; two resets between polls count once."
  if [[ "${MITIGATE}" == "true" && "${total}" -eq 0 ]]; then
    log_ok "No resets with offloads disabled — supports the GSO/GRO-path trigger hypothesis."
  elif [[ "${MITIGATE}" != "true" && "${total}" -gt 0 ]]; then
    log_ok "Baseline reproduced the reset under overlay load."
  else
    log_warn "Inconclusive — may need longer DURATION/STREAMS or the real checkup (scripts/08) as the driver."
  fi
  log_info "Cross-check the node's own boot list, which carries per-boot timestamps:"
  log_info "  oc debug node/<node> -- chroot /host journalctl --list-boots"
  # The pods restart across node crashes, so they must be stopped explicitly or
  # they would keep hammering the overlay after the measurement window closes.
  log_info "Stopping load pods (namespace ${NS} is kept for inspection)..."
  oc -n "${NS}" delete pod sink flood --ignore-not-found --timeout=120s >/dev/null 2>&1 || \
    log_warn "Could not delete the load pods; run '$0 clean' to stop the load."
  log_ok "Load stopped. Run '$0 clean' to remove namespace ${NS}."
}

ACTION="${1:-status}"
case "${ACTION}" in
  status)   cmd_status ;;
  mitigate) cmd_mitigate ;;
  revert)   cmd_revert ;;
  load)     cmd_load ;;
  run)      cmd_load ;;
  clean)    cmd_clean ;;
  *) log_error "Unknown action '${ACTION}'. Use: status|mitigate|revert|load|run|clean"; exit 1 ;;
esac
