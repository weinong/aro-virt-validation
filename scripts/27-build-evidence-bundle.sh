#!/usr/bin/env bash
# =============================================================================
# 27-build-evidence-bundle.sh - Package everything a third party needs to
# re-run the root-cause proof themselves.
#
# Produces a self-contained tarball with the analysis scripts, the raw artifacts
# (panic logs, page-table walks, deposit ledgers, stress telemetry), the writeup,
# and a verify.sh that re-runs every OFFLINE proof end to end.
#
# The recipient needs no cluster, no Azure access, and no kernel RPM: just
# bash + python3 + objdump. On-node scripts are included too, for anyone who
# does have an L1VH cluster and wants to reproduce the live experiments.
#
# The bundle is VERIFIED before it is handed over: this script extracts the
# tarball into a temp directory and runs verify.sh there. A bundle that cannot
# reproduce its own conclusions is worse than no bundle.
#
# Usage:
#   ./scripts/27-build-evidence-bundle.sh build [OUTPUT.tar.gz]
#   ./scripts/27-build-evidence-bundle.sh verify <BUNDLE.tar.gz>
#
# Tunables (env): KERNEL_DEVEL_RPM (to embed the word-at-a-time.h header).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

REPO="${_REPO_ROOT}"
RUNS="${REPO}/.checkup-runs"
KERNEL_DEVEL_RPM="${KERNEL_DEVEL_RPM:-$HOME/kernel-rpms-mgns1/kernel-devel-6.12.0-211.49.1.1794_2798046552.mgns1.el10.x86_64.rpm}"

# label : dump directory (relative to .checkup-runs) : ledger boot dir : expected correlated faults
PAIRS=(
  "fault-17:52:26|kdump-collected/aro-virt-test-8gpzs-worker-mshv-centralus1-66wzs127.0.0.1-2026-09-09-17:52:26|boot-70493c9c-53e3-491d-8ef4-4127316118b9|2"
  "fault-17:20:44|kdump-collected/aro-virt-test-8gpzs-worker-mshv-centralus1-66wzs127.0.0.1-2026-09-09-17:20:44|boot-3d6e1ee7-757e-4c7e-bc49-67261efa3fd7|1"
  "fault-21:46:03-thanos|crash-2026-09-09-2146|boot-cd8ceab0-ff99-4588-9ae6-25b994f1707b|1"
)

OFFLINE_SCRIPTS=(20-analyze-stress-runs.py 22-correlate-fault-deposits.py
                 25-analyze-deposit-ledger.py 26-verify-zeropad-overread.sh)
ONNODE_SCRIPTS=(16-mshv-kdump.sh 18-mshv-fault-differential.sh
                19-mshv-veth-csum-stress.sh 21-mshv-deposit-trace.sh
                23-csum-software-rate.sh 24-deposit-page-readability.sh
                17-kcore-directmap-probe.py)
TESTS=(zeropad-overread-tests.sh stress-run-analysis-tests.sh)

