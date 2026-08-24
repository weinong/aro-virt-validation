#!/usr/bin/env bash
# =============================================================================
# 12-rhcos-kernel-layer.sh - Day-2 RHCOS custom kernel layering for the mshv pool
#
# Applies a custom kernel to the RHCOS 10 MSHV/CNV nodes using the on-cluster
# image mode (RHCOS layering) build path: a MachineOSConfig custom resource.
# The Machine Config Operator builds the layered image in-cluster from
# `FROM configs AS final`, which inherits the mshv pool's rhel-10 base, and
# rolls it out to the mshv MachineConfigPool.
#
# This script does NOT pin osImageURL by hand and does NOT hand-edit rendered
# MachineConfigs. If the normal MachineOSConfig/MCP path does not converge, stop
# and document the issue under issues/.
#
# Usage:
#   ./scripts/12-rhcos-kernel-layer.sh [apply|revert|render]
#
#   KERNEL_RPM_SOURCE=copr  ./scripts/12-rhcos-kernel-layer.sh apply   # default
#   KERNEL_RPM_SOURCE=local ./scripts/12-rhcos-kernel-layer.sh apply
#   ./scripts/12-rhcos-kernel-layer.sh render    # print the MachineOSConfig only
#   ./scripts/12-rhcos-kernel-layer.sh revert    # remove the layer, back to base
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

IMAGE_DIR="${_REPO_ROOT}/images/rhcos-kernel-layer"

ACTION="${1:-apply}"

# --- Configurable knobs ------------------------------------------------------
MSHV_MCP_NAME="${MSHV_MCP_NAME:-mshv}"
# MachineOSConfig name must match the target MachineConfigPool name.
MOC_NAME="${MOC_NAME:-${MSHV_MCP_NAME}}"
MOC_NAMESPACE="${MOC_NAMESPACE:-openshift-machine-config-operator}"
KERNEL_RPM_SOURCE="${KERNEL_RPM_SOURCE:-copr}"

# copr/URL path: space/newline-separated direct .rpm URLs.
KERNEL_RPM_URLS="${KERNEL_RPM_URLS:-}"
# local path: carrier image pullspec produced by 12a-build-kernel-rpm-carrier.sh.
KERNEL_CARRIER_IMAGE="${KERNEL_CARRIER_IMAGE:-image-registry.openshift-image-registry.svc:5000/${MOC_NAMESPACE}/kernel-rpm-carrier:latest}"

# Where the MCO pushes the newly-built layered image and which secrets it uses.
RENDERED_IMAGE_PUSH_SPEC="${RENDERED_IMAGE_PUSH_SPEC:-image-registry.openshift-image-registry.svc:5000/${MOC_NAMESPACE}/mshv-kernel:latest}"
BASE_PULL_SECRET_NAME="${BASE_PULL_SECRET_NAME:-global-pull-secret-copy}"
RENDERED_PUSH_SECRET_NAME="${RENDERED_PUSH_SECRET_NAME:-}"

BUILD_TIMEOUT="${BUILD_TIMEOUT:-3600}"
MCP_TIMEOUT="${MCP_TIMEOUT:-3600}"

check_command oc || exit 1
check_command jq || exit 1

# --- Detect which MachineOSConfig API version the cluster serves -------------
detect_moc_apiversion() {
  local v
  for v in v1 v1alpha1; do
    if oc get --raw "/apis/machineconfiguration.openshift.io/${v}/machineosconfigs" >/dev/null 2>&1; then
      echo "machineconfiguration.openshift.io/${v}"
      return 0
    fi
  done
  return 1
}

