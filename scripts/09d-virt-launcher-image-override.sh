#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

action="${1:-}"
state_file="${VIRT_LAUNCHER_OVERRIDE_STATE_FILE:-${_REPO_ROOT}/.smoke-runs/virt-launcher-override.env}"
namespace="openshift-cnv"
deployment="virt-operator"
annotation_key="kubevirt.kubevirt.io/jsonpatch"
secret_name="${VIRT_LAUNCHER_PULL_SECRET_NAME:-qemu-3-launcher-registry}"
state_annotation="validation.aro-virt.io/override-state"

usage() { echo "Usage: $0 status|apply|restore" >&2; exit 2; }
[[ "${action}" =~ ^(status|apply|restore)$ ]] || usage
check_command oc || exit 1
check_command jq || exit 1
check_command flock || exit 1

mkdir -p "$(dirname "${state_file}")"
lock_file="${state_file}.lock"
exec 9>"${lock_file}"
flock -n 9 || { log_error "Another launcher override operation is using ${lock_file}."; exit 1; }

CLUSTER_SERVER="$(oc whoami --show-server)"
csv="$(oc get csv -n "${namespace}" -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Virtualization")].metadata.name}')"
hco="$(oc get hco -n "${namespace}" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${csv}" && -n "${hco}" ]] || { log_error "OpenShift Virtualization CSV or HCO not found."; exit 1; }
CSV_UID="$(oc get csv "${csv}" -n "${namespace}" -o jsonpath='{.metadata.uid}')"
DEPLOYMENT_UID="$(oc get deployment "${deployment}" -n "${namespace}" -o jsonpath='{.metadata.uid}')"
HCO_UID="$(oc get hco "${hco}" -n "${namespace}" -o jsonpath='{.metadata.uid}')"

current_image() {
  oc get deployment "${deployment}" -n "${namespace}" -o json \
    | jq -r '.spec.template.spec.containers[].env[]? | select(.name=="VIRT_LAUNCHER_IMAGE") | .value'
}

csv_image() {
  oc get csv "${csv}" -n "${namespace}" -o json \
    | jq -r '.spec.install.spec.deployments[] | select(.name=="virt-operator") | .spec.template.spec.containers[].env[]? | select(.name=="VIRT_LAUNCHER_IMAGE") | .value'
}

hco_jsonpatch() {
  oc get hco "${hco}" -n "${namespace}" -o json \
    | jq -r --arg key "${annotation_key}" '.metadata.annotations[$key] // ""'
}

set_csv_image() {
  local expected="$1" image="$2" object patch
  object="$(oc get csv "${csv}" -n "${namespace}" -o json)"
  patch="$(jq -c --arg expected "${expected}" --arg image "${image}" '
    [{op:"test",path:"/metadata/resourceVersion",value:.metadata.resourceVersion}] +
    [.spec.install.spec.deployments | to_entries[]
      | select(.value.name=="virt-operator")
      | .key as $deploymentIndex
      | .value.spec.template.spec.containers | to_entries[]
      | .key as $containerIndex
      | .value.env | to_entries[]
      | select(.value.name=="VIRT_LAUNCHER_IMAGE")
      | {op:"test",path:("/spec/install/spec/deployments/"+($deploymentIndex|tostring)+"/spec/template/spec/containers/"+($containerIndex|tostring)+"/env/"+(.key|tostring)+"/value"),value:$expected},
        {op:"replace",path:("/spec/install/spec/deployments/"+($deploymentIndex|tostring)+"/spec/template/spec/containers/"+($containerIndex|tostring)+"/env/"+(.key|tostring)+"/value"),value:$image}
    ]' <<< "${object}")"
  [[ "$(jq 'length' <<< "${patch}")" -eq 3 ]] || { log_error "CSV VIRT_LAUNCHER_IMAGE field is ambiguous or missing."; return 1; }
  oc patch clusterserviceversion "${csv}" -n "${namespace}" --type=json -p "${patch}" >/dev/null
}

