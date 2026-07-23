#!/usr/bin/env bash
# =============================================================================
# 04-mshv-node-setup.sh - Create the MSHV node declaratively
#
# Creates a dedicated MachineConfigPool, MachineConfigs, and MachineSet for an
# RHCOS 10 MSHV node. This script intentionally does not use direct Machines,
# manual rendered MachineConfigs, or node desiredConfig annotations. If the
# normal MCP/MachineSet path does not converge, stop and document the issue.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

MSHV_VM_SIZE="${MSHV_VM_SIZE:-Standard_D192ds_v6}"
MSHV_DISK_SIZE_GB="${MSHV_DISK_SIZE_GB:-256}"
MSHV_ZONE="${MSHV_ZONE:-1}"
MSHV_REPLICAS="${MSHV_REPLICAS:-1}"
MSHV_MACHINESET_NAME="${MSHV_MACHINESET_NAME:-}"

log_info "=== Phase 4: Declarative MSHV Node Setup ==="

check_command oc || exit 1
check_command jq || exit 1

if [[ "${MSHV_REPLICAS}" != "1" ]]; then
  log_error "This validation script currently supports exactly one MSHV node. MSHV_REPLICAS=${MSHV_REPLICAS}"
  log_error "Extend the script to validate every MSHV node before increasing replicas."
  exit 1
fi

log_info "Verifying cluster login..."
CURRENT_USER="$(oc whoami 2>/dev/null)" || { log_error "Not logged in."; exit 1; }
log_ok "Logged in as ${CURRENT_USER}"

log_info "Verifying TechPreviewNoUpgrade is enabled..."
FEATURE_SET="$(oc get featuregate/cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo '')"
if [[ "${FEATURE_SET}" != "TechPreviewNoUpgrade" ]]; then
  log_error "TechPreviewNoUpgrade is not enabled. Run scripts/03-techpreview-setup.sh first."
  exit 1
fi
log_ok "TechPreviewNoUpgrade is enabled."

log_info "Verifying cluster health before changing ARO reconciliation..."
PROGRESSING="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
FAILING="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Failing")].status}' 2>/dev/null || echo '')"
if [[ "${PROGRESSING}" == "True" || "${FAILING}" == "True" ]]; then
  log_error "ClusterVersion is not settled: Progressing=${PROGRESSING} Failing=${FAILING}"
  oc get clusterversion version
  exit 1
fi

DEGRADED="$(oc get co -o json \
  | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name' 2>/dev/null || true)"
if [[ -n "${DEGRADED}" ]]; then
  log_error "ClusterOperators are degraded. Resolve before creating MSHV nodes:"
  echo "${DEGRADED}"
  exit 1
fi

log_info "Verifying RHCOS 10 OS stream is available..."
if ! oc get osimagestreams/cluster &>/dev/null; then
  log_error "OSImageStream/cluster is not available."
  log_error "Do not pin osImageURL as a normal workflow workaround; document the missing OS stream issue."
  exit 1
fi
RHEL10_STREAM="$(oc get osimagestreams/cluster -o json | jq -r '.status.availableStreams[]? | select(.name=="rhel-10") | .name' 2>/dev/null || echo '')"
if [[ "${RHEL10_STREAM}" != "rhel-10" ]]; then
  log_error "OSImageStream/cluster does not advertise the rhel-10 stream."
  log_error "Do not pin osImageURL as a normal workflow workaround; document the missing RHCOS 10 stream issue."
  exit 1
fi
log_ok "rhel-10 OS stream is available."

if oc get crd clusters.aro.openshift.io &>/dev/null && oc get cluster.aro.openshift.io cluster &>/dev/null; then
  log_info "Disabling ARO MachineSet reconciliation for custom MSHV MachineSets..."
  oc patch cluster.aro.openshift.io cluster --type=merge \
    -p '{"spec":{"operatorflags":{"aro.machineset.enabled":"false"}}}'
  log_ok "ARO MachineSet reconciliation disabled."
else
  log_info "No ARO cluster custom resource detected (self-managed installer cluster); skipping aro.machineset.enabled patch."
fi