# --- Render the containerFile text from the template ------------------------
render_containerfile() {
  case "${KERNEL_RPM_SOURCE}" in
    copr)
      [[ -n "${KERNEL_RPM_URLS}" ]] || {
        log_error "KERNEL_RPM_SOURCE=copr requires KERNEL_RPM_URLS (direct .rpm URLs)."
        return 1
      }
      # Validate every URL is an https .rpm so we never inject shell into the build.
      local url urls_joined=""
      while read -r url; do
        [[ -z "${url}" ]] && continue
        if [[ ! "${url}" =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'\(\)*+,\;=%-]+\.rpm$ ]]; then
          log_error "Refusing suspicious kernel RPM URL: ${url}"
          return 1
        fi
        urls_joined+="${url} "
      done <<< "${KERNEL_RPM_URLS//[[:space:]]/$'\n'}"
      urls_joined="${urls_joined% }"
      [[ -n "${urls_joined}" ]] || { log_error "No usable URLs in KERNEL_RPM_URLS."; return 1; }
      sed "s|@@KERNEL_RPM_URLS@@|${urls_joined}|g" "${IMAGE_DIR}/Containerfile.copr"
      ;;
    local)
      if [[ ! "${KERNEL_CARRIER_IMAGE}" =~ ^[A-Za-z0-9._:/@-]+$ ]]; then
        log_error "Refusing suspicious KERNEL_CARRIER_IMAGE: ${KERNEL_CARRIER_IMAGE}"
        return 1
      fi
      sed "s|@@CARRIER_IMAGE@@|${KERNEL_CARRIER_IMAGE}|g" "${IMAGE_DIR}/Containerfile.local"
      ;;
    *)
      log_error "Unknown KERNEL_RPM_SOURCE='${KERNEL_RPM_SOURCE}' (expected copr or local)."
      return 1
      ;;
  esac
}

# --- Render the full MachineOSConfig YAML -----------------------------------
render_machineosconfig() {
  local apiversion="$1"
  local containerfile
  containerfile="$(render_containerfile)" || return 1

  {
    printf 'apiVersion: %s\n' "${apiversion}"
    cat <<EOF
kind: MachineOSConfig
metadata:
  name: ${MOC_NAME}
spec:
  machineConfigPool:
    name: ${MSHV_MCP_NAME}
  imageBuilder:
    imageBuilderType: Job
  baseImagePullSecret:
    name: ${BASE_PULL_SECRET_NAME}
  renderedImagePushSpec: ${RENDERED_IMAGE_PUSH_SPEC}
  renderedImagePushSecret:
    name: ${RENDERED_PUSH_SECRET_NAME}
  containerFile:
  - containerfileArch: NoArch
    content: |-
EOF
    # Indent the containerFile body by six spaces under "content: |-".
    printf '%s\n' "${containerfile}" | sed 's/^/      /'
  }
}

# --- Preconditions shared by apply -------------------------------------------
verify_preconditions() {
  log_info "Verifying cluster login..."
  local user
  user="$(oc whoami 2>/dev/null)" || { log_error "Not logged in."; exit 1; }
  log_ok "Logged in as ${user}"

  log_info "Verifying the MachineOSConfig API is served..."
  MOC_APIVERSION="$(detect_moc_apiversion)" || {
    log_error "The machineconfiguration.openshift.io MachineOSConfig API is not served."
    log_error "On-cluster RHCOS layering is unavailable on this cluster. Document this under issues/ instead of working around it."
    exit 1
  }
  log_ok "Using ${MOC_APIVERSION}."
  if [[ "${MOC_APIVERSION}" == *v1alpha1 ]]; then
    log_error "Only the v1alpha1 MachineOSConfig schema is served; this script targets the v1 schema."
    log_error "Do not guess the alpha schema. Document the version gap under issues/."
    exit 1
  fi

  log_info "Verifying TechPreviewNoUpgrade is enabled (on-cluster layering status is Tech Preview)..."
  local fs
  fs="$(oc get featuregate/cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo '')"
  if [[ "${fs}" != "TechPreviewNoUpgrade" ]]; then
    log_warn "featureSet is '${fs}', not TechPreviewNoUpgrade. On-cluster layering may be unavailable."
  fi

  log_info "Verifying the ${MSHV_MCP_NAME} MachineConfigPool exists..."
  oc get mcp "${MSHV_MCP_NAME}" >/dev/null 2>&1 || {
    log_error "MachineConfigPool ${MSHV_MCP_NAME} not found. Run scripts/04-mshv-node-setup.sh first."
    exit 1
  }
  log_ok "MachineConfigPool ${MSHV_MCP_NAME} exists."

  if [[ "${RENDERED_IMAGE_PUSH_SPEC}" == image-registry.openshift-image-registry.svc:* ]]; then
    log_info "Verifying the internal image registry is Managed..."
    local mgmt
    mgmt="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || echo '')"
    if [[ "${mgmt}" != "Managed" ]]; then
      log_error "Internal image registry managementState is '${mgmt}', expected Managed, but RENDERED_IMAGE_PUSH_SPEC targets it."
      log_error "Set the registry to Managed or point RENDERED_IMAGE_PUSH_SPEC at an external registry."
      exit 1
    fi
    log_ok "Internal image registry is Managed."
  fi
}