set_deployment_image() {
  local expected="$1" image="$2" object patch
  object="$(oc get deployment "${deployment}" -n "${namespace}" -o json)"
  patch="$(jq -c --arg expected "${expected}" --arg image "${image}" '
    [{op:"test",path:"/metadata/resourceVersion",value:.metadata.resourceVersion}] +
    [.spec.template.spec.containers | to_entries[]
      | .key as $containerIndex
      | .value.env | to_entries[]
      | select(.value.name=="VIRT_LAUNCHER_IMAGE")
      | {op:"test",path:("/spec/template/spec/containers/"+($containerIndex|tostring)+"/env/"+(.key|tostring)+"/value"),value:$expected},
        {op:"replace",path:("/spec/template/spec/containers/"+($containerIndex|tostring)+"/env/"+(.key|tostring)+"/value"),value:$image}
    ]' <<< "${object}")"
  [[ "$(jq 'length' <<< "${patch}")" -eq 3 ]] || { log_error "Deployment VIRT_LAUNCHER_IMAGE field is ambiguous or missing."; return 1; }
  oc patch deployment "${deployment}" -n "${namespace}" --type=json -p "${patch}" >/dev/null
}

set_hco_jsonpatch() {
  local expected="$1" value="$2" object resource_version current patch op path
  object="$(oc get hco "${hco}" -n "${namespace}" -o json)"
  resource_version="$(jq -r '.metadata.resourceVersion' <<< "${object}")"
  current="$(jq -r --arg key "${annotation_key}" '.metadata.annotations[$key] // ""' <<< "${object}")"
  [[ "${current}" == "${expected}" ]] || { log_error "HCO jsonpatch changed concurrently."; return 1; }
  path="/metadata/annotations/kubevirt.kubevirt.io~1jsonpatch"
  if [[ -n "${value}" ]]; then
    [[ -n "${current}" ]] && op=replace || op=add
    patch="$(jq -cn --arg rv "${resource_version}" --arg op "${op}" --arg path "${path}" --arg value "${value}" '[{op:"test",path:"/metadata/resourceVersion",value:$rv},{op:$op,path:$path,value:$value}]')"
  else
    [[ -n "${current}" ]] || return 0
    patch="$(jq -cn --arg rv "${resource_version}" --arg path "${path}" '[{op:"test",path:"/metadata/resourceVersion",value:$rv},{op:"remove",path:$path}]')"
  fi
  oc patch hco "${hco}" -n "${namespace}" --type=json -p "${patch}" >/dev/null
}

verify_identity() {
  [[ "$(oc whoami --show-server)" == "${CLUSTER_SERVER}" ]] \
    && [[ "$(oc get csv "${csv}" -n "${namespace}" -o jsonpath='{.metadata.uid}')" == "${CSV_UID}" ]] \
    && [[ "$(oc get deployment "${deployment}" -n "${namespace}" -o jsonpath='{.metadata.uid}')" == "${DEPLOYMENT_UID}" ]] \
    && [[ "$(oc get hco "${hco}" -n "${namespace}" -o jsonpath='{.metadata.uid}')" == "${HCO_UID}" ]]
}

get_owned_secret() {
  local secret
  secret="$(oc get secret "${secret_name}" -n "${namespace}" -o json 2>/dev/null)" || return 1
  [[ "$(jq -r '.metadata.uid' <<< "${secret}")" == "${SECRET_UID}" \
    && "$(jq -r --arg key "${state_annotation}" '.metadata.annotations[$key] // ""' <<< "${secret}")" == "${STATE_ID}" ]] || return 1
  printf '%s\n' "${secret}"
}

