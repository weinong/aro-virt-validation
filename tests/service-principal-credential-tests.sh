#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/home/.azure" "${TEST_DIR}/scripts"
cp "${REPO_ROOT}/Makefile" "${TEST_DIR}/Makefile"
cp "${REPO_ROOT}/scripts/env.sh" "${TEST_DIR}/scripts/env.sh"
cp "${REPO_ROOT}/scripts/00a-rotate-service-principal-credential.sh" "${TEST_DIR}/scripts/00a-rotate-service-principal-credential.sh"

cat > "${TEST_DIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${AZ_LOG}"
printf '\n' >> "${AZ_LOG}"

case "$*" in
  "account show --query name -o tsv")
    printf 'test-subscription\n'
    ;;
  "account show --query id -o tsv")
    printf 'subscription-id\n'
    ;;
  "account show --query tenantId -o tsv")
    printf 'tenant-id\n'
    ;;
  "ad app show --id client-id --query appId -o tsv")
    printf 'client-id\n'
    ;;
  ad\ app\ credential\ reset\ --id\ client-id\ --append\ --display-name\ aro-virt-validation-*)
    if [[ " $* " != *" --output json "* ]]; then
      printf 'credential reset must request JSON output\n' >&2
      exit 2
    fi
    end_date=""
    while (( $# > 0 )); do
      if [[ "$1" == "--end-date" ]]; then
        end_date="$2"
        break
      fi
      shift
    done
    end_epoch="$(date -u -d "${end_date}" +%s)"
    expected_epoch="$(date -u -d "+${EXPECTED_DAYS:-90} days" +%s)"
    if (( end_epoch < expected_epoch - 2 || end_epoch > expected_epoch + 2 )); then
      printf 'unexpected credential end date: %s\n' "${end_date}" >&2
      exit 2
    fi
    if [[ "${FAIL_RESET:-false}" == "true" ]]; then
      exit 4
    fi
    if [[ "${SLOW_RESET:-false}" == "true" ]]; then
      sleep 2
    fi
    printf '{"appId":"client-id","password":"new-secret","tenant":"tenant-id"}\n'
    ;;
  keyvault\ secret\ set\ --vault-name\ test-vault\ --name\ osServicePrincipal\ --file\ *)
    if [[ "${FAIL_KEY_VAULT:-false}" == "true" ]]; then
      exit 5
    fi
    credential_file=""
    while (( $# > 0 )); do
      if [[ "$1" == "--file" ]]; then
        credential_file="$2"
        break
      fi
      shift
    done
    cp "${credential_file}" "${PUBLISHED_CREDENTIAL}"
    ;;
  *)
    printf 'unexpected az args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${TEST_DIR}/bin/az" "${TEST_DIR}/scripts/00a-rotate-service-principal-credential.sh"

write_valid_credential() {
  cat > "${TEST_DIR}/home/.azure/osServicePrincipal.json" <<'EOF'
{"subscriptionId":"subscription-id","clientId":"client-id","clientSecret":"old-secret","tenantId":"tenant-id"}
EOF
  chmod 777 "${TEST_DIR}/home/.azure/osServicePrincipal.json"
}

run_rotation() {
  HOME="${TEST_DIR}/home" \
    PATH="${TEST_DIR}/bin:${PATH}" \
    AZ_LOG="${TEST_DIR}/az.log" \
    PUBLISHED_CREDENTIAL="${TEST_DIR}/published.json" \
    EXPECTED_DAYS="${EXPECTED_DAYS:-90}" \
    make -s -C "${TEST_DIR}" rotate-service-principal-credential \
      REGISTRY=test-vault AZURE_SUBSCRIPTION_NAME=test-subscription "$@"
}

write_valid_credential
output="$(run_rotation 2>&1)"
[[ "${output}" != *"new-secret"* ]]
! grep -q 'new-secret' "${TEST_DIR}/az.log"
jq -e '. == {
  subscriptionId: "subscription-id",
  clientId: "client-id",
  clientSecret: "new-secret",
  tenantId: "tenant-id"
}' "${TEST_DIR}/home/.azure/osServicePrincipal.json" >/dev/null
cmp "${TEST_DIR}/home/.azure/osServicePrincipal.json" "${TEST_DIR}/published.json"
[[ "$(stat -c '%a' "${TEST_DIR}/home/.azure/osServicePrincipal.json")" == "600" ]]
grep -q '^ad app credential reset .*--append ' "${TEST_DIR}/az.log"
! grep -q 'credential delete' "${TEST_DIR}/az.log"

printf '{"clientId":"client-id"}\n' > "${TEST_DIR}/home/.azure/osServicePrincipal.json"
: > "${TEST_DIR}/az.log"
if run_rotation >/dev/null 2>&1; then
  printf 'malformed credential unexpectedly succeeded\n' >&2
  exit 1
fi
! grep -q 'credential reset' "${TEST_DIR}/az.log"

write_valid_credential
cp "${TEST_DIR}/home/.azure/osServicePrincipal.json" "${TEST_DIR}/old.json"
: > "${TEST_DIR}/az.log"
rm -f "${TEST_DIR}/published.json"
if FAIL_KEY_VAULT=true run_rotation >/dev/null 2>&1; then
  printf 'Key Vault failure unexpectedly succeeded\n' >&2
  exit 1
fi
cmp "${TEST_DIR}/home/.azure/osServicePrincipal.json" "${TEST_DIR}/old.json"
[[ "$(stat -c '%a' "${TEST_DIR}/home/.azure/osServicePrincipal.json")" == "600" ]]
[[ ! -e "${TEST_DIR}/published.json" ]]
[[ -z "$(find "${TEST_DIR}/home/.azure" -name 'osServicePrincipal.*.??????' -print -quit)" ]]

write_valid_credential
: > "${TEST_DIR}/az.log"
if run_rotation SP_CREDENTIAL_DAYS=invalid >/dev/null 2>&1; then
  printf 'invalid credential lifetime unexpectedly succeeded\n' >&2
  exit 1
fi
! grep -q 'credential reset' "${TEST_DIR}/az.log"

write_valid_credential
: > "${TEST_DIR}/az.log"
EXPECTED_DAYS=120 run_rotation SP_CREDENTIAL_DAYS=120 >/dev/null
grep -q 'credential reset .*--output json' "${TEST_DIR}/az.log"

write_valid_credential
: > "${TEST_DIR}/az.log"
SLOW_RESET=true run_rotation >"${TEST_DIR}/first-run.log" 2>&1 &
first_pid=$!
for _ in {1..50}; do
  grep -q 'credential reset' "${TEST_DIR}/az.log" && break
  sleep 0.05
done
if run_rotation >"${TEST_DIR}/second-run.log" 2>&1; then
  printf 'concurrent rotation unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'Another service principal credential rotation is already running' "${TEST_DIR}/second-run.log"
wait "${first_pid}"

printf 'service-principal-credential-tests: PASS\n'
