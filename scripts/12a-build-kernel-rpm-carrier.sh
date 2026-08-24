#!/usr/bin/env bash
# =============================================================================
# 12a-build-kernel-rpm-carrier.sh - Build and push the kernel RPM carrier image
#
# The KERNEL_RPM_SOURCE=local path of the on-cluster RHCOS kernel layer needs the
# locally-provided kernel RPMs inside a container the in-cluster MachineOSConfig
# build can pull. On-cluster builds cannot upload a local build context, so this
# script verifies the staged RPMs against images/rhcos-kernel-layer/
# kernel-rpms.lock.tsv (sha256 + signature), packs them into a minimal `scratch`
# carrier image, and pushes it to the internal OpenShift registry.
#
# RPM binaries are never committed. Stage the signed RPMs in KERNEL_RPM_DIR
# outside this repository.
#
# Usage:
#   KERNEL_RPM_DIR=/abs/path/to/kernel-rpms ./scripts/12a-build-kernel-rpm-carrier.sh
#   PUSH_CARRIER=false KERNEL_RPM_DIR=... ./scripts/12a-build-kernel-rpm-carrier.sh  # build only
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

IMAGE_DIR="${_REPO_ROOT}/images/rhcos-kernel-layer"
LOCK_FILE="${IMAGE_DIR}/kernel-rpms.lock.tsv"
KERNEL_RPM_DIR="${KERNEL_RPM_DIR:?KERNEL_RPM_DIR must point to the external directory containing the signed kernel RPMs}"

MOC_NAMESPACE="${MOC_NAMESPACE:-openshift-machine-config-operator}"
CARRIER_LOCAL_TAG="${CARRIER_LOCAL_TAG:-localhost/aro-virt-validation/kernel-rpm-carrier:latest}"
CARRIER_REPO="${CARRIER_REPO:-${MOC_NAMESPACE}/kernel-rpm-carrier}"
PUSH_CARRIER="${PUSH_CARRIER:-true}"
# Signature verification base image (ships Red Hat GPG keys). Override for el10.
RPM_VERIFY_IMAGE="${RPM_VERIFY_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}"
# Optional directory of extra RPM-GPG public keys to import (e.g. RHEL 10 keys).
RPM_GPG_KEY_DIR="${RPM_GPG_KEY_DIR:-}"

check_command podman || exit 1
check_command sha256sum || exit 1
check_command realpath || exit 1