refresh_owned_secret() {
  local pull_secret_file="$1" secret resource_version encoded patch
  secret="$(get_owned_secret)" || { log_error "Pull secret is not owned by this override."; return 1; }
  resource_version="$(jq -r '.metadata.resourceVersion' <<< "${secret}")"
  encoded="$(base64 -w0 < "${pull_secret_file}")"
  patch="$(jq -cn --arg rv "${resource_version}" --arg uid "${SECRET_UID}" --arg encoded "${encoded}" \
    '[{op:"test",path:"/metadata/resourceVersion",value:$rv},{op:"test",path:"/metadata/uid",value:$uid},{op:"replace",path:"/data/.dockerconfigjson",value:$encoded}]')"
  oc patch secret "${secret_name}" -n "${namespace}" --type=json -p "${patch}" >/dev/null
}

is_original_or_applied() {
  local actual="$1" original="$2" applied="$3"
  [[ "${actual}" == "${original}" || "${actual}" == "${applied}" ]]
}

write_state() {
  local temp_state
  temp_state="$(mktemp "${state_file}.tmp.XXXXXX")"
  printf 'CLUSTER_SERVER=%q\nCSV_NAME=%q\nCSV_UID=%q\nDEPLOYMENT_UID=%q\nHCO_NAME=%q\nHCO_UID=%q\nORIGINAL_VIRT_LAUNCHER_IMAGE=%q\nORIGINAL_CSV_VIRT_LAUNCHER_IMAGE=%q\nORIGINAL_CSV=%q\nORIGINAL_HCO_JSONPATCH=%q\nAPPLIED_HCO_JSONPATCH=%q\nAPPLIED_VIRT_LAUNCHER_IMAGE=%q\nSECRET_CREATED=%q\nSECRET_UID=%q\nSTATE_ID=%q\n' \
    "${CLUSTER_SERVER}" "${csv}" "${CSV_UID}" "${DEPLOYMENT_UID}" "${hco}" "${HCO_UID}" "${ORIGINAL_VIRT_LAUNCHER_IMAGE}" "${ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE}" "${ORIGINAL_CSV}" "${ORIGINAL_HCO_JSONPATCH}" "${APPLIED_HCO_JSONPATCH}" "${APPLIED_VIRT_LAUNCHER_IMAGE}" "${SECRET_CREATED}" "${SECRET_UID}" "${STATE_ID}" > "${temp_state}"
  chmod 600 "${temp_state}"
  mv -f "${temp_state}" "${state_file}"
}

adopt_or_create_secret() {
  local pull_secret_file="$1" secret annotation
  if secret="$(oc get secret "${secret_name}" -n "${namespace}" -o json 2>/dev/null)"; then
    annotation="$(jq -r --arg key "${state_annotation}" '.metadata.annotations[$key] // ""' <<< "${secret}")"
    [[ "${annotation}" == "${STATE_ID}" ]] || { log_error "Secret ${namespace}/${secret_name} is not owned by this override."; return 1; }
    SECRET_CREATED=true
    SECRET_UID="$(jq -r '.metadata.uid' <<< "${secret}")"
    write_state
    refresh_owned_secret "${pull_secret_file}"
    return 0
  fi
  oc create secret generic "${secret_name}" -n "${namespace}" --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="${pull_secret_file}" --dry-run=client -o json \
    | jq --arg key "${state_annotation}" --arg id "${STATE_ID}" '.metadata.annotations[$key]=$id' | oc create -f - >/dev/null
  SECRET_CREATED=true
  SECRET_UID="$(oc get secret "${secret_name}" -n "${namespace}" -o jsonpath='{.metadata.uid}')"
  write_state
}

