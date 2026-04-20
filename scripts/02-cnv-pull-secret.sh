#!/usr/bin/env bash
# =============================================================================
# 02-cnv-pull-secret.sh - Add quay.io/openshift-cnv auth to cluster pull-secret
#
# Implements Steps 4-5 of Red Hat KB 6070641:
#   - Adds quay.io/openshift-cnv credentials to the global pull-secret
#   - Waits for MachineConfigPool rollout (node reboots may occur)
#
# Prerequisites:
#   - ARO cluster created and oc logged in as cluster-admin
#   - .env file with QUAY_USERNAME and QUAY_PASSWORD at repo root
#   - Quay user has accepted the openshift-cnv org invitation
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Load .env from repo root (only set vars if not already in environment)
_ENV_FILE="${_REPO_ROOT}/.env"
if [[ -f "$_ENV_FILE" ]]; then
    log_info "Loading credentials from $_ENV_FILE"
    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        # Only set if not already exported
        if [[ -z "${!key:-}" ]]; then
            export "$key=$value"
        fi
    done < "$_ENV_FILE"
else
    log_warn ".env file not found at $_ENV_FILE"
fi

echo "============================================="
echo " Phase 2: Add quay.io/openshift-cnv Pull Secret"
echo "============================================="

# -----------------------------------------------
# 1. Validate prerequisites
# -----------------------------------------------
log_info "Checking prerequisites..."
for cmd in oc jq base64; do
    check_command "$cmd" || exit 1
done

if ! oc whoami &>/dev/null; then
    log_error "Not logged in to OpenShift. Run: oc login <api-server> -u kubeadmin -p <password>"
    exit 1
fi
log_ok "Logged in as: $(oc whoami)"

if [[ -z "${QUAY_USERNAME:-}" || -z "${QUAY_PASSWORD:-}" ]]; then
    log_error "QUAY_USERNAME and QUAY_PASSWORD must be set (via .env or environment)"
    exit 1
fi
log_ok "Quay credentials loaded for user: $QUAY_USERNAME"

# -----------------------------------------------
# 2. Compute auth token
# -----------------------------------------------
QUAY_AUTH=$(printf '%s:%s' "$QUAY_USERNAME" "$QUAY_PASSWORD" | base64 -w 0)

# -----------------------------------------------
# 3. Check if already configured (idempotency)
# -----------------------------------------------
log_info "Checking if quay.io/openshift-cnv auth is already in the cluster pull-secret..."

EXISTING_AUTH=$(oc get secret pull-secret -n openshift-config -o json \
    | jq -r '.data.".dockerconfigjson"' \
    | base64 -d \
    | jq -r '.auths["quay.io/openshift-cnv"].auth // ""')

if [[ "$EXISTING_AUTH" == "$QUAY_AUTH" ]]; then
    log_ok "quay.io/openshift-cnv auth already configured and matches. Skipping update."
    log_info "Checking MachineConfigPool status..."
    if oc wait mcp master worker --for=condition=Updated --timeout=30s &>/dev/null; then
        log_ok "MachineConfigPools are already Updated. Nothing to do."
    else
        log_warn "MachineConfigPools are still rolling out. Waiting..."
        oc wait mcp master worker --for=condition=Updated --timeout=20m
        log_ok "MachineConfigPools updated."
    fi
    exit 0
fi

# -----------------------------------------------
# 4. Fetch current pull-secret, add quay.io/openshift-cnv, apply
# -----------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log_info "Fetching current global pull-secret..."
oc get secret pull-secret -n openshift-config -o json \
    | jq -r '.data.".dockerconfigjson"' \
    | base64 -d > "${TMPDIR}/global-pull-secret.json"

log_info "Adding quay.io/openshift-cnv auth entry..."
jq --arg QUAY_AUTH "$QUAY_AUTH" \
    '.auths += {"quay.io/openshift-cnv": {"auth": $QUAY_AUTH, "email": ""}}' \
    "${TMPDIR}/global-pull-secret.json" > "${TMPDIR}/global-pull-secret-new.json"

log_info "Applying updated pull-secret to cluster..."
oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson="${TMPDIR}/global-pull-secret-new.json"

log_ok "Pull-secret updated with quay.io/openshift-cnv credentials."

# -----------------------------------------------
# 5. Wait for MachineConfigPool rollout
# -----------------------------------------------
log_info "Waiting for MachineConfigPool rollout (this may take 10-20 minutes due to node reboots)..."
log_info "You can monitor progress with: oc get mcp -w"

oc wait mcp master worker --for=condition=Updated --timeout=20m

log_ok "============================================="
log_ok " Pull-secret configured and rolled out!"
log_ok "============================================="
log_ok "  quay.io/openshift-cnv auth added to all nodes."
log_ok "  Next step: run 03-cnv-install.sh"
log_ok "============================================="
