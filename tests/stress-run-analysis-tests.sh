#!/usr/bin/env bash
# Validates the offline analyser against synthetic run directories.
# Runs in ~1 second and needs no cluster: this is the fast feedback loop that
# replaces discovering a parsing bug 900 seconds into a real experiment.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
RUNS="${TMPDIR}/runs"

mk_run() { # name l1vh streams duration
  local d="${RUNS}/$1"; mkdir -p "$d"
  printf 'run_id\t%s\nnode\tnode-x\nstreams\t%s\nduration\t%s\nboot_before\tboot-1\n' "$1" "$3" "$4" > "$d/meta.tsv"
  printf 'kernel\t6.12.0-test\nl1vh\t%s\nmshv_root\t1\nnokaslr\t1\nnproc\t192\n' "$2" > "$d/node-facts.tsv"
  printf 'utc\tuptime_s\tboot_id\tready\n' > "$d/poll.tsv"
  echo "$d"
}

# --- run A: crashed at 30s after 20 GiB, on L1VH -------------------------
d="$(mk_run 20260101T000000Z-aaa-s32 1 32 900)"
for t in 0 10 20; do printf '2026-01-01T00:00:%02dZ\t%s\tboot-1\tTrue\n' "$t" "$t" >> "$d/poll.tsv"; done
printf '2026-01-01T00:00:30Z\t30\tboot-2\tFalse\n' >> "$d/poll.tsv"
{ echo "# run_id=A streams=32"; echo "# load_start_uptime=100.0"
  echo -e "SAMPLE\t110.0\t$((5*2**30))\t100"
  echo -e "SAMPLE\t120.0\t$((10*2**30))\t200"
  echo -e "SAMPLE\t130.0\t$((20*2**30))\t300"
  echo -e "SAMPLE\t140.0\t$((40*2**30))\t400"   # after the reset; must be excluded
  printf 'SAMPLE\t150.0\t99'; } > "$d/telemetry.tsv"   # truncated line: node died mid-write

# --- run B: survived, pushed 300 GiB, non-L1VH ---------------------------
d="$(mk_run 20260101T010000Z-bbb-s32 0 32 900)"
for t in 0 10 20 30; do printf '2026-01-01T01:00:%02dZ\t%s\tboot-9\tTrue\n' "$t" "$t" >> "$d/poll.tsv"; done
{ echo "# load_start_uptime=50.0"; echo -e "SAMPLE\t60.0\t$((300*2**30))\t9999"; } > "$d/telemetry.tsv"

# --- run C: survived but produced NO traffic (void negative) -------------
d="$(mk_run 20260101T020000Z-ccc-s8 1 8 900)"
printf '2026-01-01T02:00:00Z\t0\tboot-7\tTrue\n' >> "$d/poll.tsv"
: > "$d/telemetry.tsv"

out="$(python3 "${REPO_ROOT}/scripts/20-analyze-stress-runs.py" "${RUNS}")"
printf '%s\n' "${out}" > "${TMPDIR}/out.txt"

# Reset detection must come from the boot-ID change, at 30s.
grep -qE '20260101T000000Z-aaa-s32.*\b30\b' <<< "${out}" \
  || { echo "FAIL: reset time not detected"; echo "${out}"; exit 1; }

# Bytes must be attributed as of the reset (20 GiB), NOT the post-reset 40 GiB
# sample: counting bytes recorded after the node died would inflate the result.
# Compare the specific columns, not the whole line -- 40.0 legitimately appears
# in the peak column.
row="$(grep -E '^20260101T000000Z-aaa-s32' <<< "${out}")"
at_reset="$(awk '{print $(NF-2)}' <<< "${row}")"
peak="$(awk '{print $(NF-1)}' <<< "${row}")"
[[ "${at_reset}" == "20.0" ]] || { echo "FAIL: bytes-at-reset=${at_reset}, want 20.0"; echo "${out}"; exit 1; }
[[ "${peak}" == "40.0" ]] || { echo "FAIL: peak=${peak}, want 40.0"; echo "${out}"; exit 1; }

# A truncated final line (the panic) must not abort parsing.
grep -q 'samples' <<< "${out}" || { echo "FAIL: header missing"; exit 1; }

# Survivors must be reported with the traffic they actually pushed, so a
# negative result can be judged meaningful rather than assumed.
grep -qE 'bbb-s32.*300\.0 GiB' <<< "${out}" \
  || { echo "FAIL: survivor traffic not reported"; echo "${out}"; exit 1; }
grep -qE 'bbb-s32.*MEANINGFUL' <<< "${out}" \
  || { echo "FAIL: survivor with traffic should be MEANINGFUL"; echo "${out}"; exit 1; }
# A survivor with zero traffic must be called out as void, not counted as evidence.
grep -qE 'ccc-s8.*(void|NO TRAFFIC)' <<< "${out}" \
  || { echo "FAIL: zero-traffic survivor must be flagged void"; echo "${out}"; exit 1; }

# Must not touch the cluster.
grep -qi 'oc \|kubectl' "${REPO_ROOT}/scripts/20-analyze-stress-runs.py" \
  && { echo "FAIL: analyser must not call the cluster"; exit 1; }

printf 'stress-run-analysis-tests: OK (3 fixtures)\n'