wait_for_kubevirt_launcher() {
  local expected="$1" expected_secret="$2" elapsed=0 timeout=1200 config handler
  local observed target handler_init handler_ready handler_desired holder secret_present
  while true; do
    config="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n "${namespace}" -o json 2>/dev/null || true)"
    handler="$(oc get daemonset virt-handler -n "${namespace}" -o json 2>/dev/null || true)"
    observed="$(jq -r '.status.observedDeploymentConfig | fromjson | .virtLauncherImage' <<< "${config}" 2>/dev/null || echo unavailable)"
    target="$(jq -r '.status.targetDeploymentConfig | fromjson | .virtLauncherImage' <<< "${config}" 2>/dev/null || echo unavailable)"
    secret_present="$(jq -r --arg name "${expected_secret}" 'any(.spec.imagePullSecrets[]?; .name == $name)' <<< "${config}" 2>/dev/null || echo false)"
    handler_init="$(jq -r '[.spec.template.spec.initContainers[]? | select(.name=="virt-launcher") | .image] | if length == 1 then .[0] else "unavailable" end' <<< "${handler}" 2>/dev/null || echo unavailable)"
    holder="$(jq -r '[.spec.template.spec.containers[]? | select(.name=="virt-launcher-image-holder") | .image] | if length == 1 then .[0] else "unavailable" end' <<< "${handler}" 2>/dev/null || echo unavailable)"
    handler_ready="$(jq -r '.status.numberReady // 0' <<< "${handler}" 2>/dev/null || echo 0)"
    handler_desired="$(jq -r '.status.desiredNumberScheduled // 0' <<< "${handler}" 2>/dev/null || echo 0)"
    if [[ "${observed}" == "${expected}" && "${target}" == "${expected}" \
      && "${handler_init}" == "${expected}" && "${holder}" == "${expected}" \
      && "${handler_desired}" -gt 0 && "${handler_ready}" == "${handler_desired}" \
      && "${secret_present}" == "true" ]]; then return 0; fi
    (( elapsed >= timeout )) && { log_error "KubeVirt convergence timed out: observed=${observed} target=${target} init=${handler_init} holder=${holder} ready=${handler_ready}/${handler_desired} secret=${secret_present}"; return 1; }
    sleep 15; elapsed=$((elapsed + 15))
  done
}

wait_for_original() {
  local expected="$1" elapsed=0 timeout=1200 config handler observed target handler_init handler_ready handler_desired
  while true; do
    config="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n "${namespace}" -o json)"
    handler="$(oc get daemonset virt-handler -n "${namespace}" -o json)"
    observed="$(jq -r '.status.observedDeploymentConfig | fromjson | .virtLauncherImage' <<< "${config}")"
    target="$(jq -r '.status.targetDeploymentConfig | fromjson | .virtLauncherImage' <<< "${config}")"
    handler_init="$(jq -r '[.spec.template.spec.initContainers[]? | select(.name=="virt-launcher") | .image] | if length == 1 then .[0] else "unavailable" end' <<< "${handler}")"
    handler_ready="$(jq -r '.status.numberReady // 0' <<< "${handler}")"
    handler_desired="$(jq -r '.status.desiredNumberScheduled // 0' <<< "${handler}")"
    if [[ "${observed}" == "${expected}" && "${target}" == "${expected}" && "${handler_init}" == "${expected}" \
      && "${handler_desired}" -gt 0 && "${handler_ready}" == "${handler_desired}" ]]; then return 0; fi
    (( elapsed >= timeout )) && return 1
    sleep 15; elapsed=$((elapsed + 15))
  done
}

