# 2026-09-09 — ROOT CAUSE: csum_partial over-reads into a page deposited to the hypervisor

> **FIX VERIFIED 2026-09-10.** The `mgns2` kernel implements option 1 below
> (deposited pages are removed from the kernel direct map, so the over-read takes
> a recoverable `#PF` instead of an unrecoverable `#GP`). The reproducer that
> panicked this node in ~4 seconds now absorbs 18.3 TiB without a fault.
> See [`2026-09-10-mgns2-fix-verified.md`](2026-09-10-mgns2-fix-verified.md).

> **The `#GP` is a benign 8-byte over-read crossing a 4 KiB page boundary into a
> page that Linux has deposited to the Hyper-V hypervisor via
> `HVCALL_DEPOSIT_MEMORY` and which the hypervisor still owns.**
>
> Three faults, across two boots, were correlated against a complete-from-boot
> deposit ledger. In **3 of 3** cases the page the over-read crossed into was a
> deposited page that had **not** been withdrawn. With deposits covering 0.0085%
> of RAM, the odds of that happening by chance are about **1 in 1.7 × 10¹²**.

## The mechanism

1. `csum_partial`'s tail path calls `load_unaligned_zeropad()`, which deliberately
   reads a full 8 bytes and masks off the excess — an over-read of up to 7 bytes
   past the buffer. Byte-matched in the panic `Code:`:

   ```
   f7 de           neg    %esi          \
   c1 e6 03        shl    $0x3,%esi      |  shift = (-len << 3) & 63
   83 e6 3f        and    $0x3f,%esi    /
   48 8b 00        mov    (%rax),%rax   <- FAULTS: load_unaligned_zeropad()
   ```

2. The buffer ends within 8 bytes of a 4 KiB page boundary, so the read crosses
   into the **next** page. (This is why 217/217 faults sit at page offsets
   `0xff9`–`0xfff`.)
3. On an L1VH root partition, that next page may be one Linux allocated and
   handed to the hypervisor with `HVCALL_DEPOSIT_MEMORY`. The hypervisor owns it
   and the root partition can no longer read it.
4. The access raises **`#GP`** in interrupt context → `Kernel panic - not
   syncing: Fatal exception in interrupt` → reboot.

### The over-read is *supposed* to be survivable

This is the crux, and it is why "a 10-year-old over-read" is not itself the bug.
`load_unaligned_zeropad()` is annotated with an exception-table fixup:

```c
asm volatile(
    "1:	mov %[mem], %[ret]\n"
    "2:\n"
    _ASM_EXTABLE_TYPE(1b, 2b, EX_TYPE_ZEROPAD)     /* type 20 */
```

`EX_TYPE_ZEROPAD` = "longword load with zeropad on fault". The kernel *expects*
this load to fault off the end of a buffer, and on a normal host it does: the
read lands in an unmapped page, takes a **`#PF`**, `ex_handler_zeropad()`
substitutes zero-padded data, and execution continues. Nothing crashes. That is
why the over-read has been safe for a decade.

It fails here only because the hypervisor delivers **`#GP`**, not `#PF`, and the
zeropad fixup does not rescue a `#GP` — so an over-read the kernel is designed
to absorb becomes fatal.

> Verified: the faulting instruction is the zeropad load, it carries an
> `EX_TYPE_ZEROPAD` entry, and it panicked regardless. Inferred (not verified on
> this kernel): the fixup is skipped because `exc_general_protection()` passes
> `fault_addr = 0`, so `ex_handler_zeropad()`'s check that the fault address is
> the next word cannot succeed. Confirming this needs `arch/x86/mm/extable.c`,
> which is not in `kernel-devel`.

## Why `#GP` and not `#PF`?

This is the question that makes the fixup fail, so it is worth answering
precisely. The page-table walk captured at crash time, for the exact faulting
address, settles it:

```
Translating virtual address ff11003119097ffa to physical address.
  PGD : 6624888 => 7c01067        PUD : 7c02620 => 107119063
  P4D : 7c01000 => 7c02067        PMD : 107119640 => 80000031190001e3
VIRTUAL           PHYSICAL
ff11003119097ffa  3119097ffa
```

`PMD = 0x80000031190001e3`: bit 0 **Present**, bit 1 **RW**, bit 7 **PS**, bit 63
NX. The walk *terminates at the PMD* — this is a **2 MiB huge page** in the
direct map, and it is present and writable.

