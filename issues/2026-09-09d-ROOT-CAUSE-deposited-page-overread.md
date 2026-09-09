# 2026-09-09 — ROOT CAUSE: csum_partial over-reads into a page deposited to the hypervisor

> **The `#GP` is a benign 8-byte over-read crossing a 4 KiB page boundary into a
> page that Linux has deposited to the Hyper-V hypervisor via
> `HVCALL_DEPOSIT_MEMORY` and which the hypervisor still owns.**
>
> Three faults, across two boots, were correlated against a complete-from-boot
> deposit ledger. In **3 of 3** cases the page the over-read crossed into was a
> deposited page that had **not** been withdrawn. With deposits covering 0.0085%
> of RAM, the odds of that happening by chance are about **1 in 1.7 × 10¹²**.

## The mechanism

1. `csum_partial`'s tail path deliberately reads a full 8 bytes and masks off the
   excess — a benign over-read of up to 7 bytes past the buffer.
2. The buffer ends within 8 bytes of a 4 KiB page boundary, so the read crosses
   into the **next** page. (This is why 217/217 faults sit at page offsets
   `0xff9`–`0xfff`.)
3. On an L1VH root partition, that next page may be one Linux allocated and
   handed to the hypervisor with `HVCALL_DEPOSIT_MEMORY`. The hypervisor owns it
   and the root partition can no longer read it.
4. The access raises **`#GP`** in interrupt context → `Kernel panic - not
   syncing: Fatal exception in interrupt` → reboot.

On any normal host the adjacent page is always accessible, which is exactly why
upstream considers this over-read safe.

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

## The software checksum is the trigger — A/B on one node

Both arms ran on the same node, same boot lineage, same 64-stream veth load,
with the same **7,514 live deposited pages** present (deposited earlier in the
boot, zero withdrawn, and zero new deposits during the control window — so the
hazardous pages were present and stable for both arms). The only variable was
whether the kernel had to walk the payload to compute a checksum:

| arm | `tx-checksum` | data pushed | result |
|---|---|---|---|
| control | **on** (no software checksum) | **3,395 GiB** in 420 s | **no crash** |
| positive | **off** (forces `__skb_checksum`) | — | **panic in ~4 s** |

With offload on, the kernel never reads the payload, so the tail over-read never
happens and 3,395 GiB — roughly a thousand times the volume that has previously
been enough to crash this node — passes harmlessly. Flipping that one flag
killed the node almost immediately. The over-read is necessary, not incidental.

## This explains every prior observation

| Observation | Explanation |
|---|---|
| 217/217 faults straddle a 4 KiB boundary | deposits are 4 KiB granular; only a straddling read reaches the next page |
| Page tables show Present, Writable, huge-page mapped | the guest-side mapping is untouched; the hypervisor removed access *beneath* it |
| `#GP`, not `#PF` | it is not a guest paging fault at all |
| All 201,325,240 RAM pages readable on a live probe | the probe ran when those particular pages were not deposited |
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
- **Not** OVS, Geneve, CNV or MANA specific. Those merely generate software
  checksums over page-frag payloads.
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

**2. The kernel must actually walk the payload in software.** Confirmed by the
A/B above: with checksum offload on, 3,395 GiB passed cleanly. Azure forces the
software path here — both NICs can only offload fixed IPv4/IPv6 checksums, never
a Geneve inner checksum at an arbitrary offset:

```
enP30832s1 (mana)      tx-checksum-ip-generic: off [fixed]
eth0       (hv_netvsc) tx-checksum-ip-generic: off [fixed]
genev_sys_6081         tx-checksum-ip-generic: on     <- must be done in software
```

A bare-metal RHEL + QEMU/libvirt L1VH test has neither property: there is no
overlay demanding an inner checksum, virtio-net hands frames over as
`CHECKSUM_PARTIAL` without ever touching the bytes, and typical NICs advertise
generic checksum offload. `__skb_checksum` over payload essentially never runs,
so the over-read never happens and the bug is invisible no matter how long the
test runs.

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

The kernel deposits pages that are **adjacent to pages still in use by the rest
of the kernel**, while `csum_partial` (and any other function using the same
read-8-and-mask tail idiom) may legitimately over-read up to 7 bytes past a
buffer. Those two facts are incompatible on a root partition. Candidate fixes,
for whoever owns this:

1. **Isolate deposited memory.** Allocate deposit pages so they are never
   adjacent to pages the kernel may over-read into — e.g. deposit at a coarser
   granularity, or from a reserved region. The current path uses
   `alloc_page()`/`split_page()` and hands over single pages scattered
   throughout normal memory.
2. **Make the over-read safe.** Have the hypervisor leave deposited pages
   readable to the root partition, or fault them benignly instead of `#GP`.
3. **Stop over-reading.** Change `csum_partial`'s tail to a bounded read. This is
   the least attractive: it is a long-standing, deliberate optimisation and the
   idiom appears elsewhere (`load_unaligned_zeropad()` has the same shape).

Option 1 looks the most contained, and it is squarely in `hv_call_deposit_pages()`.

## Reproducing

```sh
make mshv-kdump                                    # capture panics locally
bash scripts/21-mshv-deposit-trace.sh install      # boot-time deposit ledger
# start a VM on the node, then:
NODE=<mshv-node> DURATION=420 STREAMS=64 bash scripts/19-mshv-veth-csum-stress.sh run
bash scripts/16-mshv-kdump.sh collect
python3 scripts/22-correlate-fault-deposits.py <ledger>/trace.log <dump>/vmcore-dmesg.txt
```

To run the negative control that isolates the software checksum, keep offload on
— the node should survive indefinitely:

```sh
NODE=<mshv-node> DURATION=420 STREAMS=64 DISABLE_CSUM_OFFLOAD=false \
  bash scripts/19-mshv-veth-csum-stress.sh run
```

The correlator refuses to compare a panic with a ledger from a different boot,
and states whether the ledger was complete from boot — both mistakes were made
and caught during this investigation.
