#!/usr/bin/env bash
# =============================================================================
# 06b-community-hco-install.sh - Install community HyperConverged Cluster
# Operator from upstream main (KubeVirt 1.8.2) for A/B isolation against CNV.
#
# WARNING: As of HCO_REF=0bae30f96f905734cb0d53c22b2e60f7110aaac1 the
# upstream main branch is "1.19.0-unstable" and the
# hyperconverged-cluster-operator Pod CrashLoopBackOff's on a missing
# `migrations.kubevirt.io/v1alpha1` MigController CRD that
# deploy/deploy.sh does not install. See
# issues/2026-05-09b-upstream-kubevirt-isolation.md, "Steps taken" #5.
#
# Use scripts/06c-upstream-kubevirt-install.sh instead for the actual
# upstream KubeVirt install. This script is kept only to reproduce the
# HCO-main failure.
#
# Adapted from the upstream deploy script:
#   https://github.com/kubevirt/hyperconverged-cluster-operator/blob/main/deploy/deploy.sh
#
# Differences from upstream:
#   - Pinned to a single commit SHA (HCO_REF) so re-runs are reproducible.
#   - No cluster-wide namespace deletion: assumes scripts/06-cnv-install.sh
#     output has already been removed.
#   - CRDs applied via server-side apply to avoid the
#     last-applied-configuration annotation size limit.
#
# Diagnostic only. Not a CNV replacement.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

HCO_REF="${HCO_REF:-0bae30f96f905734cb0d53c22b2e60f7110aaac1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.18.2}"
HCO_NAMESPACE="${HCO_NAMESPACE:-kubevirt-hyperconverged}"
RAW_BASE="https://raw.githubusercontent.com/kubevirt/hyperconverged-cluster-operator/${HCO_REF}/deploy"

log_info "=== Phase 6b: Install community HCO (KubeVirt 1.8.2) ==="

check_command oc || exit 1
check_command jq || exit 1

oc whoami &>/dev/null || { log_error "Not logged in."; exit 1; }
log_ok "Logged in as $(oc whoami)"

# ---------------------------------------------------------------------------
# Detect OpenShift; community HCO bundles OpenShift-only operands (SSP,
# console plugin) under specific labels.
# ---------------------------------------------------------------------------
IS_OPENSHIFT="false"
if oc get crd clusterversions.config.openshift.io &>/dev/null; then
  IS_OPENSHIFT="true"
fi
log_info "IS_OPENSHIFT=${IS_OPENSHIFT}"

LABEL_SELECTOR_ARG=()
if [[ "${IS_OPENSHIFT}" != "true" ]]; then
  LABEL_SELECTOR_ARG=(-l 'name!=ssp-operator,name!=hyperconverged-cluster-cli-download')
fi

log_info "Creating namespaces..."
oc create ns "${HCO_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc create ns openshift --dry-run=client -o yaml | oc apply -f - 2>/dev/null || true

log_info "Applying CRDs from HCO_REF=${HCO_REF} (server-side apply)..."
for crd in cluster-network-addons00 containerized-data-importer00 hco00 \
           kubevirt00 hostpath-provisioner00 scheduling-scale-performance00 \
           application-aware-quota00; do
  oc apply --server-side --force-conflicts "${LABEL_SELECTOR_ARG[@]}" \
    -f "${RAW_BASE}/crds/${crd}.crd.yaml"
done

log_info "Deploying cert-manager ${CERT_MANAGER_VERSION}..."
oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
oc -n cert-manager wait deployment/cert-manager --for=condition=Available --timeout=300s
oc -n cert-manager wait deployment/cert-manager-webhook --for=condition=Available --timeout=300s

log_info "Applying RBAC, webhooks, operator (HCO_REF=${HCO_REF})..."
for f in cluster_role.yaml service_account.yaml cluster_role_binding.yaml \
         webhooks.yaml operator.yaml; do
  oc apply "${LABEL_SELECTOR_ARG[@]}" -n "${HCO_NAMESPACE}" -f "${RAW_BASE}/${f}"
done

log_info "Waiting for hyperconverged-cluster-webhook..."
oc -n "${HCO_NAMESPACE}" wait deployment/hyperconverged-cluster-webhook \
  --for=condition=Available --timeout=300s

log_info "Applying HyperConverged CR (default upstream spec)..."
oc apply "${LABEL_SELECTOR_ARG[@]}" -n "${HCO_NAMESPACE}" -f "${RAW_BASE}/hco.cr.yaml"

log_info "Waiting for HyperConverged Available..."
oc wait HyperConverged kubevirt-hyperconverged -n "${HCO_NAMESPACE}" \
  --for=condition=Available --timeout=30m

log_ok "Community HCO is Available."
oc get csv,hyperconverged,kubevirt -A 2>/dev/null | head -30 || true

log_info "Capturing image versions for the record..."
oc get deployment -n "${HCO_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}' || true
