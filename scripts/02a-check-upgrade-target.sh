#!/usr/bin/env bash
# =============================================================================
# 02a-check-upgrade-target.sh - Fail fast if the pinned OCP target is unavailable
#
# This is intentionally read-only and safe to run before creating an ARO cluster.
# It checks ARO installable versions for context and Red Hat update graph channels
# for the exact target payload used by the pinned validation flow.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

TARGET_VERSION="${TARGET_OCP_VERSION:-4.22.4}"
TARGET_MINOR="$(printf '%s' "${TARGET_VERSION}" | cut -d. -f1-2)"
UPGRADE_TARGET_CHANNELS="${UPGRADE_TARGET_CHANNELS:-candidate-${TARGET_MINOR}}"

log_info "=== Phase 2a: Check Exact Upgrade Target ==="

check_command az || exit 1
check_command curl || exit 1
check_command jq || exit 1

if ! [[ "${TARGET_VERSION}" =~ ^4\.[0-9]+\.[0-9]+(-(ec|rc)\.[0-9]+)?$ ]]; then
  log_error "TARGET_OCP_VERSION must be an exact OCP version, got '${TARGET_VERSION}'."
  exit 1
fi

log_info "Checking ARO installable versions in ${LOCATION}..."
ARO_VERSIONS="$(az aro get-versions --location "${LOCATION}" -o json 2>/dev/null || echo '[]')"
if echo "${ARO_VERSIONS}" | jq -e --arg target "${TARGET_VERSION}" 'index($target)' >/dev/null; then
  log_ok "Exact target ${TARGET_VERSION} is directly installable by ARO in ${LOCATION}."
else
  log_warn "Exact target ${TARGET_VERSION} is not directly installable by ARO in ${LOCATION}."
  log_info "Installable ARO versions: $(echo "${ARO_VERSIONS}" | jq -r 'join(", ")')"
fi

FOUND_CHANNEL=""
FOUND_PAYLOAD=""

for channel in ${UPGRADE_TARGET_CHANNELS}; do
  log_info "Checking update graph channel ${channel} for exact target ${TARGET_VERSION}..."
  GRAPH_JSON="$(curl -sS "https://api.openshift.com/api/upgrades_info/v1/graph?channel=${channel}&arch=amd64")"
  PAYLOAD="$(echo "${GRAPH_JSON}" | jq -r --arg target "${TARGET_VERSION}" '.nodes[]? | select(.version == $target) | .payload' | head -n1)"
  if [[ -n "${PAYLOAD}" ]]; then
    FOUND_CHANNEL="${channel}"
    FOUND_PAYLOAD="${PAYLOAD}"
    break
  fi

  AVAILABLE="$(echo "${GRAPH_JSON}" | jq -r --arg minor "${TARGET_MINOR}." '.nodes[]? | select(.version | startswith($minor)) | .version' | sort -V | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  log_warn "  ${TARGET_VERSION} not found in ${channel}. Available ${TARGET_MINOR} versions: ${AVAILABLE:-<none>}"
done

if [[ -z "${FOUND_CHANNEL}" ]]; then
  log_error "Exact target ${TARGET_VERSION} was not found in configured update graph channels: ${UPGRADE_TARGET_CHANNELS}"
  log_error "This flow is pinned and will not create a cluster that cannot reach ${TARGET_VERSION}."
  exit 1
fi

if ! [[ "${FOUND_PAYLOAD}" =~ ^[^[:space:]]+@sha256:[0-9a-fA-F]{64}$ ]]; then
  log_error "Exact target ${TARGET_VERSION} was found in ${FOUND_CHANNEL}, but payload has unexpected format: ${FOUND_PAYLOAD}"
  exit 1
fi

log_ok "Exact target ${TARGET_VERSION} found in ${FOUND_CHANNEL}."
log_ok "Payload: ${FOUND_PAYLOAD}"
log_ok "Phase 2a complete. Exact upgrade target is available."
