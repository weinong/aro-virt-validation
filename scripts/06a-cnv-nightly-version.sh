#!/usr/bin/env bash
# Print the current head version from a CNV nightly catalog channel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
requested_cnv_version="${CNV_VERSION:-}"
source "${SCRIPT_DIR}/env.sh"

CNV_VERSION="${requested_cnv_version:-${CNV_VERSION:-4.99}}"
CATALOG_IMAGE="quay.io/openshift-cnv/nightly-catalog:${CNV_VERSION}"
CHANNEL="nightly-${CNV_VERSION}"

for cmd in oc jq; do
  check_command "${cmd}" || exit 1
done

if [[ ! "${CNV_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  log_error "CNV_VERSION must be a major.minor version, got '${CNV_VERSION}'."
  exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

if ! oc image extract --filter-by-os=linux/amd64 \
  --path "/configs/nightly_catalog.json:${tmp_dir}" \
  "${CATALOG_IMAGE}" >/dev/null; then
  log_error "Could not extract ${CATALOG_IMAGE}. Verify your quay.io login."
  exit 1
fi

if ! version=$(jq -er --arg channel "${CHANNEL}" '
  select(
    .schema == "olm.channel" and
    .package == "kubevirt-hyperconverged" and
    .name == $channel
  )
  | .entries as $entries
  | [$entries[] | (.replaces? // empty), (.skips[]?)] as $superseded
  | [$entries[] | select(.name as $name | ($superseded | index($name) | not))] as $heads
  | if ($heads | length) != 1 then
      error("expected exactly one channel head")
    else
      $heads[0].name
      | capture("^kubevirt-hyperconverged-operator[.]v?(?<version>.+)$").version
    end
' "${tmp_dir}/nightly_catalog.json"); then
  log_error "Could not determine the head of channel ${CHANNEL}."
  exit 1
fi

printf '%s\n' "${version}"
