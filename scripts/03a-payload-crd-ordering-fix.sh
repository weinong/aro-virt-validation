#!/usr/bin/env bash
# =============================================================================
# 03a-payload-crd-ordering-fix.sh - Work around CR-before-CRD payload ordering
#
# WORKAROUND, NOT A FIX. Some OCP release payloads ship a feature-gated custom
# resource whose CVO run level (manifest filename) sorts BEFORE the run level of
# its own CustomResourceDefinition. Under TechPreviewNoUpgrade the CVO tries to
# create the CR before its CRD exists, fails with
# "UpdatePayloadResourceTypeMissing", and wedges without ever reaching the CRD
# manifest. See issues/2026-08-24.md (CRIOCredentialProviderConfig on 4.22.4).
#
# This script detects that ordering defect directly in the release payload and
# pre-applies the affected CRD(s) straight from the payload so the CVO can make
# progress. The underlying payload bug remains open; this only unsticks the
# validation flow. It does not hand-author manifests: every applied CRD is the
# exact manifest extracted from the running cluster's release image.
#
# Tracked upstream by Red Hat as OCPBUGS-99266:
#   https://redhat.atlassian.net/browse/OCPBUGS-99266
#
# Idempotent. Safe to re-run.
#
# Usage:
#   ./scripts/03a-payload-crd-ordering-fix.sh          # detect + apply (under TP)
#   DRY_RUN=true ./scripts/03a-payload-crd-ordering-fix.sh   # detect + report only
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

DRY_RUN="${DRY_RUN:-false}"
# Only apply when the cluster is actually on TechPreviewNoUpgrade unless forced.
FORCE_APPLY="${FORCE_APPLY:-false}"

check_command oc || exit 1
check_command python3 || exit 1

log_info "=== Phase 3a: Release-payload CR-before-CRD ordering workaround ==="

oc whoami >/dev/null 2>&1 || { log_error "Not logged in."; exit 1; }

RELEASE_IMAGE="${RELEASE_IMAGE:-$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null || echo '')}"
[[ -n "${RELEASE_IMAGE}" ]] || { log_error "Could not determine the release image from ClusterVersion."; exit 1; }
log_info "Release image: ${RELEASE_IMAGE}"

FEATURE_SET="$(oc get featuregate/cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo '')"

WORK_DIR="$(mktemp -d)"
AUTH_FILE="${WORK_DIR}/auth.json"
MANIFEST_DIR="${WORK_DIR}/manifests"
mkdir -p "${MANIFEST_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

log_info "Reading the cluster global pull secret to authenticate the payload extract..."
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
  | base64 -d > "${AUTH_FILE}"
[[ -s "${AUTH_FILE}" ]] || { log_error "Could not read the cluster global pull secret."; exit 1; }

log_info "Extracting release payload manifests..."
oc adm release extract "${RELEASE_IMAGE}" -a "${AUTH_FILE}" --to "${MANIFEST_DIR}" >/dev/null

