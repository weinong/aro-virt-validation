#!/usr/bin/env bash
# =============================================================================
# 03-techpreview-setup.sh - Enable and verify TechPreviewNoUpgrade prerequisites
#
# This script intentionally runs after all required minor-version upgrades and
# before CNV/MSHV setup. TechPreviewNoUpgrade is irreversible on the cluster and
# prevents future minor-version upgrades.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

log_info "=== Phase 3: TechPreviewNoUpgrade Setup ==="

check_command oc || exit 1
check_command jq || exit 1

log_info "Verifying cluster login..."
CURRENT_USER="$(oc whoami 2>/dev/null)" || { log_error "Not logged in."; exit 1; }
log_ok "Logged in as ${CURRENT_USER}"

log_info "Checking cluster version..."
CURRENT_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
log_ok "Cluster version: ${CURRENT_VERSION}"

CURRENT_MINOR="$(echo "${CURRENT_VERSION}" | cut -d. -f2)"
if [[ "${CURRENT_MINOR}" -lt 22 ]]; then
  log_error "This validation expects OCP 4.22 or newer before TechPreviewNoUpgrade. Current: ${CURRENT_VERSION}"
  log_error "Run scripts/02-upgrade-cluster.sh 4.22 first."
  exit 1
fi

if is_known_bad_techpreview_payload "${CURRENT_VERSION}"; then
  log_warn "Payload ${CURRENT_VERSION} matches the known CR-before-CRD payload ordering issue."
  log_warn "The flow no longer fails on version alone; scripts/03a-payload-crd-ordering-fix.sh"
  log_warn "detects the defect in the payload and pre-applies the affected CRD(s) as a"
  log_warn "documented workaround (issues/2026-08-24.md, OCPBUGS-99266). The payload bug stays open."
fi

CURRENT_FS="$(oc get featuregate/cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo '')"
if [[ "${CURRENT_FS}" == "TechPreviewNoUpgrade" ]]; then
  log_ok "TechPreviewNoUpgrade already enabled."
else
  log_warn "Enabling TechPreviewNoUpgrade. This is irreversible."
  log_warn "Do this only after completing required minor-version upgrades."
  oc patch featuregate/cluster --type merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
  log_ok "TechPreviewNoUpgrade enabled."
fi

# Some payloads order a feature-gated CR before its own CRD, which wedges the
# CVO under TechPreview (issues/2026-08-24.md). Pre-apply the affected payload
# CRD(s) as a documented workaround so the CVO can make progress.
log_info "Running the payload CR-before-CRD ordering workaround (03a)..."
"${SCRIPT_DIR}/03a-payload-crd-ordering-fix.sh" || {
  log_error "The payload CRD ordering workaround failed."
  exit 1
}

log_info "Waiting for ClusterOperators to settle..."
oc wait co --all --for=condition=Available --timeout=30m

log_info "Waiting for master/worker MCP rollout..."
oc wait mcp master worker --for=condition=Updated --timeout=60m

log_info "Waiting for ClusterVersion to finish applying TechPreview-gated resources..."
CV_TIMEOUT=1800
ELAPSED=0
while true; do
  PROGRESSING="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  FAILING="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Failing")].status}' 2>/dev/null || echo '')"
  FAILING_REASON="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Failing")].reason}' 2>/dev/null || echo '')"
  MESSAGE="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo '')"
  if [[ "${FAILING}" == "True" ]]; then
    if [[ "${FAILING_REASON}" == "UpdatePayloadResourceTypeMissing" ]]; then
      log_warn "CVO is failing with UpdatePayloadResourceTypeMissing; re-running the payload CRD ordering workaround (03a)."
      oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Failing")].message}{"\n"}' || true
      "${SCRIPT_DIR}/03a-payload-crd-ordering-fix.sh" || {
        log_error "The payload CRD ordering workaround failed."
        exit 1
      }
      sleep 30
      ELAPSED=$((ELAPSED + 30))
      continue
    fi
    log_error "ClusterVersion is failing after TechPreviewNoUpgrade."
    oc get clusterversion version -o yaml
    exit 1
  fi
  if [[ "${PROGRESSING}" == "False" ]]; then
    log_ok "ClusterVersion is no longer progressing."
    break
  fi
  if [[ "${ELAPSED}" -ge "${CV_TIMEOUT}" ]]; then
    log_error "Timed out waiting for ClusterVersion Progressing=False after TechPreviewNoUpgrade."
    log_error "Last Progressing message: ${MESSAGE}"
    oc get clusterversion version -o yaml
    exit 1
  fi
  log_info "  ClusterVersion progressing=${PROGRESSING} failing=${FAILING} (${ELAPSED}s/${CV_TIMEOUT}s): ${MESSAGE}"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

DEGRADED="$(oc get co -o json \
  | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name' 2>/dev/null || true)"
if [[ -n "${DEGRADED}" ]]; then
  log_error "ClusterOperators are degraded after TechPreviewNoUpgrade:"
  echo "${DEGRADED}"
  exit 1
fi

log_info "Verifying required TechPreview-gated extension CRDs..."
REQUIRED_CRDS=(
  criocredentialproviderconfigs.config.openshift.io
  dnsnameresolvers.network.openshift.io
  osimagestreams.machineconfiguration.openshift.io
)
REMEDIATION_ATTEMPTED=false
for crd in "${REQUIRED_CRDS[@]}"; do
  if ! oc get crd "${crd}" &>/dev/null; then
    if [[ "${REMEDIATION_ATTEMPTED}" == "false" ]]; then
      log_warn "Required TechPreview CRD ${crd} missing; re-running the payload CRD ordering workaround (03a)."
      "${SCRIPT_DIR}/03a-payload-crd-ordering-fix.sh" || true
      REMEDIATION_ATTEMPTED=true
    fi
    if ! oc get crd "${crd}" &>/dev/null; then
      log_error "Required TechPreview CRD is still missing after the payload workaround: ${crd}"
      log_error "This is outside the known CR-before-CRD ordering defect. Stop and document it under issues/."
      exit 1
    fi
  fi
done
log_ok "Required TechPreview CRDs are present."

log_ok "Phase 3 complete. TechPreview prerequisites are ready."
