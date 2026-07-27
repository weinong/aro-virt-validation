#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

IMAGE_DIR="${_REPO_ROOT}/images/hybrid-virt-launcher"
source "${IMAGE_DIR}/images.lock.env"

check_command oc || exit 1

HYBRID_IMAGE="${HYBRID_IMAGE_OVERRIDE:-${HYBRID_IMAGE}}"
NAMESPACE="${HYBRID_SMOKE_NAMESPACE:-hybrid-qemu-smoke}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${_REPO_ROOT}/.smoke-runs/$(date -u +%Y%m%dT%H%M%S)-hybrid-qemu-smoke}"
mkdir -p "${ARTIFACT_DIR}"

if [[ ! "${HYBRID_IMAGE}" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
  log_error "HYBRID_IMAGE_OVERRIDE must be digest-pinned for cluster smoke testing: ${HYBRID_IMAGE}"
  exit 1
fi

namespace_created=false
cleanup() {
  if [[ "${namespace_created}" == "true" ]]; then
    if ! oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=5m >/dev/null; then
      log_warn "Failed to delete diagnostic namespace ${NAMESPACE}; manual cleanup is required."
    fi
  fi
}
trap cleanup EXIT

oc create namespace "${NAMESPACE}"
namespace_created=true

image_pull_secrets=""
if [[ -n "${HYBRID_IMAGE_PULL_SECRET_FILE:-}" ]]; then
  if [[ ! -f "${HYBRID_IMAGE_PULL_SECRET_FILE}" ]]; then
    log_error "Image pull secret file not found: ${HYBRID_IMAGE_PULL_SECRET_FILE}"
    exit 1
  fi
  oc create secret generic hybrid-qemu-registry \
    -n "${NAMESPACE}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${HYBRID_IMAGE_PULL_SECRET_FILE}"
  image_pull_secrets=$'  imagePullSecrets:\n  - name: hybrid-qemu-registry'
fi

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hybrid-qemu
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
${image_pull_secrets}
  nodeSelector:
    node-role.kubernetes.io/mshv: ""
  containers:
  - name: qemu
    image: ${HYBRID_IMAGE}
    imagePullPolicy: Always
    command: ["/usr/bin/sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 107
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
    resources:
      limits:
        devices.kubevirt.io/mshv: "1"
      requests:
        devices.kubevirt.io/mshv: "1"
EOF

oc wait pod/hybrid-qemu -n "${NAMESPACE}" --for=condition=Ready --timeout=5m
oc get pod/hybrid-qemu -n "${NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/pod.yaml"
POD_IMAGE_ID="$(oc get pod/hybrid-qemu -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="qemu")].imageID}')"
EXPECTED_DIGEST="${HYBRID_IMAGE##*@}"
if [[ "${POD_IMAGE_ID}" != *@"${EXPECTED_DIGEST}" ]]; then
  log_error "Pod imageID ${POD_IMAGE_ID} does not match requested digest ${EXPECTED_DIGEST}."
  exit 1
fi

run_probe() {
  local name="$1"
  shift
  local command
  printf -v command '%q ' "$@"
  set +e
  oc exec -n "${NAMESPACE}" hybrid-qemu -- /bin/bash -c \
    "ulimit -c 0; exec timeout 10 ${command}" \
    > "${ARTIFACT_DIR}/${name}.txt" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "${rc}" > "${ARTIFACT_DIR}/${name}.exit-code"
}

assert_probe() {
  local name="$1"
  local expected_rc="$2"
  local expected_pattern="$3"
  local actual_rc
  actual_rc="$(<"${ARTIFACT_DIR}/${name}.exit-code")"
  if [[ "${actual_rc}" != "${expected_rc}" ]]; then
    log_error "Probe ${name} returned ${actual_rc}, expected ${expected_rc}."
    return 1
  fi
  if ! grep -q "${expected_pattern}" "${ARTIFACT_DIR}/${name}.txt"; then
    log_error "Probe ${name} did not contain expected output: ${expected_pattern}"
    return 1
  fi
}

oc exec -n "${NAMESPACE}" hybrid-qemu -- /bin/bash -c '
  ulimit -c 0
  /opt/qemu-upstream/bin/qemu-kvm -machine q35,accel=mshv -cpu Westmere \
    -m 128 -smp 1 -nodefaults -display none -S &
  pid=$!
  sleep 1
  set +e
  grep / "/proc/${pid}/maps"
  rc=$?
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  exit "${rc}"
' > "${ARTIFACT_DIR}/upstream-paused-library-maps.txt"

if ! grep -q '/opt/qemu-upstream/rootfs/usr/lib64/' "${ARTIFACT_DIR}/upstream-paused-library-maps.txt"; then
  log_error "Paused upstream MSHV QEMU did not load its private library runtime."
  exit 1
fi
if grep -Eq '[[:space:]]/(usr/)?lib64/' "${ARTIFACT_DIR}/upstream-paused-library-maps.txt"; then
  log_error "Paused upstream MSHV QEMU mixed CNV libraries into its private runtime."
  exit 1
fi

run_probe upstream-paused \
  /opt/qemu-upstream/bin/qemu-kvm -machine q35,accel=mshv -cpu Westmere \
  -m 128 -smp 1 -nodefaults -display none -S
run_probe upstream-running \
  /opt/qemu-upstream/bin/qemu-kvm -machine q35,accel=mshv -cpu Westmere \
  -m 128 -smp 1 -nodefaults -display none
run_probe current-running \
  /usr/libexec/qemu-kvm -machine q35,accel=mshv -cpu Westmere \
  -m 128 -smp 1 -nodefaults -display none

assert_probe upstream-paused 124 'terminating on signal 15'
assert_probe upstream-running 134 'Failed to run on vcpu 0'
assert_probe current-running 134 'Failed to run on vcpu 0'
for probe in upstream-running current-running; do
  grep -q 'invalid intercept access type: execute' "${ARTIFACT_DIR}/${probe}.txt" || {
    log_error "Probe ${probe} did not report the expected execute-intercept failure."
    exit 1
  }
  grep -q 'failed to handle mmio' "${ARTIFACT_DIR}/${probe}.txt" || {
    log_error "Probe ${probe} did not report the expected MMIO failure."
    exit 1
  }
done

log_ok "Hybrid QEMU smoke probes complete. Artifacts: ${ARTIFACT_DIR}"
