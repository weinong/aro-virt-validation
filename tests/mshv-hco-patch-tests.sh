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
  "patch hco kubevirt-hyperconverged -n openshift-cnv --type=merge -p "*)
    jq -e '.spec.deployment.nodePlacements.workload.nodeSelector == {
      "node-role.kubernetes.io/mshv": ""
    }' <<< "${!#}" >/dev/null
    touch "${TEST_STATE_DIR}/placement-patched"
    ;;
  "get crd kubevirts.kubevirt.io -o json")
    printf '{"spec":{"versions":[{"schema":{"openAPIV3Schema":{"properties":{"spec":{"properties":{"configuration":{"properties":{"hypervisors":{}}}}}}}}}]}}'
    ;;
  "get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.spec.configuration.hypervisors[0].name}") printf 'hyperv-direct' ;;
  "get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.spec.configuration.developerConfiguration.featureGates}") printf '["ConfigurableHypervisor"]' ;;
  "get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o json")
    printf '{"spec":{"workloads":{"nodePlacement":{"nodeSelector":{"node-role.kubernetes.io/mshv":""}}}}}'
    ;;
  "get daemonset/virt-handler -n openshift-cnv -o json")
    touch "${TEST_STATE_DIR}/daemonset-checked"
    if [[ "${TEST_ZERO_DESIRED:-false}" == "true" ]]; then
      status='{"desiredNumberScheduled":0,"numberReady":0}'
    else
      status='{"desiredNumberScheduled":1,"numberReady":1}'
    fi
    printf '{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/mshv":""}}}},"status":%s}' "${status}"
    ;;
  "rollout status daemonset/virt-handler -n openshift-cnv --timeout=300s")
    [[ "${TEST_ROLLOUT_FAIL:-false}" != "true" ]]
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

test -f "${TMPDIR}/state/placement-patched"
test -f "${TMPDIR}/state/daemonset-checked"
grep -q 'workloads are restricted to MSHV nodes' "${TMPDIR}/output"

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
grep -q 'No ready virt-handler pods are scheduled' "${TMPDIR}/zero-desired"

printf 'mshv-hco-patch-tests: PASS\n'
