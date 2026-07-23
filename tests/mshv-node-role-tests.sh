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
  "whoami") printf 'system:admin\n' ;;
  "get featuregate/cluster -o jsonpath={.spec.featureSet}") printf 'TechPreviewNoUpgrade' ;;
  "get clusterversion version -o jsonpath={.status.conditions[?(@.type==\"Progressing\")].status}") printf 'False' ;;
  "get clusterversion version -o jsonpath={.status.conditions[?(@.type==\"Failing\")].status}") printf 'False' ;;
  "get co -o json") printf '{"items":[]}' ;;
  "get crd clusters.aro.openshift.io") exit 1 ;;
  "get osimagestreams/cluster") exit 0 ;;
  "get osimagestreams/cluster -o json") printf '{"status":{"availableStreams":[{"name":"rhel-10"}]}}' ;;
  "apply -f -")
    manifest="$(cat)"
    if jq -e '.kind == "MachineSet"' <<< "${manifest}" >/dev/null 2>&1; then
      jq -e '.spec.template.spec.metadata.labels == {
        "node-role.kubernetes.io/mshv": "",
        "node-role.kubernetes.io/worker": ""
      }' <<< "${manifest}" >/dev/null
      touch "${TEST_STATE_DIR}/machineset-created"
    fi
    printf 'applied\n'
    ;;
  "get mcp mshv -o jsonpath={.status.configuration.name}") printf 'rendered-mshv-test' ;;
  "get machineset.machine.openshift.io -n openshift-machine-api -o jsonpath={range .items[?(@.spec.replicas>0)]}{.metadata.name}{\"\\n\"}{end}") printf 'test-worker\n' ;;
  "get machineset.machine.openshift.io test-worker -n openshift-machine-api -o jsonpath={.metadata.labels.machine\\.openshift\\.io/cluster-api-cluster}") printf 'test-cluster' ;;
  "get machineset.machine.openshift.io test-cluster-worker-mshv-centralus1 -n openshift-machine-api")
    [[ "${TEST_MACHINESET_EXISTS}" == "true" ]]
    ;;
  "get machineset.machine.openshift.io test-worker -n openshift-machine-api -o json")
    printf '{"apiVersion":"machine.openshift.io/v1beta1","kind":"MachineSet","metadata":{"labels":{"machine.openshift.io/cluster-api-cluster":"test-cluster"}},"spec":{"replicas":1,"selector":{"matchLabels":{}},"template":{"metadata":{"labels":{}},"spec":{"providerSpec":{"value":{"osDisk":{},"tags":{}}}}}}}'
    ;;
  "patch machineset.machine.openshift.io test-cluster-worker-mshv-centralus1 -n openshift-machine-api --type=merge -p "*)
    [[ "$*" == *'node-role.kubernetes.io/mshv'* ]]
    [[ "$*" == *'node-role.kubernetes.io/worker'* ]]
    touch "${TEST_STATE_DIR}/machineset-patched"
    ;;
  "scale machineset.machine.openshift.io test-cluster-worker-mshv-centralus1 -n openshift-machine-api --replicas=1") exit 0 ;;
  "get machineset.machine.openshift.io test-cluster-worker-mshv-centralus1 -n openshift-machine-api -o jsonpath={.status.readyReplicas}") printf '1' ;;
  "get machine.machine.openshift.io -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset=test-cluster-worker-mshv-centralus1 -o jsonpath={.items[0].status.nodeRef.name}") printf 'mshv-node' ;;
  "get node mshv-node -o json")
    case "${TEST_NODE_ROLES}" in
      both) printf '{"metadata":{"labels":{"node-role.kubernetes.io/mshv":"","node-role.kubernetes.io/worker":""}}}' ;;
      mshv) printf '{"metadata":{"labels":{"node-role.kubernetes.io/mshv":""}}}' ;;
      worker) printf '{"metadata":{"labels":{"node-role.kubernetes.io/worker":""}}}' ;;
    esac
    ;;
  "get node mshv-node --show-labels") printf 'mshv-node labels\n' ;;
  "get mcp mshv -o jsonpath={.status.machineCount}") printf '1' ;;
  "get mcp mshv -o jsonpath={.status.conditions[?(@.type==\"Updated\")].status}") printf 'True' ;;
  "get mcp mshv -o jsonpath={.status.conditions[?(@.type==\"Updating\")].status}") printf 'False' ;;
  "get mcp mshv -o jsonpath={.status.conditions[?(@.type==\"Degraded\")].status}") printf 'False' ;;
  "debug node/mshv-node -- chroot /host bash -c "*)
    [[ "$*" == *'grep -q "^mshv_root" /proc/modules'* ]]
    [[ "$*" == *'dmesg | grep "running as L1VH partition" >/dev/null'* ]]
    [[ "$*" != *'lsmod | grep -q'* ]]
    [[ "$*" != *'dmesg | grep -q'* ]]
    exit 0
    ;;
  *) printf 'unexpected oc args: %s\n' "$*" >&2; exit 2 ;;
esac
EOF

chmod +x "${TMPDIR}/bin/az" "${TMPDIR}/bin/oc"

run_scenario() {
  local state_dir="${TMPDIR}/$1-$2"
  mkdir -p "${state_dir}"
  TEST_NODE_ROLES="$1" TEST_MACHINESET_EXISTS="$2" TEST_STATE_DIR="${state_dir}" \
    PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true \
    bash "${REPO_ROOT}/scripts/04-mshv-node-setup.sh"
}

if ! run_scenario both true > "${TMPDIR}/both.out" 2>&1; then
  echo 'expected a node with mshv and worker roles to pass role validation' >&2
  cat "${TMPDIR}/both.out" >&2
  exit 1
fi
grep -q 'worker and mshv roles required by the custom MachineConfigPool' "${TMPDIR}/both.out"
test -f "${TMPDIR}/both-true/machineset-patched"

if ! run_scenario both false > "${TMPDIR}/create.out" 2>&1; then
  echo 'expected a newly created MachineSet to include both node roles' >&2
  cat "${TMPDIR}/create.out" >&2
  exit 1
fi
test -f "${TMPDIR}/both-false/machineset-created"

if run_scenario mshv true > "${TMPDIR}/mshv.out" 2>&1; then
  echo 'expected a node without the worker role to fail validation' >&2
  exit 1
fi
grep -q 'missing node-role.kubernetes.io/worker' "${TMPDIR}/mshv.out"

if run_scenario worker true > "${TMPDIR}/worker.out" 2>&1; then
  echo 'expected a node without the mshv role to fail validation' >&2
  exit 1
fi
grep -q 'missing node-role.kubernetes.io/mshv' "${TMPDIR}/worker.out"
