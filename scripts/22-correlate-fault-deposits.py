#!/usr/bin/env python3
"""Correlate a csum_partial #GP fault address with MSHV page deposits.

The question: was the page the faulting read crossed into deposited to the
hypervisor for a VM, and mishandled when returned to Linux on teardown?

Inputs (all on-disk; this never touches the cluster):
  trace.log        snapshots of the mshv_deposit tracepoints, captured by
                   scripts/21-mshv-deposit-trace.sh
  vmcore-dmesg.txt panic log captured by kdump (scripts/16 ... collect)

The tracepoints give, per deposit block, base_pfn/count and base_va, and per
withdraw batch the PFNs returned to the page allocator. A fault is interesting
if its page is inside a range that was deposited, and especially if that range
was subsequently WITHDRAWN -- i.e. handed back to Linux while something still
went wrong.

Usage:
  python3 scripts/22-correlate-fault-deposits.py TRACE.log DMESG [DMESG...]
  python3 scripts/22-correlate-fault-deposits.py --self-test
"""
import re
import sys

PAGE_SHIFT = 12
# Direct-map base with 5-level paging and nokaslr. base_va in the tracepoint
# makes this unnecessary for deposits, but the oops only gives a virtual
# address, so we still need it to get the faulting PFN.
PAGE_OFFSET_5L = 0xFF11000000000000
# Used only to qualify how meaningful a null result is.
RAM_GIB = 747.0

BLOCK_RE = re.compile(
    r"hv_deposit_pages_block:.*?token=(?P<token>\d+).*?partition_id=(?P<pid>\d+).*?"
    r"base_pfn=(?P<base>0x[0-9a-f]+).*?count=(?P<count>\d+)")
DONE_RE = re.compile(
    r"hv_deposit_pages_done:.*?token=(?P<token>\d+).*?completed=(?P<completed>\d+).*?"
    r"status=(?P<status>0x[0-9a-f]+).*?ret=(?P<ret>-?\d+)")
WITHDRAW_RE = re.compile(
    r"hv_withdraw_pages:.*?partition_id=(?P<pid>\d+).*?completed=(?P<completed>\d+).*?"
    r"status=(?P<status>0x[0-9a-f]+).*?pfns=(?P<pfns>.*)$")
FAULT_RE = re.compile(
    r"general protection fault, maybe for address (0x[0-9a-f]+)")


def parse_trace(text):
    """Returns (blocks, done_by_token, withdrawn_pfns)."""
    blocks, done, withdrawn = [], {}, set()
    for line in text.splitlines():
        m = BLOCK_RE.search(line)
        if m:
            blocks.append({
                "token": int(m.group("token")),
                "pid": int(m.group("pid")),
                "base_pfn": int(m.group("base"), 16),
                "count": int(m.group("count")),
            })
            continue
        m = DONE_RE.search(line)
        if m:
            done[int(m.group("token"))] = {
                "completed": int(m.group("completed")),
                "status": int(m.group("status"), 16),
                "ret": int(m.group("ret")),
            }
            continue
        m = WITHDRAW_RE.search(line)
        if m:
            for tok in re.findall(r"0x[0-9a-f]+|\b\d+\b", m.group("pfns")):
                try:
                    withdrawn.add(int(tok, 16) if tok.startswith("0x") else int(tok))
                except ValueError:
                    continue
    return blocks, done, withdrawn


def parse_faults(text):
    return [int(a, 16) for a in FAULT_RE.findall(text)]


def classify(fault_va, blocks, done, withdrawn):
    """Where does this faulting address sit relative to deposited memory?"""
    pfn = (fault_va - PAGE_OFFSET_5L) >> PAGE_SHIFT
    # The read straddles a 4 KiB boundary, so the NEXT page is the one it
    # crossed into and the one that actually matters.
    next_pfn = pfn + 1
    hits = []
    for b in blocks:
        lo, hi = b["base_pfn"], b["base_pfn"] + b["count"] - 1
        for label, p in (("fault", pfn), ("next", next_pfn)):
            if lo <= p <= hi:
                d = done.get(b["token"], {})
                hits.append({
                    "which": label, "pfn": p, "token": b["token"], "pid": b["pid"],
                    "range": (lo, hi), "count": b["count"],
                    "ret": d.get("ret"), "status": d.get("status"),
                    "completed": d.get("completed"),
                    "withdrawn": p in withdrawn,
                })
    return pfn, next_pfn, hits


