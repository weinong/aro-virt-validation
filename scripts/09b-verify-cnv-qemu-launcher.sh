#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

BASE_IMAGE="quay.io/openshift-cnv/container-native-virtualization-virt-launcher-rhel9@sha256:2c225da83366eef8b14021181992911eded87fa2f62b94943a2d8f9832dd2f89"
CNV_QEMU_IMAGE="${CNV_QEMU_IMAGE:-localhost/aro-virt-validation/cnv-qemu-launcher:10.1.0-17.el9_8.3}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${_REPO_ROOT}/.smoke-runs/$(date -u +%Y%m%dT%H%M%S)-cnv-qemu-launcher-verify}"
mkdir -p "${ARTIFACT_DIR}"

check_command podman || exit 1

podman run --rm --entrypoint /bin/sh "${BASE_IMAGE}" -c \
  "rpm -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' | sort" \
  > "${ARTIFACT_DIR}/base-rpms.txt"
podman run --rm --entrypoint /bin/sh "${CNV_QEMU_IMAGE}" -c \
  "rpm -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' | sort" \
  > "${ARTIFACT_DIR}/derived-rpms.txt"
awk -F '\t' '$1 !~ /^(qemu-img|qemu-kvm-common|qemu-kvm-core|qemu-kvm-device-display-virtio-gpu|qemu-kvm-device-display-virtio-gpu-pci|qemu-kvm-device-display-virtio-vga|qemu-kvm-device-usb-host|qemu-kvm-device-usb-redirect)$/ {print}' \
  "${ARTIFACT_DIR}/base-rpms.txt" > "${ARTIFACT_DIR}/base-unchanged-rpms.txt"
awk -F '\t' '$1 !~ /^(qemu-img|qemu-kvm-common|qemu-kvm-core|qemu-kvm-device-display-virtio-gpu|qemu-kvm-device-display-virtio-gpu-pci|qemu-kvm-device-display-virtio-vga|qemu-kvm-device-usb-host|qemu-kvm-device-usb-redirect)$/ {print}' \
  "${ARTIFACT_DIR}/derived-rpms.txt" > "${ARTIFACT_DIR}/derived-unchanged-rpms.txt"
cmp -s "${ARTIFACT_DIR}/base-unchanged-rpms.txt" "${ARTIFACT_DIR}/derived-unchanged-rpms.txt" || {
  log_error "Unexpected RPM change outside the eight locked QEMU packages."
  exit 1
}

hash_file() {
  local image="$1" path="$2" output="$3"
  podman run --rm --entrypoint /bin/sh "${image}" -c "sha256sum '${path}'" > "${output}"
}

for spec in \
  '/usr/bin/virt-launcher:virt-launcher.sha256' \
  '/usr/bin/virt-launcher-monitor:virt-launcher-monitor.sha256' \
  '/usr/lib64/libvirt.so.0:libvirt.so.0.sha256' \
  '/usr/lib64/libvirt-qemu.so.0:libvirt-qemu.so.0.sha256' \
  '/etc/libvirt/qemu.conf:qemu.conf.sha256' \
  '/etc/libvirt/virtqemud.conf:virtqemud.conf.sha256' \
  '/usr/share/edk2/ovmf/OVMF_CODE.fd:OVMF_CODE.fd.sha256'; do
  IFS=: read -r path name <<< "${spec}"
  hash_file "${BASE_IMAGE}" "${path}" "${ARTIFACT_DIR}/base-${name}"
  hash_file "${CNV_QEMU_IMAGE}" "${path}" "${ARTIFACT_DIR}/derived-${name}"
  [[ "$(awk '{print $1}' "${ARTIFACT_DIR}/base-${name}")" == "$(awk '{print $1}' "${ARTIFACT_DIR}/derived-${name}")" ]] || {
    log_error "Unexpected change outside QEMU RPMs: ${path}"
    exit 1
  }
done

podman run --rm --entrypoint /bin/sh "${CNV_QEMU_IMAGE}" -c '
  set -e
  packages="qemu-img qemu-kvm-common qemu-kvm-core qemu-kvm-device-display-virtio-gpu qemu-kvm-device-display-virtio-gpu-pci qemu-kvm-device-display-virtio-vga qemu-kvm-device-usb-host qemu-kvm-device-usb-redirect"
  rpm -q --qf "%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SOURCERPM}\n" ${packages}
  rpm -V ${packages}
  ldd /usr/libexec/qemu-kvm | tee /tmp/ldd.txt
  ! grep -q "not found" /tmp/ldd.txt
  /usr/libexec/qemu-kvm --version
  /usr/libexec/qemu-kvm -accel help | grep -x mshv
  qemu-img --version
' | tee "${ARTIFACT_DIR}/derived-verification.txt"

[[ "$(grep -c $'\t17:10.1.0-17.el9_8.3\tx86_64\tqemu-kvm-10.1.0-17.el9_8.3.src.rpm$' "${ARTIFACT_DIR}/derived-verification.txt")" -eq 8 ]] || {
  log_error "Derived image does not contain all eight target QEMU RPMs."
  exit 1
}

podman image inspect "${CNV_QEMU_IMAGE}" > "${ARTIFACT_DIR}/image-inspect.json"
log_ok "Derived launcher verified. Artifacts: ${ARTIFACT_DIR}"
