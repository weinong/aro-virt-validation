#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/02a-check-upgrade-target.sh"

if [[ ! -x "${SCRIPT}" ]]; then
  echo "missing executable precheck script: ${SCRIPT}" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${TMPDIR}/bin"

cat > "${TMPDIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "account show --query id -o tsv" ]]; then
  printf '00000000-0000-0000-0000-000000000000\n'
  exit 0
fi
if [[ "$*" == "aro get-versions --location centralus -o json" ]]; then
  printf '["4.20.15"]\n'
  exit 0
fi
printf 'unexpected az args: %s\n' "$*" >&2
exit 2
EOF

cat > "${TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "$url" in
  *channel=candidate-4.22*)
    printf '{"nodes":[{"version":"4.22.3","payload":"quay.io/openshift-release-dev/ocp-release@sha256:%064d"}],"edges":[]}\n' 1
    ;;
  *channel=fast-4.22*)
    printf '{"nodes":[{"version":"4.22.3","payload":"quay.io/openshift-release-dev/ocp-release@sha256:%064d"},{"version":"4.22.4","payload":"quay.io/openshift-release-dev/ocp-release@sha256:%064d"}],"edges":[]}\n' 2 4
    ;;
  *channel=stable-4.22*)
    printf '{"nodes":[{"version":"4.22.2","payload":"quay.io/openshift-release-dev/ocp-release@sha256:%064d"}],"edges":[]}\n' 3
    ;;
  *)
    printf 'unexpected curl url: %s\n' "$url" >&2
    exit 2
    ;;
esac
EOF

chmod +x "${TMPDIR}/bin/az" "${TMPDIR}/bin/curl"

run_precheck() {
  PATH="${TMPDIR}/bin:${PATH}" \
    SKIP_REPO_ENV=true \
    LOCATION=centralus \
    TARGET_OCP_VERSION="$1" \
    UPGRADE_TARGET_CHANNELS="$2" \
    "${SCRIPT}"
}

if run_precheck 4.22.5 'candidate-4.22 fast-4.22 stable-4.22' > "${TMPDIR}/missing.out" 2>&1; then
  echo "expected missing exact target to fail" >&2
  exit 1
fi

grep -q 'Exact target 4.22.5 was not found' "${TMPDIR}/missing.out"

if run_precheck 4.22.4 'candidate-4.22' > "${TMPDIR}/candidate-only.out" 2>&1; then
  echo "expected target present only outside candidate channel to fail" >&2
  exit 1
fi

grep -q 'Exact target 4.22.4 was not found' "${TMPDIR}/candidate-only.out"

if ! run_precheck 4.22.3 'candidate-4.22 fast-4.22 stable-4.22' > "${TMPDIR}/present.out" 2>&1; then
  echo "expected present exact target to pass" >&2
  cat "${TMPDIR}/present.out" >&2
  exit 1
fi

grep -q 'Exact target 4.22.3 found in candidate-4.22' "${TMPDIR}/present.out"
