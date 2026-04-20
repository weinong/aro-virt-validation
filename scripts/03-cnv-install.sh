#!/usr/bin/env bash
# =============================================================================
# 03-cnv-install.sh - Install pre-release OpenShift Virtualization (CNV) via CLI
#
# Implements Steps 6-9 (CLI path) of Red Hat KB 6070641:
#   - Applies CatalogSource for the nightly CNV index
#   - Creates Namespace, OperatorGroup, and Subscription
#   - Deploys the HyperConverged CR
#   - Waits for all components to become Available
#
# Prerequisites:
#   - 02-cnv-pull-secret.sh has been run (quay.io/openshift-cnv auth in cluster)
#   - oc logged in as cluster-admin
#
# Environment variables:
#   CNV_VERSION - CNV nightly version to install (default: 4.99)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

export CNV_VERSION="${CNV_VERSION:-4.99}"

echo "============================================="
echo " Phase 3: Install OpenShift Virtualization"
echo "   CNV nightly version: ${CNV_VERSION}"
echo "============================================="

# -----------------------------------------------
# 1. Validate prerequisites
# -----------------------------------------------
log_info "Checking prerequisites..."
for cmd in oc jq; do
    check_command "$cmd" || exit 1
done

if ! oc whoami &>/dev/null; then
    log_error "Not logged in to OpenShift. Run: oc login <api-server> -u kubeadmin -p <password>"
    exit 1
fi
log_ok "Logged in as: $(oc whoami)"

# Verify pull-secret has quay.io/openshift-cnv
CNV_AUTH=$(oc get secret pull-secret -n openshift-config -o json \
    | jq -r '.data.".dockerconfigjson"' \
    | base64 -d \
    | jq -r '.auths["quay.io/openshift-cnv"].auth // ""')

if [[ -z "$CNV_AUTH" ]]; then
    log_error "quay.io/openshift-cnv auth not found in cluster pull-secret."
    log_error "Run 02-cnv-pull-secret.sh first."
    exit 1
fi
log_ok "quay.io/openshift-cnv auth present in pull-secret."

# Check MCP is healthy
if ! oc wait mcp master worker --for=condition=Updated --timeout=30s &>/dev/null; then
    log_error "MachineConfigPools are not in Updated state."
    log_error "Wait for the rollout to complete or re-run 02-cnv-pull-secret.sh."
    exit 1
fi
log_ok "MachineConfigPools are Updated."

# -----------------------------------------------
# 2. Apply CatalogSource
# -----------------------------------------------
log_info "Applying CatalogSource for CNV nightly ${CNV_VERSION}..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: cnv-nightly-catalog-source
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/openshift-cnv/nightly-catalog:${CNV_VERSION}
  displayName: OpenShift Virtualization Nightly Index
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 8h
EOF
log_ok "CatalogSource applied."