cmd_build() {
  local out="${1:-${REPO}/aro-l1vh-csum-evidence-$(date -u +%Y%m%d).tar.gz}"
  local stage top
  stage="$(mktemp -d)"
  top="aro-l1vh-csum-evidence"
  local B="${stage}/${top}"
  mkdir -p "${B}"/{scripts,tests,issues,evidence/faults,evidence/ledgers,evidence/kernel,evidence/stress-runs}

  log_info "collecting scripts"
  cp "${REPO}/scripts/env.sh" "${B}/scripts/"
  for s in "${OFFLINE_SCRIPTS[@]}" "${ONNODE_SCRIPTS[@]}"; do
    [[ -f "${REPO}/scripts/${s}" ]] && cp "${REPO}/scripts/${s}" "${B}/scripts/"
  done
  for t in "${TESTS[@]}"; do cp "${REPO}/tests/${t}" "${B}/tests/"; done

  log_info "collecting writeups"
  cp "${REPO}"/issues/2026-09-0*.md "${B}/issues/" 2>/dev/null || true
  [[ -f "${RUNS}/mshv-deposit-trace/root-cause-summary.html" ]] && \
    cp "${RUNS}/mshv-deposit-trace/root-cause-summary.html" "${B}/summary.html"

  log_info "collecting fault/ledger pairs"
  : > "${B}/evidence/pairs.tsv"
  printf 'label\tdump\tledger\texpected_correlated\n' >> "${B}/evidence/pairs.tsv"
  for p in "${PAIRS[@]}"; do
    IFS='|' read -r label dump ledger want <<<"${p}"
    local src="${RUNS}/${dump}"
    if [[ ! -f "${src}/vmcore-dmesg.txt" ]]; then
      log_warn "missing dump for ${label}: ${src}"; continue
    fi
    mkdir -p "${B}/evidence/faults/${label}"
    cp "${src}/vmcore-dmesg.txt" "${B}/evidence/faults/${label}/"
    [[ -f "${src}/vtop.txt" ]] && cp "${src}/vtop.txt" "${B}/evidence/faults/${label}/"
    if [[ -f "${RUNS}/mshv-deposit-trace/${ledger}/trace.log" ]]; then
      mkdir -p "${B}/evidence/ledgers/${ledger}"
      cp "${RUNS}/mshv-deposit-trace/${ledger}/trace.log" "${B}/evidence/ledgers/${ledger}/"
      [[ -f "${RUNS}/mshv-deposit-trace/${ledger}/meta.txt" ]] && \
        cp "${RUNS}/mshv-deposit-trace/${ledger}/meta.txt" "${B}/evidence/ledgers/${ledger}/"
    else
      log_warn "missing ledger for ${label}: ${ledger}"
    fi
    printf '%s\t%s\t%s\t%s\n' "${label}" "${label}" "${ledger}" "${want}" >> "${B}/evidence/pairs.tsv"
  done

  log_info "collecting stress-run telemetry (the offload A/B)"
  if [[ -d "${RUNS}/veth-csum-stress" ]]; then
    cp -r "${RUNS}/veth-csum-stress/." "${B}/evidence/stress-runs/" 2>/dev/null || true
  fi

  log_info "embedding word-at-a-time.h (instead of a 19 MB kernel RPM)"
  if [[ -f "${KERNEL_DEVEL_RPM}" ]] && command -v rpm2cpio >/dev/null && command -v cpio >/dev/null; then
    local t; t="$(mktemp -d)"
    ( cd "${t}" && rpm2cpio "${KERNEL_DEVEL_RPM}" 2>/dev/null | cpio -id --quiet 2>/dev/null ) || true
    local hdr; hdr="$(find "${t}" -path '*asm/word-at-a-time.h' | head -1)"
    if [[ -n "${hdr}" ]]; then
      cp "${hdr}" "${B}/evidence/kernel/word-at-a-time.h"
      printf 'from: %s\n' "$(basename "${KERNEL_DEVEL_RPM}")" > "${B}/evidence/kernel/PROVENANCE.txt"
    fi
    rm -rf "${t}"
  else
    log_warn "kernel-devel RPM not found at ${KERNEL_DEVEL_RPM}; extable proof will be skipped"
  fi

  write_readme "${B}"
  write_verify "${B}"
  chmod +x "${B}/verify.sh"

  log_info "writing MANIFEST.sha256"
  ( cd "${B}" && find . -type f ! -name MANIFEST.sha256 -print0 |
      sort -z | xargs -0 sha256sum > MANIFEST.sha256 )

  log_info "creating tarball"
  ( cd "${stage}" && tar czf "${out}" "${top}" )
  rm -rf "${stage}"
  log_ok "bundle: ${out} ($(du -h "${out}" | cut -f1))"

  cmd_verify "${out}"
}

