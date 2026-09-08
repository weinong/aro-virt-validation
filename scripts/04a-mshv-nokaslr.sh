#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc
check_command jq
TIMEOUT="${MCP_UPDATE_TIMEOUT_SECONDS:-1800}"
POLL="${MCP_UPDATE_POLL_SECONDS:-15}"
if ! [[ "${TIMEOUT}" =~ ^[1-9][0-9]*$ && "${POLL}" =~ ^[1-9][0-9]*$ ]]; then
  log_error "MCP update timeout and poll interval must be positive integers."
  exit 1
fi

pool_settled() {
  jq -e '
    .spec.paused != true and
    .status.observedGeneration == .metadata.generation and
    .spec.configuration.name == .status.configuration.name and
    .status.machineCount > 0 and
    .status.readyMachineCount == .status.machineCount and
    .status.updatedMachineCount == .status.machineCount and
    any(.status.conditions[]; .type == "Updated" and .status == "True") and
    any(.status.conditions[]; .type == "Updating" and .status == "False") and
    any(.status.conditions[]; .type == "Degraded" and .status == "False")
  ' >/dev/null <<< "$1"
}

oc whoami --request-timeout=30s >/dev/null
oc get clusterversion version --request-timeout=30s
POOL="$(oc get mcp mshv -o json --request-timeout=30s)"
if ! pool_settled "${POOL}"; then
  log_error "The mshv pool must be populated, unpaused, and fully Updated before applying nokaslr. No changes applied."
  show_machine_config_pool_diagnostics
  exit 1
fi

log_warn "Disabling kernel ASLR on the mshv pool reduces exploit protection and drains/reboots nodes."
oc apply -f - --request-timeout=30s <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-mshv-nokaslr
  labels:
    machineconfiguration.openshift.io/role: mshv
spec:
  config:
    ignition:
      version: 3.4.0
  kernelArguments:
    - nokaslr
EOF

log_info "Waiting for the mshv pool to render and finish the nokaslr rollout..."
DEADLINE=$((SECONDS + TIMEOUT))
while (( SECONDS < DEADLINE )); do
  POOL="$(oc get mcp mshv -o json --request-timeout=30s)"
  if jq -e 'any(.status.conditions[]; .type == "Degraded" and .status == "True")' >/dev/null <<< "${POOL}"; then
    log_error "The mshv pool became Degraded; leaving the MachineConfig in place for investigation."
    show_machine_config_pool_diagnostics
    exit 1
  fi
  # Updated can still describe the old config immediately after oc apply.
  if pool_settled "${POOL}" && jq -e 'any(.status.configuration.source[]?; .name == "99-mshv-nokaslr")' >/dev/null <<< "${POOL}"; then
    RENDERED="$(jq -r '.status.configuration.name' <<< "${POOL}")"
    oc get mc "${RENDERED}" -o json --request-timeout=30s |
      jq -e '.spec.kernelArguments | index("nokaslr") != null' >/dev/null
    NODES="$(oc get nodes -l node-role.kubernetes.io/mshv -o json --request-timeout=30s)"
    jq -e --arg config "${RENDERED}" --argjson count "$(jq '.status.machineCount' <<< "${POOL}")" '
      (.items | length) == $count and all(.items[];
        .metadata.annotations["machineconfiguration.openshift.io/currentConfig"] == $config and
        .metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] == $config and
        .metadata.annotations["machineconfiguration.openshift.io/state"] == "Done")
    ' >/dev/null <<< "${NODES}"
    while IFS= read -r node; do
      log_info "Verifying booted kernel command line on ${node}..."
      oc debug "node/${node}" -- chroot /host bash -c '
        read -r cmdline < /proc/cmdline
        printf "%s\n" "$cmdline"
        [[ " $cmdline " == *" nokaslr "* ]]
      '
    done < <(jq -r '.items[].metadata.name' <<< "${NODES}")
    log_ok "nokaslr verified on every mshv node."
    exit 0
  fi
  REMAINING=$((DEADLINE - SECONDS))
  (( REMAINING > 0 )) || break
  sleep "$((POLL < REMAINING ? POLL : REMAINING))"
done

log_error "Timed out waiting for nokaslr after ${TIMEOUT}s; the MachineConfig remains applied."
show_machine_config_pool_diagnostics
exit 1
