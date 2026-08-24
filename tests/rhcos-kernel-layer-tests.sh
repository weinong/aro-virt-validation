#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${REPO_ROOT}/images/rhcos-kernel-layer"

required=(
  "${IMAGE_DIR}/Containerfile.copr"
  "${IMAGE_DIR}/Containerfile.local"
  "${IMAGE_DIR}/carrier.Containerfile"
  "${IMAGE_DIR}/kernel-rpms.lock.tsv"
  "${IMAGE_DIR}/README.md"
  "${REPO_ROOT}/scripts/12-rhcos-kernel-layer.sh"
  "${REPO_ROOT}/scripts/12a-build-kernel-rpm-carrier.sh"
  "${REPO_ROOT}/scripts/12b-verify-kernel-layer.sh"
  "${REPO_ROOT}/scripts/12c-rhcos-kernel-layer-out-of-cluster.sh"
)
for file in "${required[@]}"; do
  [[ -f "${file}" ]] || { printf 'missing required file: %s\n' "${file}" >&2; exit 1; }
done

# RPM binaries must never be committed.
grep -qx '/rpms/' "${REPO_ROOT}/.gitignore"

# On-cluster layering: inherit the pool base, never hand-pin osImageURL.
grep -q 'FROM configs AS final' "${IMAGE_DIR}/Containerfile.copr"
grep -q 'FROM configs AS final' "${IMAGE_DIR}/Containerfile.local"
if grep -Eq 'osImageURL' "${REPO_ROOT}/scripts/12-rhcos-kernel-layer.sh"; then
  # Allowed only in comments explaining we do NOT pin it.
  if grep -nE 'osImageURL' "${REPO_ROOT}/scripts/12-rhcos-kernel-layer.sh" | grep -vqiE 'never|not|without|do not|hand'; then
    printf 'scripts/12 appears to set osImageURL\n' >&2
    exit 1
  fi
fi

# Kernel swap must use rpm-ostree override replace + bootc container lint.
grep -q 'rpm-ostree override replace' "${IMAGE_DIR}/Containerfile.copr"
grep -q 'rpm-ostree override replace' "${IMAGE_DIR}/Containerfile.local"
grep -q 'bootc container lint' "${IMAGE_DIR}/Containerfile.copr"
grep -q 'bootc container lint' "${IMAGE_DIR}/Containerfile.local"
grep -q 'COPY --from=rpms' "${IMAGE_DIR}/Containerfile.local"
grep -q '^FROM scratch' "${IMAGE_DIR}/carrier.Containerfile"

# Unsafe RPM operations are not allowed anywhere in the layer definition.
for cf in "${IMAGE_DIR}/Containerfile.copr" "${IMAGE_DIR}/Containerfile.local"; do
  if grep -Eq -- '--nodeps|--force|--replacefiles|--replacepkgs|rpm -e' "${cf}"; then
    printf 'unsafe RPM operation found in %s\n' "${cf}" >&2
    exit 1
  fi
done

# Main script invariants.
main="${REPO_ROOT}/scripts/12-rhcos-kernel-layer.sh"
grep -q 'kind: MachineOSConfig' "${main}"
grep -q 'machineConfigPool' "${main}"
grep -q 'detect_moc_apiversion' "${main}"
grep -q 'wait_for_build' "${main}"
grep -q 'wait_for_mcp' "${main}"
grep -q 'do_revert' "${main}"
# One MachineOSConfig per pool: name must default to the pool name.
grep -q 'MOC_NAME="${MOC_NAME:-${MSHV_MCP_NAME}}"' "${main}"

# Carrier build must verify checksum and signature like the qemu path.
carrier="${REPO_ROOT}/scripts/12a-build-kernel-rpm-carrier.sh"
grep -q 'sha256sum --check' "${carrier}"
grep -q 'rpm -Kv' "${carrier}"
grep -q 'must be outside the repository' "${carrier}"

# Verify script re-checks MSHV/L1VH host state after the kernel swap.
verify="${REPO_ROOT}/scripts/12b-verify-kernel-layer.sh"
grep -q '/dev/mshv' "${verify}"
grep -q 'mshv_root' "${verify}"
grep -q 'running as L1VH partition' "${verify}"
grep -q 'rpm-ostree status' "${verify}"
# Verify script handles both the on-cluster and out-of-cluster (osImageURL) paths.
grep -q 'machineosconfig' "${verify}"
grep -q 'osImageURL' "${verify}"

# Out-of-cluster script builds FROM the resolved base and applies osImageURL.
ooc="${REPO_ROOT}/scripts/12c-rhcos-kernel-layer-out-of-cluster.sh"
grep -q 'rpm-ostree override replace' "${ooc}"
grep -q 'bootc container lint' "${ooc}"
grep -q 'osImageURL' "${ooc}"
grep -q 'sha256sum --check' "${ooc}"
grep -q 'imagedigestmirrorset' "${ooc}"
# Must handle the osImageStream/osImageURL mutual exclusion and restore on revert.
grep -q 'osImageStream' "${ooc}"
grep -q 'original-os-image-stream' "${ooc}"

# The lock file template must parse (comments only is fine as a template).
awk -F '\t' 'NF && $1 !~ /^#/ {
  if (NF != 4 || length($4) != 64) { print "bad lock row: " $0 > "/dev/stderr"; exit 1 }
}' "${IMAGE_DIR}/kernel-rpms.lock.tsv"

# The renderer must produce a valid MachineOSConfig for both sources.
copr_out="$(KERNEL_RPM_SOURCE=copr \
  KERNEL_RPM_URLS='https://example.com/kernel-6.12.0-55.el10.x86_64.rpm' \
  "${main}" render 2>/dev/null)"
grep -q 'kind: MachineOSConfig' <<< "${copr_out}"
grep -q 'rpm-ostree override replace https://example.com/kernel-6.12.0-55.el10.x86_64.rpm' <<< "${copr_out}"

local_out="$(KERNEL_RPM_SOURCE=local \
  KERNEL_CARRIER_IMAGE='image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/kernel-rpm-carrier@sha256:abc' \
  "${main}" render 2>/dev/null)"
grep -q 'FROM image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/kernel-rpm-carrier@sha256:abc AS rpms' <<< "${local_out}"

# A bogus (non-.rpm, non-https) URL must be rejected.
if KERNEL_RPM_SOURCE=copr KERNEL_RPM_URLS='http://evil/x;rm -rf' "${main}" render >/dev/null 2>&1; then
  printf 'renderer accepted a suspicious KERNEL_RPM_URLS value\n' >&2
  exit 1
fi

# Unknown source must be rejected.
if KERNEL_RPM_SOURCE=bogus "${main}" render >/dev/null 2>&1; then
  printf 'renderer accepted an unknown KERNEL_RPM_SOURCE\n' >&2
  exit 1
fi

printf 'rhcos-kernel-layer-tests: OK\n'
