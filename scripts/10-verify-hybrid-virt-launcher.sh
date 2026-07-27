#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

IMAGE_DIR="${_REPO_ROOT}/images/hybrid-virt-launcher"
source "${IMAGE_DIR}/images.lock.env"

check_command podman || exit 1

HYBRID_IMAGE="${HYBRID_IMAGE_OVERRIDE:-${HYBRID_IMAGE}}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${_REPO_ROOT}/.smoke-runs/$(date -u +%Y%m%dT%H%M%S)-hybrid-virt-launcher}"
mkdir -p "${ARTIFACT_DIR}"

podman image inspect "${HYBRID_IMAGE}" > "${ARTIFACT_DIR}/image-inspect.json"

podman run --rm --entrypoint /bin/sh "${HYBRID_IMAGE}" -c \
  'sha256sum /usr/libexec/qemu-kvm' > "${ARTIFACT_DIR}/current-qemu.sha256"
podman run --rm --entrypoint /bin/sh "${HYBRID_IMAGE}" -c \
  'sha256sum /opt/qemu-upstream/rootfs/usr/libexec/qemu-kvm' > "${ARTIFACT_DIR}/upstream-qemu.sha256"

CURRENT_QEMU_HASH="$(awk '{print $1}' "${ARTIFACT_DIR}/current-qemu.sha256")"
UPSTREAM_QEMU_HASH="$(awk '{print $1}' "${ARTIFACT_DIR}/upstream-qemu.sha256")"
if [[ "${CURRENT_QEMU_HASH}" == "${UPSTREAM_QEMU_HASH}" ]]; then
  log_error "Current and upstream QEMU hashes unexpectedly match."
  exit 1
fi

podman run --rm --entrypoint /opt/qemu-upstream/bin/qemu-kvm \
  --user 107:107 --cap-drop=all --security-opt=no-new-privileges \
  "${HYBRID_IMAGE}" --version | tee "${ARTIFACT_DIR}/upstream-version.txt"
podman run --rm --entrypoint /opt/qemu-upstream/bin/qemu-kvm \
  --user 107:107 --cap-drop=all --security-opt=no-new-privileges \
  "${HYBRID_IMAGE}" -accel help | tee "${ARTIFACT_DIR}/upstream-accelerators.txt"

grep -q '^mshv$' "${ARTIFACT_DIR}/upstream-accelerators.txt" || {
  log_error "Upstream QEMU does not advertise mshv."
  exit 1
}

printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' \
  | timeout 30 podman run --rm --interactive \
    --entrypoint /opt/qemu-upstream/bin/qemu-kvm \
    --user 107:107 --cap-drop=all --security-opt=no-new-privileges \
    "${HYBRID_IMAGE}" -nodefaults -display none -machine q35,accel=tcg \
    -device virtio-vga -S -qmp stdio \
  > "${ARTIFACT_DIR}/upstream-module-probe.txt"

podman run --rm --entrypoint /bin/sh \
  --user 107:107 --cap-drop=all --security-opt=no-new-privileges \
  "${HYBRID_IMAGE}" -c '
    /opt/qemu-upstream/bin/qemu-kvm -machine q35,accel=tcg -cpu Westmere \
      -m 128 -smp 1 -nodefaults -display none -S &
    pid=$!
    sleep 1
    set +e
    grep / "/proc/${pid}/maps"
    rc=$?
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    exit "${rc}"
  ' > "${ARTIFACT_DIR}/upstream-library-maps.txt"

if ! grep -q '/opt/qemu-upstream/rootfs/usr/lib64/' "${ARTIFACT_DIR}/upstream-library-maps.txt"; then
  log_error "Upstream QEMU did not load libraries from its private runtime."
  exit 1
fi

if grep -Eq '[[:space:]]/(usr/)?lib64/' "${ARTIFACT_DIR}/upstream-library-maps.txt"; then
  log_error "Upstream QEMU mixed host-image libraries into its private runtime."
  exit 1
fi

podman run --rm --entrypoint /bin/sh "${HYBRID_IMAGE}" -c \
  '/opt/qemu-upstream/bin/qemu-kvm -machine help | grep -E "^(q35|pc-i440fx)"' \
  > "${ARTIFACT_DIR}/upstream-machines.txt"

log_ok "Hybrid image verified. Artifacts: ${ARTIFACT_DIR}"
