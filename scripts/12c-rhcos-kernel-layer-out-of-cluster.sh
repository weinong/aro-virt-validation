#!/usr/bin/env bash
# =============================================================================
# 12c-rhcos-kernel-layer-out-of-cluster.sh - Day-2 kernel layer via osImageURL
#
# The on-cluster MachineOSConfig path (scripts/12) is blocked on ARO 4.22: the
# MCO build pod's buildah cannot satisfy the `openshift` ClusterImagePolicy
# signature requirement for the release base image pulled from the ARO mirror
# (sigstore attachment lookup is disabled in the build).
# See issues/2026-08-24b-oncluster-layering-signature.md.
#
# This script uses the documented out-of-cluster layering method instead:
#   1. Resolve the mshv pool's rhel-10 base image from its rendered MachineConfig.
#   2. Build the layered image locally with podman FROM that base (pulled through
#      the cluster's ImageDigestMirrorSet mirror using the cluster global pull
#      secret), swapping the kernel with rpm-ostree override replace.
#   3. Push the result to the internal registry.
#   4. Apply a MachineConfig for the mshv role that sets osImageURL to the built
#      image, so the MCO rolls it out to the mshv node(s).
#
# Building outside the cluster avoids the in-build ClusterImagePolicy check, and
# the node pulls the final image from our own repo (not a signed release scope).
#
# Usage:
#   KERNEL_RPM_DIR=/abs/path ./scripts/12c-rhcos-kernel-layer-out-of-cluster.sh apply
#   ./scripts/12c-rhcos-kernel-layer-out-of-cluster.sh revert
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

IMAGE_DIR="${_REPO_ROOT}/images/rhcos-kernel-layer"
LOCK_FILE="${IMAGE_DIR}/kernel-rpms.lock.tsv"

ACTION="${1:-apply}"

MSHV_MCP_NAME="${MSHV_MCP_NAME:-mshv}"
MC_NAME="${MC_NAME:-99-${MSHV_MCP_NAME}-kernel-osimage}"
MOC_NAMESPACE="${MOC_NAMESPACE:-openshift-machine-config-operator}"
OSIMAGE_REPO="${OSIMAGE_REPO:-${MOC_NAMESPACE}/mshv-kernel-osimage}"
OSIMAGE_LOCAL_TAG="${OSIMAGE_LOCAL_TAG:-localhost/aro-virt-validation/mshv-kernel-osimage:l1vh}"
ALLOW_UNSIGNED_KERNEL_RPMS="${ALLOW_UNSIGNED_KERNEL_RPMS:-false}"
RPM_VERIFY_IMAGE="${RPM_VERIFY_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}"
RPM_GPG_KEY_DIR="${RPM_GPG_KEY_DIR:-}"
MCP_TIMEOUT="${MCP_TIMEOUT:-3600}"

check_command oc || exit 1
check_command jq || exit 1

do_revert() {
  log_info "=== Reverting the out-of-cluster kernel layer on the ${MSHV_MCP_NAME} pool ==="
  if ! oc get mc "${MC_NAME}" &>/dev/null; then
    log_ok "MachineConfig ${MC_NAME} not present; nothing to revert."
    return 0
  fi
  local orig_stream prev_rendered
  orig_stream="$(oc get mc "${MC_NAME}" -o jsonpath='{.metadata.annotations.aro-virt-validation/original-os-image-stream}' 2>/dev/null || echo '')"
  prev_rendered="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.configuration.name}' 2>/dev/null || echo '')"
  oc delete mc "${MC_NAME}"
  if [[ -n "${orig_stream}" ]]; then
    log_info "Restoring mshv MCP spec.osImageStream.name=${orig_stream}..."
    oc patch mcp "${MSHV_MCP_NAME}" --type=merge -p "{\"spec\":{\"osImageStream\":{\"name\":\"${orig_stream}\"}}}"
  fi
  log_info "Waiting for the ${MSHV_MCP_NAME} MCP to roll back to the base image..."
  wait_for_mshv_mcp "${prev_rendered}"
  log_ok "Reverted the ${MSHV_MCP_NAME} pool to its base image."
}

wait_for_mshv_mcp() {
  local prev_rendered="${1:-}"
  local elapsed=0 updated updating degraded count rendered
  while true; do
    count="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.machineCount}' 2>/dev/null || echo '0')"
    updated="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo '')"
    updating="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo '')"
    degraded="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo '')"
    rendered="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.configuration.name}' 2>/dev/null || echo '')"
    if [[ "${degraded}" == "True" ]]; then
      log_error "${MSHV_MCP_NAME} MCP is Degraded."
      oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}' || true
      exit 1
    fi
    # Require the pool to have re-rendered (when a previous name was provided)
    # before we trust Updated=True, to avoid a stale pre-change reading.
    if [[ -n "${prev_rendered}" && "${rendered}" == "${prev_rendered}" ]]; then
      : # not re-rendered yet
    elif [[ "${count}" -ge 1 && "${updated}" == "True" && "${updating}" == "False" ]]; then
      log_ok "${MSHV_MCP_NAME} MCP is Updated (${rendered}) across ${count} node(s)."
      return 0
    fi
    if [[ "${elapsed}" -ge "${MCP_TIMEOUT}" ]]; then
      log_error "${MSHV_MCP_NAME} MCP did not converge."
      oc get mcp "${MSHV_MCP_NAME}" -o yaml || true
      exit 1
    fi
    log_info "  MCP: rendered=${rendered} machineCount=${count} updated=${updated} updating=${updating} degraded=${degraded} (${elapsed}s/${MCP_TIMEOUT}s)"
    sleep 30
    elapsed=$((elapsed + 30))
  done
}