1. **Linux's own paging still maps the page, so the CPU cannot raise `#PF`.**
   Linux donated the *physical* page to the hypervisor; it never unmapped it from
   the direct map. The guest page walk succeeds. A `#PF` is architecturally
   impossible here — there is nothing wrong with the guest's page tables.
2. **The revocation lives one level below Linux.** Ownership was transferred at
   the GPA/SLAT level. A second-level violation is reported by the CPU *to the
   hypervisor*, not to the guest — the guest never sees an EPT/NPT fault.
3. **So the hypervisor must synthesise something.** It cannot deliver a coherent
   `#PF` (that would contradict the guest's own present PTE and require a CR2
   the guest could act on), so Hyper-V injects a **`#GP(0)`**. The panic line
   corroborates this: error code `0000`, meaning no segment selector is
   involved, and the kernel prints "**maybe** for address", which it only does
   when it has to *decode the instruction* to guess the address — i.e. the trap
   delivered no fault address at all.
4. **That is exactly what defeats the fixup.** `ex_handler_zeropad()` needs the
   faulting address to confirm the access was the benign next-word case. `#GP`
   supplies none, so the fixup cannot apply and the exception goes unhandled —
   in IRQ context, that is an instant panic.

In one line: **the page is revoked at a level Linux's page tables cannot
express, so the failure arrives as the architecture's generic "illegal
operation" fault rather than the page fault the kernel is prepared to absorb.**

The 2 MiB huge page also constrains the fix. A single deposited 4 KiB page sits
inside a 2 MiB direct-map mapping shared with 511 pages in ordinary use, so
Linux cannot simply unmap the donated page without splitting the huge page.

### Deposited pages are not uniformly revoked

Reading live deposited pages through `/proc/kcore` (which zero-fills on fault —
calibrated against known-unmapped vmalloc guard pages, which return all-zero
with `errno=0`, never an error):

| population | reads all-zero |
|---|---|
| known-unmapped vmalloc guard pages | 87% |
| **live deposited, not withdrawn** | **65%** |
| control PFNs (+1 GiB offset) | 17.5% |

14 of 40 live deposited pages returned real non-zero data, so deposit does
**not** immediately make a page inaccessible — consistent with the hypervisor
revoking only the pages it actually commits to partition state, while the rest
sit in the pool still readable. This matches the observed low spontaneous fault
rate: only a subset of deposited pages are live hazards at any moment.

> Caveat: `kcore`'s zero-fill makes "all-zero" ambiguous between *faulted* and
> *genuinely zero*, so the 65% is an upper bound on inaccessibility, not a
> measurement of it. The unambiguous half of the result is the 14 readable pages.

## The evidence

Deposit tracepoints (instrumented `mgns1` kernel) streamed to disk from **boot**,
so the ledger has no gap and lost no events. Correlated against kdump-captured
panic logs, with boot identity verified by wall-clock (`boot-start delta 6s`):

```
LEDGER COMPLETE FROM BOOT: YES        deposit blocks: 6073 (16548 pages)
same boot: YES (boot-start delta 6s)  withdrawn PFNs: 1431

fault 0xff1100941a3dfffc  pfn=0x941a3df  next=0x941a3e0  -> IN DEPOSITED RANGE
    next_pfn=0x941a3e0 block [0x941a3e0-0x941a3e0] token=5346 partition=160
    deposit_ret=0  withdrawn=False

fault 0xff110093911efffc  pfn=0x93911ef  next=0x93911f0  -> IN DEPOSITED RANGE
    next_pfn=0x93911f0 block [0x93911f0-0x93911f0] token=5975 partition=160
    deposit_ret=0  withdrawn=False
```

A third fault from the preceding boot correlated the same way
(`next_pfn=0x1df4d8`, `token=1895`, `withdrawn=False`).

A **fourth** fault (boot `cd8ceab0`, kdump `2026-09-09-21:46:03`) correlated the
same way — and this one was **not** from the stress harness. It was ordinary
cluster traffic:

```
Comm: thanos          RIP: csum_partial+0xe5/0x110
Oops: general protection fault, maybe for address 0xff11003119097ffa
Call Trace: __skb_checksum+0x184/0x330 -> csum_partial+0xe5

fault 0xff11003119097ffa  pfn=0x3119097  next=0x3119098 -> IN DEPOSITED RANGE
    next_pfn=0x3119098 block [0x3119098-0x3119098] count=1 token=1189
    partition=177  deposit_ret=0  withdrawn=False
```

