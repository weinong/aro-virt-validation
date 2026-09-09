#!/usr/bin/env bash
# Validates the offline halves of the root-cause proof:
#   * scripts/25-analyze-deposit-ledger.py  -- ledger parsing
#   * scripts/26-verify-zeropad-overread.sh -- panic Code: decode, PMD decode
#
# Runs in ~1 second, needs no cluster. Each case here corresponds to a parsing
# bug that was actually hit and would otherwise have produced a confidently
# wrong claim in the writeup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. ledger analyser self-test -------------------------------------------
python3 "${REPO_ROOT}/scripts/25-analyze-deposit-ledger.py" --self-test >/dev/null \
  || fail "25 self-test"

# --- 2. REGRESSION: ftrace comms containing spaces --------------------------
# "CPU 0/MSHV-14292" has a space in the comm. Matching it as \S+ silently
# dropped ~a third of all deposit records and understated the single-page
# fraction that the "deposits scatter next to network buffers" claim rests on.
cat > "${TMPDIR}/ledger.log" <<'EOF'
      CPU 0/MSHV-14292   [078] .....   100.000000: hv_deposit_pages_block: token=1 partition_id=160 node=-1 base_pfn=0x1000 count=1 end_pfn=0x1000 va=0x0-0x0
      CPU 0/MSHV-14292   [078] .....   100.500000: hv_deposit_pages_block: token=2 partition_id=160 node=-1 base_pfn=0x2000 count=4 end_pfn=0x2003 va=0x0-0x0
          qemu-kvm-999   [001] .....   101.000000: hv_deposit_pages_block: token=3 partition_id=161 node=-1 base_pfn=0x3000 count=1 end_pfn=0x3000 va=0x0-0x0
             <...>-14226 [048] .....   102.000000: hv_withdraw_pages: partition_id=160 completed=1 status=0x0 pfns={0x1000,0x2000}
EOF
out="$(python3 "${REPO_ROOT}/scripts/25-analyze-deposit-ledger.py" "${TMPDIR}/ledger.log")"
grep -q 'deposit blocks     : 3  (6 pages)' <<<"${out}" || fail "block/page count: ${out}"
grep -q 'single-page blocks : 2' <<<"${out}"            || fail "single-page count"
# 6 deposited, 2 withdrawn -> 4 live
grep -q 'live deposited     : 4 pages' <<<"${out}"      || fail "live page count"
grep -q 'CPU 0/MSHV' <<<"${out}"                        || fail "comm with space dropped"
grep -q 'guest partitions seen: 2' <<<"${out}"          || fail "partition count"

# --- 3. panic Code: decode --------------------------------------------------
# Byte-for-byte the real panic: the <> byte is the faulting instruction.
cat > "${TMPDIR}/vmcore-dmesg.txt" <<'EOF'
[  270.221617] Oops: general protection fault, maybe for address 0xff11003119097ffa: 0000 [#1] SMP NOPTI
[  270.223904] RIP: 0010:csum_partial+0xe5/0x110
[  270.224192] Code: e3 fb f0 c2 20 48 01 d0 48 c1 e8 20 c3 cc cc cc cc 48 03 10 48 83 d2 00 48 83 c0 08 40 f6 c6 07 74 dd f7 de c1 e6 03 83 e6 3f <48> 8b 00 c4 e2 c9 f7 c0 c4 e2 cb f7 c0 48 01 c2 48 83 d2 00 c4 e3
EOF
out="$(bash "${REPO_ROOT}/scripts/26-verify-zeropad-overread.sh" insn "${TMPDIR}/vmcore-dmesg.txt")"
grep -q 'neg *%esi' <<<"${out}"        || fail "expected neg %esi"
grep -q 'shl *\$0x3,%esi' <<<"${out}"  || fail "expected shl \$0x3"
grep -q 'and *\$0x3f,%esi' <<<"${out}" || fail "expected and \$0x3f"
grep -q 'mov *(%rax),%rax' <<<"${out}" || fail "expected the zeropad load"

# --- 4. REGRESSION: vtop.txt holds MANY translations ------------------------
# Taking the first PMD in the file decoded an unrelated page (0x8000000100...)
# and would have "confirmed" the huge-page claim from the wrong mapping.
cat > "${TMPDIR}/vtop.txt" <<'EOF'
Translating virtual address ff11000100000000 to physical address.
  PGD :          6624888 =>          7c01067
  PMD :        107119640 => 80000001000001e3
VIRTUAL           PHYSICAL
ff11000100000000  100000000

Translating virtual address ff11003119097ffa to physical address.
  PGD :          6624888 =>          7c01067
  PUD :          7c02620 =>        107119063
  PMD :        107119640 => 80000031190001e3
VIRTUAL           PHYSICAL
ff11003119097ffa  3119097ffa
EOF
out="$(bash "${REPO_ROOT}/scripts/26-verify-zeropad-overread.sh" ptes "${TMPDIR}/vtop.txt" 0xff11003119097ffa)"
grep -q 'PMD entry 0x80000031190001e3' <<<"${out}" || fail "selected the wrong translation block"
grep -q 'bit 0  Present         = 1' <<<"${out}"   || fail "Present bit"
grep -q 'bit 7  PS (huge page)  = 1' <<<"${out}"   || fail "PS bit"

# An address that is not in the file must be an error, never a silent fallback.
if bash "${REPO_ROOT}/scripts/26-verify-zeropad-overread.sh" ptes "${TMPDIR}/vtop.txt" 0xdeadbeef >/dev/null 2>&1; then
  fail "unknown address should not succeed"
fi

echo "zeropad-overread-tests: OK (4 groups)"
