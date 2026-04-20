#!/usr/bin/env bash
# =============================================================================
# 04-upgrade-cluster.sh - Upgrade ARO/OCP cluster one minor version at a time
#
# Usage:
#   ./scripts/04-upgrade-cluster.sh <target-minor>
#   e.g. ./scripts/04-upgrade-cluster.sh 4.21
#        ./scripts/04-upgrade-cluster.sh 4.22
#
# Uses the candidate-X.Y channel to access pre-GA / tech-preview builds.
# Only allows N -> N+1 minor upgrades (refuses skip-level).
#
# WARNING: Upgrading beyond versions listed in `az aro get-versions` puts
#          the cluster in a Microsoft-unsupported state. The ARO Operator
#          may degrade. Acceptable for lab/validation clusters only.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# -----------------------------------------------
# 0. Argument parsing
# -----------------------------------------------
if [[ $# -ne 1 ]] || ! [[ "$1" =~ ^4\.[0-9]+$ ]]; then
    log_error "Usage: $0 <target-minor>  (e.g. 4.21)"
    exit 1
fi

TARGET_MINOR="$1"
TARGET_MAJOR="${TARGET_MINOR%%.*}"
TARGET_MINOR_NUM="${TARGET_MINOR#*.}"

echo "============================================="
echo " Cluster Upgrade to ${TARGET_MINOR}"
echo "============================================="

# -----------------------------------------------
# 1. Validate current version and hop distance
# -----------------------------------------------
log_info "Checking current cluster version..."
CURRENT_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
CURRENT_MAJOR="${CURRENT_VERSION%%.*}"
# Extract minor: 4.20.15 -> 20
CURRENT_MINOR_NUM=$(echo "$CURRENT_VERSION" | cut -d. -f2)

log_info "Current version: $CURRENT_VERSION"
log_info "Target minor:    $TARGET_MINOR"

if [[ "$TARGET_MAJOR" != "$CURRENT_MAJOR" ]]; then
    log_error "Major version mismatch: current=$CURRENT_MAJOR, target=$TARGET_MAJOR"
    exit 1
fi

EXPECTED_MINOR=$((CURRENT_MINOR_NUM + 1))
if [[ "$TARGET_MINOR_NUM" -ne "$EXPECTED_MINOR" ]]; then
    log_error "Only N -> N+1 minor upgrades allowed."
    log_error "Current minor: $CURRENT_MINOR_NUM, target minor: $TARGET_MINOR_NUM, expected: $EXPECTED_MINOR"
    exit 1
fi
log_ok "Hop validated: ${CURRENT_MAJOR}.${CURRENT_MINOR_NUM} -> ${TARGET_MINOR}"

# -----------------------------------------------
# 2. Pre-flight health check
# -----------------------------------------------
log_info "Running pre-flight health checks..."

if ! oc whoami &>/dev/null; then
    log_error "Not logged in to OpenShift."
    exit 1
fi
log_ok "Logged in as: $(oc whoami)"

# Check no upgrade in progress
CURRENT_STATE=$(oc get clusterversion version -o jsonpath='{.status.history[0].state}')
if [[ "$CURRENT_STATE" == "Partial" ]]; then
    log_error "An upgrade is already in progress (state=Partial). Wait for it to complete."
    exit 1
fi
log_ok "No upgrade in progress (state=$CURRENT_STATE)."

# Check ClusterOperators health
DEGRADED_COS=$(oc get co -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name')
if [[ -n "$DEGRADED_COS" ]]; then
    log_warn "Degraded ClusterOperators detected (may block upgrade):"
    echo "$DEGRADED_COS" | while read -r co; do log_warn "  - $co"; done
fi

UNAVAILABLE_COS=$(oc get co -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Available" and .status=="False")) | .metadata.name')
if [[ -n "$UNAVAILABLE_COS" ]]; then
    log_error "Unavailable ClusterOperators:"
    echo "$UNAVAILABLE_COS" | while read -r co; do log_error "  - $co"; done
    exit 1
fi
log_ok "All ClusterOperators are Available."

# Check MCPs
if ! oc wait mcp master worker --for=condition=Updated --timeout=30s &>/dev/null; then
    log_error "MachineConfigPools are not Updated. Wait for current rollout to finish."
    exit 1
fi
log_ok "MachineConfigPools are Updated."

# -----------------------------------------------
# 3. Capture pre-upgrade snapshot
# -----------------------------------------------
SNAPSHOT_DIR="${_REPO_ROOT}/.upgrade-snapshots"
mkdir -p "$SNAPSHOT_DIR"

log_info "Saving pre-upgrade snapshot..."
oc get clusterversion version -o yaml > "${SNAPSHOT_DIR}/cv-pre-${TARGET_MINOR}.yaml"
oc get co -o wide > "${SNAPSHOT_DIR}/co-pre-${TARGET_MINOR}.txt"
log_ok "Snapshot saved to ${SNAPSHOT_DIR}/"

# -----------------------------------------------
# 4. Set candidate channel
# -----------------------------------------------
CHANNEL="candidate-${TARGET_MINOR}"
log_info "Setting update channel to ${CHANNEL}..."
oc adm upgrade channel "$CHANNEL" --allow-explicit-channel
log_ok "Channel set to ${CHANNEL}."

log_info "Waiting for available updates to be retrieved (up to 5 minutes)..."
TIMEOUT=300
ELAPSED=0
while true; do
    RETRIEVED=$(oc get clusterversion version \
        -o jsonpath='{.status.conditions[?(@.type=="RetrievedUpdates")].status}' 2>/dev/null || echo "")
    if [[ "$RETRIEVED" == "True" ]]; then
        log_ok "Available updates retrieved."
        break
    fi
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        MSG=$(oc get clusterversion version \
            -o jsonpath='{.status.conditions[?(@.type=="RetrievedUpdates")].message}' 2>/dev/null || echo "unknown")
        log_error "Failed to retrieve updates within ${TIMEOUT}s."
        log_error "Reason: $MSG"
        exit 1
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    log_info "  Waiting for update retrieval... (${ELAPSED}s / ${TIMEOUT}s)"
done

# -----------------------------------------------
# 5. Resolve admin-ack blockers
# -----------------------------------------------
log_info "Resolving known upgrade blockers..."

# cloud-credential upgradeable annotation
log_info "  Setting cloud-credential upgradeable-to annotation..."
oc annotate cloudcredential cluster \
    "cloudcredential.openshift.io/upgradeable-to=${TARGET_MINOR}.0" \
    --overwrite 2>/dev/null || log_warn "  Could not annotate cloudcredential (may not exist)."

# Admin acks in openshift-config/admin-acks configmap
# Check if admin-acks configmap exists; create if not
if ! oc get cm admin-acks -n openshift-config &>/dev/null; then
    oc create cm admin-acks -n openshift-config 2>/dev/null || true
fi

# Common admin-ack keys for 4.x upgrades
ADMIN_ACK_KEY="ack-${CURRENT_MAJOR}.${CURRENT_MINOR_NUM}-kube-${TARGET_MAJOR}.${TARGET_MINOR_NUM}-api-removals-in-${TARGET_MAJOR}.${TARGET_MINOR_NUM}"
log_info "  Applying admin-ack: ${ADMIN_ACK_KEY}..."
oc -n openshift-config annotate cm admin-acks "${ADMIN_ACK_KEY}=true" --overwrite 2>/dev/null || true

log_info "  Waiting up to 60s for Upgradeable condition to clear..."
sleep 10
UPGRADE_WAIT=0
while [[ $UPGRADE_WAIT -lt 60 ]]; do
    UPGRADEABLE=$(oc get clusterversion version \
        -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].status}' 2>/dev/null || echo "")
    if [[ "$UPGRADEABLE" == "True" ]]; then
        log_ok "Cluster is Upgradeable."
        break
    fi
    sleep 10
    UPGRADE_WAIT=$((UPGRADE_WAIT + 10))
done

if [[ "$UPGRADEABLE" != "True" ]]; then
    UPGRADE_MSG=$(oc get clusterversion version \
        -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].message}' 2>/dev/null || echo "unknown")
    log_warn "Upgradeable is still False after admin-ack resolution."
    log_warn "Reason: $UPGRADE_MSG"
    log_warn "Will proceed with --force flag."
fi

# -----------------------------------------------
# 6. Pick target patch version
# -----------------------------------------------
log_info "Selecting target patch version..."

# Collect from availableUpdates
AVAILABLE=$(oc get clusterversion version -o json \
    | jq -r '(.status.availableUpdates // [])[] | .version' 2>/dev/null \
    | grep "^${TARGET_MINOR}\." \
    | sort -V || echo "")

# Collect from conditionalUpdates
CONDITIONAL=$(oc get clusterversion version -o json \
    | jq -r '(.status.conditionalUpdates // [])[] | .release.version' 2>/dev/null \
    | grep "^${TARGET_MINOR}\." \
    | sort -V || echo "")

# Prefer available, fall back to conditional
USE_NOT_RECOMMENDED=""
FORCE_FLAG=""
if [[ -n "$AVAILABLE" ]]; then
    TARGET_VERSION=$(echo "$AVAILABLE" | tail -1)
    log_ok "Selected from availableUpdates: $TARGET_VERSION"
elif [[ -n "$CONDITIONAL" ]]; then
    TARGET_VERSION=$(echo "$CONDITIONAL" | tail -1)
    USE_NOT_RECOMMENDED="--allow-not-recommended"
    log_warn "Selected from conditionalUpdates (not recommended): $TARGET_VERSION"
    # Log the conditional risks
    RISKS=$(oc get clusterversion version -o json \
        | jq -r --arg v "$TARGET_VERSION" \
        '(.status.conditionalUpdates // [])[] | select(.release.version==$v) | .conditions[]? | "\(.type): \(.message)"' 2>/dev/null || echo "unknown")
    if [[ -n "$RISKS" ]]; then
        log_warn "Conditional update risks:"
        echo "$RISKS" | while IFS= read -r line; do log_warn "  $line"; done
    fi
else
    # No versions in cluster's available/conditional updates.
    # Fall back to querying Red Hat's update graph API directly and using --to-image.
    log_warn "No ${TARGET_MINOR}.x versions found in cluster's available/conditional updates."
    log_warn "Querying Red Hat update graph API for candidate-${TARGET_MINOR}..."

    GRAPH_JSON=$(curl -sS "https://api.openshift.com/api/upgrades_info/v1/graph?channel=candidate-${TARGET_MINOR}&arch=amd64" 2>/dev/null || echo "{}")

    # Find the latest version in the graph that starts with TARGET_MINOR
    TARGET_VERSION=$(echo "$GRAPH_JSON" | jq -r --arg prefix "${TARGET_MINOR}." \
        '[.nodes[] | select(.version | startswith($prefix))] | sort_by(.version) | last | .version // ""' 2>/dev/null || echo "")
    TARGET_IMAGE=$(echo "$GRAPH_JSON" | jq -r --arg v "$TARGET_VERSION" \
        '.nodes[] | select(.version==$v) | .payload // ""' 2>/dev/null || echo "")

    if [[ -z "$TARGET_VERSION" || -z "$TARGET_IMAGE" ]]; then
        log_error "No ${TARGET_MINOR}.x versions found in Red Hat update graph either."
        log_error "Channel candidate-${TARGET_MINOR} may not have any releases yet."
        exit 1
    fi

    USE_TO_IMAGE=true
    log_warn "Found ${TARGET_VERSION} in update graph (no direct edge from current version)."
    log_warn "Will use --to-image with --allow-explicit-upgrade to force the upgrade."
    log_warn "Release image: ${TARGET_IMAGE}"
fi

if [[ "$UPGRADEABLE" != "True" ]]; then
    FORCE_FLAG="--force"
fi

# -----------------------------------------------
# 7. Trigger upgrade
# -----------------------------------------------
log_info "Triggering upgrade to ${TARGET_VERSION}..."

if [[ "${USE_TO_IMAGE:-false}" == "true" ]]; then
    UPGRADE_CMD="oc adm upgrade --to-image=${TARGET_IMAGE} --allow-explicit-upgrade --force"
    log_warn "Using --to-image with --allow-explicit-upgrade (no graph edge from current version)."
else
    UPGRADE_CMD="oc adm upgrade --to=${TARGET_VERSION}"
    [[ -n "$USE_NOT_RECOMMENDED" ]] && UPGRADE_CMD+=" $USE_NOT_RECOMMENDED"
    [[ -n "$FORCE_FLAG" ]] && UPGRADE_CMD+=" $FORCE_FLAG"
fi

log_info "Running: $UPGRADE_CMD"
eval "$UPGRADE_CMD"
log_ok "Upgrade initiated to ${TARGET_VERSION}."

# -----------------------------------------------
# 8. Poll until completion (timeout: 3 hours)
# -----------------------------------------------
log_info "Polling upgrade progress (timeout: 3 hours)..."
UPGRADE_TIMEOUT=10800
UPGRADE_ELAPSED=0
POLL_INTERVAL=60

while true; do
    STATE=$(oc get clusterversion version -o jsonpath='{.status.history[0].state}' 2>/dev/null || echo "Unknown")
    HIST_VERSION=$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>/dev/null || echo "Unknown")

    # Count COs not yet on target
    CO_COUNT=$(oc get co -o json 2>/dev/null \
        | jq -r --arg v "$TARGET_VERSION" '[.items[] | select(.status.versions[]? | select(.name=="operator" and .version!=$v))] | length' 2>/dev/null || echo "?")
    PROGRESSING_COUNT=$(oc get co -o json 2>/dev/null \
        | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Progressing" and .status=="True"))] | length' 2>/dev/null || echo "?")

    ELAPSED_MIN=$((UPGRADE_ELAPSED / 60))
    log_info "[${ELAPSED_MIN}m] state=${STATE} version=${HIST_VERSION} | COs pending=${CO_COUNT} progressing=${PROGRESSING_COUNT}"

    if [[ "$STATE" == "Completed" && "$HIST_VERSION" == "$TARGET_VERSION" ]]; then
        log_ok "Upgrade to ${TARGET_VERSION} completed!"
        break
    fi

    if [[ $UPGRADE_ELAPSED -ge $UPGRADE_TIMEOUT ]]; then
        log_error "Upgrade did not complete within $((UPGRADE_TIMEOUT / 3600)) hours."
        log_error "Current state: $STATE, version: $HIST_VERSION"
        log_error "Investigate with: oc describe clusterversion version"
        exit 1
    fi

    # Log degraded COs (informational during upgrade)
    DEGRADED_NOW=$(oc get co -o json 2>/dev/null \
        | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$DEGRADED_NOW" ]]; then
        log_warn "  Degraded COs (may be transient during upgrade): $(echo "$DEGRADED_NOW" | tr '\n' ', ')"
    fi

    sleep $POLL_INTERVAL
    UPGRADE_ELAPSED=$((UPGRADE_ELAPSED + POLL_INTERVAL))
done

# -----------------------------------------------
# 9. Wait for MachineConfigPools
# -----------------------------------------------
log_info "Waiting for MachineConfigPools to finish rolling out..."
oc wait mcp master worker --for=condition=Updated --timeout=60m
log_ok "MachineConfigPools are Updated."

# -----------------------------------------------
# 10. Post-upgrade health summary
# -----------------------------------------------
log_info "Running post-upgrade health checks..."

# Save post-upgrade snapshot
oc get clusterversion version -o yaml > "${SNAPSHOT_DIR}/cv-post-${TARGET_MINOR}.yaml"
oc get co -o wide > "${SNAPSHOT_DIR}/co-post-${TARGET_MINOR}.txt"

FINAL_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')

# ARO operator check (canary for Microsoft RP compatibility)
ARO_AVAILABLE=$(oc get co aro -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "N/A")
ARO_DEGRADED=$(oc get co aro -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "N/A")

# CNV check
CNV_CSV_PHASE=$(oc get csv -n openshift-cnv -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "N/A")
HCO_AVAILABLE=$(oc get hco kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "N/A")

# Final degraded COs
POST_DEGRADED=$(oc get co -o json \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Degraded" and .status=="True")) | .metadata.name' 2>/dev/null || echo "")

echo ""
log_ok "============================================="
log_ok " Upgrade Complete!"
log_ok "============================================="
log_ok "  Cluster version:    $FINAL_VERSION"
log_ok "  ARO Operator:       Available=$ARO_AVAILABLE Degraded=$ARO_DEGRADED"
log_ok "  CNV CSV:            $CNV_CSV_PHASE"
log_ok "  CNV HyperConverged: Available=$HCO_AVAILABLE"
if [[ -n "$POST_DEGRADED" ]]; then
    log_warn "  Degraded COs:      $(echo "$POST_DEGRADED" | tr '\n' ', ')"
else
    log_ok "  Degraded COs:      None"
fi
log_ok ""
log_ok "  Snapshots saved to: ${SNAPSHOT_DIR}/"
log_ok "============================================="
