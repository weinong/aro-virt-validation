#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${REPO_ROOT}/images/cnv-qemu-launcher"

grep -qx '/rpms/' "${REPO_ROOT}/.gitignore"

required=(
  "${IMAGE_DIR}/Containerfile"
  "${IMAGE_DIR}/README.md"
  "${IMAGE_DIR}/qemu-rpms.lock.tsv"
  "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
  "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh"
  "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"
  "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
  "${REPO_ROOT}/scripts/08-cnv-validation-checkup.sh"
)

for file in "${required[@]}"; do
  [[ -f "${file}" ]] || { printf 'missing required file: %s\n' "${file}" >&2; exit 1; }
done

[[ "$(awk 'NF && $1 !~ /^#/' "${IMAGE_DIR}/qemu-rpms.lock.tsv" | wc -l)" -eq 8 ]]
awk -F '\t' 'NF && $1 !~ /^#/ {
  if ($2 != "17:10.1.0-17.el9_8.3" || $3 != "x86_64" || length($4) != 64) exit 1
}' "${IMAGE_DIR}/qemu-rpms.lock.tsv"

grep -q 'RHBA-2026:28656' "${IMAGE_DIR}/README.md"
grep -q '^FROM .*@sha256:' "${IMAGE_DIR}/Containerfile"
grep -q 'rpm -Uvh --test' "${IMAGE_DIR}/Containerfile"

if grep -Eq -- '--nodeps|--force|--replacefiles|--replacepkgs|rpm -e' "${IMAGE_DIR}/Containerfile"; then
  printf 'unsafe RPM operation found in Containerfile\n' >&2
  exit 1
fi

grep -q 'rpm -Kv' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
grep -q 'sha256sum --check' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
grep -q 'qemu-kvm-10.1.0-17.el9_8.3.src.rpm' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
grep -q 'QEMU_RPM_DIR must point to the external directory' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
grep -q 'must be outside the repository' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
grep -q 'key ID fd431d51: OK' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
grep -q 'expected-metadata.txt' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"
grep -q 'exact files that passed' "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh"

grep -q 'virt-launcher.sha256' "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh"
grep -q 'libvirt.so.0.sha256' "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh"
grep -q 'OVMF_CODE.fd.sha256' "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh"
grep -q 'Unexpected RPM change outside the eight locked QEMU packages' "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh"
grep -q 'rpm -V' "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh"
grep -q -- '-accel help' "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh"

grep -q 'must be digest-pinned' "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"
grep -q 'active-running' "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"
grep -q 'query-status' "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"
grep -q '"running": true' "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"
grep -q 'ulimit -c 0' "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"
grep -q 'pod_image_id' "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"
grep -q 'Running pod does not contain all eight target QEMU RPMs' "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh"

grep -q 'status|apply|restore' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'ORIGINAL_VIRT_LAUNCHER_IMAGE' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'ORIGINAL_CSV' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'clusterserviceversion' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
if grep -q 'trap .*restore' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"; then
  printf 'override apply must not install an automatic restore trap\n' >&2
  exit 1
fi
grep -q 'virt-handler-init' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'observedDeploymentConfig' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'targetDeploymentConfig' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'CLUSTER_SERVER' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'CSV_UID' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'DEPLOYMENT_UID' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'desiredNumberScheduled' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'APPLIED_VIRT_LAUNCHER_IMAGE' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'HCO_UID' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'ORIGINAL_HCO_JSONPATCH' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'VIRT_LAUNCHER_IMAGE_PULL_SECRET_FILE' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'virt-launcher-image-holder' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'flock -n' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'preconditions.*uid' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'mv -f.*state_file' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'resume_apply' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'is_original_or_applied' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"
grep -q 'refresh_owned_secret' "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh"

grep -q 'USE_QEMU_3_LAUNCHER' "${REPO_ROOT}/scripts/08-cnv-validation-checkup.sh"
grep -q 'QEMU_3_LAUNCHER_IMAGE' "${REPO_ROOT}/scripts/08-cnv-validation-checkup.sh"
grep -q 'QEMU_3_PULL_SECRET_FILE' "${REPO_ROOT}/scripts/08-cnv-validation-checkup.sh"
grep -q '09d-virt-launcher-image-override.sh.*apply' "${REPO_ROOT}/scripts/08-cnv-validation-checkup.sh"
if grep -q '09d-virt-launcher-image-override.sh.*restore' "${REPO_ROOT}/scripts/08-cnv-validation-checkup.sh"; then
  printf 'validation script must leave the launcher override active\n' >&2
  exit 1
fi

grep -q '^restore-qemu-3-launcher:' "${REPO_ROOT}/Makefile"
grep -q 'USE_QEMU_3_LAUNCHER=true' "${REPO_ROOT}/README.md"
grep -q 'remains active' "${REPO_ROOT}/README.md"

bash -n \
  "${REPO_ROOT}/scripts/09a-build-cnv-qemu-launcher.sh" \
  "${REPO_ROOT}/scripts/09b-verify-cnv-qemu-launcher.sh" \
  "${REPO_ROOT}/scripts/09c-cnv-qemu-direct-smoke.sh" \
  "${REPO_ROOT}/scripts/09d-virt-launcher-image-override.sh" \
  "${REPO_ROOT}/scripts/08-cnv-validation-checkup.sh"