log_info "Creating dedicated MachineConfigPool 'mshv'..."
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: mshv
spec:
  osImageStream:
    name: rhel-10
  machineConfigSelector:
    matchExpressions:
    - key: machineconfiguration.openshift.io/role
      operator: In
      values:
      - worker
      - mshv
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/mshv: ""
EOF

log_info "Creating MSHV MachineConfig for persistent mshv_root loading..."
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-mshv-load-mshv-root
  labels:
    machineconfiguration.openshift.io/role: mshv
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
      - path: /etc/modules-load.d/mshv-root.conf
        mode: 0644
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8,mshv_root%0A
EOF

log_info "Checking that the mshv MCP rendered a configuration..."
RENDER_TIMEOUT=300
ELAPSED=0
while true; do
  RENDERED="$(oc get mcp mshv -o jsonpath='{.status.configuration.name}' 2>/dev/null || echo '')"
  if [[ -n "${RENDERED}" ]]; then
    log_ok "mshv MCP rendered ${RENDERED}."
    break
  fi
  if [[ "${ELAPSED}" -ge "${RENDER_TIMEOUT}" ]]; then
    log_error "mshv MCP did not render a configuration."
    oc get mcp mshv -o yaml
    exit 1
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

EXISTING_MS="$(oc get machineset.machine.openshift.io -n openshift-machine-api \
  -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{"\n"}{end}' \
  | head -n1)"
if [[ -z "${EXISTING_MS}" ]]; then
  EXISTING_MS="$(oc get machineset.machine.openshift.io -n openshift-machine-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
fi
if [[ -z "${EXISTING_MS}" ]]; then
  log_error "No existing MachineSet found to use as a providerSpec template."
  exit 1
fi

CLUSTER_ID="$(oc get machineset.machine.openshift.io "${EXISTING_MS}" -n openshift-machine-api \
  -o jsonpath='{.metadata.labels.machine\.openshift\.io/cluster-api-cluster}')"
if [[ -z "${MSHV_MACHINESET_NAME}" ]]; then
  MSHV_MACHINESET_NAME="${CLUSTER_ID}-worker-mshv-${LOCATION}${MSHV_ZONE}"
fi

log_info "Creating MSHV MachineSet ${MSHV_MACHINESET_NAME}..."
if oc get machineset.machine.openshift.io "${MSHV_MACHINESET_NAME}" -n openshift-machine-api &>/dev/null; then
  log_ok "MachineSet ${MSHV_MACHINESET_NAME} already exists."
  oc patch machineset.machine.openshift.io "${MSHV_MACHINESET_NAME}" -n openshift-machine-api --type=merge \
    -p '{"spec":{"template":{"spec":{"metadata":{"labels":{"node-role.kubernetes.io/mshv":"","node-role.kubernetes.io/worker":""}}}}}}'
  oc scale machineset.machine.openshift.io "${MSHV_MACHINESET_NAME}" -n openshift-machine-api --replicas="${MSHV_REPLICAS}"
else
  oc get machineset.machine.openshift.io "${EXISTING_MS}" -n openshift-machine-api -o json \
    | jq --arg name "${MSHV_MACHINESET_NAME}" \
         --arg vmSize "${MSHV_VM_SIZE}" \
         --arg zone "${MSHV_ZONE}" \
         --argjson diskSize "${MSHV_DISK_SIZE_GB}" \
         --argjson replicas "${MSHV_REPLICAS}" \
    '
      del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
          .metadata.generation, .status, .metadata.annotations) |
      .metadata.name = $name |
      .metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
      .spec.replicas = $replicas |
      .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $name |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-role" = "mshv" |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machine-type" = "mshv" |
      .spec.template.spec.providerSpec.value.vmSize = $vmSize |
      .spec.template.spec.providerSpec.value.osDisk.diskSizeGB = $diskSize |
      .spec.template.spec.providerSpec.value.zone = $zone |
      .spec.template.spec.providerSpec.value.tags = ((.spec.template.spec.providerSpec.value.tags // {}) + {
        "platformsettings.host_environment.nodefeatures.hierarchicalvirtualizationv1": "True"
      }) |
      .spec.template.spec.metadata.labels = {
        "node-role.kubernetes.io/mshv": "",
        "node-role.kubernetes.io/worker": ""
      }
    ' | oc apply -f -
fi

