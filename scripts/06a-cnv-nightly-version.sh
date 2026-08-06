#!/usr/bin/env bash
# Print component versions from the current head of a CNV nightly channel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
requested_cnv_version="${CNV_VERSION:-}"
source "${SCRIPT_DIR}/env.sh"

CNV_VERSION="${requested_cnv_version:-${CNV_VERSION:-4.99}}"
CATALOG_IMAGE="quay.io/openshift-cnv/nightly-catalog:${CNV_VERSION}"
CHANNEL="nightly-${CNV_VERSION}"

for cmd in oc jq podman sed; do
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

if ! bundle_name=$(jq -er --arg channel "${CHANNEL}" '
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
    end
' "${tmp_dir}/nightly_catalog.json"); then
  log_error "Could not determine the head of channel ${CHANNEL}."
  exit 1
fi

if ! cnv_version=$(jq -ner --arg name "${bundle_name}" '
  $name | capture("^kubevirt-hyperconverged-operator[.]v?(?<version>[0-9]+[.][0-9]+[.][0-9]+-[0-9]+)$").version
') ||
  ! component_images=$(jq -cer --arg bundle "${bundle_name}" '
    select(
      .schema == "olm.bundle" and
      .package == "kubevirt-hyperconverged" and
      .name == $bundle
    )
    | {
        operator: ([.relatedImages[].image | select(test("/container-native-virtualization-virt-operator-rhel9@"))] | if length == 1 then .[0] else error("expected one virt-operator image") end),
        launcher: ([.relatedImages[].image | select(test("/container-native-virtualization-virt-launcher-rhel9@"))] | if length == 1 then .[0] else error("expected one virt-launcher image") end)
      }
  ' "${tmp_dir}/nightly_catalog.json"); then
  log_error "Could not resolve component images for ${bundle_name}."
  exit 1
fi

operator_image=$(jq -r '.operator' <<< "${component_images}")
launcher_image=$(jq -r '.launcher' <<< "${component_images}")

if ! kubevirt_version=$(oc image info --filter-by-os=linux/amd64 \
  -o json "${operator_image}" \
  | jq -er '.config.config.Labels["upstream-version"] | select(test("^v?[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$")) | sub("^v"; "")'); then
  log_error "Could not determine the KubeVirt version from ${operator_image}."
  exit 1
fi

if ! qemu_version=$(podman run --rm --quiet --platform linux/amd64 \
  --entrypoint /usr/libexec/qemu-kvm \
  "${launcher_image}" --version \
  | sed -n '1s/^QEMU emulator version \([^ ]*\) (\(qemu-kvm-[^)]*\))$/\1 (\2)/p') ||
  [[ -z "${qemu_version}" ]]; then
  log_error "Could not determine the QEMU version from ${launcher_image}."
  exit 1
fi

printf 'CNV:      %s\n' "${cnv_version}"
printf 'KubeVirt: v%s\n' "${kubevirt_version}"
printf 'QEMU:     %s\n' "${qemu_version}"
