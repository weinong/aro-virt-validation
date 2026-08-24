#!/usr/bin/env bash
# =============================================================================
# 03a-payload-crd-ordering-fix.sh - Pre-apply TechPreview CRDs the CVO reaches
#                                   too late (payload ordering workaround)
#
# WORKAROUND, NOT A FIX. Under TechPreviewNoUpgrade some 4.22 payloads wedge the
# Cluster Version Operator because a CustomResourceDefinition is applied AFTER
# something that already needs it. Two observed shapes, both tracked upstream as
# OCPBUGS-99266 (see issues/2026-08-24.md):
#
#   1. CR-before-CRD: a feature-gated CR (e.g. CRIOCredentialProviderConfig,
#      ClusterAPI) has a lower CVO run level than its own CRD. The CVO applies
#      the CR first, fails with UpdatePayloadResourceTypeMissing, and never
#      reaches the CRD.
#   2. Consumer-before-CRD: a controller rolled out early (e.g. ovnkube-node)
#      watches a TechPreview CRD (e.g. DNSNameResolver) that the CVO only applies
#      at a later run level, so the controller crash-loops, blocks CNI, and the
#      CVO can never progress far enough to apply that CRD. A deadlock.
#
# This script extracts the running cluster's release payload and pre-applies the
# TechPreview-gated CRDs (for this cluster's topology) that are not yet served,
# plus any CRD that is the "later" half of a CR-before-CRD defect. Every applied
# CRD is the exact manifest from the payload; nothing is hand-authored. The CVO
# still owns and reconciles these CRDs at their (mis-ordered) run levels; this
# only unsticks the flow. The underlying payload bug stays open.
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
# Release-payload topology annotation to match (ARO / self-managed installer HA).
TOPOLOGY_INCLUDE="${TOPOLOGY_INCLUDE:-self-managed-high-availability}"

check_command oc || exit 1
check_command python3 || exit 1

log_info "=== Phase 3a: Release-payload TechPreview CRD ordering workaround ==="

oc whoami >/dev/null 2>&1 || { log_error "Not logged in."; exit 1; }

RELEASE_IMAGE="${RELEASE_IMAGE:-$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null || echo '')}"
[[ -n "${RELEASE_IMAGE}" ]] || { log_error "Could not determine the release image from ClusterVersion."; exit 1; }
log_info "Release image: ${RELEASE_IMAGE}"

FEATURE_SET="$(oc get featuregate/cluster -o jsonpath='{.spec.featureSet}' 2>/dev/null || echo '')"
# Which feature set the CRDs must be gated for. Default to the active one.
MATCH_FEATURE_SET="${MATCH_FEATURE_SET:-${FEATURE_SET:-TechPreviewNoUpgrade}}"

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

