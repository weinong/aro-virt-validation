#!/usr/bin/env python3
"""Summarise an MSHV deposit ledger: churn, granularity, and live page count.

Evidence for the "Why decade-old code only breaks here" section of
issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md -- specifically the
claims that deposits are overwhelmingly SINGLE pages (so they scatter through
the buddy allocator next to network buffers) and that CNV drives constant
partition churn.

Input is a trace.log produced by scripts/21-mshv-deposit-trace.sh (fetch it with
`21-mshv-deposit-trace.sh fetch`, or read it from the node under
/var/log/mshv-deposit/boot-<id>/trace.log).

Usage:
    scripts/25-analyze-deposit-ledger.py <trace.log>
    scripts/25-analyze-deposit-ledger.py --self-test

Read-only; parses text and prints. Never touches a cluster.
"""
import re
import sys
import collections

SELF = 18446744073709551615  # partition_id for the root/SELF partition

# The ftrace comm field may itself contain spaces (e.g. "CPU 0/MSHV-14292"), so
# the comm is matched separately and non-greedily rather than as \S+. Matching it
# as \S+ silently dropped ~a third of the records; the self-test covers this.
DEP_RE = re.compile(
    r"(?P<ts>\d+\.\d+):\s+"
    r"hv_deposit_pages_block: token=(?P<token>\d+) partition_id=(?P<pid>\d+).*?"
    r"base_pfn=0x(?P<base>[0-9a-f]+) count=(?P<count>\d+)")
COMM_RE = re.compile(r"^\s*(?P<comm>.+?)-\d+\s+\[\d+\]")
WD_RE = re.compile(
    r"(?P<ts>\d+\.\d+):\s+hv_withdraw_pages: partition_id=(?P<pid>\d+).*?pfns=\{(?P<pfns>[^}]*)\}")


def parse(text):
    deposits, withdraws = [], []
    for line in text.splitlines():
        m = DEP_RE.search(line)
        if m:
            c = COMM_RE.match(line)
            deposits.append(dict(comm=c.group("comm") if c else "?", ts=float(m.group("ts")),
                                 pid=int(m.group("pid")), base=int(m.group("base"), 16),
                                 count=int(m.group("count"))))
            continue
        m = WD_RE.search(line)
        if m:
            pfns = {int(p.strip(), 16) for p in m.group("pfns").split(",")
                    if p.strip().startswith("0x")}
            withdraws.append(dict(ts=float(m.group("ts")), pid=int(m.group("pid")), pfns=pfns))
    return deposits, withdraws


def report(deposits, withdraws, out=sys.stdout):
    def emit(s=""):
        print(s, file=out)

    if not deposits:
        emit("no deposit records found -- is this a scripts/21 ledger?")
        return

    pages = sum(d["count"] for d in deposits)
    singles = sum(1 for d in deposits if d["count"] == 1)
    withdrawn = set()
    for w in withdraws:
        withdrawn |= w["pfns"]

    live = 0
    for d in deposits:
        if d["pid"] == SELF:
            continue
        live += sum(1 for i in range(d["count"]) if d["base"] + i not in withdrawn)

    span = max(d["ts"] for d in deposits) - min(d["ts"] for d in deposits)
    emit(f"deposit blocks     : {len(deposits)}  ({pages} pages)")
    emit(f"single-page blocks : {singles}  ({100.0 * singles / len(deposits):.1f}% of blocks)")
    emit(f"withdraw events    : {len(withdraws)}  ({len(withdrawn)} distinct PFNs)")
    emit(f"live deposited     : {live} pages, guest partitions only "
         f"({live * 4096 / 2 ** 20:.1f} MiB)")
    if span > 0:
        emit(f"observed span      : {span:.0f}s  "
             f"({len(deposits) / span:.1f} blocks/s, {pages / span:.1f} pages/s)")

    sizes = collections.Counter(d["count"] for d in deposits)
    emit("\nblock size distribution (pages per block):")
    for size, n in sizes.most_common(6):
        emit(f"  count={size:<5} {n} blocks")

    comms = collections.Counter(d["comm"] for d in deposits)
    emit("\ndepositing processes:")
    for comm, n in comms.most_common(6):
        emit(f"  {comm:<20} {n}")

    guests = [d for d in deposits if d["pid"] != SELF]
    if guests:
        first, last = {}, {}
        for d in guests:
            first.setdefault(d["pid"], d["ts"])
            last[d["pid"]] = d["ts"]
        emit(f"\nguest partitions seen: {len(first)}  "
             "(lifecycle = first -> last deposit)")
        for pid in sorted(first, key=lambda p: first[p]):
            emit(f"  partition {pid:<6} {first[pid]:9.1f}s -> {last[pid]:9.1f}s "
                 f"({last[pid] - first[pid]:6.1f}s)")
        emit("\nShort lifetimes here indicate ephemeral partitions -- CNV creates and")
        emit("tears these down around VM lifecycle and node-labeller probing, which is")
        emit("what keeps scattering fresh single-page deposits through memory.")


FIXTURE = """\
 CPU 0/MSHV-14292   [078] .....   100.000000: hv_deposit_pages_block: token=1 partition_id=160 node=-1 base_pfn=0x1000 count=1 end_pfn=0x1000 va=0x0-0x0
 CPU 0/MSHV-14292   [078] .....   100.500000: hv_deposit_pages_block: token=2 partition_id=160 node=-1 base_pfn=0x2000 count=2 end_pfn=0x2001 va=0x0-0x0
     qemu-kvm-999   [001] .....   101.000000: hv_deposit_pages_block: token=3 partition_id=161 node=-1 base_pfn=0x3000 count=1 end_pfn=0x3000 va=0x0-0x0
        <...>-14226 [048] .....   102.000000: hv_withdraw_pages: partition_id=160 completed=1 status=0x0 pfns={0x1000}
"""


def self_test():
    deposits, withdraws = parse(FIXTURE)
    assert len(deposits) == 3, deposits
    # Regression: "CPU 0/MSHV" contains a space; matching comm as \S+ drops it.
    assert deposits[0]["comm"] == "CPU 0/MSHV", deposits[0]
    assert deposits[2]["comm"] == "qemu-kvm", deposits[2]
    assert sum(d["count"] for d in deposits) == 4
    assert len(withdraws) == 1 and withdraws[0]["pfns"] == {0x1000}
    # 4 deposited pages, one withdrawn -> 3 live
    withdrawn = withdraws[0]["pfns"]
    live = sum(1 for d in deposits for i in range(d["count"])
               if d["base"] + i not in withdrawn)
    assert live == 3, live
    singles = sum(1 for d in deposits if d["count"] == 1)
    assert singles == 2, singles
    pids = {d["pid"] for d in deposits}
    assert pids == {160, 161}, pids
    print("analyze-deposit-ledger self-test: OK")


def main():
    if "--self-test" in sys.argv:
        self_test()
        return
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    text = open(sys.argv[1], errors="replace").read()
    report(*parse(text))


if __name__ == "__main__":
    main()
