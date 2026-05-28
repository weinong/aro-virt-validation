#!/usr/bin/env bash
# =============================================================================
# self-managed-cluster.sh - Bring a self-managed OpenShift cluster up or down.
#
# Adapted from ../aro-install/hack/cluster.sh. Generates installer/install-config.yaml
# from an install-config template and runs openshift-install.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

INSTALLER_DIR="${INSTALLER_DIR:-${_REPO_ROOT}/installer}"
OPENSHIFT_INSTALL="${OPENSHIFT_INSTALL:-${_REPO_ROOT}/ocp-tools/openshift-install}"
PULLSECRET_FILE="${PULLSECRET_FILE:-${_REPO_ROOT}/.pullsecret}"

usage() {
  echo "Usage: $0 up|down" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

action="$1"

require_binary() {
  local bin="$1"
  if [[ ! -x "$bin" ]]; then
    log_error "Required binary '$bin' not found or not executable."
    exit 2
  fi
}

select_install_config() {
  if [[ -n "${INSTALL_CONFIG:-}" ]]; then
    printf '%s\n' "${INSTALL_CONFIG}"
    return
  fi

  local location_config="${_REPO_ROOT}/install-config.${LOCATION}.yaml"
  if [[ -f "${location_config}" ]]; then
    printf '%s\n' "${location_config}"
  else
    printf '%s\n' "${_REPO_ROOT}/install-config.yaml"
  fi
}

case "${action}" in
  up)
    require_binary "${OPENSHIFT_INSTALL}"

    base_config="$(select_install_config)"
    if [[ ! -f "${base_config}" ]]; then
      log_error "Base install-config template not found: ${base_config}"
      exit 3
    fi

    mkdir -p "${INSTALLER_DIR}"
    if [[ -f "${INSTALLER_DIR}/metadata.json" ]]; then
      log_error "metadata.json already exists in ${INSTALLER_DIR}; refusing to overwrite an existing cluster."
      log_error "Run '$0 down' first if you intend to destroy it, or remove the directory manually."
      exit 4
    fi

    cluster="${SELF_MANAGED_CLUSTER:-${cluster:-}}"
    if [[ -z "${cluster}" && -n "${CLUSTER:-}" && "${CLUSTER}" != "aro-virt-test" ]]; then
      cluster="${CLUSTER}"
    fi
    if [[ -z "${cluster}" ]]; then
      lc_user="${USER:-user}"
      lc_user="${lc_user,,}"
      lc_user="$(printf '%s' "${lc_user}" | tr -c 'a-z0-9-' '-' | sed -E 's/^-+//; s/-+$//; s/-+/-/g' | cut -c1-20)"
      [[ -n "${lc_user}" ]] || lc_user="user"
      random_suffix="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c4 2>/dev/null || true)"
      [[ -n "${random_suffix}" ]] || random_suffix="$(date +%s | tail -c 5)"
      cluster="${lc_user}-${random_suffix}"
      log_info "Generated new cluster name: ${cluster}"
    fi
    if ! [[ "${cluster}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [[ "${#cluster}" -gt 54 ]]; then
      log_error "Invalid cluster name '${cluster}'. Use a DNS-1123 name up to 54 characters."
      exit 4
    fi

    if [[ -z "${SELF_MANAGED_BASE_DOMAIN:-}" || -z "${SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP:-}" ]]; then
      log_error "SELF_MANAGED_BASE_DOMAIN and SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP are required for self-managed OCP."
      exit 4
    fi

    if [[ ! -f "${PULLSECRET_FILE}" ]]; then
      log_error "Pull secret file not found: ${PULLSECRET_FILE}"
      log_error "Run 'make .pullsecret' or set PULLSECRET_FILE to an existing file."
      exit 5
    fi
    validate_pull_secret "${PULLSECRET_FILE}" || {
      log_error "Pull secret is not valid JSON with an auths key: ${PULLSECRET_FILE}"
      exit 5
    }
    check_command jq || exit 1
    pullsecret="$(jq -c . "${PULLSECRET_FILE}")"

    ssh_key_file="${SSH_PUB_KEY:-${HOME}/.ssh/id_rsa.pub}"
    if [[ ! -f "${ssh_key_file}" ]]; then
      log_error "SSH public key file not found: ${ssh_key_file}"
      log_error "Set SSH_PUB_KEY or create ${HOME}/.ssh/id_rsa.pub."
      exit 6
    fi
    sshkey="$(<"${ssh_key_file}")"

    temp_config="$(mktemp)"
    trap 'rm -f "${temp_config}"' EXIT

    sed \
      -e "s/%clustername%/${cluster}/g" \
      -e "s/%region%/${LOCATION}/g" \
      -e "s/%baseDomain%/${SELF_MANAGED_BASE_DOMAIN}/g" \
      -e "s/%baseDomainResourceGroupName%/${SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP}/g" \
      "${base_config}" > "${temp_config}"
    awk -v pullsecret="${pullsecret}" -v sshkey="${sshkey}" '
      {
        if ($0 ~ /%pullsecret%/) {
          gsub(/%pullsecret%/, pullsecret)
        }
        if ($0 ~ /%sshkey%/) {
          gsub(/%sshkey%/, sshkey)
        }
        print
      }
    ' "${temp_config}" > "${INSTALLER_DIR}/install-config.yaml"

    log_ok "Wrote ${INSTALLER_DIR}/install-config.yaml from ${base_config} with cluster name ${cluster}."

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      log_warn "DRY_RUN=true; skipping cluster creation."
      log_info "Would run: ${OPENSHIFT_INSTALL} create cluster --dir ${INSTALLER_DIR}"
    else
      log_info "Creating cluster with openshift-install. This can take a while..."
      "${OPENSHIFT_INSTALL}" create cluster --dir "${INSTALLER_DIR}"
      log_ok "Create complete."
    fi
    ;;
  down)
    require_binary "${OPENSHIFT_INSTALL}"
    if [[ ! -d "${INSTALLER_DIR}" ]]; then
      log_info "Nothing to destroy: ${INSTALLER_DIR} does not exist."
      exit 0
    fi
    if [[ ! -f "${INSTALLER_DIR}/metadata.json" ]]; then
      log_warn "No metadata.json found in ${INSTALLER_DIR}; nothing to destroy or already destroyed."
      exit 0
    fi
    log_info "Destroying cluster. This can take several minutes..."
    "${OPENSHIFT_INSTALL}" destroy cluster --dir "${INSTALLER_DIR}"
    log_ok "Destroy complete."
    ;;
  *)
    usage
    ;;
esac
