#!/usr/bin/env bash
# =============================================================================
# 26-verify-zeropad-overread.sh - Prove the faulting instruction is a DELIBERATE,
# exception-fixup-annotated over-read, and that Linux still maps the page.
#
# This is the evidence for the central claim of
# issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md: the decade-old
# over-read is not the bug. csum_partial's tail is load_unaligned_zeropad(),
# which carries an EX_TYPE_ZEROPAD fixup and is designed to survive running off
# the end of a buffer via #PF. It is fatal here only because the platform raises
# #GP instead, and the zeropad fixup cannot rescue a #GP.
#
# Runs entirely locally against artifacts already collected. Touches no cluster.
#
# Usage:
#   ./scripts/26-verify-zeropad-overread.sh insn   <vmcore-dmesg.txt>
#   ./scripts/26-verify-zeropad-overread.sh extable <kernel-devel...rpm>
#   ./scripts/26-verify-zeropad-overread.sh ptes   <vtop.txt> [fault-addr]
#   ./scripts/26-verify-zeropad-overread.sh all    <dumpdir> <kernel-devel rpm>
#
# `dumpdir` is a kdump directory from scripts/16-mshv-kdump.sh collect, i.e. one
# containing vmcore-dmesg.txt and (for `ptes`) vtop.txt.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