# Emit candidate CRDs to pre-apply. Two record shapes on stdout:
#   ORDERING<TAB>crd_path<TAB>crd_name<TAB>group/kind<TAB>cr_file<TAB>crd_file
#   GATED<TAB>crd_path<TAB>crd_name<TAB>feature_set
mapfile -t CANDIDATES < <(python3 - "${MANIFEST_DIR}" "${TOPOLOGY_INCLUDE}" "${MATCH_FEATURE_SET}" <<'PY'
import os, sys, re

manifest_dir, topology, match_fs = sys.argv[1], sys.argv[2], sys.argv[3]
files = sorted(f for f in os.listdir(manifest_dir) if f.endswith((".yaml", ".yml")))

def docs(path):
    with open(path, "r", errors="replace") as fh:
        text = fh.read()
    for chunk in re.split(r'(?m)^---\s*$', text):
        if chunk.strip():
            yield chunk

def field(chunk, pattern):
    m = re.search(pattern, chunk, re.M)
    return m.group(1).strip().strip('"') if m else None

crds = {}          # (group, kind) -> {name, file, feature_set, topo}
gated_crd = {}     # crd_name -> {path, feature_set}  (topology + feature-set match)
crs = []           # potential CRs of payload CRDs

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
            feature_set = field(chunk, r'release\.openshift\.io/feature-set:\s*(\S+)') or ""
            topo = field(chunk, r'include\.release\.openshift\.io/%s:\s*"?(\S+?)"?\s*$' % re.escape(topology))
            if group and served_kind:
                crds[(group, served_kind)] = {"name": name, "file": fname}
            # Collect topology-matched, feature-set-gated CRDs for pre-apply.
            if name and topo == "true" and match_fs and match_fs in feature_set.split(","):
                gated_crd.setdefault(name, {"path": path, "feature_set": feature_set})
        else:
            api = field(chunk, r'^apiVersion:\s*(\S+)')
            if not api or "/" not in api:
                continue
            group = api.rsplit("/", 1)[0]
            gated = bool(re.search(r'release\.openshift\.io/feature-(gate|set)\s*:', chunk))
            crs.append({"group": group, "kind": top_kind, "file": fname, "gated": gated})

# Shape 1: CR-before-CRD ordering defects (report + pre-apply the CRD).
ordering_names = set()
seen = set()
for cr in crs:
    key = (cr["group"], cr["kind"])
    crd = crds.get(key)
    if not crd or key in seen or not cr["gated"]:
        continue
    if cr["file"] < crd["file"]:
        seen.add(key)
        ordering_names.add(crd["name"])
        print("\t".join([
            "ORDERING", os.path.join(manifest_dir, crd["file"]), crd["name"] or "",
            "%s/%s" % (cr["group"], cr["kind"]), cr["file"], crd["file"],
        ]))

# Shape 2: topology-matched, TechPreview-gated CRDs (pre-apply if missing).
for name, info in sorted(gated_crd.items()):
    if name in ordering_names:
        continue  # already emitted as ORDERING
    print("\t".join(["GATED", info["path"], name, info["feature_set"]]))
PY
)

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  log_ok "No TechPreview CRD ordering candidates found in the release payload."
  exit 0
fi

# Report CR-before-CRD ordering defects prominently (the OCPBUGS-99266 headline).
ORDERING_COUNT=0
for line in "${CANDIDATES[@]}"; do
  [[ "${line}" == ORDERING$'\t'* ]] || continue
  IFS=$'\t' read -r _ crd_path crd_name gk cr_file crd_file <<< "${line}"
  if [[ "${ORDERING_COUNT}" -eq 0 ]]; then
    log_warn "CR-before-CRD ordering defect(s) in ${RELEASE_IMAGE} (OCPBUGS-99266):"
  fi
  log_warn "  ${gk}: CR '${cr_file}' is ordered before CRD '${crd_file}'"
  ORDERING_COUNT=$((ORDERING_COUNT + 1))
done

log_warn "Pre-applying payload CRD(s) is a documented WORKAROUND to unstick the CVO,"
log_warn "not a fix (see issues/2026-08-24.md, OCPBUGS-99266)."

if [[ "${DRY_RUN}" == "true" ]]; then
  log_info "DRY_RUN=true; not applying. Candidate CRDs (applied only when missing):"
  for line in "${CANDIDATES[@]}"; do
    IFS=$'\t' read -r kind crd_path crd_name _ <<< "${line}"
    echo "  [${kind}] ${crd_name}"
  done
  exit 0
fi

if [[ "${FEATURE_SET}" != "TechPreviewNoUpgrade" && "${FORCE_APPLY}" != "true" ]]; then
  log_warn "featureSet is '${FEATURE_SET}', not TechPreviewNoUpgrade; skipping apply."
  log_warn "These CRDs are only needed once TechPreview is enabled. Set FORCE_APPLY=true to override."
  exit 0
fi

APPLIED=0
for line in "${CANDIDATES[@]}"; do
  IFS=$'\t' read -r kind crd_path crd_name _ <<< "${line}"
  if [[ -n "${crd_name}" ]] && oc get crd "${crd_name}" &>/dev/null; then
    log_ok "CRD ${crd_name} already present; skipping."
    continue
  fi
  log_info "Applying payload CRD ${crd_name} (${kind})..."
  oc apply -f "${crd_path}"
  APPLIED=$((APPLIED + 1))
done

if [[ "${APPLIED}" -eq 0 ]]; then
  log_ok "All candidate CRDs were already present; nothing to apply."
else
  log_ok "Pre-applied ${APPLIED} payload CRD(s). The CVO/controllers should progress on their next resync."
fi
log_warn "The underlying payload ordering bug stays open; this workaround only unsticks the flow."
