#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

command -v jq >/dev/null
mkdir -p "${TMPDIR}/bin"

cat > "${TMPDIR}/manifest.yaml" <<'EOF'
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

cat > "${TMPDIR}/pool.json" <<'EOF'
{
  "metadata": {"name": "mshv", "generation": 1},
  "spec": {"paused": false, "configuration": {"name": "rendered-mshv-old"}},
  "status": {
    "observedGeneration": 1,
    "configuration": {"name": "rendered-mshv-old", "source": [{"name": "00-worker"}]},
    "machineCount": 2,
    "readyMachineCount": 2,
    "updatedMachineCount": 2,
    "conditions": [
      {"type": "Updated", "status": "True"},
      {"type": "Updating", "status": "False"},
      {"type": "Degraded", "status": "False"}
    ]
  }
}
EOF

# Never fall through to a real Azure CLI, even if the script changes.
cat > "${TMPDIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
touch "${TEST_STATE_DIR}/unexpected-az"
printf 'unexpected Azure invocation\n' >&2
exit 2
EOF

cat > "${TMPDIR}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_STATE_DIR}/oc.log"
case "$*" in
  "whoami --request-timeout=30s") printf 'system:admin\n' ;;
  "get clusterversion version --request-timeout=30s") printf 'version 4.22.0-rc.0\n' ;;
  "get mcp mshv -o json --request-timeout=30s")
    count=0
    [[ ! -f "${TEST_STATE_DIR}/pool-calls" ]] || count="$(<"${TEST_STATE_DIR}/pool-calls")"
    count=$((count + 1))
    printf '%s\n' "${count}" > "${TEST_STATE_DIR}/pool-calls"
    pool="$(<"${TEST_FIXTURE_DIR}/pool.json")"
    if [[ -f "${TEST_STATE_DIR}/applies" ]]; then
      pool="$(jq '
        .metadata.generation = 2 | .status.observedGeneration = 2 |
        .spec.configuration.name = "rendered-mshv-new" |
        .status.configuration = {name: "rendered-mshv-new", source: [{name: "99-mshv-nokaslr"}]}
      ' <<< "${pool}")"
      case "${TEST_SCENARIO}" in
        stale)
          case "${count}" in
            2) pool="$(<"${TEST_FIXTURE_DIR}/pool.json")" ;;
            3) pool="$(jq '.status.observedGeneration = 1' <<< "${pool}")" ;;
            4) pool="$(jq '.status.configuration.name = "rendered-mshv-old"' <<< "${pool}")" ;;
          esac
          ;;
        timeout) pool="$(<"${TEST_FIXTURE_DIR}/pool.json")" ;;
        rollout-degraded)
          pool="$(jq '(.status.conditions[] | select(.type == "Degraded").status) = "True"' <<< "${pool}")"
          ;;
      esac
    else
      case "${TEST_SCENARIO}" in
        paused) pool="$(jq '.spec.paused = true' <<< "${pool}")" ;;
        updating)
          pool="$(jq '(.status.conditions[] | select(.type == "Updating").status) = "True"' <<< "${pool}")"
          ;;
        degraded)
          pool="$(jq '(.status.conditions[] | select(.type == "Degraded").status) = "True"' <<< "${pool}")"
          ;;
        empty)
          pool="$(jq '.status.machineCount = 0 | .status.readyMachineCount = 0 | .status.updatedMachineCount = 0' <<< "${pool}")"
          ;;
      esac
    fi
    jq -r '.status.configuration.name' <<< "${pool}" > "${TEST_STATE_DIR}/rendered"
    printf '%s\n' "${pool}"
    ;;
  "apply -f - --request-timeout=30s")
    count=0
    [[ ! -f "${TEST_STATE_DIR}/applies" ]] || count="$(<"${TEST_STATE_DIR}/applies")"
    count=$((count + 1))
    cat > "${TEST_STATE_DIR}/manifest-${count}.yaml"
    diff -u "${TEST_FIXTURE_DIR}/manifest.yaml" "${TEST_STATE_DIR}/manifest-${count}.yaml"
    printf '%s\n' "${count}" > "${TEST_STATE_DIR}/applies"
    printf 'machineconfig.machineconfiguration.openshift.io/99-mshv-nokaslr configured\n'
    ;;
  "get mc rendered-mshv-old -o json --request-timeout=30s"|"get mc rendered-mshv-new -o json --request-timeout=30s")
    # Even the old config has nokaslr: kernelArguments alone cannot prove rendering.
    printf '{"spec":{"kernelArguments":["nokaslr"]}}\n'
    ;;
  "get nodes -l node-role.kubernetes.io/mshv -o json --request-timeout=30s")
    jq -n --arg config "$(<"${TEST_STATE_DIR}/rendered")" '{items: [
      ["mshv-1", "mshv-2"][] | {metadata: {name: ., annotations: {
        "machineconfiguration.openshift.io/currentConfig": $config,
        "machineconfiguration.openshift.io/desiredConfig": $config,
        "machineconfiguration.openshift.io/state": "Done"
      }}}
    ]}'
    ;;
  "debug node/mshv-1 -- chroot /host bash -c "*|"debug node/mshv-2 -- chroot /host bash -c "*)
    [[ "$8" == *'/proc/cmdline'* && "$8" == *' nokaslr '* ]]
    printf '%s\n' "$2" >> "${TEST_STATE_DIR}/debug-nodes"
    if [[ "${TEST_SCENARIO}" == "debug-failed" && "$2" == "node/mshv-2" ]]; then
      printf 'BOOT_IMAGE=/vmlinuz quiet\n'
      printf 'mock debug: nokaslr missing on mshv-2\n' >&2
      exit 1
    fi
    printf 'BOOT_IMAGE=/vmlinuz nokaslr quiet\n'
    ;;
  "get mcp -o wide --request-timeout=30s") printf 'MCP DIAGNOSTICS\n' ;;
  "get nodes -o custom-columns="*" --request-timeout=30s") printf 'NODE DIAGNOSTICS\n' ;;
  *)
    touch "${TEST_STATE_DIR}/unexpected-oc"
    printf 'unexpected oc args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