# Detect ordering defects. Prints, per defect, a TSV line:
#   <crd_manifest_path>\t<crd_name>\t<group>\t<kind>\t<cr_manifest_basename>\t<crd_manifest_basename>
mapfile -t DEFECTS < <(python3 - "${MANIFEST_DIR}" <<'PY'
import os, sys, re

manifest_dir = sys.argv[1]
files = sorted(f for f in os.listdir(manifest_dir) if f.endswith((".yaml", ".yml")))

def docs(path):
    with open(path, "r", errors="replace") as fh:
        text = fh.read()
    for chunk in re.split(r'(?m)^---\s*$', text):
        if chunk.strip():
            yield chunk

def field(chunk, pattern):
    m = re.search(pattern, chunk, re.M)
    return m.group(1).strip() if m else None

crds = {}          # (group, kind) -> {"name":..., "file":..., "sort": basename}
crs = []           # list of {"group","kind","file","gated"}

for fname in files:
    path = os.path.join(manifest_dir, fname)
    for chunk in docs(path):
        top_kind = field(chunk, r'^kind:\s*(\S+)')
        if not top_kind:
            continue
        if top_kind == "CustomResourceDefinition":
            group = field(chunk, r'^\s{2}group:\s*(\S+)')
            served_kind = field(chunk, r'^\s{4,}kind:\s*(\S+)')
            name = field(chunk, r'^\s{2}name:\s*(\S+)')
            if group and served_kind:
                crds[(group, served_kind)] = {"name": name, "file": fname}
        else:
            api = field(chunk, r'^apiVersion:\s*(\S+)')
            if not api or "/" not in api:
                continue
            group = api.rsplit("/", 1)[0]
            gated = bool(re.search(r'release\.openshift\.io/feature-(gate|set)\s*:', chunk))
            crs.append({"group": group, "kind": top_kind, "file": fname, "gated": gated})

seen = set()
for cr in crs:
    key = (cr["group"], cr["kind"])
    crd = crds.get(key)
    if not crd:
        continue
    # Defect: the CR manifest sorts before its own CRD manifest.
    if cr["file"] < crd["file"] and key not in seen:
        # Only care about gated CRs; GA resources are correctly ordered and are
        # not the source of the TechPreview wedge.
        if not cr["gated"]:
            continue
        seen.add(key)
        print("\t".join([
            os.path.join(manifest_dir, crd["file"]),
            crd["name"] or "",
            cr["group"], cr["kind"], cr["file"], crd["file"],
        ]))
PY
)

if [[ "${#DEFECTS[@]}" -eq 0 ]]; then
  log_ok "No CR-before-CRD ordering defect detected in the release payload."
  exit 0
fi

log_warn "Detected ${#DEFECTS[@]} CR-before-CRD ordering defect(s) in ${RELEASE_IMAGE}:"
for line in "${DEFECTS[@]}"; do
  IFS=$'\t' read -r crd_path crd_name group kind cr_file crd_file <<< "${line}"
  log_warn "  ${group}/${kind}: CR '${cr_file}' is ordered before CRD '${crd_file}'"
done
log_warn "This is a release-payload bug (see issues/2026-08-24.md, OCPBUGS-99266)."
log_warn "Pre-applying the payload CRD(s) is a documented WORKAROUND to unstick the"
log_warn "CVO, not a fix."

if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "DRY_RUN=true; not applying. The following payload CRDs would be applied when missing:"
  for line in "${DEFECTS[@]}"; do
    IFS=$'\t' read -r crd_path crd_name _ _ _ _ <<< "${line}"
    echo "  ${crd_name:-${crd_path##*/}}"
  done
  exit 0
fi

if [[ "${FEATURE_SET}" != "TechPreviewNoUpgrade" && "${FORCE_APPLY}" != "true" ]]; then
  log_warn "featureSet is '${FEATURE_SET}', not TechPreviewNoUpgrade; skipping apply."
  log_warn "These CRDs are only needed once TechPreview is enabled. Set FORCE_APPLY=true to override."
  exit 0
fi

APPLIED=0
for line in "${DEFECTS[@]}"; do
  IFS=$'\t' read -r crd_path crd_name group kind cr_file crd_file <<< "${line}"
  if [[ -n "${crd_name}" ]] && oc get crd "${crd_name}" &>/dev/null; then
    log_ok "CRD ${crd_name} already present; skipping."
    continue
  fi
  log_info "Applying payload CRD ${crd_name:-${crd_file}} for ${group}/${kind}..."
  oc apply -f "${crd_path}"
  APPLIED=$((APPLIED + 1))
done

if [[ "${APPLIED}" -eq 0 ]]; then
  log_ok "All affected CRDs were already present; nothing to apply."
else
  log_ok "Pre-applied ${APPLIED} payload CRD(s). The CVO should progress past the ordering defect on its next resync."
fi
log_warn "The underlying payload ordering bug stays open; this workaround only unsticks the flow."
