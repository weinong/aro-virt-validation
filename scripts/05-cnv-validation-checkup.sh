#!/usr/bin/env bash
# =============================================================================
# Phase 5 — Run the OCP Virt Validation Checkup
# https://github.com/openshift-cnv/ocp-virt-validation-checkup
#
# Usage:
#   ./scripts/05-cnv-validation-checkup.sh            # run with defaults
#   TEST_SUITES=compute ./scripts/05-cnv-validation-checkup.sh   # single suite
#   DRY_RUN=true ./scripts/05-cnv-validation-checkup.sh          # preview only
#
# Prerequisites:
#   - oc logged in to the cluster as kube:admin
#   - podman available and logged in to quay.io (for the checkup image)
#   - CNV installed (CSV present in openshift-cnv namespace)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Load .env if present (contains QUAY_USERNAME / QUAY_PASSWORD)
[[ -f "${_REPO_ROOT}/.env" ]] && source "${_REPO_ROOT}/.env"

# ---------------------------------------------------------------------------
# Configurable parameters (override via environment)
# ---------------------------------------------------------------------------
TEST_SUITES="${TEST_SUITES:-compute,network,storage}"
STORAGE_CLASS="${STORAGE_CLASS:-managed-csi}"
# Omit RWX caps since ARO only has Azure Disk (RWO).
STORAGE_CAPABILITIES="${STORAGE_CAPABILITIES:-storageClassRhel,storageClassWindows,storageRWOBlock,storageRWOFileSystem,storageClassCSI,storageSnapshot,WFFC}"
TEST_SKIPS="${TEST_SKIPS:-}"
DRY_RUN="${DRY_RUN:-false}"
FULL_SUITE="${FULL_SUITE:-false}"
JOB_TIMEOUT="${JOB_TIMEOUT:-7200}"  # seconds (2 hours)
CHECKUP_NS="ocp-virt-validation"
RESULTS_DIR="${_REPO_ROOT}/.checkup-runs"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
log_info "=== Phase 5: OCP Virt Validation Checkup ==="

check_command oc   || exit 1
check_command podman || exit 1
check_command jq   || exit 1

log_info "Verifying cluster login..."
CURRENT_USER="$(oc whoami 2>/dev/null)" || { log_error "Not logged in to cluster. Run 'oc login' first."; exit 1; }
log_ok  "Logged in as ${CURRENT_USER}"

# ---------------------------------------------------------------------------
# Extract validation image from the installed CNV CSV
# ---------------------------------------------------------------------------
log_info "Extracting validation checkup image from CNV CSV..."
CSV_NAME="$(oc get csv -n openshift-cnv -o json \
  | jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged")) | .metadata.name')"
[[ -z "${CSV_NAME}" ]] && { log_error "No kubevirt-hyperconverged CSV found in openshift-cnv."; exit 1; }

OCP_VIRT_VALIDATION_IMAGE="$(oc get csv -n openshift-cnv "${CSV_NAME}" -o json \
  | jq -r '.spec.relatedImages[] | select(.name | contains("ocp-virt-validation-checkup")).image')"
[[ -z "${OCP_VIRT_VALIDATION_IMAGE}" ]] && { log_error "Validation checkup image not found in CSV ${CSV_NAME}."; exit 1; }

log_ok  "CSV: ${CSV_NAME}"
log_ok  "Image: ${OCP_VIRT_VALIDATION_IMAGE}"