chmod +x "${TMPDIR}/bin/oc" "${TMPDIR}/bin/az"

run_scenario() {
  local scenario="$1" expected="$2" timeout="${3:-15}" status=0
  local state_dir="${TMPDIR}/${scenario}"
  mkdir -p "${state_dir}"
  TEST_SCENARIO="${scenario}" TEST_STATE_DIR="${state_dir}" TEST_FIXTURE_DIR="${TMPDIR}" \
    PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true SUBSCRIPTION_ID=test \
    MCP_UPDATE_TIMEOUT_SECONDS="${timeout}" MCP_UPDATE_POLL_SECONDS=1 MCP_REQUEST_TIMEOUT_SECONDS=30 \
    bash "${REPO_ROOT}/scripts/04a-mshv-nokaslr.sh" > "${state_dir}/output" 2>&1 || status=$?
  if [[ "${status}" -ne "${expected}" ]]; then
    printf '%s: expected exit %s, got %s\n' "${scenario}" "${expected}" "${status}" >&2
    cat "${state_dir}/output" >&2
    exit 1
  fi
  test ! -f "${state_dir}/unexpected-oc"
  test ! -f "${state_dir}/unexpected-az"
  if [[ "${expected}" -eq 0 ]]; then
    grep -q 'nokaslr verified on every mshv node' "${state_dir}/output"
  else
    ! grep -q 'nokaslr verified on every mshv node' "${state_dir}/output"
  fi
}

run_scenario healthy 0
test "$(<"${TMPDIR}/healthy/applies")" -eq 1
test "$(<"${TMPDIR}/healthy/pool-calls")" -eq 2
test "$(<"${TMPDIR}/healthy/debug-nodes")" = $'node/mshv-1\nnode/mshv-2'

# Preserve mock state: preflight already includes the applied config on a rerun.
run_scenario healthy 0
test "$(<"${TMPDIR}/healthy/applies")" -eq 2
test "$(<"${TMPDIR}/healthy/pool-calls")" -eq 4
cmp "${TMPDIR}/healthy/manifest-1.yaml" "${TMPDIR}/healthy/manifest-2.yaml"
test "$(<"${TMPDIR}/healthy/debug-nodes")" = $'node/mshv-1\nnode/mshv-2\nnode/mshv-1\nnode/mshv-2'

# Updated remains True through missing source, stale generation, and stale config.
# All other verification mocks would pass early, so the poll count is essential.
run_scenario stale 0
test "$(<"${TMPDIR}/stale/pool-calls")" -eq 5
test "$(<"${TMPDIR}/stale/applies")" -eq 1
test "$(<"${TMPDIR}/stale/debug-nodes")" = $'node/mshv-1\nnode/mshv-2'

for scenario in paused updating degraded empty; do
  run_scenario "${scenario}" 1
  grep -q 'No changes applied' "${TMPDIR}/${scenario}/output"
  grep -q 'MCP DIAGNOSTICS' "${TMPDIR}/${scenario}/output"
  grep -q 'NODE DIAGNOSTICS' "${TMPDIR}/${scenario}/output"
  test "$(<"${TMPDIR}/${scenario}/pool-calls")" -eq 1
  ! grep -q '^apply ' "${TMPDIR}/${scenario}/oc.log"
  test ! -f "${TMPDIR}/${scenario}/debug-nodes"
done

run_scenario debug-failed 1
grep -q 'mock debug: nokaslr missing on mshv-2' "${TMPDIR}/debug-failed/output"
test "$(<"${TMPDIR}/debug-failed/applies")" -eq 1
test "$(<"${TMPDIR}/debug-failed/debug-nodes")" = $'node/mshv-1\nnode/mshv-2'

run_scenario rollout-degraded 1
grep -q 'pool became Degraded; leaving the MachineConfig in place' "${TMPDIR}/rollout-degraded/output"
test "$(<"${TMPDIR}/rollout-degraded/pool-calls")" -eq 2

run_scenario timeout 1 2
grep -q 'Timed out waiting for nokaslr after 2s; the MachineConfig remains applied' "${TMPDIR}/timeout/output"
test "$(<"${TMPDIR}/timeout/pool-calls")" -ge 2

for scenario in rollout-degraded timeout; do
  test "$(<"${TMPDIR}/${scenario}/applies")" -eq 1
  test ! -f "${TMPDIR}/${scenario}/debug-nodes"
  grep -q 'MCP DIAGNOSTICS' "${TMPDIR}/${scenario}/output"
  grep -q 'NODE DIAGNOSTICS' "${TMPDIR}/${scenario}/output"
done

printf 'mshv-nokaslr-tests: OK (10 scenarios)\n'