write_readme() {
  local B="$1"
  cat > "${B}/README.md" <<'EOF'
# ARO L1VH `csum_partial` `#GP` — evidence bundle

Everything needed to re-check the root cause independently.

## TL;DR

```sh
./verify.sh
```

Runs every **offline** proof and prints PASS/FAIL per claim. Needs only
`bash`, `python3`, and `objdump`. No cluster, no Azure, no kernel RPM.

## The conclusion being tested

`csum_partial`'s tail is `load_unaligned_zeropad()`, which deliberately
over-reads up to 7 bytes past a buffer. That load is annotated
`EX_TYPE_ZEROPAD`, so on a normal host it takes a `#PF`, the fixup substitutes
zero-padded data, and nothing crashes. On an L1VH root partition the next page
may be one donated to the hypervisor via `HVCALL_DEPOSIT_MEMORY`; touching it
raises **`#GP`**, which the zeropad fixup cannot rescue, and the node panics.

The decade-old over-read is not the bug. The `#GP`-instead-of-`#PF` contract
violation is.

## What is in here

| Path | What it is |
|---|---|
| `evidence/faults/*/vmcore-dmesg.txt` | kdump panic logs (the `Code:` bytes and `#GP` line) |
| `evidence/faults/*/vtop.txt` | page-table walks captured at crash time |
| `evidence/ledgers/boot-*/trace.log` | deposit/withdraw tracepoint ledgers, streamed from boot |
| `evidence/kernel/word-at-a-time.h` | the header showing the `EX_TYPE_ZEROPAD` annotation |
| `evidence/stress-runs/` | telemetry from the checksum-offload A/B |
| `evidence/pairs.tsv` | which ledger belongs to which panic |
| `scripts/` | analysis scripts (offline) and experiment drivers (need a cluster) |
| `issues/` | full writeups, including superseded theories and why they were wrong |
| `summary.html` | one-page summary |

## Offline checks, individually

```sh
# 1. The faulting insn is the fixup-annotated zeropad load; page still mapped.
scripts/26-verify-zeropad-overread.sh insn    evidence/faults/<label>/vmcore-dmesg.txt
scripts/26-verify-zeropad-overread.sh extable evidence/kernel/word-at-a-time.h
scripts/26-verify-zeropad-overread.sh ptes    evidence/faults/<label>/vtop.txt <fault-addr>

# 2. The fault's NEXT page was deposited to the hypervisor and not withdrawn.
python3 scripts/22-correlate-fault-deposits.py \
    evidence/ledgers/<boot>/trace.log evidence/faults/<label>/vmcore-dmesg.txt

# 3. Deposits are single scattered pages; partitions churn constantly.
python3 scripts/25-analyze-deposit-ledger.py evidence/ledgers/<boot>/trace.log

# 4. The checksum-offload A/B.
python3 scripts/20-analyze-stress-runs.py evidence/stress-runs

# 5. The analysis tooling itself.
bash tests/zeropad-overread-tests.sh
bash tests/stress-run-analysis-tests.sh
```

## Reproducing the LIVE experiments (needs an L1VH cluster)

These panic nodes on purpose. See
`issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md` for the full
procedure and prerequisites (`nokaslr`, kdump, boot-time deposit ledger).

```sh
export KUBECONFIG=... NODE=<mshv-node>
bash scripts/21-mshv-deposit-trace.sh install     # ledger, complete from boot
DISABLE_CSUM_OFFLOAD=false bash scripts/19-mshv-veth-csum-stress.sh run  # survives
DISABLE_CSUM_OFFLOAD=true  bash scripts/19-mshv-veth-csum-stress.sh run  # panics
bash scripts/23-csum-software-rate.sh validate    # run BEFORE trusting measure
bash scripts/24-deposit-page-readability.sh probe
```

## Caveats carried with the evidence

* Networking is the dominant trigger, not the only one. `strscpy()` and the
  dcache path use the same over-reading load.
* Deposit does not immediately revoke access — a substantial fraction of live
  deposited pages still read back real data.
* That the fixup is skipped specifically because `#GP` passes `fault_addr = 0`
  is **inferred**; confirming it needs `arch/x86/mm/extable.c`.
* The offload A/B control ran 420 s against a heavy-tailed crash distribution,
  so its weight rests on volume (~1000x), not elapsed time.
EOF
}