log_info "Waiting for MSHV MachineSet readyReplicas=${MSHV_REPLICAS}..."
MACHINE_TIMEOUT=2400
ELAPSED=0
while true; do
  READY="$(oc get machineset.machine.openshift.io "${MSHV_MACHINESET_NAME}" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0')"
  READY="${READY:-0}"
  if [[ "${READY}" -ge "${MSHV_REPLICAS}" ]]; then
    log_ok "MSHV MachineSet has ${READY} ready replica(s)."
    break
  fi
  if [[ "${ELAPSED}" -ge "${MACHINE_TIMEOUT}" ]]; then
    log_error "Timeout waiting for MSHV MachineSet."
    oc get machineset.machine.openshift.io "${MSHV_MACHINESET_NAME}" -n openshift-machine-api -o yaml
    oc get machine.machine.openshift.io -n openshift-machine-api -o wide
    exit 1
  fi
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

NODE_NAME="$(oc get machine.machine.openshift.io -n openshift-machine-api \
  -l machine.openshift.io/cluster-api-machineset="${MSHV_MACHINESET_NAME}" \
  -o jsonpath='{.items[0].status.nodeRef.name}')"
if [[ -z "${NODE_NAME}" ]]; then
  log_error "MSHV Machine does not have a nodeRef."
  oc get machine.machine.openshift.io -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset="${MSHV_MACHINESET_NAME}" -o yaml
  exit 1
fi

log_info "Verifying node labels for ${NODE_NAME}..."
if [[ "$(oc get node "${NODE_NAME}" -o json | jq -r '.metadata.labels | has("node-role.kubernetes.io/mshv")')" != "true" ]]; then
  log_error "MSHV node is missing node-role.kubernetes.io/mshv label."
  oc get node "${NODE_NAME}" --show-labels
  exit 1
fi
if [[ "$(oc get node "${NODE_NAME}" -o json | jq -r '.metadata.labels | has("node-role.kubernetes.io/worker")')" != "true" ]]; then
  log_error "MSHV node is missing node-role.kubernetes.io/worker label required by custom MachineConfigPools."
  oc get node "${NODE_NAME}" --show-labels
  exit 1
fi
log_ok "MSHV node has the worker and mshv roles required by the custom MachineConfigPool."

log_info "Waiting for mshv MCP to apply RHCOS 10 and module-load config..."
MCP_TIMEOUT=3600
ELAPSED=0
while true; do
  MACHINE_COUNT="$(oc get mcp mshv -o jsonpath='{.status.machineCount}' 2>/dev/null || echo '0')"
  UPDATED="$(oc get mcp mshv -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo '')"
  UPDATING="$(oc get mcp mshv -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo '')"
  DEGRADED="$(oc get mcp mshv -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo '')"
  if [[ "${MACHINE_COUNT}" -ge 1 && "${UPDATED}" == "True" && "${UPDATING}" == "False" && "${DEGRADED}" != "True" ]]; then
    log_ok "mshv MCP is updated and manages ${MACHINE_COUNT} node(s)."
    break
  fi
  if [[ "${ELAPSED}" -ge "${MCP_TIMEOUT}" ]]; then
    log_error "mshv MCP did not converge through the normal path."
    oc get mcp mshv -o yaml
    oc describe node "${NODE_NAME}"
    exit 1
  fi
  log_info "  MCP: machineCount=${MACHINE_COUNT} updated=${UPDATED} updating=${UPDATING} degraded=${DEGRADED} (${ELAPSED}s/${MCP_TIMEOUT}s)"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

log_info "Verifying host MSHV state on ${NODE_NAME}..."
oc debug "node/${NODE_NAME}" -- chroot /host bash -c '
  set -euo pipefail
  source /etc/os-release
  echo "OS=${PRETTY_NAME}"
  [[ "${VERSION_ID}" == 10* ]]
  uname -r
  test -e /dev/mshv
  test -e /dev/vhost-net
  lsmod | grep -q "^mshv_root"
  test -f /etc/modules-load.d/mshv-root.conf
  grep -q "running as L1VH partition" /var/log/dmesg 2>/dev/null || dmesg | grep -q "running as L1VH partition"
'

log_ok "Phase 4 complete. MSHV node is declaratively configured."
