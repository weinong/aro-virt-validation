# 2026-09-09 — Instrumented kernel deployed; deposit tracing cannot test the hypothesis

> **ROOT CAUSE FOUND — see `issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md`.**
> The `#GP` is `csum_partial`'s 8-byte tail over-read crossing a 4 KiB page
> boundary into a page deposited to the hypervisor via `HVCALL_DEPOSIT_MEMORY`
> and still owned by it. Confirmed 3/3 against a complete-from-boot deposit
> ledger (p ~ 6e-13 by chance).


> **TL;DR:** The instrumented kernel (`...mgns1.el10`) is deployed on the `mshv`
> pool and its three `mshv_deposit` tracepoints work. The panic was reproduced
> with tracing live, and the faulting pages do **not** fall in any deposited
> range — **but that null result is not evidence.** The tracepoints cover
> `HVCALL_DEPOSIT_MEMORY`, which carries only the hypervisor's own bookkeeping
> pages: **29.5 MiB, 0.00385% of the node's 747 GiB.** Zero overlap is the
> expected outcome whether or not the hypothesis is true.
>
> To test "pages given to a VM are mishandled when returned to Linux" we need
> instrumentation on the **guest memory** path — `mshv_map_user_memory` /
> `mshv_region_pin` — not the deposit path.

## What was deployed

The RPMs from `kernel-rpms-6.12.0-211.49.1.1794_2798046552.mgns1.tar` were
layered onto the `mshv` pool with the existing out-of-cluster path
(`scripts/12c`), since on-cluster builds are blocked on ARO. Both pool members
now run the instrumented kernel:

| node | kernel | L1VH |
|---|---|---|
| `…-mshv-centralus1-66wzs` | `6.12.0-211.49.1.1794_2798046552.mgns1.el10` | yes |
| `…-nol1vh-centralus1-g8n4k` | `6.12.0-211.49.1.1794_2798046552.mgns1.el10` | no |

`kernel-rpms.lock.tsv` is repinned (note the release suffix changed from
`el10_2` to `mgns1.el10`) and `EXPECTED_KERNEL` updated to match.

The tarball also ships `kernel-devel`, `kernel-devel-matched`,
`kernel-modules-extra-matched`, `kernel-modules-internal` and
`kernel-modules-partner`; RHCOS does not install those, so they are deliberately
excluded from the carrier.

Worth noting from the RPM changelog, independent of the instrumentation — the
base build already carries several MSHV memory fixes, at least one of which is
in the area we are investigating:

```
mshv: Fix use-after-free in mshv_map_user_memory error path
mshv: Fix error handling in mshv_region_pin
mshv: Handle insufficient root memory hypervisor statuses
mshv: Introduce hv_deposit_memory helper functions
mshv: Fix infinite fault loop on permission-denied GPA intercepts
```

## Tracing works

`scripts/21-mshv-deposit-trace.sh` enables the tracepoints and snapshots the
ring buffer to disk. Confirmed live during a VM create/delete cycle:

```
hv_deposit_pages_block: token=1924 partition_id=… base_pfn=0x15b9ec count=1 va=0xff1100015b9ec000-…
hv_deposit_pages_done:  token=1924 … completed=1 status=0x100000000 ret=0
hv_withdraw_pages:      partition_id=132 completed=229 status=0xe50000001d pfns={0x92cd35a,…}
```

1,412 deposit blocks and 2 withdraw batches (229 and 149 PFNs) were captured
across one VM lifecycle.

**Durability matters here**: the ftrace ring buffer is memory-only and is lost in
the panic, so a snapshotter `fsync()`s the buffer to disk every few seconds.
`ftrace_dump_on_oops` was deliberately not used — dumping a large buffer through
printk at panic time risks overflowing the log buffer and stalling the panic path
before kdump runs.

## Reproduction and correlation

Panic reproduced at t=151 s with tracing live. Trace covers uptime 684.6–856.0 s;
the panic is at 905.8 s, so both are from the same boot.

| fault address | fault PFN | in a deposited range? |
|---|---|---|
| `0xff1100314634fffc` | `0x314634f` | no |
| `0xff110031b032fffc` | `0x31b032f` | no |
| `0xff1100311299fffc` | `0x311299f` | no |
| `0xff1100316b6ffffc` | `0x316b6ff` | no |
| `0xff11003166d0fffc` | `0x3166d0f` | no |

## Why the null result proves nothing

```
distinct pages traced : 7546  (29.5 MiB)
coverage of 747 GiB   : 0.00385%
faults examined       : 5
overlap expected by chance: 0.000193 pages
```

We would expect **zero** overlap by chance. The measurement has essentially no
statistical power, and `scripts/22-correlate-fault-deposits.py` now says so
explicitly rather than reporting a misleading "not in any deposited range".

The reason is structural: `HVCALL_DEPOSIT_MEMORY` is how the root partition gives
the hypervisor pages for **its own bookkeeping** (partition state, page tables).
A 2 GiB guest needs ~524,288 pages of RAM; the entire deposit trace for that VM's
lifecycle was 7,546 pages. **Guest RAM never goes through this path.** It is
pinned and mapped into the partition by `mshv_map_user_memory` /
`mshv_region_pin`, which the current patch does not instrument.

## What would actually test the hypothesis

Instrument the guest-memory path and record, per region:

- the PFN ranges pinned and mapped into a partition (`mshv_region_pin`,
  `mshv_map_user_memory`), and
- when they are unmapped/unpinned and released back to the page allocator on
  teardown, including the error paths — the changelog above shows this area has
  had a use-after-free.

With those ranges recorded, the existing correlator works unchanged: it already
takes deposited ranges plus withdrawn PFNs and checks the faulting page and the
**next** page (the one the over-read crosses into) against them.

A cheaper interim check, if patching again is expensive: log the guest memory
region ranges at VM start/stop from userspace (virt-launcher / `/dev/mshv`
ioctl arguments) and correlate against those instead.

## Tooling added

- `scripts/21-mshv-deposit-trace.sh` — enable/snapshot/fetch/stop the
  tracepoints, with the snapshot `fsync`ed so it survives the panic.
- `scripts/22-correlate-fault-deposits.py` — offline correlation of fault
  addresses against deposited/withdrawn ranges, with a built-in `--self-test`
  and an explicit coverage verdict so a null result cannot be over-read.

Two bugs worth recording, both the same class as earlier ones in this
investigation:

- A `nohup`'d background process started inside `oc debug` is killed with the
  pod's cgroup when the session ends, so the first snapshotter only ever wrote
  its initial sample. It now runs as a transient `systemd-run` unit on the host.
- `pgrep -f`/`pkill -f` match the pattern against **this script's own command
  line**, so they reported phantom processes and, earlier, killed the run itself.
  Process control is now by recorded PID or systemd unit.
