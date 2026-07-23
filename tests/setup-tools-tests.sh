#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${TMPDIR}/bin"

cat > "${TMPDIR}/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${FAIL_AZ:-false}" == "true" ]]; then
  printf 'az must not run when extracted tools are cached\n' >&2
  exit 3
fi

case "$*" in
  "account show --query name -o tsv")
    printf 'test-subscription\n'
    ;;
  "keyvault secret show --name ocp-pullsecret --vault-name test-registry --query value -o tsv")
    printf '{"auths":'
    sleep 1
    printf '{"quay.io":{"auth":"test"}}}\n'
    ;;
  *)
    printf 'unexpected az args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

cat > "${TMPDIR}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1 $2 $3" != "adm release extract" ]]; then
  printf 'unexpected oc args: %s\n' "$*" >&2
  exit 2
fi

command_name=""
from_image=""
registry_config=""
output_dir=""
while (( $# > 0 )); do
  case "$1" in
    --command=*) command_name="${1#--command=}" ;;
    --from=*) from_image="${1#--from=}" ;;
    --registry-config=*) registry_config="${1#--registry-config=}" ;;
    --to) output_dir="$2"; shift ;;
  esac
  shift
done

if [[ -z "${command_name}" || -z "${output_dir}" ]]; then
  printf 'missing command or output directory: %s\n' "$*" >&2
  exit 2
fi
if [[ "${from_image}" != "${EXPECTED_FROM}" ]]; then
  printf 'unexpected release image: %s\n' "${from_image}" >&2
  exit 3
fi
if [[ "${registry_config}" != ".pullsecret" || ! -s "${registry_config}" ]]; then
  printf 'missing registry config .pullsecret\n' >&2
  exit 3
fi
if [[ "$(<"${registry_config}")" != '{"auths":{"quay.io":{"auth":"test"}}}' ]]; then
  printf 'invalid registry config .pullsecret\n' >&2
  exit 3
fi

mkdir -p "${output_dir}"
printf '#!/usr/bin/env bash\n' > "${output_dir}/${command_name}"
EOF

chmod +x "${TMPDIR}/bin/az" "${TMPDIR}/bin/oc"
cp "${REPO_ROOT}/Makefile" "${TMPDIR}/Makefile"

run_setup_tools() {
  make -j4 -C "${TMPDIR}" "$@" \
    TOOLS_DIR="${TMPDIR}/tools" \
    REGISTRY=test-registry \
    AZURE_SUBSCRIPTION_NAME=test-subscription \
    RELEASE_IMAGE=quay.io/example/release@sha256:test
}

PATH="${TMPDIR}/bin:${PATH}" \
  EXPECTED_FROM=quay.io/example/release@sha256:test \
  run_setup_tools setup-tools .pullsecret

test -x "${TMPDIR}/tools/oc"
test -x "${TMPDIR}/tools/openshift-install"
test "$(stat -c '%a' "${TMPDIR}/.pullsecret")" = 600

rm "${TMPDIR}/.pullsecret"
PATH="${TMPDIR}/bin:${PATH}" FAIL_AZ=true run_setup_tools setup-tools

PATH="${TMPDIR}/bin:${PATH}" \
  EXPECTED_FROM=quay.io/openshift-release-dev/ocp-release@sha256:1a50a7c21acc0b113aa74c187bec8798cb58481c065a4c5a0e25df6bc46b8815 \
  make -j4 -C "${TMPDIR}" setup-tools \
    TOOLS_DIR="${TMPDIR}/default-tools" \
    REGISTRY=test-registry \
    AZURE_SUBSCRIPTION_NAME=test-subscription
