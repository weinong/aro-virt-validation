#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

mkdir -p "${TEST_DIR}/scripts" "${TEST_DIR}/bin"
cp "${REPO_ROOT}/Makefile" "${TEST_DIR}/Makefile"

cat > "${TEST_DIR}/scripts/09a-build-cnv-qemu-launcher.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'build\n' >> "${TEST_LOG}"
printf '%s' "${QEMU_RPM_DIR}" > "${RPM_VALUE_FILE}"
printf '%s' "${CNV_QEMU_IMAGE}" > "${IMAGE_VALUE_FILE}"
EOF

cat > "${TEST_DIR}/scripts/09b-verify-cnv-qemu-launcher.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify\n' >> "${TEST_LOG}"
EOF

cat > "${TEST_DIR}/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'push\n' >> "${TEST_LOG}"
[[ "${1:-}" == "push" ]]
digest_file=""
image=""
for argument in "$@"; do
  case "${argument}" in
    --digestfile=*) digest_file="${argument#*=}" ;;
    *) image="${argument}" ;;
  esac
done
[[ -n "${digest_file}" ]]
printf '%s' "${image}" > "${PUSHED_IMAGE_FILE}"
printf '%s\n' "${PODMAN_DIGEST:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" > "${digest_file}"
EOF

chmod +x \
  "${TEST_DIR}/scripts/09a-build-cnv-qemu-launcher.sh" \
  "${TEST_DIR}/scripts/09b-verify-cnv-qemu-launcher.sh" \
  "${TEST_DIR}/bin/podman"

export PATH="${TEST_DIR}/bin:${PATH}"
export TEST_LOG="${TEST_DIR}/commands.log"
export RPM_VALUE_FILE="${TEST_DIR}/rpm-value"
export IMAGE_VALUE_FILE="${TEST_DIR}/image-value"
export PUSHED_IMAGE_FILE="${TEST_DIR}/pushed-image"

malicious_rpm_dir='outside"; touch injected; #'
image='registry.example.com:5000/team/cnv-qemu:testing'
make -s -C "${TEST_DIR}" build-qemu-3-launcher \
  QEMU_RPM_DIR="${malicious_rpm_dir}" CNV_QEMU_IMAGE="${image}"
[[ "$(<"${RPM_VALUE_FILE}")" == "${malicious_rpm_dir}" ]]
[[ "$(<"${IMAGE_VALUE_FILE}")" == "${image}" ]]
[[ ! -e "${TEST_DIR}/injected" ]]
[[ "$(<"${TEST_LOG}")" == $'build\nverify' ]]

: > "${TEST_LOG}"
output="$(make -s -C "${TEST_DIR}" publish-qemu-3-launcher \
  QEMU_RPM_DIR=/external/rpms CNV_QEMU_IMAGE="${image}")"
[[ "${output}" == "QEMU_3_LAUNCHER_IMAGE=registry.example.com:5000/team/cnv-qemu@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]
[[ "$(<"${TEST_LOG}")" == $'build\nverify\npush' ]]
[[ "$(<"${PUSHED_IMAGE_FILE}")" == "${image}" ]]

: > "${TEST_LOG}"
if make -s -C "${TEST_DIR}" publish-qemu-3-launcher \
  QEMU_RPM_DIR=/external/rpms CNV_QEMU_IMAGE=unqualified:testing >/dev/null 2>&1; then
  printf 'unqualified publish image unexpectedly succeeded\n' >&2
  exit 1
fi
[[ ! -s "${TEST_LOG}" ]]

for invalid_image in unqualified:testing team/cnv-qemu:testing 'registry.example.com/team/cnv-qemu@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
  : > "${TEST_LOG}"
  if make -s -C "${TEST_DIR}" publish-qemu-3-launcher \
    QEMU_RPM_DIR=/external/rpms CNV_QEMU_IMAGE="${invalid_image}" >/dev/null 2>&1; then
    printf 'invalid publish image unexpectedly succeeded: %s\n' "${invalid_image}" >&2
    exit 1
  fi
  [[ ! -s "${TEST_LOG}" ]]
done

: > "${TEST_LOG}"
if PODMAN_DIGEST=invalid make -s -C "${TEST_DIR}" publish-qemu-3-launcher \
  QEMU_RPM_DIR=/external/rpms CNV_QEMU_IMAGE="${image}" >/dev/null 2>&1; then
  printf 'invalid registry digest unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(<"${TEST_LOG}")" == $'build\nverify\npush' ]]

printf 'qemu-launcher-make-targets-tests: PASS\n'