# --- Ensure the base image pull secret exists in the MCO namespace -----------
ensure_base_pull_secret() {
  if oc -n "${MOC_NAMESPACE}" get secret "${BASE_PULL_SECRET_NAME}" >/dev/null 2>&1; then
    log_ok "Base pull secret ${BASE_PULL_SECRET_NAME} already present."
    return 0
  fi
  log_info "Creating base pull secret ${BASE_PULL_SECRET_NAME} from the global pull secret..."
  local dockercfg
  dockercfg="$(oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null || echo '')"
  [[ -n "${dockercfg}" ]] || { log_error "Could not read the global pull secret (openshift-config/pull-secret)."; exit 1; }
  oc -n "${MOC_NAMESPACE}" create secret generic "${BASE_PULL_SECRET_NAME}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-literal=.dockerconfigjson="$(printf '%s' "${dockercfg}" | base64 -d)"
  log_ok "Created ${BASE_PULL_SECRET_NAME}."
}

# --- Resolve the push secret the MCO uses to push the built image ------------
resolve_push_secret() {
  if [[ -n "${RENDERED_PUSH_SECRET_NAME}" ]]; then
    oc -n "${MOC_NAMESPACE}" get secret "${RENDERED_PUSH_SECRET_NAME}" >/dev/null 2>&1 || {
      log_error "RENDERED_PUSH_SECRET_NAME=${RENDERED_PUSH_SECRET_NAME} not found in ${MOC_NAMESPACE}."
      exit 1
    }
    return 0
  fi
  log_info "Resolving an internal-registry push secret in ${MOC_NAMESPACE}..."
  # The namespace builder service account is granted push access to the internal
  # registry; its dockercfg secret is the documented push credential.
  RENDERED_PUSH_SECRET_NAME="$(oc -n "${MOC_NAMESPACE}" get secrets -o name 2>/dev/null \
    | sed 's|^secret/||' | grep -E '^builder-dockercfg-' | head -n1 || true)"
  [[ -n "${RENDERED_PUSH_SECRET_NAME}" ]] || {
    log_error "Could not find a builder-dockercfg-* secret in ${MOC_NAMESPACE}."
    log_error "Set RENDERED_PUSH_SECRET_NAME to a secret that can push to ${RENDERED_IMAGE_PUSH_SPEC}."
    exit 1
  }
  log_ok "Using push secret ${RENDERED_PUSH_SECRET_NAME}."
}

# --- Wait for the MachineOSBuild to succeed ----------------------------------
wait_for_build() {
  log_info "Waiting for the MachineOSBuild for ${MOC_NAME} to succeed (timeout ${BUILD_TIMEOUT}s)..."
  local elapsed=0 succeeded failed interrupted build
  while true; do
    build="$(oc get machineosbuild -o json 2>/dev/null \
      | jq -r --arg moc "${MOC_NAME}" '[.items[] | select(.spec.machineOSConfig.name==$moc or (.metadata.name | startswith($moc)))] | .[0] // empty')"
    if [[ -n "${build}" ]]; then
      succeeded="$(jq -r '[.status.conditions[]? | select(.type=="Succeeded")][0].status // "Unknown"' <<< "${build}")"
      failed="$(jq -r '[.status.conditions[]? | select(.type=="Failed")][0].status // "False"' <<< "${build}")"
      interrupted="$(jq -r '[.status.conditions[]? | select(.type=="Interrupted")][0].status // "False"' <<< "${build}")"
      if [[ "${succeeded}" == "True" ]]; then
        log_ok "MachineOSBuild succeeded."
        return 0
      fi
      if [[ "${failed}" == "True" || "${interrupted}" == "True" ]]; then
        log_error "MachineOSBuild failed (Failed=${failed} Interrupted=${interrupted})."
        oc get machineosbuild -o wide || true
        oc get pods -n "${MOC_NAMESPACE}" | grep -E 'build-|machine-os-builder' || true
        exit 1
      fi
    fi
    if [[ "${elapsed}" -ge "${BUILD_TIMEOUT}" ]]; then
      log_error "Timeout waiting for the MachineOSBuild to succeed."
      oc get machineosbuild -o wide || true
      exit 1
    fi
    log_info "  build not ready yet (${elapsed}s/${BUILD_TIMEOUT}s)"
    sleep 30
    elapsed=$((elapsed + 30))
  done
}

