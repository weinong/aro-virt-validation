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
#   NS (default ovn-mshv-isolation), IMAGE (default origin-tools).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

NS="${NS:-ovn-mshv-isolation}"
IMAGE="${IMAGE:-quay.io/openshift/origin-tools:latest}"
DURATION="${DURATION:-900}"
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

node_boot_count() {
  local node="$1"
  timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --request-timeout="${REQUEST_TIMEOUT}s" \
    -- chroot /host bash -c 'journalctl --list-boots --no-pager 2>/dev/null | wc -l' 2>/dev/null \
    | grep -aoE '^[0-9]+' | head -1
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
  log_info "MSHV nodes: boot counts + offload state"
  local n
  for n in $(mshv_nodes); do
    log_info "---- ${n} ----"
    echo "  kernel boot count: $(node_boot_count "${n}")"
    node_offload_state "${n}" | sed 's/^/  /'
  done
}

cmd_mitigate() { local n; for n in $(mshv_nodes); do apply_offload "${n}" off; done; log_ok "Offloads disabled (non-persistent)."; }
cmd_revert()   { local n; for n in $(mshv_nodes); do apply_offload "${n}" on;  done; log_ok "Offloads restored to on (defaults)."; }
cmd_clean()    { oc delete ns "${NS}" --wait=false >/dev/null 2>&1 || true; log_ok "Removed namespace ${NS}."; }

deploy_load_pods() {
  local server_node="$1" client_node="$2"
  oc create ns "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label ns "${NS}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

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
  restartPolicy: Never
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
  restartPolicy: Never
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
  oc -n "${NS}" wait --for=condition=Ready pod/flood --timeout=180s >/dev/null
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

  declare -A before
  local n
  for n in "${nodes[@]}"; do before[$n]="$(node_boot_count "$n")"; log_info "before: ${n} boots=${before[$n]}"; done

  deploy_load_pods "${server_node}" "${client_node}"

  log_info "Driving load for ${DURATION}s (polling for resets every 30s)..."
  local start elapsed
  start="$(date +%s)"
  while :; do
    elapsed=$(( $(date +%s) - start ))
    (( elapsed >= DURATION )) && break
    sleep 30
    for n in "${nodes[@]}"; do
      local now; now="$(node_boot_count "$n" || echo '?')"
      if [[ "${now}" =~ ^[0-9]+$ && "${now}" -gt "${before[$n]}" ]]; then
        log_warn "RESET DETECTED on ${n}: boots ${before[$n]} -> ${now} at t=${elapsed}s (MITIGATE=${MITIGATE})"
      fi
    done
  done

  log_info "==== RESULT (MITIGATE=${MITIGATE}, DURATION=${DURATION}s, STREAMS=${STREAMS}) ===="
  local resets=0
  for n in "${nodes[@]}"; do
    local after; after="$(node_boot_count "$n" || echo '?')"
    local delta="?"
    [[ "${after}" =~ ^[0-9]+$ ]] && delta=$(( after - before[$n] ))
    log_info "  ${n}: boots ${before[$n]} -> ${after} (resets=${delta})"
    [[ "${delta}" =~ ^[0-9]+$ ]] && resets=$(( resets + delta ))
  done
  log_info "  total resets during test: ${resets}"
  if [[ "${MITIGATE}" == "true" && "${resets}" -eq 0 ]]; then
    log_ok "No resets with offloads disabled — supports the GSO/GRO-path trigger hypothesis."
  elif [[ "${MITIGATE}" != "true" && "${resets}" -gt 0 ]]; then
    log_ok "Baseline reproduced the reset under overlay load."
  else
    log_warn "Inconclusive — may need longer DURATION/STREAMS or the real checkup (scripts/08) as the driver."
  fi
  log_info "Leaving load namespace ${NS} in place; run '$0 clean' to remove."
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
