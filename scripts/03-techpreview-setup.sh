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

guard_known_bad_techpreview_payload "${CURRENT_VERSION}" "TechPreviewNoUpgrade validation" || exit 1

CURRENT_FS="$(oc get featuregate/cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo '')"
if [[ "${CURRENT_FS}" == "TechPreviewNoUpgrade" ]]; then
  log_ok "TechPreviewNoUpgrade already enabled."
else
  log_warn "Enabling TechPreviewNoUpgrade. This is irreversible."
  log_warn "Do this only after completing required minor-version upgrades."
  oc patch featuregate/cluster --type merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
  log_ok "TechPreviewNoUpgrade enabled."
fi

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
  MESSAGE="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo '')"
  if [[ "${FAILING}" == "True" ]]; then
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
for crd in "${REQUIRED_CRDS[@]}"; do
  if ! oc get crd "${crd}" &>/dev/null; then
    log_error "Required TechPreview CRD is missing: ${crd}"
    log_error "Stop and document the missing extension instead of applying payload CRDs manually."
    exit 1
  fi
done
log_ok "Required TechPreview CRDs are present."

log_ok "Phase 3 complete. TechPreview prerequisites are ready."