# ---------------------------------------------------------------------------
# Ensure podman can pull the image (verify quay.io login)
# ---------------------------------------------------------------------------
log_info "Verifying podman can access the checkup image..."
if ! podman image exists "${OCP_VIRT_VALIDATION_IMAGE}" 2>/dev/null; then
  if ! podman pull --quiet "${OCP_VIRT_VALIDATION_IMAGE}" 2>/dev/null; then
    log_warn "Pull failed — attempting podman login to quay.io..."
    if [[ -n "${QUAY_USERNAME:-}" && -n "${QUAY_PASSWORD:-}" ]]; then
      echo "${QUAY_PASSWORD}" | podman login -u "${QUAY_USERNAME}" --password-stdin quay.io || {
        log_error "podman login to quay.io failed. Check QUAY_USERNAME / QUAY_PASSWORD in .env."
        exit 1
      }
      podman pull --quiet "${OCP_VIRT_VALIDATION_IMAGE}" || {
        log_error "Still cannot pull image after login."
        exit 1
      }
    else
      log_error "Cannot pull image. Set QUAY_USERNAME and QUAY_PASSWORD in .env, or run 'podman login quay.io' manually."
      exit 1
    fi
  fi
fi
log_ok  "Image available locally."

# ---------------------------------------------------------------------------
# Print run configuration
# ---------------------------------------------------------------------------
log_info "--- Run configuration ---"
log_info "  TEST_SUITES:          ${TEST_SUITES}"
log_info "  STORAGE_CLASS:        ${STORAGE_CLASS}"
log_info "  STORAGE_CAPABILITIES: ${STORAGE_CAPABILITIES}"
log_info "  TEST_SKIPS:           ${TEST_SKIPS:-<none>}"
log_info "  DRY_RUN:              ${DRY_RUN}"
log_info "  FULL_SUITE:           ${FULL_SUITE}"
log_info "  JOB_TIMEOUT:          ${JOB_TIMEOUT}s"
log_info "-------------------------"

# ---------------------------------------------------------------------------
# Step 1: Generate YAML and apply (creates namespace, RBAC, PVC, Job)
# ---------------------------------------------------------------------------
log_info "Generating validation checkup resources..."
GENERATE_YAML="$(podman run --rm \
  -e OCP_VIRT_VALIDATION_IMAGE="${OCP_VIRT_VALIDATION_IMAGE}" \
  -e TEST_SUITES="${TEST_SUITES}" \
  -e STORAGE_CLASS="${STORAGE_CLASS}" \
  -e STORAGE_CAPABILITIES="${STORAGE_CAPABILITIES}" \
  -e TEST_SKIPS="${TEST_SKIPS}" \
  -e DRY_RUN="${DRY_RUN}" \
  -e FULL_SUITE="${FULL_SUITE}" \
  "${OCP_VIRT_VALIDATION_IMAGE}" generate 2>/dev/null)"

# Extract TIMESTAMP from the generated YAML (the tool embeds it in PVC name)
TIMESTAMP="$(echo "${GENERATE_YAML}" | grep -oP 'ocp-virt-validation-pvc-\K[0-9]{8}-[0-9]{6}' | head -1)"
[[ -z "${TIMESTAMP}" ]] && { log_error "Could not extract timestamp from generated YAML."; exit 1; }
log_ok  "Run timestamp: ${TIMESTAMP}"

# Save the generated YAML for reference
mkdir -p "${RESULTS_DIR}/${TIMESTAMP}"
echo "${GENERATE_YAML}" > "${RESULTS_DIR}/${TIMESTAMP}/generate.yaml"
log_ok  "Saved generate YAML to .checkup-runs/${TIMESTAMP}/generate.yaml"

log_info "Applying resources to cluster..."
echo "${GENERATE_YAML}" | oc apply -f - 2>&1
log_ok  "Resources applied."

# ---------------------------------------------------------------------------
# Step 2: Wait for the Job to complete
# ---------------------------------------------------------------------------
JOB_NAME="ocp-virt-validation-job-${TIMESTAMP}"
log_info "Waiting for Job ${JOB_NAME} to complete (timeout: ${JOB_TIMEOUT}s)..."
log_info "  Monitor progress:  oc logs -f -n ${CHECKUP_NS} job/${JOB_NAME}"

if oc wait --for=condition=complete "job/${JOB_NAME}" \
     -n "${CHECKUP_NS}" --timeout="${JOB_TIMEOUT}s" 2>/dev/null; then
  log_ok "Job completed successfully."
  JOB_STATUS="Complete"