That boot's deposits covered only **0.00241%** of RAM, so this single match had
roughly 1-in-41,000 odds of being coincidental. It also demonstrates the defect
is not an artifact of the reproducer: a stock OpenShift monitoring pod
(Thanos) sending TCP over the pod network panicked the node.

In every case the *faulting* page is ordinary kernel memory holding the network
buffer; it is the **next** page — the one the over-read spills into — that is
hypervisor-owned. `withdrawn=False` means the hypervisor had not returned it.

### Why this is not chance

| | |
|---|---|
| pages deposited this boot | 16,548 |
| RAM pages | 195,821,568 |
| P(one fault's next page is deposited) | 8.45 × 10⁻⁵ |
| **P(3 of 3 by chance)** | **6.0 × 10⁻¹³** |

Including the fourth fault (whose boot deposited only 4,715 pages,
p = 2.41 × 10⁻⁵), **P(4 of 4 by chance) ≈ 1.5 × 10⁻¹⁷**.

## The payload walk, not traffic volume, converts traffic into faults

Both arms ran on the same node, same boot lineage, same 64-stream veth load,
with the same **7,514 live deposited pages** present (deposited earlier in the
boot, zero withdrawn, and zero new deposits during the control window — so the
hazardous pages were present and stable for both arms). The only variable was
whether the kernel had to walk the payload to compute a checksum:

| arm | `tx-checksum` | data pushed | result |
|---|---|---|---|
| control | **on** (no software checksum) | **3,395 GiB** in 420 s | **no crash** |
| positive | **off** (forces `__skb_checksum`) | — | **panic in ~4 s** |

The control pushed *more* data than the arm that died, so volume is not the
trigger. What matters is whether something walks the payload bytes: with offload
on the kernel never reads them and 3.4 TiB passes harmlessly.

This does **not** mean a software checksum is strictly required for the defect.
Any kernel code that over-reads past a buffer into the adjacent page would fault
identically. `csum_partial` is simply the highest-volume such reader in this
workload, which is why it is the one caught in all four panics.

## This explains every prior observation

| Observation | Explanation |
|---|---|
| 217/217 faults straddle a 4 KiB boundary | deposits are 4 KiB granular; only a straddling read reaches the next page |
| Page tables show Present, Writable, huge-page mapped | the guest-side mapping is untouched; the hypervisor removed access *beneath* it |
| `#GP`, not `#PF` | it is not a guest paging fault at all |
| All 201,325,240 RAM pages readable on a live probe | **misstatement** — that probe sampled one 8-byte read per 2 MiB (1 page in 512), so it never read most pages. Targeted reads of *known* deposited pages later showed 65% read as all-zero vs 17.5% of controls |
| L1VH 4/4 crashes vs non-L1VH 0/3 with 8 TiB | only an L1VH root partition deposits pages to a hypervisor |
| Reproduces with a bare veth pair, no OVS/Geneve/VM in the path | the network path only supplies a software checksum over page-frag data |
| No guest-side mitigation ever worked | nothing in the guest can make a hypervisor-owned page readable |
| Disabling GSO did not help | `skb_checksum_help` over-reads just the same |

## The role of VMs — correlated, not deterministic

Deposits scale with partition activity, so VM lifecycle changes how many pages
are hypervisor-owned. Measured on one node, same kernel, same load:

| VM state | runs | traffic | crashes |
|---|---|---:|---:|
| never ran this boot | 2 | 5,432 GiB | **0** |
| running during the load | 2 | — | **2** |
| ran, then torn down | 2 | 3,552 GiB | **1** |

Suggestive, and consistent with the mechanism, but **not deterministic**: one
torn-down run survived 3.5 TiB. Expected — the fault needs a network buffer to
land immediately below a currently-deposited page, which is probabilistic. Do
not read the VM arms as a reliable on/off switch.

## What this is *not*

- **Not** a use-after-free of returned pages. In all four hits the page was
  still deposited (`withdrawn=False`), so this is not the "mishandled on return
  to Linux" variant of the theory. Guest-memory-path instrumentation
  (`mshv_map_user_memory` / `mshv_region_pin`) is **not** required to explain it.
- **Not** OVS, Geneve, CNV or MANA specific *as a mechanism*. Any code that
  over-reads into an adjacent page would fault the same way. But on this
  platform the OVN/OVS datapath is, by measurement, the sole producer of the
  software checksums that do the over-reading — so it is the practical trigger
  even though it is not the defect.
- **Not** volume-driven: a non-L1VH node absorbed 8 TiB through the identical
  code path without a fault.

## Why decade-old code only breaks here

`csum_partial`'s tail over-read is ancient and has always been safe, because
reading a few bytes past a buffer into the next page of your own RAM is
harmless. Three conditions must hold simultaneously for it to become fatal, and
this platform is the first place all three co-occur:

**1. A neighbouring page must be revocable by someone else.** Only a *root
partition* deposits pages to the hypervisor. A normal VM guest — including every
ordinary Azure VM — never calls `HVCALL_DEPOSIT_MEMORY`, so no page in its
address space can be hypervisor-owned. Linux-as-root-partition (L1VH/mshv) is
new; this hazard simply cannot exist on the hardware where `csum_partial` was
written and hardened.

**2. Something must walk the payload in software.** Measured with kprobes on the
node, in a private ftrace instance (the global buffer is drained by the deposit
tracer, which silently zeroed a first attempt):

| condition | `skb_checksum_help` | `__skb_checksum` |
|---|---|---|
| ordinary cluster traffic, no synthetic load | 2.5/s | **12/s** |
| veth stress with offload off (13.1 MB) | 3,115 | 23,461 (~7,800/s) |

So ordinary OpenShift traffic on an idle-ish node runs a steady **trickle** of
software checksums — not a flood. Every one of them, by stack trace, comes from
the OVN datapath:

```
ovs_dp_process_packet 72   ovs_vport_receive 59   ovs_execute_actions 41
internal_dev_xmit     37   ovs_dp_upcall/queue_userspace_packet 31
```

Both physical NICs are `tx-checksum-ip-generic: off [fixed]` (`mana`,
`hv_netvsc`), so they can offload only fixed-offset IPv4/IPv6 checksums, never
one at the arbitrary offset an encapsulated packet needs. When OVS requires a
materialized checksum — punting to `ovs-vswitchd`, or transmitting via an
internal port — it therefore falls to software.

That trickle is enough: at 12 walks/s a node dies in tens of minutes to hours,
which matches the observed boot lifetimes and the spontaneous Thanos panic. The
stress harness raises the rate ~650×, compressing time-to-crash from hours to
seconds; it is an accelerant, not a different mechanism.

A bare-metal RHEL + QEMU/libvirt L1VH test has no OVS datapath and no overlay
demanding an inner checksum, and virtio-net hands frames over as
`CHECKSUM_PARTIAL` without touching the bytes. It generates essentially none of
these checksum walks — so this trigger disappears.

### Why networking, when the hazard is generic memory?

The hazard is not networking-specific and neither is `load_unaligned_zeropad()`:
`strscpy()` and the dcache path (`dentry_string_cmp()`, `hash_name()`) use the
same over-reading load, and would fault identically on a deposited neighbour.
Removing OVS therefore lowers the rate by orders of magnitude; it does not prove
the hazard is gone. Networking dominates for two compounding reasons:

**It over-reads across page boundaries constantly, by construction.** An MTU
payload of 1500 bytes has `1500 & 7 == 4`, so the tail load begins 4 bytes before
the buffer end and reads 8 — 4 bytes into the next page. skb page frags are
carved from page-allocator pages and routinely run to the page boundary, so a
large fraction of ordinary packets perform a cross-page over-read. That is why
all 217 observed faults straddle a boundary rather than a handful.

**Its buffers share an allocator with the deposits.** skb frags come from the
page allocator, and `hv_call_deposit_pages()` takes *single* pages from that same
buddy pool (98% `count=1`). Network buffers and hypervisor-owned pages are drawn
from the same free lists and so become physical neighbours far more often than
slab-backed data — a dcache name sits inside a multi-object slab page whose
neighbours are almost always more slab.

By contrast the dcache/strscpy users over-read short strings that rarely end
within 7 bytes of a page boundary, and whose neighbouring page is rarely a
deposited one. Same defect, vastly lower exposure.

**3. Deposited pages must be scattered next to hot network buffers.** They are,
because deposits are overwhelmingly *single* pages taken from the buddy
allocator — **5,980 of 6,073 blocks had `count=1`** — which land interleaved
with everything else rather than in one isolated region. CNV keeps this churning:
partitions are created and torn down constantly, in pairs, around VM lifecycle
and node-labeller probing.

```
partition 152  56.3s ->   56.7s  ( 0.4s)     10 partitions in 18 minutes
partition 153 248.4s ->  248.7s  ( 0.4s)     5.6 deposit blocks/s
partition 154 249.4s ->  250.6s  ( 1.2s)     15.4 pages/s
partition 155 282.4s ->  282.7s  ( 0.4s)     98% single-page deposits
...
partition 160 1131.4s -> 1132.7s ( 1.3s)  <- fault hit this partition's page 19s later
```

A bare QEMU test starts one long-lived partition and deposits once. Here the
node continuously sprays single hypervisor-owned pages across memory adjacent to
the very buffers being checksummed — which is why the same "harmless" over-read
lands on a poisoned neighbour within seconds.

## Where the defect actually is

Two facts are incompatible on a root partition: the kernel deposits pages that
are **adjacent to pages still in use by the rest of the kernel**, and
`load_unaligned_zeropad()` may legitimately over-read up to 7 bytes past a
buffer. Crucially, the kernel already has a contract for the second fact — the
`EX_TYPE_ZEROPAD` fixup — and the platform breaks that contract by signalling
`#GP` instead of `#PF`. Candidate fixes, for whoever owns this:

1. **Deliver the fault as `#PF`, or keep deposited pages readable.** If touching
   a deposited page produced a page fault instead of `#GP`, the existing
   `ex_handler_zeropad()` would substitute zero-padded data and execution would
   continue — exactly as on every normal host. This fixes the whole class at
   once, including the `strscpy()` and dcache users of the same idiom, without
   touching any hot path. This is the most contained fix and belongs in the
   hypervisor / mshv page-donation path.
2. **Isolate deposited memory.** Allocate deposit pages so they are never
   adjacent to pages the kernel may over-read into — e.g. deposit at a coarser
   granularity, or from a reserved region. The current path hands over single
   pages scattered throughout normal memory (98% `count=1`). Note the direct map
   uses 2 MiB huge pages, so a donated 4 KiB page shares its mapping with 511
   pages in ordinary use — meaning isolation realistically has to happen at
   2 MiB granularity or from a region mapped at 4 KiB. Also effective, but it
   only removes the adjacency; the underlying `#GP`-instead-of-`#PF` contract
   violation would remain for any other route to a deposited page.
3. **Extend the fixup to `#GP`.** Teach the zeropad handler to recover from a
   `#GP` with no fault address. Plausible but risky — `#GP` carries no address,
   so the handler cannot verify the fault was the benign next-word case, and
   silently zero-padding genuine `#GP`s would mask real bugs.
4. **Stop over-reading.** Change `csum_partial`'s tail to a bounded read. Least
   attractive: it is a deliberate long-standing optimisation, and it fixes only
   `csum_partial` while leaving every other `load_unaligned_zeropad()` caller
   exposed.

Option 1 is preferred: it restores an invariant the kernel already relies on,
rather than working around its violation.

## Reproducing

Every claim in this document maps to a command below. Offline steps need only
the collected artifacts; on-node steps need `KUBECONFIG` and an MSHV node.

### 0. Prerequisites (one time, reboots the node)

```sh
export KUBECONFIG=$PWD/kubeconfig
export NODE=$(oc get nodes -l node-role.kubernetes.io/mshv \
                -o jsonpath='{.items[0].metadata.name}')

bash scripts/04a-mshv-nokaslr.sh              # fixed PAGE_OFFSET, needed by 17/24
make mshv-kdump                               # capture panic logs across reboot
bash scripts/21-mshv-deposit-trace.sh install # boot-time deposit ledger
bash scripts/21-mshv-deposit-trace.sh ledger  # verify it is complete from boot
```

The ledger **must** be complete from boot: a ledger started after the deposits it
is supposed to explain will silently fail to correlate. `ledger` reports this.

### 1. Root cause: the over-read is a fixup-annotated load, and Linux still maps the page

Fully offline, from one kdump directory plus the matching `kernel-devel` RPM:

```sh
bash scripts/26-verify-zeropad-overread.sh all \
  .checkup-runs/crash-2026-09-09-2146 \
  ~/kernel-rpms-mgns1/kernel-devel-6.12.0-211.49.1.1794_2798046552.mgns1.el10.x86_64.rpm
```

Proves, in order:

| Sub-claim | Expected output |
|---|---|
| The faulting instruction is `load_unaligned_zeropad()` | `neg %esi` / `shl $0x3,%esi` / `and $0x3f,%esi` / `mov (%rax),%rax` |
| That load is *designed* to fault | `_ASM_EXTABLE_TYPE(1b, 2b, EX_TYPE_ZEROPAD)` |
| Linux still maps the page, so `#PF` is impossible | `PMD 0x80000031190001e3` → Present=1, PS=1 |

Individually: `insn <vmcore-dmesg.txt>`, `extable <rpm>`, `ptes <vtop.txt> <addr>`.

### 2. The fault lands on a page deposited to the hypervisor (4/4)

```sh
# start a VM on the node so partitions exist, then:
NODE=$NODE DURATION=420 STREAMS=64 bash scripts/19-mshv-veth-csum-stress.sh run
bash scripts/16-mshv-kdump.sh collect
bash scripts/21-mshv-deposit-trace.sh fetch

python3 scripts/22-correlate-fault-deposits.py \
  .checkup-runs/mshv-deposit-trace/boot-<id>/trace.log \
  .checkup-runs/crash-<stamp>/vmcore-dmesg.txt
```

Expect `-> IN DEPOSITED RANGE` with `withdrawn=False`. The correlator refuses to
compare a panic against a ledger from a different boot and states whether the
ledger was complete from boot — both mistakes were made and caught here.

### 3. The payload walk, not traffic volume, is what kills

Same node, same live deposited pages; only the offload flag differs. Run the
control **first** — it should survive:

```sh
NODE=$NODE DURATION=420 STREAMS=64 DISABLE_CSUM_OFFLOAD=false \
  bash scripts/19-mshv-veth-csum-stress.sh run      # ~3,395 GiB, no crash

NODE=$NODE DURATION=420 STREAMS=64 DISABLE_CSUM_OFFLOAD=true \
  bash scripts/19-mshv-veth-csum-stress.sh run      # panics in seconds

bash scripts/19-mshv-veth-csum-stress.sh fetch      # after the reboot
python3 scripts/20-analyze-stress-runs.py
```

Verify the node really did survive the control arm rather than rebooting
unnoticed — compare boot IDs, do not infer from the absence of a crash marker:

```sh
oc debug node/$NODE -- chroot /host journalctl --list-boots -n 5
```

### 4. Software checksums are a trickle, and they come from OVS

```sh
NODE=$NODE bash scripts/23-csum-software-rate.sh validate   # MUST be non-zero
NODE=$NODE bash scripts/23-csum-software-rate.sh measure 20 # ~12 __skb_checksum/s
NODE=$NODE bash scripts/23-csum-software-rate.sh stacks 25  # ovs_dp_* callers
```

Run `validate` first, always. The global ftrace buffer is drained by
`mshv-trace-stream.service`, so enabling events there reports **zero hits** — for
real traffic *and* for a known-good positive control. This script measures in a
private ftrace instance to avoid that; `validate` is what proves it worked.

Supporting NIC capability (why an inner checksum cannot be offloaded):

```sh
oc debug node/$NODE -- chroot /host ethtool -k eth0 | grep tx-checksum
# tx-checksum-ip-generic: off [fixed]   <- cannot offload at an arbitrary offset
```

### 5. Deposits are single scattered pages, from constant partition churn

```sh
python3 scripts/25-analyze-deposit-ledger.py \
  .checkup-runs/mshv-deposit-trace/boot-<id>/trace.log
```

Expect ~98% `count=1`, ~15 pages/s, and guest partitions with sub-second
lifetimes (ephemeral CNV probe partitions).

### 6. Deposit does not immediately revoke read access

```sh
NODE=$NODE bash scripts/24-deposit-page-readability.sh probe 40
```

Expect the `KNOWN-UNMAPPED` calibration row to read all-zero with `errno=0` —
that is what proves `/proc/kcore` zero-fills on fault, making the all-zero rate an
**upper bound** on inaccessibility rather than a measurement. The unambiguous
result is the opposite arm: deposited pages returning real data were not revoked.

### 7. L1VH is required

```sh
NODE=$NODE bash scripts/18-mshv-fault-differential.sh run
```

L1VH crashes; a non-L1VH node of the same size and kernel absorbs TiB without a
fault.

### Offline test suite

No cluster required; ~2 seconds. Run before trusting any analysis output:

```sh
bash tests/zeropad-overread-tests.sh          # Code:/PMD decode, ledger parsing
bash tests/stress-run-analysis-tests.sh       # stress-run analyser
python3 scripts/22-correlate-fault-deposits.py --self-test
python3 scripts/25-analyze-deposit-ledger.py  --self-test
```

Each case in `zeropad-overread-tests.sh` is a parsing bug that was actually hit
during this investigation and would otherwise have produced a confidently wrong
claim — an ftrace comm containing a space silently dropping a third of the
deposit records, and `vtop.txt`'s multiple translation blocks causing the wrong
page's PMD to be decoded.