# -----------------------------------------------
# 3. Wait for CatalogSource to become READY
# -----------------------------------------------
log_info "Waiting for CatalogSource to become READY (up to 5 minutes)..."
TIMEOUT=300
INTERVAL=10
ELAPSED=0
while true; do
    STATE=$(oc get catalogsource cnv-nightly-catalog-source -n openshift-marketplace \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
    if [[ "$STATE" == "READY" ]]; then
        log_ok "CatalogSource is READY."
        break
    fi
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        log_error "CatalogSource did not become READY within ${TIMEOUT}s. Current state: $STATE"
        log_error "Check: oc get catalogsource cnv-nightly-catalog-source -n openshift-marketplace -o yaml"
        exit 1
    fi
    log_info "  CatalogSource state: ${STATE:-Pending} (${ELAPSED}s / ${TIMEOUT}s)..."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

# -----------------------------------------------
# 4. Wait for kubevirt-hyperconverged packagemanifest
# -----------------------------------------------
log_info "Waiting for kubevirt-hyperconverged packagemanifest (up to 3 minutes)..."
TIMEOUT=180
ELAPSED=0
while true; do
    PKG=$(oc get packagemanifest -l catalog=cnv-nightly-catalog-source -n openshift-cnv \
        -o jsonpath='{.items[?(@.metadata.name=="kubevirt-hyperconverged")].metadata.name}' 2>/dev/null || echo "")
    if [[ "$PKG" == "kubevirt-hyperconverged" ]]; then
        log_ok "kubevirt-hyperconverged packagemanifest available."
        break
    fi
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        log_error "kubevirt-hyperconverged packagemanifest not found within ${TIMEOUT}s."
        log_error "Available packagemanifests from nightly catalog:"
        oc get packagemanifest -l catalog=cnv-nightly-catalog-source 2>&1 || true
        exit 1
    fi
    log_info "  Waiting for packagemanifest... (${ELAPSED}s / ${TIMEOUT}s)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

# -----------------------------------------------
# 5. Extract STARTING_CSV
# -----------------------------------------------
log_info "Extracting starting CSV from nightly-${CNV_VERSION} channel..."
STARTING_CSV=$(oc get packagemanifest -l catalog=cnv-nightly-catalog-source \
    -o jsonpath="{$.items[?(@.metadata.name=='kubevirt-hyperconverged')].status.channels[?(@.name==\"nightly-${CNV_VERSION}\")].currentCSV}")

if [[ -z "$STARTING_CSV" ]]; then
    log_error "Could not extract STARTING_CSV for channel nightly-${CNV_VERSION}."
    log_error "Available channels:"
    oc get packagemanifest -l catalog=cnv-nightly-catalog-source \
        -o jsonpath='{.items[?(@.metadata.name=="kubevirt-hyperconverged")].status.channels[*].name}' 2>&1 || true
    echo ""
    exit 1
fi
log_ok "Starting CSV: $STARTING_CSV"

# -----------------------------------------------
# 6. Create Namespace, OperatorGroup, Subscription
# -----------------------------------------------
log_info "Creating Namespace, OperatorGroup, and Subscription..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
    name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
    name: kubevirt-hyperconverged-group
    namespace: openshift-cnv
spec:
    targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
    name: hco-operatorhub
    namespace: openshift-cnv
spec:
    source: cnv-nightly-catalog-source
    sourceNamespace: openshift-marketplace
    name: kubevirt-hyperconverged
    startingCSV: ${STARTING_CSV}
    channel: "nightly-${CNV_VERSION}"
EOF
log_ok "Namespace, OperatorGroup, and Subscription created."

# -----------------------------------------------
# 7. Wait for CSV to reach Succeeded
# -----------------------------------------------
log_info "Waiting for CSV ${STARTING_CSV} to reach Succeeded (up to 15 minutes)..."
TIMEOUT=900
ELAPSED=0
while true; do
    PHASE=$(oc get csv "$STARTING_CSV" -n openshift-cnv \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$PHASE" == "Succeeded" ]]; then
        log_ok "CSV $STARTING_CSV is Succeeded."
        break
    fi
    if [[ "$PHASE" == "Failed" ]]; then
        log_error "CSV $STARTING_CSV has Failed."
        log_error "Check: oc describe csv $STARTING_CSV -n openshift-cnv"
        exit 1
    fi
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        log_error "CSV did not reach Succeeded within ${TIMEOUT}s. Current phase: $PHASE"
        exit 1
    fi
    log_info "  CSV phase: ${PHASE:-Pending} (${ELAPSED}s / ${TIMEOUT}s)..."
    sleep 15
    ELAPSED=$((ELAPSED + 15))
done

# -----------------------------------------------
# 8. Deploy HyperConverged CR
# -----------------------------------------------
log_info "Deploying HyperConverged CR..."
cat <<EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
    name: kubevirt-hyperconverged
    namespace: openshift-cnv
spec: {}
EOF
log_ok "HyperConverged CR applied."

# -----------------------------------------------
# 9. Wait for HyperConverged to become Available
# -----------------------------------------------
log_info "Waiting for HyperConverged to become Available (up to 30 minutes)..."
oc wait HyperConverged kubevirt-hyperconverged -n openshift-cnv \
    --for=condition=Available --timeout=30m

log_ok "============================================="
log_ok " OpenShift Virtualization installed!"
log_ok "============================================="
log_ok "  CNV Version: ${CNV_VERSION} (nightly)"
log_ok "  CSV: ${STARTING_CSV}"
log_ok "  HyperConverged CR: Available"
log_ok ""
log_ok "  Verify with:"
log_ok "    oc get csv -n openshift-cnv"
log_ok "    oc get hco -n openshift-cnv"
log_ok "    oc get pods -n openshift-cnv"
log_ok ""
log_ok "  Upgrades within the same minor version happen"
log_ok "  automatically every 8h (registryPoll interval)."
log_ok "  To upgrade to a new minor version, patch the CatalogSource:"
log_ok "    oc patch CatalogSource cnv-nightly-catalog-source -n openshift-marketplace \\"
log_ok "      --patch '{\"spec\":{\"image\":\"quay.io/openshift-cnv/nightly-catalog:<NEW_VERSION>\"}}' \\"
log_ok "      --type=merge"
log_ok "============================================="