else
  # Check if it failed vs timed out
  FAILED="$(oc get job "${JOB_NAME}" -n "${CHECKUP_NS}" -o jsonpath='{.status.failed}' 2>/dev/null || echo "")"
  if [[ "${FAILED}" -gt 0 ]] 2>/dev/null; then
    log_error "Job FAILED. Check logs: oc logs -n ${CHECKUP_NS} job/${JOB_NAME}"
    JOB_STATUS="Failed"
  else
    log_error "Job timed out after ${JOB_TIMEOUT}s."
    JOB_STATUS="Timeout"
  fi
fi

# Save job logs regardless of status
oc logs -n "${CHECKUP_NS}" "job/${JOB_NAME}" > "${RESULTS_DIR}/${TIMESTAMP}/job.log" 2>&1 || true
log_ok  "Job logs saved to .checkup-runs/${TIMESTAMP}/job.log"

# ---------------------------------------------------------------------------
# Step 3: Deploy results viewer (nginx pod + Route)
# ---------------------------------------------------------------------------
log_info "Generating results viewer resources..."
RESULTS_YAML="$(podman run --rm \
  -e OCP_VIRT_VALIDATION_IMAGE="${OCP_VIRT_VALIDATION_IMAGE}" \
  -e TIMESTAMP="${TIMESTAMP}" \
  "${OCP_VIRT_VALIDATION_IMAGE}" get_results 2>/dev/null)"

echo "${RESULTS_YAML}" > "${RESULTS_DIR}/${TIMESTAMP}/get_results.yaml"
log_ok  "Saved get_results YAML to .checkup-runs/${TIMESTAMP}/get_results.yaml"

log_info "Applying results viewer..."
echo "${RESULTS_YAML}" | oc apply -f - 2>&1

# Wait for the nginx pod to be ready
READER_POD="pvc-reader-${TIMESTAMP}"
log_info "Waiting for results viewer pod ${READER_POD}..."
oc wait --for=condition=ready "pod/${READER_POD}" -n "${CHECKUP_NS}" --timeout=120s 2>/dev/null || \
  log_warn "Results viewer pod not ready after 120s."

# Get the Route URL
ROUTE_URL="$(oc get route "pvcreader-${TIMESTAMP}" -n "${CHECKUP_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")"

# ---------------------------------------------------------------------------
# Step 4: Print summary
# ---------------------------------------------------------------------------
log_info "============================================"
log_info "  Validation Checkup Summary"
log_info "============================================"
log_info "  Job:       ${JOB_NAME}"
log_info "  Status:    ${JOB_STATUS}"
log_info "  Suites:    ${TEST_SUITES}"
log_info "  Namespace: ${CHECKUP_NS}"

if [[ -n "${ROUTE_URL}" ]]; then
  log_ok  "  Results:   https://${ROUTE_URL}"
else
  log_warn "  Route URL not available. Check: oc get route -n ${CHECKUP_NS}"
fi

log_info "  Local artifacts: ${RESULTS_DIR}/${TIMESTAMP}/"
log_info "============================================"

# Print ConfigMap summary if it exists
CM_NAME="ocp-virt-validation-${TIMESTAMP}"
CM_DATA="$(oc get configmap "${CM_NAME}" -n "${CHECKUP_NS}" -o json 2>/dev/null || echo "")"
if [[ -n "${CM_DATA}" ]]; then
  log_info "ConfigMap ${CM_NAME} contents:"
  echo "${CM_DATA}" | jq -r '.data | to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || true
  echo "${CM_DATA}" | jq '.' > "${RESULTS_DIR}/${TIMESTAMP}/configmap.json" 2>/dev/null || true
fi

if [[ "${JOB_STATUS}" == "Complete" ]]; then
  log_ok  "Phase 5 complete."
else
  log_warn "Phase 5 finished with status: ${JOB_STATUS}. Review logs and results above."
  exit 1
fi