restore_override() {
  verify_identity || { log_error "Cluster or resource identity changed; refusing stale restore."; return 1; }
  deployment_current="$(current_image)"; csv_current="$(csv_image)"; hco_current="$(hco_jsonpatch)"
  is_original_or_applied "${deployment_current}" "${ORIGINAL_VIRT_LAUNCHER_IMAGE}" "${APPLIED_VIRT_LAUNCHER_IMAGE}" \
    && is_original_or_applied "${csv_current}" "${ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE}" "${APPLIED_VIRT_LAUNCHER_IMAGE}" \
    && is_original_or_applied "${hco_current}" "${ORIGINAL_HCO_JSONPATCH}" "${APPLIED_HCO_JSONPATCH}" \
    || { log_error "Override persistence sources contain third-party drift; refusing restore."; return 1; }
  if oc get secret "${secret_name}" -n "${namespace}" >/dev/null 2>&1; then
    if [[ -z "${SECRET_UID:-}" ]]; then
      secret="$(oc get secret "${secret_name}" -n "${namespace}" -o json)"
      [[ "$(jq -r --arg key "${state_annotation}" '.metadata.annotations[$key] // ""' <<< "${secret}")" == "${STATE_ID}" ]] \
        || { log_error "Pull secret is not owned by this override."; return 1; }
      SECRET_CREATED=true; SECRET_UID="$(jq -r '.metadata.uid' <<< "${secret}")"; write_state
    fi
    get_owned_secret >/dev/null || { log_error "Pull secret ownership changed; refusing deletion."; return 1; }
  fi
  [[ "${csv_current}" == "${ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE}" ]] || set_csv_image "${APPLIED_VIRT_LAUNCHER_IMAGE}" "${ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE}"
  [[ "${deployment_current}" == "${ORIGINAL_VIRT_LAUNCHER_IMAGE}" ]] || set_deployment_image "${APPLIED_VIRT_LAUNCHER_IMAGE}" "${ORIGINAL_VIRT_LAUNCHER_IMAGE}"
  oc rollout status deployment/"${deployment}" -n "${namespace}" --timeout=5m
  [[ "${hco_current}" == "${ORIGINAL_HCO_JSONPATCH}" ]] || set_hco_jsonpatch "${APPLIED_HCO_JSONPATCH}" "${ORIGINAL_HCO_JSONPATCH}"
  wait_for_original "${ORIGINAL_VIRT_LAUNCHER_IMAGE}"
  if [[ "${SECRET_CREATED}" == "true" ]] && oc get secret "${secret_name}" -n "${namespace}" >/dev/null 2>&1; then
    secret="$(get_owned_secret)" || { log_error "Pull secret ownership changed during rollback."; return 1; }
    secret_resource_version="$(jq -r '.metadata.resourceVersion' <<< "${secret}")"
    delete_body="$(jq -cn --arg uid "${SECRET_UID}" --arg rv "${secret_resource_version}" '{apiVersion:"v1",kind:"DeleteOptions",preconditions:{uid:$uid,resourceVersion:$rv}}')"
    oc delete --raw "/api/v1/namespaces/${namespace}/secrets/${secret_name}" -f - <<< "${delete_body}" >/dev/null
  fi
  rm -f "${state_file}"
}

resume_apply() {
  local pull_secret_file="$1" deployment_current csv_current hco_current
  verify_identity || { log_error "Cluster or resource identity changed; refusing resume."; return 1; }
  deployment_current="$(current_image)"; csv_current="$(csv_image)"; hco_current="$(hco_jsonpatch)"
  is_original_or_applied "${deployment_current}" "${ORIGINAL_VIRT_LAUNCHER_IMAGE}" "${APPLIED_VIRT_LAUNCHER_IMAGE}" \
    && is_original_or_applied "${csv_current}" "${ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE}" "${APPLIED_VIRT_LAUNCHER_IMAGE}" \
    && is_original_or_applied "${hco_current}" "${ORIGINAL_HCO_JSONPATCH}" "${APPLIED_HCO_JSONPATCH}" \
    || { log_error "Existing override state contains third-party drift; refusing resume."; return 1; }
  adopt_or_create_secret "${pull_secret_file}"
  [[ "${hco_current}" == "${APPLIED_HCO_JSONPATCH}" ]] || set_hco_jsonpatch "${ORIGINAL_HCO_JSONPATCH}" "${APPLIED_HCO_JSONPATCH}"
  [[ "${csv_current}" == "${APPLIED_VIRT_LAUNCHER_IMAGE}" ]] || set_csv_image "${ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE}" "${APPLIED_VIRT_LAUNCHER_IMAGE}"
  [[ "${deployment_current}" == "${APPLIED_VIRT_LAUNCHER_IMAGE}" ]] || set_deployment_image "${ORIGINAL_VIRT_LAUNCHER_IMAGE}" "${APPLIED_VIRT_LAUNCHER_IMAGE}"
  oc rollout status deployment/"${deployment}" -n "${namespace}" --timeout=5m
  wait_for_kubevirt_launcher "${APPLIED_VIRT_LAUNCHER_IMAGE}" "${secret_name}"
}

