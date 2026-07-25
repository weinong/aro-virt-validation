#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

IMAGE_DIR="${_REPO_ROOT}/images/hybrid-virt-launcher"
source "${IMAGE_DIR}/images.lock.env"

check_command podman || exit 1

CNV_LAUNCHER_IMAGE="${CNV_LAUNCHER_IMAGE_OVERRIDE:-${CNV_LAUNCHER_IMAGE}}"
UPSTREAM_LAUNCHER_IMAGE="${UPSTREAM_LAUNCHER_IMAGE_OVERRIDE:-${UPSTREAM_LAUNCHER_IMAGE}}"
HYBRID_IMAGE="${HYBRID_IMAGE_OVERRIDE:-${HYBRID_IMAGE}}"

for image in "${CNV_LAUNCHER_IMAGE}" "${UPSTREAM_LAUNCHER_IMAGE}"; do
  if [[ ! "${image}" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
    log_error "Source image must be digest-pinned: ${image}"
    exit 1
  fi
  log_info "Pulling ${image}..."
  podman pull "${image}" >/dev/null
done

log_info "Building ${HYBRID_IMAGE}..."
podman build \
  --pull=never \
  --build-arg "CNV_LAUNCHER_IMAGE=${CNV_LAUNCHER_IMAGE}" \
  --build-arg "UPSTREAM_LAUNCHER_IMAGE=${UPSTREAM_LAUNCHER_IMAGE}" \
  --label "io.kubevirt.upstream-qemu.cnv-source=${CNV_LAUNCHER_IMAGE}" \
  --label "io.kubevirt.upstream-qemu.upstream-source=${UPSTREAM_LAUNCHER_IMAGE}" \
  --tag "${HYBRID_IMAGE}" \
  --file "${IMAGE_DIR}/Containerfile" \
  "${IMAGE_DIR}"

log_ok "Built ${HYBRID_IMAGE}."

if [[ "${PUSH_IMAGE:-false}" == "true" ]]; then
  log_info "Pushing ${HYBRID_IMAGE}..."
  podman push "${HYBRID_IMAGE}"
  log_ok "Pushed ${HYBRID_IMAGE}."
fi

log_info "Verify with: HYBRID_IMAGE_OVERRIDE='${HYBRID_IMAGE}' scripts/10-verify-hybrid-virt-launcher.sh"