def main():
    if "--self-test" in sys.argv:
        return self_test()
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    trace_path, dmesg_paths = sys.argv[1], sys.argv[2:]

    blocks, done, withdrawn = parse_trace(open(trace_path, errors="replace").read())
    dep_pages = sum(b["count"] for b in blocks)
    print(f"deposit blocks : {len(blocks)}  ({dep_pages} pages)")
    print(f"deposit results: {len(done)}  failures: {sum(1 for d in done.values() if d['ret'])}")
    print(f"withdrawn PFNs : {len(withdrawn)}")
    if not blocks:
        print("\n!! no deposit events in the trace: either no VM activity occurred,")
        print("   or tracing was not running. Correlation below is meaningless.")

    # A null result is only meaningful if the trace could plausibly have covered
    # the faulting pages. HVCALL_DEPOSIT_MEMORY carries the hypervisor's own
    # bookkeeping pages, not guest RAM, so coverage is normally minuscule and
    # "no overlap" is the expected outcome either way.
    covered = set()
    for b in blocks:
        covered.update(range(b["base_pfn"], b["base_pfn"] + b["count"]))
    ram_pages = int(RAM_GIB * (2 ** 30) // 4096)
    frac = len(covered) / ram_pages if ram_pages else 0
    print(f"distinct pages traced: {len(covered)} ({len(covered) * 4096 / 2**20:.1f} MiB)")
    print(f"coverage of {RAM_GIB:g} GiB RAM: {100 * frac:.5f}%")

    total = matched = 0
    for path in dmesg_paths:
        faults = parse_faults(open(path, errors="replace").read())
        for fv in faults:
            total += 1
            pfn, next_pfn, hits = classify(fv, blocks, done, withdrawn)
            tag = "IN DEPOSITED RANGE" if hits else "not in any deposited range"
            print(f"\nfault {hex(fv)}  pfn={hex(pfn)} next={hex(next_pfn)}  -> {tag}")
            print(f"  source: {path}")
            for h in hits:
                matched += 1
                print(f"    {h['which']}_pfn={hex(h['pfn'])} in block "
                      f"[{hex(h['range'][0])}-{hex(h['range'][1])}] count={h['count']} "
                      f"token={h['token']} partition={h['pid']} "
                      f"deposit_ret={h['ret']} status={h['status']} "
                      f"withdrawn={h['withdrawn']}")

    print(f"\nfaults examined: {total}   inside a deposited range: {matched}")
    expected = total * frac
    print(f"overlap expected by chance: {expected:.6f} pages")
    if total and not matched:
        if expected < 0.05:
            print(f"\n!! VERDICT: this null result is NOT evidence against the hypothesis.")
            print(f"   With {100*frac:.5f}% coverage, zero overlap is the expected outcome")
            print(f"   whether or not the hypothesis is true. To test it you need")
            print(f"   instrumentation on the GUEST MEMORY path (mshv_map_user_memory /")
            print(f"   mshv_region_pin), not HVCALL_DEPOSIT_MEMORY, which only carries")
            print(f"   the hypervisor's own bookkeeping pages.")
        else:
            print("\nNo overlap, and coverage was high enough that some was expected.")
            print("That is weak evidence against the deposit hypothesis.")
        print("\nAlso confirm trace.log and the dmesg are from the SAME boot:")
        print("compare the trace's kernel timestamps with the panic uptime.")


def self_test():
    trace = """
 kworker/0:1-123 [000] .... 100.0: hv_deposit_pages_block: token=7 partition_id=5 node=0 base_pfn=0x1000 count=4 end_pfn=0x1003 va=0xff11000001000000-0xff11000001003fff
 kworker/0:1-123 [000] .... 100.1: hv_deposit_pages_done: token=7 partition_id=5 requested=4 page_count=1 completed=1 status=0x0 ret=0
 kworker/0:1-123 [000] .... 200.0: hv_withdraw_pages: partition_id=5 completed=2 status=0x0 pfns=0x1000,0x1001
"""
    blocks, done, withdrawn = parse_trace(trace)
    assert len(blocks) == 1 and blocks[0]["base_pfn"] == 0x1000 and blocks[0]["count"] == 4, blocks
    assert done[7]["ret"] == 0 and done[7]["completed"] == 1, done
    assert withdrawn == {0x1000, 0x1001}, withdrawn

    # A fault whose NEXT page (the one the over-read crosses into) is deposited.
    va = PAGE_OFFSET_5L + (0x1002 << PAGE_SHIFT) + 0xFFC
    pfn, next_pfn, hits = classify(va, blocks, done, withdrawn)
    assert pfn == 0x1002 and next_pfn == 0x1003, (pfn, next_pfn)
    assert {h["which"] for h in hits} == {"fault", "next"}, hits
    assert all(not h["withdrawn"] for h in hits), hits

    # A fault on a page that was deposited AND later withdrawn.
    va2 = PAGE_OFFSET_5L + (0x1000 << PAGE_SHIFT) + 0xFF8
    _, _, hits2 = classify(va2, blocks, done, withdrawn)
    assert any(h["withdrawn"] for h in hits2), hits2

    # A fault far away must not match.
    va3 = PAGE_OFFSET_5L + (0x99999 << PAGE_SHIFT)
    _, _, hits3 = classify(va3, blocks, done, withdrawn)
    assert hits3 == [], hits3

    assert parse_faults("Oops: general protection fault, maybe for address 0xff1100025d6cffff: 0000") \
        == [0xff1100025d6cffff]
    print("correlate-fault-deposits self-test: OK")


if __name__ == "__main__":
    main()
