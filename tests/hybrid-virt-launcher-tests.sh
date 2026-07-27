#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${REPO_ROOT}/images/hybrid-virt-launcher"

for file in \
  "${IMAGE_DIR}/Containerfile" \
  "${IMAGE_DIR}/README.md" \
  "${IMAGE_DIR}/images.lock.env" \
  "${IMAGE_DIR}/upstream-qemu-kvm" \
  "${REPO_ROOT}/scripts/09-build-hybrid-virt-launcher.sh" \
  "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh" \
  "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"; do
  [[ -f "${file}" ]] || { printf 'missing required file: %s\n' "${file}" >&2; exit 1; }
done

source "${IMAGE_DIR}/images.lock.env"

[[ "${CNV_LAUNCHER_IMAGE}" == *@sha256:* ]]
[[ "${UPSTREAM_LAUNCHER_IMAGE}" == *@sha256:* ]]
[[ "${CNV_LAUNCHER_IMAGE}" != *':latest' ]]
[[ "${UPSTREAM_LAUNCHER_IMAGE}" != *':latest' ]]

grep -q '^FROM .* AS upstream-qemu$' "${IMAGE_DIR}/Containerfile"
grep -q '^FROM .* AS cnv-launcher$' "${IMAGE_DIR}/Containerfile"
grep -q '/opt/qemu-upstream/rootfs/usr/lib64' "${IMAGE_DIR}/Containerfile"
grep -q '/opt/qemu-upstream/rootfs/usr/libexec/qemu-kvm' "${IMAGE_DIR}/Containerfile"
grep -q 'ENTRYPOINT' "${IMAGE_DIR}/Containerfile"

grep -q 'ld-linux-x86-64.so.2' "${IMAGE_DIR}/upstream-qemu-kvm"
grep -q 'QEMU_MODULE_DIR' "${IMAGE_DIR}/upstream-qemu-kvm"
grep -q 'usr/share/qemu-kvm' "${IMAGE_DIR}/upstream-qemu-kvm"

grep -q -- '--user 107:107' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q -- '-accel help' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q 'current-qemu.sha256' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q 'upstream-qemu.sha256' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q 'upstream-library-maps.txt' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q '/opt/qemu-upstream/rootfs/usr/lib64/' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q '\[\[:space:\]\].*/.*lib64/' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q -- '--interactive' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q 'timeout 30 podman run' "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh"
grep -q 'PUSH_IMAGE' "${REPO_ROOT}/scripts/09-build-hybrid-virt-launcher.sh"
grep -q 'podman push' "${REPO_ROOT}/scripts/09-build-hybrid-virt-launcher.sh"

grep -q 'trap .*cleanup.*EXIT' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'namespace_created=true' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'must be digest-pinned' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'automountServiceAccountToken: false' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'devices.kubevirt.io/mshv' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'HYBRID_IMAGE_PULL_SECRET_FILE' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'imagePullSecrets' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'upstream-paused' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'upstream-running' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'current-running' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'assert_probe' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'upstream-paused-library-maps.txt' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
grep -q 'ulimit -c 0' "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"

grep -q 'Diagnostic only' "${IMAGE_DIR}/README.md"
grep -q 'does not replace' "${IMAGE_DIR}/README.md"

bash -n \
  "${IMAGE_DIR}/upstream-qemu-kvm" \
  "${REPO_ROOT}/scripts/09-build-hybrid-virt-launcher.sh" \
  "${REPO_ROOT}/scripts/10-verify-hybrid-virt-launcher.sh" \
  "${REPO_ROOT}/scripts/11-hybrid-virt-launcher-smoke.sh"
