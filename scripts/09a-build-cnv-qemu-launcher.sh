#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

IMAGE_DIR="${_REPO_ROOT}/images/cnv-qemu-launcher"
LOCK_FILE="${IMAGE_DIR}/qemu-rpms.lock.tsv"
QEMU_RPM_DIR="${QEMU_RPM_DIR:?QEMU_RPM_DIR must point to the external directory containing the eight locked RPMs}"
CNV_QEMU_IMAGE="${CNV_QEMU_IMAGE:-localhost/aro-virt-validation/cnv-qemu-launcher:10.1.0-17.el9_8.3}"

check_command podman || exit 1
check_command sha256sum || exit 1
check_command realpath || exit 1

[[ -d "${QEMU_RPM_DIR}" ]] || { log_error "QEMU_RPM_DIR not found: ${QEMU_RPM_DIR}"; exit 1; }
rpm_dir="$(realpath "${QEMU_RPM_DIR}")"
[[ "${rpm_dir}" != "${_REPO_ROOT}" && "${rpm_dir}" != "${_REPO_ROOT}"/* ]] || {
  log_error "QEMU_RPM_DIR must be outside the repository so RPM binaries cannot be committed."
  exit 1
}

mapfile -t lock_lines < <(awk -F '\t' 'NF && $1 !~ /^#/ {print}' "${LOCK_FILE}")
[[ "${#lock_lines[@]}" -eq 8 ]] || { log_error "Expected 8 locked QEMU RPMs."; exit 1; }
awk -F '\t' '
  NF && $1 !~ /^#/ {
    if (NF != 4 || seen[$1]++ || $2 != "17:10.1.0-17.el9_8.3" ||
        $3 != "x86_64" || length($4) != 64 || $4 !~ /^[0-9a-f]+$/) exit 1
  }
' "${LOCK_FILE}" || { log_error "Invalid or duplicate RPM lock entry."; exit 1; }

verify_dir="$(mktemp -d)"
context_dir="$(mktemp -d)"
trap 'rm -rf "${verify_dir}" "${context_dir}"' EXIT
mkdir -p "${verify_dir}/rpms"
mkdir -p "${context_dir}/rpms"
cp "${IMAGE_DIR}/Containerfile" "${context_dir}/Containerfile"

for line in "${lock_lines[@]}"; do
  IFS=$'\t' read -r name evr arch sha <<< "${line}"
  version_release="${evr#*:}"
  rpm_file="${rpm_dir}/${name}-${version_release}.${arch}.rpm"
  [[ -f "${rpm_file}" ]] || { log_error "Missing RPM: ${rpm_file}"; exit 1; }
  printf '%s  rpms/%s\n' "${sha}" "${rpm_file##*/}" >> "${verify_dir}/SHA256SUMS"
  printf '%s\t%s\t%s\tqemu-kvm-10.1.0-17.el9_8.3.src.rpm\n' \
    "${name}" "${evr}" "${arch}" >> "${verify_dir}/expected-metadata.txt"
  cp "${rpm_file}" "${verify_dir}/rpms/"
done
(cd "${verify_dir}" && sha256sum --check SHA256SUMS)

podman run --rm \
  -v "${verify_dir}/rpms:/rpms:ro,Z" \
  --entrypoint /bin/sh \
  quay.io/openshift-cnv/container-native-virtualization-virt-launcher-rhel9@sha256:2c225da83366eef8b14021181992911eded87fa2f62b94943a2d8f9832dd2f89 \
  -c '
    set -e
    for f in /rpms/*.x86_64.rpm; do
      verification="$(rpm -Kv "$f")"
      printf "%s\n" "$verification"
      case "$verification" in
        *"key ID fd431d51: OK"*) ;;
        *) echo "Unexpected or missing RPM signature: $f" >&2; exit 1 ;;
      esac
      rpm -qp --qf "%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SOURCERPM}\n" "$f"
    done
  ' | tee "${verify_dir}/rpm-verification.txt"

[[ "$(grep -c 'key ID fd431d51: OK' "${verify_dir}/rpm-verification.txt")" -eq 8 ]] || {
  log_error "Not all RPMs have the expected Red Hat signature."
  exit 1
}
grep $'\t' "${verify_dir}/rpm-verification.txt" | LC_ALL=C sort > "${verify_dir}/actual-metadata.txt"
LC_ALL=C sort -o "${verify_dir}/expected-metadata.txt" "${verify_dir}/expected-metadata.txt"
cmp -s "${verify_dir}/expected-metadata.txt" "${verify_dir}/actual-metadata.txt" || {
  log_error "RPM metadata does not match the locked source build."
  exit 1
}

# Build from the exact files that passed checksum, signature, and metadata checks.
cp "${verify_dir}"/rpms/*.rpm "${context_dir}/rpms/"

podman build --pull=never -t "${CNV_QEMU_IMAGE}" -f "${context_dir}/Containerfile" "${context_dir}"
log_ok "Built ${CNV_QEMU_IMAGE}."

if [[ "${PUSH_IMAGE:-false}" == "true" ]]; then
  podman push "${CNV_QEMU_IMAGE}"
  log_ok "Pushed ${CNV_QEMU_IMAGE}."
fi
