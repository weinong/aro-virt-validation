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

case "$*" in
  "whoami") exit 0 ;;
  "get hco -n openshift-cnv -o jsonpath={.items[0].metadata.name}") printf 'kubevirt-hyperconverged' ;;
  "annotate hco kubevirt-hyperconverged -n openshift-cnv --overwrite "*) exit 0 ;;
  "get hco kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.spec.deployment.nodePlacements.workload}")
    # Fresh cluster: no legacy mshv-only workload placement present.
    printf '' ;;
  "get crd kubevirts.kubevirt.io -o json")
    printf '{"spec":{"versions":[{"schema":{"openAPIV3Schema":{"properties":{"spec":{"properties":{"configuration":{"properties":{"hypervisors":{}}}}}}}}}]}}'
    ;;
  "get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.spec.configuration.hypervisors[0].name}") printf 'hyperv-direct' ;;
  "get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.spec.configuration.developerConfiguration.featureGates}") printf '["ConfigurableHypervisor"]' ;;
  "get nodes -l node-role.kubernetes.io/mshv -o jsonpath={.items[0].metadata.name}") printf 'mshv-node-1' ;;
  "get node mshv-node-1 -o jsonpath={.status.allocatable.devices\.kubevirt\.io/mshv}")
    touch "${TEST_STATE_DIR}/mshv-device-checked"
    if [[ "${TEST_NO_MSHV_DEVICE:-false}" == "true" ]]; then printf '0'; else printf '1k'; fi
    ;;
  "rollout status daemonset/virt-handler -n openshift-cnv --timeout=300s")
    [[ "${TEST_ROLLOUT_FAIL:-false}" != "true" ]]
    ;;
  "get daemonset/virt-handler -n openshift-cnv -o json")
    touch "${TEST_STATE_DIR}/daemonset-checked"
    if [[ "${TEST_ZERO_DESIRED:-false}" == "true" ]]; then
      status='{"desiredNumberScheduled":0,"numberReady":0}'
    else
      status='{"desiredNumberScheduled":4,"numberReady":4}'
    fi
    printf '{"status":%s}' "${status}"
    ;;
  "get pods -n openshift-cnv -l kubevirt.io=virt-handler --field-selector spec.nodeName=mshv-node-1 -o name")
    printf 'pod/virt-handler-abcde\n'
    ;;
  "get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.spec.configuration.hypervisors}") printf '[{"name":"hyperv-direct"}]' ;;
  *) printf 'unexpected oc args: %s\n' "$*" >&2; exit 2 ;;
esac
EOF

chmod +x "${TMPDIR}/bin/az" "${TMPDIR}/bin/oc"
mkdir -p "${TMPDIR}/state"

if ! TEST_STATE_DIR="${TMPDIR}/state" PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true \
  bash "${REPO_ROOT}/scripts/07-mshv-hco-patch.sh" > "${TMPDIR}/output" 2>&1; then
  cat "${TMPDIR}/output" >&2
  exit 1
fi

# The script no longer pins workloads to mshv; it relies on the mshv device
# constraint and verifies virt-handler is ready (incl. on the mshv node).
test -f "${TMPDIR}/state/mshv-device-checked"
test -f "${TMPDIR}/state/daemonset-checked"
grep -q 'advertises devices.kubevirt.io/mshv' "${TMPDIR}/output"
grep -q 'virt-handler is ready' "${TMPDIR}/output"
# It must NOT reintroduce the mshv-only workload nodePlacement.
if grep -qE 'restricted to MSHV nodes' "${TMPDIR}/output"; then
  echo 'script should not pin workloads to mshv nodes' >&2
  exit 1
fi

if TEST_ROLLOUT_FAIL=true TEST_STATE_DIR="${TMPDIR}/state" PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true \
  bash "${REPO_ROOT}/scripts/07-mshv-hco-patch.sh" > "${TMPDIR}/rollout-failure" 2>&1; then
  echo 'expected a failed virt-handler rollout to fail phase 7' >&2
  exit 1
fi
grep -q 'virt-handler rollout did not complete' "${TMPDIR}/rollout-failure"

if TEST_ZERO_DESIRED=true TEST_STATE_DIR="${TMPDIR}/state" PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true \
  bash "${REPO_ROOT}/scripts/07-mshv-hco-patch.sh" > "${TMPDIR}/zero-desired" 2>&1; then
  echo 'expected zero desired virt-handler pods to fail phase 7' >&2
  exit 1
fi
grep -q 'virt-handler pods are not all ready' "${TMPDIR}/zero-desired"

if TEST_NO_MSHV_DEVICE=true TEST_STATE_DIR="${TMPDIR}/state" PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true \
  bash "${REPO_ROOT}/scripts/07-mshv-hco-patch.sh" > "${TMPDIR}/no-device" 2>&1; then
  echo 'expected a missing mshv device to fail phase 7' >&2
  exit 1
fi
grep -q 'does not advertise devices.kubevirt.io/mshv' "${TMPDIR}/no-device"

printf 'mshv-hco-patch-tests: PASS\n'