if [[ "${ACTION}" == "revert" ]]; then
  do_revert
  exit 0
fi
[[ "${ACTION}" == "apply" ]] || { log_error "Unknown action '${ACTION}'. Use apply or revert."; exit 1; }

check_command podman || exit 1
check_command skopeo || exit 1
check_command sha256sum || exit 1
check_command realpath || exit 1

KERNEL_RPM_DIR="${KERNEL_RPM_DIR:?KERNEL_RPM_DIR must point to the external directory containing the kernel RPMs}"
[[ -d "${KERNEL_RPM_DIR}" ]] || { log_error "KERNEL_RPM_DIR not found: ${KERNEL_RPM_DIR}"; exit 1; }
rpm_dir="$(realpath "${KERNEL_RPM_DIR}")"
[[ "${rpm_dir}" != "${_REPO_ROOT}" && "${rpm_dir}" != "${_REPO_ROOT}"/* ]] || {
  log_error "KERNEL_RPM_DIR must be outside the repository so RPM binaries cannot be committed."
  exit 1
}

log_info "=== Day-2 RHCOS kernel layering (out-of-cluster) for the ${MSHV_MCP_NAME} pool ==="
oc whoami >/dev/null 2>&1 || { log_error "Not logged in."; exit 1; }
oc get mcp "${MSHV_MCP_NAME}" >/dev/null 2>&1 || { log_error "MCP ${MSHV_MCP_NAME} not found. Run scripts/04-mshv-node-setup.sh first."; exit 1; }

# --- Verify RPMs against the lock (sha256 always; signature unless opted out) --
mapfile -t lock_lines < <(awk -F '\t' 'NF && $1 !~ /^#/ {print}' "${LOCK_FILE}")
[[ "${#lock_lines[@]}" -ge 1 ]] || { log_error "No RPM rows in ${LOCK_FILE}."; exit 1; }

work_dir="$(mktemp -d)"
context_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}" "${context_dir}"' EXIT
mkdir -p "${work_dir}/rpms" "${context_dir}/rpms"

for line in "${lock_lines[@]}"; do
  IFS=$'\t' read -r name evr arch sha <<< "${line}"
  version_release="${evr#*:}"
  rpm_file="${rpm_dir}/${name}-${version_release}.${arch}.rpm"
  [[ -f "${rpm_file}" ]] || { log_error "Missing RPM: ${rpm_file}"; exit 1; }
  printf '%s  rpms/%s\n' "${sha}" "${rpm_file##*/}" >> "${work_dir}/SHA256SUMS"
  cp "${rpm_file}" "${work_dir}/rpms/"
done
(cd "${work_dir}" && sha256sum --check SHA256SUMS)
log_ok "All staged kernel RPMs match the locked sha256 digests."

if [[ "${ALLOW_UNSIGNED_KERNEL_RPMS}" == "true" ]]; then
  log_warn "ALLOW_UNSIGNED_KERNEL_RPMS=true: skipping GPG signature verification (unsigned developer kernel)."
else
  key_mount=()
  if [[ -n "${RPM_GPG_KEY_DIR}" ]]; then
    [[ -d "${RPM_GPG_KEY_DIR}" ]] || { log_error "RPM_GPG_KEY_DIR not found: ${RPM_GPG_KEY_DIR}"; exit 1; }
    key_mount=(-v "$(realpath "${RPM_GPG_KEY_DIR}"):/extra-keys:ro,Z")
  fi
  podman run --rm -v "${work_dir}/rpms:/rpms:ro,Z" "${key_mount[@]}" \
    --entrypoint /bin/sh "${RPM_VERIFY_IMAGE}" -c '
      set -e
      for k in /etc/pki/rpm-gpg/RPM-GPG-KEY-* /extra-keys/*; do [ -f "$k" ] && rpm --import "$k" 2>/dev/null || true; done
      fail=0
      for f in /rpms/*.rpm; do
        out="$(rpm -Kv "$f")"; printf "%s\n%s\n" "$f" "$out"
        echo "$out" | grep -qi "digests signatures OK" || { echo "NO_SIGNATURE_OK: $f" >&2; fail=1; }
      done
      exit $fail'
  log_ok "All staged kernel RPMs carry a trusted signature."
fi

# --- Resolve the mshv pool base image and its ImageDigestMirrorSet mirror ------
rendered_mc="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.spec.configuration.name}')"
BASE_IMAGE="${BASE_IMAGE:-$(oc get mc "${rendered_mc}" -o jsonpath='{.spec.osImageURL}')}"
[[ -n "${BASE_IMAGE}" ]] || { log_error "Could not resolve the ${MSHV_MCP_NAME} base osImageURL."; exit 1; }
log_info "mshv base image: ${BASE_IMAGE}"

base_repo="${BASE_IMAGE%@*}"
base_digest="${BASE_IMAGE#*@}"
mirror_repo="$(oc get imagedigestmirrorset -o json 2>/dev/null \
  | jq -r --arg src "${base_repo}" '[.items[].spec.imageDigestMirrors[]? | select(.source==$src) | .mirrors[0]] | .[0] // empty')"
if [[ -n "${mirror_repo}" ]]; then
  PULL_BASE="${mirror_repo}@${base_digest}"
  log_info "Using ImageDigestMirrorSet mirror for the base pull: ${PULL_BASE}"
else
  PULL_BASE="${BASE_IMAGE}"
  log_warn "No ImageDigestMirrorSet mirror found for ${base_repo}; pulling the source directly."
fi

auth_file="${work_dir}/auth.json"
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${auth_file}"
[[ -s "${auth_file}" ]] || { log_error "Could not read the cluster global pull secret."; exit 1; }

# --- Build the layered image out-of-cluster -----------------------------------
cp "${work_dir}"/rpms/*.rpm "${context_dir}/rpms/"
cat > "${context_dir}/Containerfile" <<EOF
FROM ${PULL_BASE}
COPY rpms/ /tmp/kernel-rpms/
RUN rpm-ostree override replace /tmp/kernel-rpms/*.rpm && \\
    rm -rf /tmp/kernel-rpms && \\
    rpm-ostree cleanup -m && \\
    bootc container lint
EOF
log_info "Building the layered OS image locally..."
podman build --authfile "${auth_file}" -t "${OSIMAGE_LOCAL_TAG}" "${context_dir}"
log_ok "Built ${OSIMAGE_LOCAL_TAG}."

# --- Push to the internal registry via its default route ----------------------
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

oc registry login --registry="${route_host}" --insecure=true --to="${work_dir}/reg-auth.json" >/dev/null 2>&1 || true
podman login --tls-verify=false --authfile "${work_dir}/reg-auth.json" \
  -u kubeadmin -p "$(oc whoami -t)" "${route_host}" >/dev/null

remote="${route_host}/${OSIMAGE_REPO}:l1vh"
digest_file="${work_dir}/digest"
push_ok=false
for attempt in 1 2 3; do
  if podman push --tls-verify=false --authfile "${work_dir}/reg-auth.json" \
       --digestfile="${digest_file}" "${OSIMAGE_LOCAL_TAG}" "${remote}"; then
    push_ok=true
    break
  fi
  log_warn "Push attempt ${attempt} failed; refreshing registry login and retrying..."
  podman login --tls-verify=false --authfile "${work_dir}/reg-auth.json" \
    -u kubeadmin -p "$(oc whoami -t)" "${route_host}" >/dev/null 2>&1 || true
  sleep 10
done
[[ "${push_ok}" == "true" ]] || { log_error "Failed to push the OS image to the internal registry."; exit 1; }
digest="$(<"${digest_file}")"
OSIMAGE_INCLUSTER="image-registry.openshift-image-registry.svc:5000/${OSIMAGE_REPO}@${digest}"
log_ok "Pushed OS image; in-cluster ref: ${OSIMAGE_INCLUSTER}"

# --- Apply the MachineConfig with osImageURL for the mshv role -----------------
# osImageURL and a pool osImageStream are mutually exclusive. If the pool is on an
# OS stream (set by scripts/04-mshv-node-setup.sh), switch it to the custom
# osImageURL and stash the stream name on the MachineConfig for revert.
ORIG_STREAM="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.spec.osImageStream.name}' 2>/dev/null || echo '')"
PREV_RENDERED="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.configuration.name}' 2>/dev/null || echo '')"
if [[ -n "${ORIG_STREAM}" ]]; then
  log_warn "mshv MCP uses osImageStream=${ORIG_STREAM}, which cannot coexist with an osImageURL MachineConfig."
  log_warn "Removing spec.osImageStream so the custom osImageURL takes effect (stored on ${MC_NAME} for revert)."
  oc patch mcp "${MSHV_MCP_NAME}" --type=json -p '[{"op":"remove","path":"/spec/osImageStream"}]'
fi

log_info "Applying MachineConfig ${MC_NAME} (osImageURL) for role ${MSHV_MCP_NAME}..."
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: ${MC_NAME}
  labels:
    machineconfiguration.openshift.io/role: ${MSHV_MCP_NAME}
  annotations:
    aro-virt-validation/original-os-image-stream: "${ORIG_STREAM}"
spec:
  osImageURL: ${OSIMAGE_INCLUSTER}
EOF

log_info "Waiting for the ${MSHV_MCP_NAME} MCP to roll out the custom kernel (node reboots)..."
wait_for_mshv_mcp "${PREV_RENDERED}"
log_ok "Out-of-cluster kernel layer applied to the ${MSHV_MCP_NAME} pool."
log_info "Verify on the node with: ./scripts/12b-verify-kernel-layer.sh"
