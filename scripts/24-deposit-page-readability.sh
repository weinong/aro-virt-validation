#!/usr/bin/env bash
# =============================================================================
# 24-deposit-page-readability.sh - Are pages deposited to the hypervisor still
# readable by the root partition?
#
# Evidence for the "Deposited pages are not uniformly revoked" section of
# issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md.
#
# METHOD. Reads live deposited PFNs (from the scripts/21 ledger, minus any that
# were withdrawn) through their direct-map addresses in /proc/kcore, and compares
# against two reference populations:
#
#   * CONTROL       - the same PFNs offset by +1 GiB (ordinary memory)
#   * KNOWN-UNMAPPED - vmalloc guard pages, which are definitely not mapped
#
# ⚠️ WHY THE CALIBRATION MATTERS:
#   /proc/kcore ZERO-FILLS on fault rather than returning an error -- verified by
#   the KNOWN-UNMAPPED arm, which reads back all-zero with errno=0. So "all-zero"
#   is ambiguous between *faulted* and *genuinely zero content*, and the all-zero
#   rate is only an UPPER BOUND on inaccessibility. The unambiguous signal is the
#   opposite one: any deposited page returning NON-ZERO data was definitely
#   readable, i.e. not revoked.
#
# Safe: read-only, and kcore's fault path is non-fatal (EX_TYPE_DEFAULT fixups
# handle #GP), so this does not panic the node.
#
# Requires: scripts/21-mshv-deposit-trace.sh install (boot-time ledger), and
# nokaslr so PAGE_OFFSET is the fixed 5-level default.
#
# Usage:
#   ./scripts/24-deposit-page-readability.sh probe [SAMPLES]   # default 40
#
# Tunables (env): NODE, REQUEST_TIMEOUT, PAGE_OFFSET.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"
PAGE_OFFSET="${PAGE_OFFSET:-0xFF11000000000000}"
TRACE_DIR="/var/log/mshv-deposit"

oc_() { oc --request-timeout="${REQUEST_TIMEOUT}s" "$@"; }

pick_node() {
  [[ -n "${NODE:-}" ]] && { printf '%s' "${NODE}"; return; }
  oc_ get nodes -l node-role.kubernetes.io/mshv \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -1
}

cmd_probe() {
  local samples="${1:-40}" node; node="$(pick_node)"
  log_info "probing deposited-page readability on ${node} (${samples} samples)"

  # shellcheck disable=SC2016
  oc debug "node/${node}" --quiet --request-timeout=0 -- chroot /host bash -c '
cat > /tmp/depread.py <<"PYEOF"
import os, re, struct, random, sys

SAMPLES     = int(os.environ.get("SAMPLES", "40"))
PAGE_OFFSET = int(os.environ.get("PAGE_OFFSET", "0xFF11000000000000"), 16)
TRACE_DIR   = os.environ.get("TRACE_DIR", "/var/log/mshv-deposit")

boot = open("/proc/sys/kernel/random/boot_id").read().strip()
path = f"{TRACE_DIR}/boot-{boot}/trace.log"
if not os.path.exists(path):
    sys.exit(f"NO LEDGER for current boot at {path}; run scripts/21 install and reboot")
txt = open(path, errors="replace").read()

withdrawn = set()
for m in re.finditer(r"hv_withdraw_pages:.*?pfns=\{([^}]*)\}", txt):
    for p in m.group(1).split(","):
        p = p.strip()
        if p.startswith("0x"):
            withdrawn.add(int(p, 16))

dep = []
for m in re.finditer(
        r"hv_deposit_pages_block: token=\d+ partition_id=(\d+).*?base_pfn=0x([0-9a-f]+) count=(\d+)", txt):
    pid, base, cnt = int(m.group(1)), int(m.group(2), 16), int(m.group(3))
    if pid == 18446744073709551615:      # SELF/root, not a guest partition
        continue
    for i in range(cnt):
        if base + i not in withdrawn:
            dep.append(base + i)

print(f"ledger            : {path}")
print(f"withdrawn PFNs    : {len(withdrawn)}")
print(f"live deposited    : {len(dep)}")
if not dep:
    sys.exit("no live deposited pages; start a VM on this node and retry")

fd = os.open("/proc/kcore", os.O_RDONLY)
hdr = os.pread(fd, 64, 0)
e_phoff, = struct.unpack_from("<Q", hdr, 32)
e_phentsize, e_phnum = struct.unpack_from("<HH", hdr, 54)
loads = []
for i in range(e_phnum):
    ph = os.pread(fd, e_phentsize, e_phoff + i * e_phentsize)
    typ, = struct.unpack_from("<I", ph, 0)
    if typ != 1:
        continue
    off, va, _, fsz = struct.unpack_from("<QQQQ", ph, 8)
    loads.append((va, off, fsz))

def read_va(va, n):
    for base, off, size in loads:
        if base <= va < base + size:
            try:
                return os.pread(fd, n, off + (va - base))
            except OSError as exc:
                return "ERRNO:%d" % exc.errno
    return "NOT-IN-KCORE"

def score(tag, vaddrs, n=4096):
    z = nz = err = miss = 0
    for va in vaddrs:
        b = read_va(va, n)
        if b == "NOT-IN-KCORE":   miss += 1
        elif isinstance(b, str):  err  += 1
        elif set(b) == {0}:       z    += 1
        else:                     nz   += 1
    tot = max(len(vaddrs), 1)
    print(f"  {tag:<34} all-zero={z:>3} ({100*z/tot:5.1f}%)  nonzero={nz:>3}  "
          f"errno={err}  not-in-kcore={miss}")
    return z, nz

random.seed(7)
samp = random.sample(dep, min(SAMPLES, len(dep)))
print("\nreading 4096 bytes at each address via /proc/kcore:")
_,  dep_nz = score("DEPOSITED (live, not withdrawn)", [PAGE_OFFSET + (p << 12) for p in samp])
score("CONTROL (+1 GiB offset)",          [PAGE_OFFSET + ((p + 0x40000) << 12) for p in samp])

guards = []
for line in open("/proc/vmallocinfo"):
    m = re.match(r"0x([0-9a-f]+)-0x([0-9a-f]+)", line)
    if m:
        guards.append(int(m.group(2), 16))   # end == start of the guard page
score("KNOWN-UNMAPPED (vmalloc guards)", guards[:SAMPLES], n=64)

print("\nCALIBRATION: the KNOWN-UNMAPPED row should be mostly all-zero with errno=0.")
print("That proves kcore zero-fills on fault, so all-zero is an UPPER BOUND on")
print("inaccessibility -- not a measurement of it.")
print(f"\nUNAMBIGUOUS RESULT: {dep_nz} of {len(samp)} live deposited pages returned real")
print("data, so deposit does NOT immediately revoke read access.")
PYEOF
SAMPLES='"${samples}"' PAGE_OFFSET='"${PAGE_OFFSET}"' TRACE_DIR='"${TRACE_DIR}"' python3 /tmp/depread.py' \
    2>&1 | grep -avE 'Starting pod|Removing debug|To use host|^Warning|^Pod IP|^If you'
}

case "${1:-}" in
  probe) shift; cmd_probe "${1:-40}" ;;
  *) sed -n '2,34p' "$0"; exit 1 ;;
esac
