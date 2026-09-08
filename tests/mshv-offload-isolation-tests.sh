#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${TMPDIR}/bin"

cat > "${TMPDIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
touch "${TEST_STATE_DIR}/unexpected-az"
exit 2
EOF

# Boot IDs are served from a per-node file so a scenario can simulate a reset by
# rewriting it. The node's journal boot COUNT is deliberately held constant to
# reproduce the journal-rotation case that previously masked real resets.
cat > "${TMPDIR}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_STATE_DIR}/oc.log"
case "$*" in
  "get nodes -l node-role.kubernetes.io/mshv -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end} --request-timeout=60s")
    printf 'node-a\nnode-b\n'
    ;;
  "get node/node-a -o jsonpath={.status.nodeInfo.bootID} --request-timeout=60s"|\
  "get node/node-b -o jsonpath={.status.nodeInfo.bootID} --request-timeout=60s")
    node="${2#node/}"
    polls=0
    [[ ! -f "${TEST_STATE_DIR}/polls-${node}" ]] || polls="$(<"${TEST_STATE_DIR}/polls-${node}")"
    polls=$((polls + 1))
    printf '%s\n' "${polls}" > "${TEST_STATE_DIR}/polls-${node}"
    # node-a resets on its 3rd and 5th observation; node-b never resets.
    if [[ "${node}" == "node-a" && "${TEST_SCENARIO}" == "reset" ]]; then
      if   (( polls >= 5 )); then printf 'boot-a-3'
      elif (( polls >= 3 )); then printf 'boot-a-2'
      else                        printf 'boot-a-1'
      fi
    elif [[ "${node}" == "node-a" && "${TEST_SCENARIO}" == "unreadable" ]]; then
      printf ''
    else
      printf 'boot-%s-1' "${node#node-}"
    fi
    ;;
  "create ns ovn-mshv-isolation --dry-run=client -o yaml") printf 'apiVersion: v1\nkind: Namespace\n' ;;
  "apply -f -") cat > /dev/null; printf 'applied\n' ;;
  "label ns ovn-mshv-isolation pod-security.kubernetes.io/enforce=privileged --overwrite") printf 'labeled\n' ;;
  "-n ovn-mshv-isolation wait --for=condition=Ready pod/sink --timeout=180s") printf 'ready\n' ;;
  "-n ovn-mshv-isolation wait --for=condition=Ready pod/flood --timeout=180s")
    # A crashing node may never make the flood pod Ready; the run must continue.
    [[ "${TEST_SCENARIO}" != "reset" ]] || exit 1
    printf 'ready\n'
    ;;
  "-n ovn-mshv-isolation delete pod sink flood --ignore-not-found --timeout=120s")
    printf '%s\n' "$*" >> "${TEST_STATE_DIR}/pod-deletes"
    printf 'deleted\n'
    ;;
  "-n ovn-mshv-isolation get pod sink -o jsonpath={.status.podIP}") printf '10.0.0.1' ;;
  *)
    touch "${TEST_STATE_DIR}/unexpected-oc"
    printf 'unexpected oc args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

chmod +x "${TMPDIR}/bin/oc" "${TMPDIR}/bin/az"

run_scenario() {
  local scenario="$1" expected="$2" status=0
  local state_dir="${TMPDIR}/${scenario}"
  mkdir -p "${state_dir}"
  TEST_SCENARIO="${scenario}" TEST_STATE_DIR="${state_dir}" \
    PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true SUBSCRIPTION_ID=test \
    MITIGATE=false DURATION=4 POLL=1 STREAMS=2 \
    bash "${REPO_ROOT}/scripts/15-mshv-offload-isolation-test.sh" run \
      > "${state_dir}/output" 2>&1 || status=$?
  if [[ "${status}" -ne "${expected}" ]]; then
    printf '%s: expected exit %s, got %s\n' "${scenario}" "${expected}" "${status}" >&2
    cat "${state_dir}/output" >&2
    exit 1
  fi
  test ! -f "${state_dir}/unexpected-oc"
  test ! -f "${state_dir}/unexpected-az"
}

# A reset must be detected from the boot ID even though the journal boot count
# never moves, and the resetting node must be named. This scenario also has the
# flood pod never reaching Ready, which must not abort the measurement.
run_scenario reset 0
grep -q 'RESET DETECTED on node-a: boot boot-a-1 -> boot-a-2' "${TMPDIR}/reset/output"
grep -q 'RESET DETECTED on node-a: boot boot-a-2 -> boot-a-3' "${TMPDIR}/reset/output"
grep -q 'node-a: resets=2' "${TMPDIR}/reset/output"
grep -q 'node-b: resets=0' "${TMPDIR}/reset/output"
grep -q 'total resets observed during test: 2' "${TMPDIR}/reset/output"
grep -q 'Baseline reproduced the reset under overlay load' "${TMPDIR}/reset/output"
grep -q 'flood pod not Ready yet' "${TMPDIR}/reset/output"
! grep -q 'RESET DETECTED on node-b' "${TMPDIR}/reset/output"
# Detection must not shell into the node; that was the slow, rotation-blind path.
! grep -q '^debug node' "${TMPDIR}/reset/oc.log"
# Stale pods are cleared before the run, and the restarting load is stopped after.
test "$(wc -l < "${TMPDIR}/reset/pod-deletes")" -eq 2
grep -q 'Load stopped' "${TMPDIR}/reset/output"

# A stable cluster must not be reported as reproducing the crash.
run_scenario stable 0
grep -q 'total resets observed during test: 0' "${TMPDIR}/stable/output"
grep -q 'Inconclusive' "${TMPDIR}/stable/output"
! grep -q 'RESET DETECTED' "${TMPDIR}/stable/output"

# An unreadable boot ID must fail loudly instead of silently reporting resets=0.
run_scenario unreadable 1
grep -q 'Could not read the boot ID of node-a' "${TMPDIR}/unreadable/output"
! grep -q 'total resets observed' "${TMPDIR}/unreadable/output"
! grep -q '^apply -f -' "${TMPDIR}/unreadable/oc.log"

printf 'mshv-offload-isolation-tests: OK (3 scenarios)\n'