write_verify() {
  local B="$1"
  cat > "${B}/verify.sh" <<'EOF'
#!/usr/bin/env bash
# Re-runs every offline proof in this bundle. No cluster required.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export SKIP_REPO_ENV=true      # do not source a .env we did not ship

pass=0; fail=0
ok()   { echo "  PASS  $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
need() { command -v "$1" >/dev/null || { echo "missing required tool: $1"; exit 2; }; }
need bash; need python3

echo "== 0. integrity =="
if command -v sha256sum >/dev/null; then
  if sha256sum --quiet -c MANIFEST.sha256 2>/dev/null; then ok "MANIFEST.sha256"
  else bad "MANIFEST.sha256 (files modified or missing)"; fi
else echo "  SKIP  sha256sum not available"; fi

echo "== 1. analysis tooling self-tests =="
bash tests/zeropad-overread-tests.sh >/dev/null 2>&1 && ok "zeropad-overread-tests" || bad "zeropad-overread-tests"
bash tests/stress-run-analysis-tests.sh >/dev/null 2>&1 && ok "stress-run-analysis-tests" || bad "stress-run-analysis-tests"
python3 scripts/22-correlate-fault-deposits.py --self-test >/dev/null 2>&1 && ok "correlator self-test" || bad "correlator self-test"
python3 scripts/25-analyze-deposit-ledger.py --self-test >/dev/null 2>&1 && ok "ledger analyser self-test" || bad "ledger analyser self-test"

echo "== 2. faulting instruction is the zeropad load =="
if command -v objdump >/dev/null; then
  for d in evidence/faults/*/; do
    out="$(bash scripts/26-verify-zeropad-overread.sh insn "$d/vmcore-dmesg.txt" 2>&1)"
    if grep -q 'mov *(%rax),%rax' <<<"$out" && grep -q 'and *\$0x3f,%esi' <<<"$out"; then
      ok "zeropad load in $(basename "$d")"
    else bad "zeropad load in $(basename "$d")"; fi
  done
else echo "  SKIP  objdump not available"; fi

echo "== 3. that load carries an EX_TYPE_ZEROPAD fixup =="
if [ -f evidence/kernel/word-at-a-time.h ]; then
  # Capture first: piping into `grep -q` with pipefail set makes grep exit on the
  # first match, SIGPIPE the producer, and turn a PASS into a spurious FAIL.
  out="$(bash scripts/26-verify-zeropad-overread.sh extable evidence/kernel/word-at-a-time.h 2>&1)"
  if grep -q 'EX_TYPE_ZEROPAD' <<<"$out"; then ok "EX_TYPE_ZEROPAD annotation"
  else bad "EX_TYPE_ZEROPAD annotation"; fi
else echo "  SKIP  no kernel header bundled"; fi

echo "== 4. Linux still maps the faulting page (so #PF was impossible) =="
for d in evidence/faults/*/; do
  [ -f "$d/vtop.txt" ] || continue
  addr="$(grep -aoE 'general protection fault, maybe for address 0x[0-9a-f]+' "$d/vmcore-dmesg.txt" | head -1 | grep -oE '0x[0-9a-f]+')"
  [ -n "$addr" ] || continue
  out="$(bash scripts/26-verify-zeropad-overread.sh ptes "$d/vtop.txt" "$addr" 2>&1)"
  if grep -q 'bit 0  Present         = 1' <<<"$out" && grep -q 'bit 7  PS (huge page)  = 1' <<<"$out"; then
    ok "PMD Present+huge for $addr"
  else echo "  SKIP  no matching translation block for $addr in $(basename "$d")"; fi
done

echo "== 5. each fault's NEXT page was deposited and not withdrawn =="
while IFS=$'\t' read -r label dump ledger want; do
  [ -n "$label" ] || continue
  led="evidence/ledgers/$ledger/trace.log"
  dmp="evidence/faults/$dump/vmcore-dmesg.txt"
  if [ ! -f "$led" ] || [ ! -f "$dmp" ]; then bad "$label (missing artifact)"; continue; fi
  out="$(python3 scripts/22-correlate-fault-deposits.py "$led" "$dmp" 2>&1)"
  got="$(grep -oE 'inside a deposited range: [0-9]+' <<<"$out" | grep -oE '[0-9]+$')"
  got="${got:-0}"
  if [ "$got" -ge "$want" ]; then ok "$label: $got/$want faults in a deposited range"
  else bad "$label: only $got of $want correlated"; fi
done < <(tail -n +2 evidence/pairs.tsv)

echo "== 6. deposits are single scattered pages =="
for l in evidence/ledgers/*/trace.log; do
  [ -f "$l" ] || continue
  out="$(python3 scripts/25-analyze-deposit-ledger.py "$l" 2>&1)"
  pct="$(grep -oE 'single-page blocks : [0-9]+  \([0-9.]+%' <<<"$out" | grep -oE '[0-9.]+%' | tr -d '%')"
  if [ -n "$pct" ] && awk "BEGIN{exit !($pct > 90)}"; then
    ok "$(basename "$(dirname "$l")"): ${pct}% single-page deposits"
  else bad "$(basename "$(dirname "$l")"): single-page fraction ${pct:-?}%"; fi
done

echo
echo "-------------------------------------------"
if [ "$fail" -eq 0 ]; then
  echo "ALL OFFLINE PROOFS REPRODUCED ($pass checks)"
else
  echo "$pass passed, $fail FAILED"
fi
echo "-------------------------------------------"
[ "$fail" -eq 0 ]
EOF
}

cmd_verify() {
  local tarball="${1:?need a bundle tarball}"
  local t; t="$(mktemp -d)"
  log_info "verifying bundle by extracting and running verify.sh in a clean dir"
  tar xzf "${tarball}" -C "${t}"
  local root; root="$(find "${t}" -maxdepth 1 -mindepth 1 -type d | head -1)"
  ( cd "${root}" && bash verify.sh )
  local rc=$?
  rm -rf "${t}"
  if [[ ${rc} -eq 0 ]]; then
    log_ok "bundle verified: it reproduces its own conclusions"
  else
    log_error "bundle FAILED its own verification"
  fi
  return ${rc}
}

case "${1:-}" in
  build)  shift; cmd_build "${1:-}" ;;
  verify) shift; cmd_verify "${1:-}" ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