# --- Wait for the mshv MCP to roll out the layered image ---------------------
wait_for_mcp() {
  log_info "Waiting for the ${MSHV_MCP_NAME} MCP to apply the layered image (timeout ${MCP_TIMEOUT}s)..."
  local elapsed=0 updated updating degraded count
  while true; do
    count="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.machineCount}' 2>/dev/null || echo '0')"
    updated="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo '')"
    updating="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo '')"
    degraded="$(oc get mcp "${MSHV_MCP_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo '')"
    if [[ "${degraded}" == "True" ]]; then
      log_error "${MSHV_MCP_NAME} MCP is Degraded."
      oc get mcp "${MSHV_MCP_NAME}" -o yaml || true
      exit 1
    fi
    if [[ "${count}" -ge 1 && "${updated}" == "True" && "${updating}" == "False" ]]; then
      log_ok "${MSHV_MCP_NAME} MCP is Updated across ${count} node(s)."
      return 0
    fi
    if [[ "${elapsed}" -ge "${MCP_TIMEOUT}" ]]; then
      log_error "${MSHV_MCP_NAME} MCP did not converge through the normal path."
      oc get mcp "${MSHV_MCP_NAME}" -o yaml || true
      exit 1
    fi
    log_info "  MCP: machineCount=${count} updated=${updated} updating=${updating} degraded=${degraded} (${elapsed}s/${MCP_TIMEOUT}s)"
    sleep 30
    elapsed=$((elapsed + 30))
  done
}

do_render() {
  local apiversion="${MOC_APIVERSION:-machineconfiguration.openshift.io/v1}"
  render_machineosconfig "${apiversion}"
}

do_apply() {
  log_info "=== Day-2 RHCOS kernel layering (on-cluster) for the ${MSHV_MCP_NAME} pool ==="
  verify_preconditions
  ensure_base_pull_secret
  resolve_push_secret

  local manifest
  manifest="$(mktemp)"
  trap 'rm -f "${manifest}"' RETURN
  render_machineosconfig "${MOC_APIVERSION}" > "${manifest}" || exit 1

  log_info "Applying MachineOSConfig ${MOC_NAME} (source=${KERNEL_RPM_SOURCE})..."
  oc apply -f "${manifest}"

  wait_for_build
  wait_for_mcp

  log_ok "Custom kernel layer applied to the ${MSHV_MCP_NAME} pool."
  log_info "Verify on the node with: ./scripts/12b-verify-kernel-layer.sh"
}

do_revert() {
  log_info "=== Reverting the RHCOS kernel layer on the ${MSHV_MCP_NAME} pool ==="
  MOC_APIVERSION="$(detect_moc_apiversion)" || {
    log_error "MachineOSConfig API not served; nothing to revert."
    exit 1
  }
  if ! oc get machineosconfig "${MOC_NAME}" >/dev/null 2>&1; then
    log_ok "MachineOSConfig ${MOC_NAME} not present; nothing to revert."
    return 0
  fi
  log_info "Deleting MachineOSConfig ${MOC_NAME} (rolls the pool back to the base image)..."
  oc delete machineosconfig "${MOC_NAME}"
  wait_for_mcp
  log_ok "Reverted the ${MSHV_MCP_NAME} pool to its base image."
}

case "${ACTION}" in
  apply) do_apply ;;
  revert) do_revert ;;
  render)
    MOC_APIVERSION="$(detect_moc_apiversion 2>/dev/null || echo 'machineconfiguration.openshift.io/v1')"
    do_render
    ;;
  *)
    log_error "Unknown action '${ACTION}'. Use apply, revert, or render."
    exit 1
    ;;
esac
