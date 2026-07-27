#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

CNV_QEMU_IMAGE="${CNV_QEMU_IMAGE:?CNV_QEMU_IMAGE must be set to a pullable image digest}"
[[ "${CNV_QEMU_IMAGE}" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || { log_error "CNV_QEMU_IMAGE must be digest-pinned"; exit 1; }
NAMESPACE="${CNV_QEMU_SMOKE_NAMESPACE:-cnv-qemu-smoke}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${_REPO_ROOT}/.smoke-runs/$(date -u +%Y%m%dT%H%M%S)-cnv-qemu-direct-smoke}"
mkdir -p "${ARTIFACT_DIR}"

namespace_created=false
cleanup() {
  if [[ "${namespace_created}" == "true" ]]; then
    oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=5m >/dev/null || log_warn "Manual namespace cleanup required: ${NAMESPACE}"
  fi
}
trap cleanup EXIT

oc create namespace "${NAMESPACE}"
namespace_created=true

pull_secret=""
if [[ -n "${CNV_QEMU_IMAGE_PULL_SECRET_FILE:-}" ]]; then
  [[ -f "${CNV_QEMU_IMAGE_PULL_SECRET_FILE}" ]] || {
    log_error "Image pull secret file not found: ${CNV_QEMU_IMAGE_PULL_SECRET_FILE}"
    exit 1
  }
  oc create secret generic cnv-qemu-registry -n "${NAMESPACE}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${CNV_QEMU_IMAGE_PULL_SECRET_FILE}"
  pull_secret=$'  imagePullSecrets:\n  - name: cnv-qemu-registry'
fi

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cnv-qemu
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
${pull_secret}
  nodeSelector:
    node-role.kubernetes.io/mshv: ""
  containers:
  - name: qemu
    image: ${CNV_QEMU_IMAGE}
    imagePullPolicy: Always
    command: ["/usr/bin/sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 107
      capabilities: {drop: ["ALL"]}
      seccompProfile: {type: RuntimeDefault}
    resources:
      limits: {devices.kubevirt.io/mshv: "1"}
      requests: {devices.kubevirt.io/mshv: "1"}
EOF

oc wait pod/cnv-qemu -n "${NAMESPACE}" --for=condition=Ready --timeout=5m
oc get pod/cnv-qemu -n "${NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/pod.yaml"
pod_image_id="$(oc get pod/cnv-qemu -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="qemu")].imageID}')"
expected_digest="${CNV_QEMU_IMAGE##*@}"
[[ "${pod_image_id}" == *@"${expected_digest}" ]] || {
  log_error "Pod imageID ${pod_image_id} does not match requested digest ${expected_digest}."
  exit 1
}

oc exec -n "${NAMESPACE}" cnv-qemu -- rpm -q --qf \
  '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SOURCERPM}\n' \
  qemu-img qemu-kvm-common qemu-kvm-core \
  qemu-kvm-device-display-virtio-gpu qemu-kvm-device-display-virtio-gpu-pci \
  qemu-kvm-device-display-virtio-vga qemu-kvm-device-usb-host \
  qemu-kvm-device-usb-redirect > "${ARTIFACT_DIR}/rpms.txt"
[[ "$(grep -c $'\t17:10.1.0-17.el9_8.3\tx86_64\tqemu-kvm-10.1.0-17.el9_8.3.src.rpm$' "${ARTIFACT_DIR}/rpms.txt")" -eq 8 ]] || {
  log_error "Running pod does not contain all eight target QEMU RPMs."
  exit 1
}

run_probe() {
  local name="$1"
  shift
  local command rc
  printf -v command '%q ' "$@"
  set +e
  oc exec -n "${NAMESPACE}" cnv-qemu -- /bin/bash -c "ulimit -c 0; exec timeout 10 ${command}" > "${ARTIFACT_DIR}/${name}.txt" 2>&1
  rc=$?
  set -e
  printf '%s\n' "${rc}" > "${ARTIFACT_DIR}/${name}.exit-code"
}

run_probe paused-running /usr/libexec/qemu-kvm -machine q35,accel=mshv -cpu Westmere -m 128 -smp 1 -nodefaults -display none -S
set +e
oc exec -n "${NAMESPACE}" cnv-qemu -- /bin/bash -c '
  set -euo pipefail
  ulimit -c 0
  rm -f /tmp/qemu-3-qmp.sock /tmp/qemu-3.log
  /usr/libexec/qemu-kvm -machine q35,accel=mshv -cpu Westmere \
    -m 128 -smp 1 -nodefaults -display none \
    -qmp unix:/tmp/qemu-3-qmp.sock,server=on,wait=off \
    > /tmp/qemu-3.log 2>&1 &
  pid=$!
  cleanup_qemu() { kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; }
  trap cleanup_qemu EXIT
  for _ in $(seq 1 50); do
    [[ -S /tmp/qemu-3-qmp.sock ]] && break
    kill -0 "${pid}" 2>/dev/null || { cat /tmp/qemu-3.log; exit 1; }
    sleep 0.1
  done
  [[ -S /tmp/qemu-3-qmp.sock ]]
  sleep 3
  kill -0 "${pid}"
  printf "{\"execute\":\"qmp_capabilities\"}\n{\"execute\":\"query-status\"}\n" \
    | socat - UNIX-CONNECT:/tmp/qemu-3-qmp.sock
  cat /tmp/qemu-3.log
' > "${ARTIFACT_DIR}/active-running.txt" 2>&1
active_rc=$?
set -e
printf '%s\n' "${active_rc}" > "${ARTIFACT_DIR}/active-running.exit-code"

paused_rc="$(<"${ARTIFACT_DIR}/paused-running.exit-code")"
active_rc="$(<"${ARTIFACT_DIR}/active-running.exit-code")"
[[ "${paused_rc}" == "124" ]] || { log_error "Paused probe returned ${paused_rc}, expected 124"; exit 1; }
if [[ "${active_rc}" != "0" ]]; then
  log_error "Active QMP probe returned ${active_rc}, expected 0"
  exit 1
fi
grep -q '"running": true' "${ARTIFACT_DIR}/active-running.txt" || {
  log_error "Active QMP query-status did not report running=true."
  exit 1
}
if grep -Eq 'invalid intercept access type|failed to handle mmio|Failed to run on vcpu 0' "${ARTIFACT_DIR}/active-running.txt"; then
  log_error "Active QEMU 10.1.0-17.el9_8.3 probe reproduced the MSHV crash."
  exit 1
fi

log_ok "QEMU .3 active MSHV smoke succeeded. Artifacts: ${ARTIFACT_DIR}"
