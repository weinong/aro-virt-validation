#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

check_command az || exit 1
check_command flock || exit 1
check_command jq || exit 1

credential_file="${HOME}/.azure/osServicePrincipal.json"
vault_name="${REGISTRY:?REGISTRY is required}"
validity_days="${SP_CREDENTIAL_DAYS:-90}"

mkdir -p "${HOME}/.azure"
umask 077
exec 9>"${HOME}/.azure/osServicePrincipal.lock"
if ! flock -n 9; then
  log_error "Another service principal credential rotation is already running."
  exit 1
fi

if [[ ! "${validity_days}" =~ ^[1-9][0-9]*$ ]]; then
  log_error "SP_CREDENTIAL_DAYS must be a positive integer."
  exit 1
fi
if [[ ! -f "${credential_file}" ]]; then
  log_error "Service principal file not found: ${credential_file}"
  exit 1
fi
chmod 600 "${credential_file}"
if ! jq -e '
  . as $credential
  | type == "object"
    and all(["subscriptionId", "clientId", "clientSecret", "tenantId"][];
      ($credential[.] | type == "string" and length > 0))
' "${credential_file}" >/dev/null; then
  log_error "Service principal file is not valid credential JSON: ${credential_file}"
  exit 1
fi

subscription_id="$(jq -r '.subscriptionId' "${credential_file}")"
client_id="$(jq -r '.clientId' "${credential_file}")"
tenant_id="$(jq -r '.tenantId' "${credential_file}")"
active_subscription_id="$(az account show --query id -o tsv)"
active_tenant_id="$(az account show --query tenantId -o tsv)"

if [[ "${subscription_id}" != "${active_subscription_id}" ]]; then
  log_error "Service principal subscription does not match the active Azure subscription."
  exit 1
fi
if [[ "${tenant_id}" != "${active_tenant_id}" ]]; then
  log_error "Service principal tenant does not match the active Azure tenant."
  exit 1
fi
if [[ "$(az ad app show --id "${client_id}" --query appId -o tsv)" != "${client_id}" ]]; then
  log_error "Could not verify service principal application ${client_id}."
  exit 1
fi

reset_output="$(mktemp "${HOME}/.azure/osServicePrincipal.reset.XXXXXX")"
new_credential="$(mktemp "${HOME}/.azure/osServicePrincipal.new.XXXXXX")"
trap 'rm -f "${reset_output}" "${new_credential}"' EXIT

credential_name="aro-virt-validation-$(date -u +%Y%m%dT%H%M%SZ)"
end_date="$(date -u -d "+${validity_days} days" +%Y-%m-%dT%H:%M:%SZ)"

log_info "Appending a ${validity_days}-day credential to service principal ${client_id}..."
az ad app credential reset \
  --id "${client_id}" \
  --append \
  --display-name "${credential_name}" \
  --end-date "${end_date}" \
  --output json > "${reset_output}"

if ! jq -e --arg client_id "${client_id}" --arg tenant_id "${tenant_id}" '
  type == "object"
  and .appId == $client_id
  and .tenant == $tenant_id
  and (.password | type == "string" and length > 0)
' "${reset_output}" >/dev/null; then
  log_error "Azure returned an invalid credential response."
  exit 1
fi

jq \
  --slurpfile reset "${reset_output}" \
  '{
    subscriptionId,
    clientId,
    clientSecret: $reset[0].password,
    tenantId
  }' "${credential_file}" > "${new_credential}"
chmod 600 "${new_credential}"

log_info "Publishing the new credential to Key Vault secret osServicePrincipal..."
if ! az keyvault secret set \
  --vault-name "${vault_name}" \
  --name osServicePrincipal \
  --file "${new_credential}" \
  --output none; then
  log_error "Key Vault publication failed; the local credential file was not replaced."
  log_warn "The newly appended application credential was retained to avoid invalidating a potentially published Key Vault version."
  exit 1
fi

mv "${new_credential}" "${credential_file}"
chmod 600 "${credential_file}"

log_ok "Updated Key Vault and ${credential_file}; prior application credentials were retained."
log_warn "Existing clusters keep their embedded credentials and are not updated by this target."
