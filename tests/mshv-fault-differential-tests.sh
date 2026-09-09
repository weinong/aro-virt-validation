#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
mkdir -p "${TMPDIR}/bin"

cat > "${TMPDIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
touch "${TEST_STATE_DIR}/unexpected-az"; exit 2
EOF

# node-a resets during the 2nd poll of every "overlay" block and never otherwise,
# so the harness must attribute resets to the right arm.
cat > "${TMPDIR}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_STATE_DIR}/oc.log"
case "$*" in
  "--request-timeout=30s get nodes -l node-role.kubernetes.io/mshv -o jsonpath="*)
    printf 'node-a\nnode-b\n' ;;
  "--request-timeout=30s get node/node-a -o jsonpath={.status.nodeInfo.bootID}")
    arm="$(cat "${TEST_STATE_DIR}/arm" 2>/dev/null || echo none)"
    n=0; [[ ! -f "${TEST_STATE_DIR}/polls" ]] || n="$(<"${TEST_STATE_DIR}/polls")"
    n=$((n+1)); printf '%s' "$n" > "${TEST_STATE_DIR}/polls"
    if [[ "$arm" == "overlay" && "$n" -ge 2 ]]; then printf 'boot-a-2'; else printf 'boot-a-1'; fi ;;
  "--request-timeout=30s get node/node-b -o jsonpath={.status.nodeInfo.bootID}") printf 'boot-b-1' ;;
  "--request-timeout=30s get node/node-a -o jsonpath={.status.conditions[?(@.type==\"Ready\")].status}"|\
  "--request-timeout=30s get node/node-b -o jsonpath={.status.conditions[?(@.type==\"Ready\")].status}")
    printf 'True' ;;
  "--request-timeout=30s create ns mshv-fault-diff --dry-run=client -o yaml") printf 'kind: Namespace\n' ;;
  "--request-timeout=30s apply -f -")
    manifest="$(cat)"
    printf '%s\n' "${manifest}" >> "${TEST_STATE_DIR}/manifests.yaml"
    printf 'applied\n' ;;
  "--request-timeout=30s label ns "*) printf 'labeled\n' ;;
  "--request-timeout=30s -n mshv-fault-diff wait --for=condition=Ready pod/sink --timeout=180s"|\
  "--request-timeout=30s -n mshv-fault-diff wait --for=condition=Ready pod/flood --timeout=180s")
    printf 'ready\n' ;;
  "--request-timeout=30s -n mshv-fault-diff get pod sink -o jsonpath={.status.podIP}") printf '10.0.0.9' ;;
  "--request-timeout=30s -n mshv-fault-diff delete pod sink flood --ignore-not-found --timeout=120s")
    printf 'deleted\n' ;;
  "debug node/node-a --quiet --request-timeout=30s -- chroot /host bash -c "*|\
  "debug node/node-b --quiet --request-timeout=30s -- chroot /host bash -c "*)
    if [[ "$*" == *"ethtool -K"* ]]; then
      printf '%s\n' "$*" | grep -o 'gso [a-z]*' | head -1 >> "${TEST_STATE_DIR}/offload-cmds"
    fi
    printf 'eth0=on,\n' ;;
  *) touch "${TEST_STATE_DIR}/unexpected-oc"; printf 'unexpected: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "${TMPDIR}/bin/oc" "${TMPDIR}/bin/az"

STATE="${TMPDIR}/state"; mkdir -p "${STATE}"
RESULTS="${TMPDIR}/results.tsv"
run_arms() {
  TEST_STATE_DIR="${STATE}" PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true SUBSCRIPTION_ID=test \
    env ARMS="$1" ROUNDS=1 BLOCK_SECONDS=2 POLL=1 STREAMS=2 RESULTS="${RESULTS}" \
    bash "${REPO_ROOT}/scripts/18-mshv-fault-differential.sh" run > "${STATE}/out-$1" 2>&1
}

# Each arm runs separately so the mock can key on it.
for arm in overlay hostnet nogso; do
  rm -f "${STATE}/polls"; printf '%s' "${arm}" > "${STATE}/arm"
  run_arms "${arm}"
done

test ! -f "${STATE}/unexpected-oc"
test ! -f "${STATE}/unexpected-az"

# Resets must be attributed to the arm that was running.
awk -F'\t' 'NR>1 && $3=="overlay" && $5>0 {found=1} END {exit !found}' "${RESULTS}" \
  || { echo "expected overlay to record resets" >&2; cat "${RESULTS}" >&2; exit 1; }
awk -F'\t' 'NR>1 && $3!="overlay" && $5>0 {bad=1} END {exit bad}' "${RESULTS}" \
  || { echo "non-overlay arms must not record resets" >&2; cat "${RESULTS}" >&2; exit 1; }

# hostnet must actually use host networking; overlay must not.
python3 - "${STATE}/manifests.yaml" <<'MANIFEST'
import sys
m = open(sys.argv[1]).read()
assert "hostNetwork: true" in m, "hostnet arm must set hostNetwork: true"
assert "hostNetwork: false" in m, "overlay/nogso arms must set hostNetwork: false"
# Load pods must survive their node crashing, or the block measures an idle cluster.
assert "restartPolicy: Always" in m, m
MANIFEST

# nogso must disable offloads; the other arms must re-enable them, because a
# reboot restores defaults and a stale "off" would contaminate later blocks.
grep -q 'gso off' "${STATE}/offload-cmds"
grep -q 'gso on'  "${STATE}/offload-cmds"

printf 'mshv-fault-differential-tests: OK (3 arms)\n'