# Decode the Code: line from a panic. The byte inside <> is the faulting insn.
cmd_insn() {
  local dmesg="${1:?need vmcore-dmesg.txt}"
  check_command objdump || exit 1
  log_info "faulting instruction from ${dmesg}"

  grep -aE 'RIP: [0-9]{4}:csum_partial|Oops: general protection' "${dmesg}" | head -2

  python3 - "${dmesg}" <<'PY' > /tmp/zeropad.bin
import re, sys
text = open(sys.argv[1], errors="replace").read()
m = re.search(r"Code: ([0-9a-f <>]+)", text)
if not m:
    sys.exit("no Code: line in panic log")
code = m.group(1)
if "<" not in code:
    sys.exit("Code: line has no <> marker for the faulting instruction")
# Emit from 8 bytes before the faulting instruction so the shift setup is visible.
toks = code.replace("<", "").replace(">", "").split()
idx = len(code[:code.index("<")].split())
sys.stdout.buffer.write(bytes(int(b, 16) for b in toks[max(0, idx - 8):idx + 6]))
PY

  echo
  echo "disassembly (last 8 bytes before the fault, then the faulting insn):"
  objdump -D -b binary -m i386:x86-64 -M att /tmp/zeropad.bin |
    sed -n '/<.data>:/,$p' | tail -n +2 | sed 's/^/  /'
  echo
  cat <<'EOF'
EXPECTED, and what it means:
  neg %esi / shl $0x3,%esi / and $0x3f,%esi   ->  shift = (-len << 3) & 63
  mov (%rax),%rax                            ->  load_unaligned_zeropad(buff)

That is csum_partial's tail:
    if (len & 7) {
        unsigned int shift = (-len << 3) & 63;
        trail = (load_unaligned_zeropad(buff) << shift) >> shift;
EOF
}

# Show that the faulting load is annotated with an exception-table fixup.
cmd_extable() {
  local rpm="${1:?need a kernel-devel .rpm matching the crashing kernel}"
  check_command rpm2cpio || exit 1
  check_command cpio || exit 1
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  log_info "extracting asm/word-at-a-time.h from $(basename "${rpm}")"
  ( cd "${tmp}" && rpm2cpio "${rpm}" 2>/dev/null | cpio -id --quiet 2>/dev/null ) || true
  local hdr
  hdr="$(find "${tmp}" -path '*asm/word-at-a-time.h' | head -1)"
  [[ -n "${hdr}" ]] || { log_error "word-at-a-time.h not found in RPM"; return 1; }

  sed -n '/static inline unsigned long load_unaligned_zeropad/,/^}/p' "${hdr}" | sed 's/^/  /'
  echo
  if grep -q 'EX_TYPE_ZEROPAD' "${hdr}"; then
    log_ok "the faulting load carries _ASM_EXTABLE_TYPE(..., EX_TYPE_ZEROPAD)"
    echo "  => the kernel EXPECTS this load to fault off the end of a buffer."
    echo "  => on #PF, ex_handler_zeropad() substitutes zero-padded data and continues."
    echo "  => a #GP carries no fault address, so that fixup cannot apply -> panic."
  else
    log_warn "no EX_TYPE_ZEROPAD annotation found; this kernel differs"
  fi
}

# Show that Linux's own page tables still map the faulting page.
# vtop.txt contains MANY translations; the correct block must be selected by
# address or the decode silently describes an unrelated page.
cmd_ptes() {
  local vtop="${1:?need vtop.txt}" addr="${2:-}"
  log_info "page-table walk recorded at crash time (${vtop})"
  python3 - "${vtop}" "${addr}" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
want = (sys.argv[2] or "").lower().removeprefix("0x")

blocks = re.split(r"(?=Translating virtual address)", text)
blocks = [b for b in blocks if b.strip().startswith("Translating")]
if not blocks:
    sys.exit("no 'Translating virtual address' block found in vtop.txt")

chosen = None
if want:
    for b in blocks:
        m = re.search(r"Translating virtual address ([0-9a-f]+)", b)
        if m and m.group(1).lower() == want:
            chosen = b
            break
    if chosen is None:
        sys.exit(f"no translation block for address {want} "
                 f"(file has {len(blocks)} blocks)")
else:
    chosen = blocks[-1]
    print(f"  NOTE: no address given; using the LAST of {len(blocks)} blocks.\n"
          f"        Pass the fault address explicitly to be certain.\n")

for line in chosen.strip().splitlines()[:8]:
    print("  " + line.rstrip())

m = re.search(r"PMD\s*:\s*[0-9a-f]+\s*=>\s*([0-9a-f]+)", chosen)
if not m:
    sys.exit("\n  (no PMD entry in the selected block)")
e = int(m.group(1), 16)
print(f"\n  PMD entry 0x{e:x} decodes as:")
for bit, name in ((0, "Present"), (1, "Read/Write"), (2, "User"),
                  (5, "Accessed"), (6, "Dirty"), (7, "PS (huge page)")):
    print(f"    bit {bit:<2} {name:<15} = {(e >> bit) & 1}")
print(f"    bit 63 NX              = {(e >> 63) & 1}")
if (e & 1) and ((e >> 7) & 1):
    print("\n  => Present, and the walk TERMINATES at the PMD: a 2 MiB huge page.")
    print("  => Linux donated the physical page but never unmapped it, so the")
    print("     guest page walk SUCCEEDS and a #PF is architecturally impossible.")
    print("  => The revocation is at the GPA/SLAT level, below Linux's page tables,")
    print("     so the hypervisor injects #GP instead.")
elif e & 1:
    print("\n  => Present, but not a huge page at PMD level.")
else:
    print("\n  => NOT present -- this block is not the faulting mapping.")
PY
}

# Pull the faulting address out of a panic log, for use with `ptes`.
fault_addr_from_dmesg() {
  grep -aoE 'general protection fault, maybe for address 0x[0-9a-f]+' "$1" |
    head -1 | grep -oE '0x[0-9a-f]+'
}

case "${1:-}" in
  insn)    shift; cmd_insn "$@" ;;
  extable) shift; cmd_extable "$@" ;;
  ptes)    shift; cmd_ptes "$@" ;;
  all)
    shift
    dir="${1:?need dumpdir}"; rpm="${2:?need kernel-devel rpm}"
    cmd_insn "${dir}/vmcore-dmesg.txt"; echo
    cmd_extable "${rpm}"; echo
    if [[ -f "${dir}/vtop.txt" ]]; then
      # Select the translation block by the address from the panic itself.
      cmd_ptes "${dir}/vtop.txt" "$(fault_addr_from_dmesg "${dir}/vmcore-dmesg.txt")"
    fi
    ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
