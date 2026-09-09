#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

command -v jq >/dev/null
mkdir -p "${TMPDIR}/bin"

cat > "${TMPDIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
touch "${TEST_STATE_DIR}/unexpected-az"
exit 2
EOF

cat > "${TMPDIR}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_STATE_DIR}/oc.log"
case "$*" in
  "--request-timeout=30s whoami") printf 'system:admin\n' ;;
  "--request-timeout=30s get mcp mshv") printf 'mshv\n' ;;
  "--request-timeout=30s wait mcp/mshv --for=condition=Updated=True --timeout=45m")
    printf 'condition met\n'
    ;;
  "--request-timeout=30s apply -f -")
    cat > "${TEST_STATE_DIR}/manifest.yaml"
    printf 'applied\n'
    ;;
  "--request-timeout=30s get nodes -l node-role.kubernetes.io/mshv -o jsonpath="*)
    printf 'node-a\n'
    ;;
  "debug node/node-a --quiet --request-timeout=30s -- chroot /host bash -c "*)
    # Emulate the node probe used by cmd_verify.
    if [[ "${TEST_ARMED}" == "true" ]]; then
      printf 'cmdline_crashkernel=crashkernel=8G,high,\nkexec_crash_size=8858370048\nkexec_crash_loaded=1\nkdump_enabled=enabled\nkdump_active=active\nvmcore_path=/var/crash\nvar_crash_free=219G\n'
    else
      printf 'cmdline_crashkernel=\nkexec_crash_size=0\nkexec_crash_loaded=0\nkdump_enabled=disabled\nkdump_active=inactive\nvmcore_path=/var/crash\nvar_crash_free=219G\n'
    fi
    ;;
  *)
    touch "${TEST_STATE_DIR}/unexpected-oc"
    printf 'unexpected oc args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${TMPDIR}/bin/oc" "${TMPDIR}/bin/az"

run() {
  local name="$1" armed="$2" expected="$3"; shift 3
  local state_dir="${TMPDIR}/${name}"; mkdir -p "${state_dir}"
  local status=0
  TEST_ARMED="${armed}" TEST_STATE_DIR="${state_dir}" \
    PATH="${TMPDIR}/bin:${PATH}" SKIP_REPO_ENV=true SUBSCRIPTION_ID=test ROLLOUT_SETTLE_SECONDS=1 \
    env "$@" bash "${REPO_ROOT}/scripts/16-mshv-kdump.sh" "${ACTION}" \
      > "${state_dir}/output" 2>&1 || status=$?
  if [[ "${status}" -ne "${expected}" ]]; then
    printf '%s: expected exit %s, got %s\n' "${name}" "${expected}" "${status}" >&2
    cat "${state_dir}/output" >&2; exit 1
  fi
  test ! -f "${state_dir}/unexpected-oc"
  test ! -f "${state_dir}/unexpected-az"
}

# --- verify -------------------------------------------------------------
ACTION=verify
run verify-armed true 0
grep -q 'kdump armed on all mshv nodes' "${TMPDIR}/verify-armed/output"

# An unarmed node must fail loudly: a panic there yields no vmcore, and silently
# "succeeding" would let us wait forever for a dump that can never appear.
run verify-unarmed false 1
grep -q 'crash kernel is NOT armed' "${TMPDIR}/verify-unarmed/output"

# --- enable -------------------------------------------------------------
ACTION=enable
run enable-default true 0
MANIFEST="${TMPDIR}/enable-default/manifest.yaml"

grep -q 'crashkernel=2G,high' "${MANIFEST}"
grep -q 'crashkernel=256M,low' "${MANIFEST}"
grep -q 'name: kdump.service' "${MANIFEST}"
grep -q 'enabled: true' "${MANIFEST}"
grep -q 'machineconfiguration.openshift.io/role: mshv' "${MANIFEST}"

# The collector must be a single word: kdump.sh expands $CORE_COLLECTOR
# unquoted, so a quoted inline wrapper is word-split and dies instantly.
python3 - "${MANIFEST}" <<'PY'
import base64, re, sys
m = open(sys.argv[1]).read()
files = dict(re.findall(r'- path: (\S+).*?base64,([A-Za-z0-9+/=]+)"', m, re.S))
conf = base64.b64decode(files['/etc/kdump.conf']).decode()
wrap = base64.b64decode(files['/usr/local/bin/kdump-collect']).decode()

cc = [l for l in conf.splitlines() if l.startswith('core_collector')]
assert len(cc) == 1, conf
assert cc[0].split() == ['core_collector', '/usr/local/bin/kdump-collect'], cc
assert 'extra_bins /usr/local/bin/kdump-collect' in conf, conf
assert 'path /var/crash' in conf, conf

# --non-mmap is what stops makedumpfile taking SIGSEGV on unreadable pages.
assert '--non-mmap' in wrap, wrap
# The wrapper must persist the log and preserve makedumpfile's exit code,
# otherwise kdump renames a truncated vmcore-incomplete to vmcore.
assert 'makedumpfile.log' in wrap, wrap
assert 'exit $rc' in wrap, wrap
print("manifest OK")
PY
grep -q 'manifest OK' "${TMPDIR}/enable-default/output" 2>/dev/null || true

# Overrides must reach the manifest.
ACTION=enable
run enable-override true 0 CRASHKERNEL_HIGH=16G CORE_COLLECTOR="makedumpfile --non-mmap -E -d 31"
grep -q 'crashkernel=16G,high' "${TMPDIR}/enable-override/manifest.yaml"
python3 - "${TMPDIR}/enable-override/manifest.yaml" <<'PY'
import base64, re, sys
m=open(sys.argv[1]).read()
files=dict(re.findall(r'- path: (\S+).*?base64,([A-Za-z0-9+/=]+)"', m, re.S))
wrap=base64.b64decode(files['/usr/local/bin/kdump-collect']).decode()
assert '-E -d 31' in wrap, wrap
PY

printf 'mshv-kdump-tests: OK (4 scenarios)\n'
