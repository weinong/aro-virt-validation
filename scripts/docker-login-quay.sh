#!/usr/bin/env bash
# =============================================================================
# docker-login-quay.sh - Login to quay.io using .quay-pullsecret credentials.
#
# Adapted from ../aro-install/hack/docker-login-quay.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

QUAY_PULLSECRET_FILE="${QUAY_PULLSECRET_FILE:-${_REPO_ROOT}/.quay-pullsecret}"

if [[ ! -f "${QUAY_PULLSECRET_FILE}" ]]; then
  log_error "Quay credential file not found: ${QUAY_PULLSECRET_FILE}"
  log_error "Run 'make download-local-secrets' first or set QUAY_PULLSECRET_FILE."
  exit 1
fi

CONTAINER_CLI=""
if command -v docker &>/dev/null; then
  CONTAINER_CLI="docker"
elif command -v podman &>/dev/null; then
  CONTAINER_CLI="podman"
else
  log_error "Neither docker nor podman command found."
  exit 1
fi

load_quay_pullsecret "${QUAY_PULLSECRET_FILE}"

if [[ -z "${QUAY_USERNAME:-}" || -z "${QUAY_PASSWORD:-}" ]]; then
  log_error "QUAY_USERNAME and QUAY_PASSWORD must be set in ${QUAY_PULLSECRET_FILE}."
  exit 1
fi

log_info "Logging in to quay.io using ${CONTAINER_CLI}..."
if printf '%s' "${QUAY_PASSWORD}" | "${CONTAINER_CLI}" login quay.io -u "${QUAY_USERNAME}" --password-stdin; then
  log_ok "Successfully logged in to quay.io."
else
  log_error "Failed to login to quay.io."
  exit 1
fi
