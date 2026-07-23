#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${TMPDIR}/bin"

cat > "${TMPDIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${TMPDIR}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1 $2 $3 $4" == "get mcp master worker" && "$5" == "-o" && "$6" == "json" && "$7" == --request-timeout=* ]]; then
  if [[ "${TEST_SCENARIO}" == "malformed" ]]; then
    printf 'not json\n'
    exit 0
  fi

  count_file="${TEST_STATE_DIR}/calls"
  count=0
  [[ -f "${count_file}" ]] && count="$(<"${count_file}")"
  count=$((count + 1))
  printf '%s\n' "${count}" > "${count_file}"

  if [[ "${TEST_SCENARIO}" == "rollout" && "${count}" -ge 2 ]]; then
    updated=True
    degraded=False
  elif [[ "${TEST_SCENARIO}" == "degraded" ]]; then
    updated=False
    degraded=True
  else
    updated=False
    degraded=False
  fi

  cat <<JSON
{"items":[
  {"metadata":{"name":"master"},"status":{"conditions":[{"type":"Updated","status":"${updated}"},{"type":"Degraded","status":"${degraded}","message":"master pool failure"}]}},
  {"metadata":{"name":"worker"},"status":{"conditions":[{"type":"Updated","status":"True"},{"type":"Degraded","status":"False","message":""}]}}
]}
JSON
  exit 0
fi

if [[ "$1 $2 $3 $4" == "get mcp -o wide" && "$5" == --request-timeout=* ]]; then
  printf 'MCP DIAGNOSTICS\n'
  exit 0
fi

if [[ "$1 $2" == "get nodes" && "${*: -1}" == --request-timeout=* ]]; then
  printf 'NODE DIAGNOSTICS\n'
  exit 0
fi

printf 'unexpected oc args: %s\n' "$*" >&2
exit 2
EOF

chmod +x "${TMPDIR}/bin/az" "${TMPDIR}/bin/oc"

PATH="${TMPDIR}/bin:${PATH}"
SKIP_REPO_ENV=true
export PATH SKIP_REPO_ENV
source "${REPO_ROOT}/scripts/env.sh"

run_scenario() {
  local scenario="$1"
  local timeout="${2:-3}"
  local state_dir="${TMPDIR}/${scenario}"
  mkdir -p "${state_dir}"
  TEST_SCENARIO="${scenario}" TEST_STATE_DIR="${state_dir}" \
    MCP_UPDATE_TIMEOUT_SECONDS="${timeout}" MCP_UPDATE_POLL_SECONDS=1 \
    wait_for_machine_config_pools
}

if ! run_scenario rollout > "${TMPDIR}/rollout.out" 2>&1; then
  echo "expected an active rollout to become updated" >&2
  cat "${TMPDIR}/rollout.out" >&2
  exit 1
fi
grep -q 'MachineConfigPools are Updated' "${TMPDIR}/rollout.out"

if run_scenario degraded > "${TMPDIR}/degraded.out" 2>&1; then
  echo "expected a degraded pool to fail" >&2
  exit 1
fi
grep -q 'MachineConfigPool master is Degraded: master pool failure' "${TMPDIR}/degraded.out"
grep -q 'MCP DIAGNOSTICS' "${TMPDIR}/degraded.out"
grep -q 'NODE DIAGNOSTICS' "${TMPDIR}/degraded.out"

mkdir -p "${TMPDIR}/timeout"
timeout_started="${SECONDS}"
if TEST_SCENARIO=timeout TEST_STATE_DIR="${TMPDIR}/timeout" \
  MCP_UPDATE_TIMEOUT_SECONDS=1 MCP_UPDATE_POLL_SECONDS=5 \
  wait_for_machine_config_pools > "${TMPDIR}/timeout.out" 2>&1; then
  echo "expected a stalled pool to time out" >&2
  exit 1
fi
if (( SECONDS - timeout_started > 2 )); then
  echo "timeout exceeded its wall-clock bound" >&2
  exit 1
fi
grep -q 'MachineConfigPools did not become Updated within 1s: master' "${TMPDIR}/timeout.out"
grep -q 'MCP DIAGNOSTICS' "${TMPDIR}/timeout.out"
grep -q 'NODE DIAGNOSTICS' "${TMPDIR}/timeout.out"

if run_scenario malformed > "${TMPDIR}/malformed.out" 2>&1; then
  echo "expected malformed MCP status to fail" >&2
  exit 1
fi
grep -q 'Could not evaluate MachineConfigPool status' "${TMPDIR}/malformed.out"
grep -q 'MCP DIAGNOSTICS' "${TMPDIR}/malformed.out"
grep -q 'NODE DIAGNOSTICS' "${TMPDIR}/malformed.out"