[[ -d "${KERNEL_RPM_DIR}" ]] || { log_error "KERNEL_RPM_DIR not found: ${KERNEL_RPM_DIR}"; exit 1; }
rpm_dir="$(realpath "${KERNEL_RPM_DIR}")"
[[ "${rpm_dir}" != "${_REPO_ROOT}" && "${rpm_dir}" != "${_REPO_ROOT}"/* ]] || {
  log_error "KERNEL_RPM_DIR must be outside the repository so RPM binaries cannot be committed."
  exit 1
}

# --- Parse the lock file (skip comments/blank lines) -------------------------
mapfile -t lock_lines < <(awk -F '\t' 'NF && $1 !~ /^#/ {print}' "${LOCK_FILE}")
[[ "${#lock_lines[@]}" -ge 1 ]] || {
  log_error "No RPM rows in ${LOCK_FILE}. Fill in one row per kernel RPM (NAME, EPOCH:VERSION-RELEASE, ARCH, sha256)."
  exit 1
}
awk -F '\t' '
  NF && $1 !~ /^#/ {
    if (NF != 4 || seen[$1]++ || $2 !~ /^[0-9]+:.+-.+$/ ||
        $3 !~ /^[a-z0-9_]+$/ || length($4) != 64 || $4 !~ /^[0-9a-f]+$/) {
      print "bad row: " $0 > "/dev/stderr"; exit 1
    }
  }
' "${LOCK_FILE}" || { log_error "Invalid or duplicate RPM lock entry."; exit 1; }

verify_dir="$(mktemp -d)"
context_dir="$(mktemp -d)"
trap 'rm -rf "${verify_dir}" "${context_dir}"' EXIT
mkdir -p "${verify_dir}/rpms" "${context_dir}/rpms"
cp "${IMAGE_DIR}/carrier.Containerfile" "${context_dir}/Containerfile"

for line in "${lock_lines[@]}"; do
  IFS=$'\t' read -r name evr arch sha <<< "${line}"
  version_release="${evr#*:}"
  rpm_file="${rpm_dir}/${name}-${version_release}.${arch}.rpm"
  [[ -f "${rpm_file}" ]] || { log_error "Missing RPM: ${rpm_file}"; exit 1; }
  printf '%s  rpms/%s\n' "${sha}" "${rpm_file##*/}" >> "${verify_dir}/SHA256SUMS"
  cp "${rpm_file}" "${verify_dir}/rpms/"
done
(cd "${verify_dir}" && sha256sum --check SHA256SUMS)
log_ok "All staged kernel RPMs match the locked sha256 digests."

# --- Signature verification in a container that has the Red Hat GPG keys ------
key_mount=()
if [[ -n "${RPM_GPG_KEY_DIR}" ]]; then
  [[ -d "${RPM_GPG_KEY_DIR}" ]] || { log_error "RPM_GPG_KEY_DIR not found: ${RPM_GPG_KEY_DIR}"; exit 1; }
  key_mount=(-v "$(realpath "${RPM_GPG_KEY_DIR}"):/extra-keys:ro,Z")
fi

podman run --rm \
  -v "${verify_dir}/rpms:/rpms:ro,Z" \
  "${key_mount[@]}" \
  --entrypoint /bin/sh \
  "${RPM_VERIFY_IMAGE}" \
  -c '
    set -e
    for k in /etc/pki/rpm-gpg/RPM-GPG-KEY-* /extra-keys/*; do
      [ -f "$k" ] && rpm --import "$k" 2>/dev/null || true
    done
    fail=0
    for f in /rpms/*.rpm; do
      out="$(rpm -Kv "$f")"
      printf "%s\n%s\n" "$f" "$out"
      echo "$out" | grep -qiE "Header V[0-9]+ .* Signature.*: OK" || { echo "UNSIGNED_OR_UNTRUSTED: $f" >&2; fail=1; }
      echo "$out" | grep -qi "digests signatures OK" || { echo "NO_SIGNATURE_OK: $f" >&2; fail=1; }
    done
    exit $fail
  ' | tee "${verify_dir}/rpm-verification.txt"
log_ok "All staged kernel RPMs carry a trusted signature."

# Build from the exact files that passed checksum and signature checks.
cp "${verify_dir}"/rpms/*.rpm "${context_dir}/rpms/"
podman build --pull=never -t "${CARRIER_LOCAL_TAG}" -f "${context_dir}/Containerfile" "${context_dir}"
log_ok "Built carrier image ${CARRIER_LOCAL_TAG}."

if [[ "${PUSH_CARRIER}" != "true" ]]; then
  log_info "PUSH_CARRIER=false; skipping push. Local tag: ${CARRIER_LOCAL_TAG}"
  exit 0
fi

# --- Push to the internal registry via its default route ---------------------
check_command oc || exit 1
oc whoami >/dev/null 2>&1 || { log_error "Not logged in; cannot push to the internal registry."; exit 1; }

log_info "Ensuring the internal image registry default route is exposed..."
oc patch configs.imageregistry.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"defaultRoute":true}}' >/dev/null
route_host=""
for _ in $(seq 1 30); do
  route_host="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || echo '')"
  [[ -n "${route_host}" ]] && break
  sleep 5
done
[[ -n "${route_host}" ]] || { log_error "Internal registry default route did not appear."; exit 1; }
log_ok "Registry route: ${route_host}"

log_info "Logging in to the internal registry..."
oc registry login --registry="${route_host}" --insecure=true >/dev/null 2>&1 \
  || podman login --tls-verify=false -u kubeadmin -p "$(oc whoami -t)" "${route_host}"

carrier_remote="${route_host}/${CARRIER_REPO}:latest"
digest_file="$(mktemp)"
trap 'rm -rf "${verify_dir}" "${context_dir}" "${digest_file}"' EXIT
podman push --tls-verify=false --digestfile="${digest_file}" "${CARRIER_LOCAL_TAG}" "${carrier_remote}"
digest="$(<"${digest_file}")"
log_ok "Pushed carrier to ${carrier_remote} (${digest})."

in_cluster="image-registry.openshift-image-registry.svc:5000/${CARRIER_REPO}@${digest}"
log_info "Use this in-cluster pullspec for the layer:"
printf 'KERNEL_CARRIER_IMAGE=%s\n' "${in_cluster}"
