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

- **Not** a use-after-free of returned pages. In all three hits the page was
  still deposited (`withdrawn=False`), so this is not the "mishandled on return
  to Linux" variant of the theory. Guest-memory-path instrumentation
  (`mshv_map_user_memory` / `mshv_region_pin`) is **not** required to explain it.
- **Not** OVS, Geneve, CNV or MANA specific. Those merely generate software
  checksums over page-frag payloads.
- **Not** volume-driven: a non-L1VH node absorbed 8 TiB through the identical
  code path without a fault.

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

The correlator refuses to compare a panic with a ledger from a different boot,
and states whether the ledger was complete from boot — both mistakes were made
and caught during this investigation.