case "${action}" in
  status)
    printf 'deployment=%s\ncsv=%s\nstate=%s\n' "$(current_image)" "$(csv_image)" "$([[ -f "${state_file}" ]] && echo present || echo absent)"
    ;;
  apply)
    image="${VIRT_LAUNCHER_IMAGE:?VIRT_LAUNCHER_IMAGE must be a repository@sha256 digest}"
    pull_secret_file="${VIRT_LAUNCHER_IMAGE_PULL_SECRET_FILE:?VIRT_LAUNCHER_IMAGE_PULL_SECRET_FILE is required}"
    [[ "${image}" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || { log_error "VIRT_LAUNCHER_IMAGE must be digest-pinned"; exit 1; }
    [[ -f "${pull_secret_file}" ]] || { log_error "Pull secret file not found: ${pull_secret_file}"; exit 1; }
    if [[ -f "${state_file}" ]]; then
      source "${state_file}"
      [[ "${APPLIED_VIRT_LAUNCHER_IMAGE}" == "${image}" ]] || { log_error "Existing override state targets another image."; exit 1; }
      resume_apply "${pull_secret_file}"
      log_ok "Requested launcher override is already active."
      exit 0
    fi
    ORIGINAL_VIRT_LAUNCHER_IMAGE="$(current_image)"; ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE="$(csv_image)"
    ORIGINAL_HCO_JSONPATCH="$(hco_jsonpatch)"; ORIGINAL_CSV="${csv}"; APPLIED_VIRT_LAUNCHER_IMAGE="${image}"
    [[ "${ORIGINAL_CSV_VIRT_LAUNCHER_IMAGE}" == "${ORIGINAL_VIRT_LAUNCHER_IMAGE}" ]] || { log_error "Original CSV and Deployment launcher images differ."; exit 1; }
    original_patch="${ORIGINAL_HCO_JSONPATCH:-[]}"; jq -e . <<< "${original_patch}" >/dev/null
    jq -e 'all(.[]?; (.path | startswith("/spec/imagePullSecrets") | not))' <<< "${original_patch}" >/dev/null || { log_error "HCO jsonpatch already manages imagePullSecrets."; exit 1; }
    existing_pull_secrets="$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n "${namespace}" -o json | jq '.spec.imagePullSecrets // []')"
    [[ "${existing_pull_secrets}" == "[]" ]] || { log_error "KubeVirt already has imagePullSecrets; refusing replacement."; exit 1; }
    APPLIED_HCO_JSONPATCH="$(jq -c --arg secret "${secret_name}" '. + [{op:"add",path:"/spec/imagePullSecrets",value:[{name:$secret}]}]' <<< "${original_patch}")"
    [[ ! -e "${state_file}" ]] || { log_error "Override state already exists: ${state_file}"; exit 1; }
    oc get secret "${secret_name}" -n "${namespace}" >/dev/null 2>&1 && { log_error "Secret ${namespace}/${secret_name} already exists."; exit 1; }
    STATE_ID="$(date -u +%Y%m%dT%H%M%S)-$$"; SECRET_CREATED=false; SECRET_UID=""
    write_state
    resume_apply "${pull_secret_file}"
    log_warn "Persistent unsupported launcher override is active. It will remain active until explicit restore."
    ;;
  restore)
    [[ -f "${state_file}" ]] || { log_error "Override state not found: ${state_file}"; exit 1; }
    source "${state_file}"
    [[ "${CSV_NAME}" == "${csv}" && "${HCO_NAME}" == "${hco}" ]] || { log_error "Stored resource names do not match current resources."; exit 1; }
    restore_override
    log_ok "Restored original virt-launcher image and pull-secret configuration."
    ;;
esac
