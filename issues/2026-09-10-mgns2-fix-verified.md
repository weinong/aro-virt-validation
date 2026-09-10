# 2026-09-10 — Candidate fix verified: `mgns2` survives the reproducer

**Status: the reproducer no longer reproduces.** The `mgns2` kernel removes
deposited pages from the kernel direct map, and the node absorbed **18.3 TiB**
of the exact load that panicked `mgns1` in **~4 seconds**.

Root cause this validates:
[`issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md`](2026-09-09d-ROOT-CAUSE-deposited-page-overread.md).

## What the fix does

`drivers/hv/hv_proc.c` — `hv_call_deposit_pages()` now calls
`set_direct_map_valid_noflush(..., false)` plus `flush_tlb_kernel_range()` on the
pages **before** handing them to the hypervisor, and restores the mapping on both
the error path and in `hv_restore_withdrawn_pages()` before pages go back to the
page allocator.

The patch's own comment states the root cause in the same terms we derived
independently:

> Once a page has been deposited the hypervisor owns it and revokes root
> partition access to it in the SLAT. Leaving such a page present in the direct
> map breaks the kernel's assumption that every direct map address is readable,
> which speculative-read-past-the-end helpers such as `load_unaligned_zeropad()`
> rely on. On x86 the resulting access raises `#GP` rather than `#PF`, so the
> exception table cannot recover and the machine panics.

This is fix option 1 from the root-cause writeup: make the fault a recoverable
`#PF` instead of an unrecoverable `#GP`, so the existing `EX_TYPE_ZEROPAD` fixup
does its job. It fixes the whole class, not just `csum_partial` — the
`strscpy()` and dcache users of the same idiom are covered too.

## Deployment

```sh
tar xf kernel-rpms-...mgns2.tar -C ~/kernel-rpms-mgns2      # 10 RPMs; 5 are used
KERNEL_RPM_DIR=~/kernel-rpms-mgns2/staged \
  bash scripts/12c-rhcos-kernel-layer-out-of-cluster.sh apply
bash scripts/12b-verify-kernel-layer.sh
```

`images/rhcos-kernel-layer/kernel-rpms.lock.tsv` and `l1vh.env` are pinned to
`mgns2.el10`. Both mshv-pool nodes (the L1VH node and the non-L1VH control) rolled
over cleanly.

## Mechanism check — the direct map really does change now

Deposits on `mgns1` left the direct map untouched: the page-table walk captured at
crash time showed the faulting page still **Present, RW, 2 MiB huge**. On `mgns2`,
deposits split and unmap it. Measured causally across a VM restart on one node:

| | |
|---|---|
| deposits made | **1,398** |
| `DirectMap4k` change | **+200,704 kB** |

Cross-node at rest, both on `mgns2`:

| node | deposits | `DirectMap4k` |
|---|---|---|
| L1VH (`66wzs`) | 3,330 | **976,000 kB** |
| non-L1VH control (`g8n4k`) | 0 | 476,288 kB |

A kernel that leaves deposited pages mapped shows no such 4 KiB growth. This is
the fix working, not a side effect.

## The reproducer

Identical parameters to the arm that panicked `mgns1` in ~4 s (veth pair,
`tx-checksum` off, 64 streams), with a VM running so live deposited pages exist:

| kernel | load | data pushed | result |
|---|---|---|---|
| `mgns1` | 64 streams, offload off | a few GiB | **panic in ~4 s** |
| `mgns2` | 64 streams, offload off, 420 s | 3,219 GiB | **no crash** |
| `mgns2` | 64 streams, offload off, 1,800 s | **15,048 GiB** | **no crash** |

Verified by boot ID rather than by absence of a crash marker — boot
`6fd4f09b` spans both runs unchanged. Zero `general protection` / `csum_partial` /
`Kernel panic` lines in the journal for the whole boot, and no new `/var/crash`
directories.

### The vulnerable path was still being exercised

"No crash" would be worthless if the load had stopped hitting `csum_partial`.
It had not — the software checksum rate on `mgns2` is indistinguishable from
`mgns1`:

| | `skb_checksum_help` | `__skb_checksum` |
|---|---|---|
| `mgns1`, 13.1 MB over veth | 3,115 | 23,461 |
| `mgns2`, 13.1 MB over veth | 3,100 | **23,466** |

And live deposited pages were present throughout (11,445 at the time of the
soak). Both preconditions held; only the outcome changed.

## Caveats and open questions

* **Absence of a crash is weaker evidence than a crash.** The strength here is
  the ratio: `mgns1` died in ~4 s under this load, `mgns2` absorbed ~450× the
  time and ~18.3 TiB. It is not proof that the fault is impossible, only that the
  rate has collapsed below anything we can measure.
* **`scripts/24` still reports some live deposited pages as readable** (8 of 20).
  Expected to be near zero if every deposited page were unmapped. Two plausible
  explanations, neither yet confirmed: the ledger over-counts "live" pages
  because `hv_withdraw_pages` PFN lists may be truncated by ftrace line limits,
  or deposit blocks whose hypercall failed (and were therefore restored to the
  direct map) are still counted. The probe does not currently consult
  `hv_deposit_pages_done`'s return status. **This needs resolving** — until then
  that number should not be read as "the fix leaves pages mapped".
* **The `/proc/kcore` probe cannot distinguish a faulted read from genuinely
  zero content**, so its all-zero rate remains an upper bound.
* **arm64 is not covered.** Per the patch comment,
  `set_direct_map_valid_noflush()` is a no-op there unless `can_set_direct_map()`
  holds, so the direct map may keep deposited pages mapped. What an SLAT denial
  delivers on arm64 is unresolved.
* **No long-duration production-like soak yet.** 30 minutes at synthetic load is
  ~450× the `mgns1` time-to-crash, but the spontaneous (Thanos) crashes on
  `mgns1` had a heavy-tailed distribution measured in tens of minutes to hours.
  A multi-hour idle-ish soak would test the low-rate path the synthetic load
  does not.

## Cluster state

Interventions from `issues/2026-09-09b` are still in place and must be reverted
before judging normal ARO behaviour: MachineHealthCheck disabled, kdump enabled,
the `99-mshv-deposit-trace` MachineConfig, and the non-L1VH worker MachineSet
scaled to 1. The mshv pool now also carries `99-mshv-kernel-osimage` pointing at
the locally built `mgns2` layer.
