# 2026-09-08 — MSHV/L1VH GSO panic re-reproduced with `nokaslr`; reproducer reset detection was broken

> **TL;DR:** The sender-side node reset from
> `issues/2026-09-03-mshv-reboots-are-guest-gso-csum-panics.md` **reproduces
> reliably**: 600 s of cross-node Geneve load reset the **sending** node
> **3 times** while the **receiving** node stayed up. The crash also survives a
> full node replacement, so it is **not** tied to one damaged VM.
>
> `nokaslr` is now active on both MSHV nodes, so kernel text is at the fixed
> default base `0xffffffff81000000` and **panic RIPs are directly decodable and
> comparable across boots and across nodes**. A decode table for the documented
> panic frames is included below.
>
> Serial-console logs for the four panic windows were retrieved and analysed:
> the `csum_partial+0xe5` signature is **unchanged**, but the analysis **corrects
> the 09-03 root-cause framing**. The fault addresses are *not* non-canonical
> garbage — with `nokaslr` they decode to ordinary direct-map pointers into real
> RAM, and **217/217 faults are 8-byte reads straddling a 4 KiB page boundary**
> from `csum_partial`'s deliberate tail over-read. Why that read raises **#GP**
> rather than succeeding is now the central open question. The underlying defect
> remains **open and unfixed**.

## Environment

| Field | Value |
|-------|-------|
| Cluster | `aro-virt-test`, RG `aro-virt-test-rg-o98l`, `centralus` |
| Managed (node) RG | `aro-wa2fvt52` |
| Nodes | `…-worker-mshv-centralus1-7rn6g` (**new**, replaced `bl5zw`), `…-l7njd` |
| Kernel | `6.12.0-211.49.1.1794_2798046552.el10_2.x86_64` (unchanged) |
| Kernel cmdline | `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all psi=1 nokaslr` |
| OCP / CNV | 4.22.4 / `4.99.0-2981` (HCO Available at test time) |

`bl5zw` was replaced earlier the same day for an unrelated truncated-image
outage (`issues/2026-09-08.md`). The replacement node reproduces the **same**
NIC/overlay offload state, and the panic still occurs, so the defect is not
specific to the retired VM.

## `nokaslr` is active and kernel symbols are now stable

Captured from `/proc/kallsyms` on both nodes
(`.checkup-runs/mana-gso-repro-20260908/nokaslr-symbol-map.txt`):

```
kptr_restrict=1 kaslr_in_cmdline=1
ffffffff81000000 T _text          <- default base, i.e. KASLR is off
ffffffff81e8cb20 T csum_partial
ffffffff81bdb6b0 T __skb_checksum
ffffffff81be5560 T skb_segment
ffffffff81d19bf0 t __skb_udp_tunnel_segment
```

**All core-kernel symbols above are byte-identical on both nodes.** Before
`nokaslr`, every boot used a different random text offset, so raw RIP/fault
addresses could not be compared between panics; now they can.

**Caveat — module addresses are still not stable.** `geneve`, `openvswitch`, and
`udp_tunnel` load into the module area at addresses that differ per node and per
boot (e.g. `geneve` at `0xffffffffc1703000` vs `0xffffffffc1706000`). `nokaslr`
does not pin those. Frames inside `[geneve]` / `[openvswitch]` therefore still
need the per-boot module base; only the core-kernel frames decode directly.

### Panic-frame decode table

Absolute addresses for the frames recorded on 2026-09-03. With `nokaslr` these
values should now be **identical in every future panic**; a mismatch means the
crash moved to a different instruction and must be re-analysed, not assumed.

```
FRAME                              SYMBOL BASE          ABSOLUTE ADDRESS
csum_partial+0xe5                  0xffffffff81e8cb20   0xffffffff81e8cc05
__skb_checksum+0x184               0xffffffff81bdb6b0   0xffffffff81bdb834
skb_segment+0x667                  0xffffffff81be5560   0xffffffff81be5bc7
tcp_gso_segment+0xe9               0xffffffff81d0d570   0xffffffff81d0d659
inet_gso_segment+0x149             0xffffffff81d26e20   0xffffffff81d26f69
skb_mac_gso_segment+0xaa           0xffffffff81c47ba0   0xffffffff81c47c4a
__skb_udp_tunnel_segment+0x1ba     0xffffffff81d19bf0   0xffffffff81d19daa
skb_udp_tunnel_segment+0x70        0xffffffff81d1a160   0xffffffff81d1a1d0
__skb_gso_segment+0x78             0xffffffff81c47d70   0xffffffff81c47de8
validate_xmit_skb+0x142            0xffffffff81c012b0   0xffffffff81c013f2
sch_direct_xmit+0x17c              0xffffffff81c774f0   0xffffffff81c7766c
__dev_queue_xmit+0x43d             0xffffffff81c01ac0   0xffffffff81c01efd
ip_finish_output2+0x23d            0xffffffff81ccf090   0xffffffff81ccf2cd
iptunnel_xmit+0x194                0xffffffff81d3e030   0xffffffff81d3e1c4
```

Decoding to **source lines** still requires a `vmlinux` matching this exact
build, which this repository does not ship. `nokaslr` makes the addresses
stable; it does not supply debug information.

## Reproduction result (2026-09-08)

Command (the documented reproducer, unchanged parameters except poll interval):

```sh
KUBECONFIG="$PWD/kubeconfig" MITIGATE=false STREAMS=64 DURATION=600 POLL=10 \
  bash scripts/15-mshv-offload-isolation-test.sh run
```

Roles: `sink` on **7rn6g** (receiver), `flood` on **l7njd** (sender).

```
RESET DETECTED on …-l7njd: boot 95609651… -> 64ad6917… at t=141s
RESET DETECTED on …-l7njd: boot 64ad6917… -> 1d249739… at t=304s
RESET DETECTED on …-l7njd: boot 1d249739… -> 73cb3b0e… at t=510s
  …-7rn6g: resets=0
  …-l7njd: resets=3
```

**The sender crashed three times; the receiver never crashed.** This matches the
TX/segmentation framing of the 09-03 analysis. A fourth reset followed at
22:12:46, just as the window closed.

Per-boot timestamps from the node itself (each gap is ~25-40 s, consistent with
`kernel.panic = 10` plus boot time):

```
9560965141b340e18f8307ef3396b999  21:43:56 -> 22:03:44
64ad691718e346b9ba0ebd5b769bb5b5  22:04:24 -> 22:06:37
1d24973907fe42af9a04d0273c43c2ff  22:07:04 -> 22:09:59
73cb3b0e2ac6490682bd09cc57db7a9c  22:10:28 -> 22:12:46
17ca970d35a243e0b9b51040f976177e  22:13:16 -> (current)
```

### Serial-console windows to fetch

The panic text is **not** in journald (fatal exception in interrupt) and is
**not** in pstore: `/sys/fs/pstore` is mounted but empty, and `kdump` is
`disabled`/`inactive`, so no vmcore is produced. Azure boot-diagnostics serial
console remains the only source. Panic windows on **l7njd**, UTC:

| # | Panic near | Back up at |
|---|------------|------------|
| 1 | 22:03:44 | 22:04:24 |
| 2 | 22:06:37 | 22:07:04 |
| 3 | 22:09:59 | 22:10:28 |
| 4 | 22:12:46 | 22:13:16 |

Earlier resets the same evening, before this controlled run: 21:06:44, 21:32:47,
21:35:50, 21:40:31, 21:43:26. Several of those occurred with **no synthetic
load** running, so the crash is not exclusive to the reproducer's traffic.

## Serial-console analysis (received 2026-09-08)

Serial log for `l7njd` covering **216 boots / 217 GPF oopses / 210 panics**,
analysed with `scripts/13-serial-log-panic-analysis.sh`. **10 oopses are from
`nokaslr` boots**, 207 predate it.

### The signature is unchanged

Every single panic RIP in the whole file is the same:

```
$ grep -o 'RIP: 0010:[a-z_]*+0x[0-9a-f]*/0x[0-9a-f]*' … | sort | uniq -c
    426 csum_partial+0xe5/0x110
    155 default_idle+0xf/0x20      <- idle CPUs in the multi-CPU dump, not the fault
```

The call chain is identical to 09-03, including on `nokaslr` boots:
`csum_partial` ← `__skb_checksum` ← `skb_segment` ← `tcp_gso_segment` ←
`inet_gso_segment` ← `skb_mac_gso_segment` ← `__skb_udp_tunnel_segment` ←
`skb_udp_tunnel_segment` ← … ← `geneve_xmit_skb [geneve]`. So `nokaslr` changed
nothing about the failure; it is purely diagnostic, as intended.

### CORRECTION: the fault addresses are **not** non-canonical, and not garbage

The 09-03 issue states the fault address is *"a **non-canonical** pointer …
(top bits not sign-extended → GPF)"*. **That is wrong**, and `nokaslr` is what
exposed it.

From the register dump of the last panic:

```
CR4: 0000000000b71ef0      -> bit 12 (LA57) is SET  => 5-level paging
RSP: ffa00000192e6a68      -> 5-level VMALLOC_START (0xffa0000000000000)
GS:  ff1100303fa00000      -> 5-level PAGE_OFFSET   (0xff11000000000000)
RAX: ff110091feab7ffc      -> the faulting address
```

With 5-level paging a linear address is canonical when bits 63:57 equal bit 56.
For `0xff11…` they do, so **the address is canonical**. It only looked
non-canonical if you assume 4-level paging, which this kernel is not using.

What `nokaslr` proves is stronger. KASLR randomizes `page_offset_base`, so before
`nokaslr` the fault addresses had **57 distinct high-16 prefixes** and looked like
random garbage. With `nokaslr` all 10 fault addresses share the single prefix
`0xff11` — exactly the default 5-level `PAGE_OFFSET`:

```
0xff110002b7907ffb  ->  phys 0x0002b7907ffb
0xff110064c24b7ffc  ->  phys 0x0064c24b7ffc
0xff110031f2617ffa  ->  phys 0x0031f2617ffa
0xff110091feab7ffc  ->  phys 0x0091feab7ffc
…
```

**The fault addresses are ordinary direct-map (physmap) pointers**, i.e.
`PAGE_OFFSET + physical_address`. Every decoded physical address lands inside a
`usable` e820 RAM region, hundreds of GB away from any region boundary, and the
**next** page is also usable RAM:

```
FAULT PHYS       NEXT PAGE        NEXT PAGE USABLE RAM?
0x0091feab7ffc   0x0091feab8000   YES - mapped RAM
0x009400dffffc   0x009400e00000   YES - mapped RAM        (all 10 identical)
```

So the crash is **not** a wild pointer, **not** non-canonical, and **not** an
access past the end of physical memory.

### 217 of 217 faults straddle a 4 KiB page boundary

Distribution of the faulting address within its page, across the entire file:

```
  0xff9 n=14   0xffa n=29   0xffb n=29   0xffc n=98
  0xffd n=24   0xffe n=15   0xfff n=8
  -> 217/217 = 100% within 7 bytes of the page end
```

**Every fault is an 8-byte read that crosses into the following page.** No fault
ever occurs anywhere else in a page.

### The faulting instruction is `csum_partial`'s deliberate tail over-read

Disassembling the `Code:` bytes around the `<48>` fault marker:

```
add    (%rax),%rdx        ; 8-byte accumulate loop
adc    $0x0,%rdx
add    $0x8,%rax
test   $0x7,%sil          ; loop while length is a multiple of 8
je     <loop>
neg    %esi               ; --- tail path ---
shl    $0x3,%esi
and    $0x3f,%esi
mov    (%rax),%rax        ; <== FAULT: reads a full 8 bytes, then masks off
```

This is the standard tail optimisation: read 8 bytes and shift away the bytes
beyond the buffer. It **intentionally over-reads by up to 7 bytes**.

Working the register values backwards: `%esi` ends as `0x20`, which requires the
remaining length ≡ 4 (mod 8); `RDI = …7c8c` (the buffer) and `RAX = …7ffc`, so
the buffer ends at `…8000` — **exactly on the page boundary**. The tail then
reads 4 bytes beyond the buffer, into the next page.

### What this means, and the open question

The mechanism is now precise and measured:

1. A Geneve-encapsulated TCP skb is software-segmented (the uplink cannot offload
   tunnel segmentation), so the guest checksums the payload itself.
2. The buffer being checksummed ends exactly on a 4 KiB page boundary — routine
   for page-backed skb frags.
3. `csum_partial`'s tail reads 8 bytes and masks, touching the next page.
4. That read faults with **#GP**.

**Step 4 is unexplained and is now the central question.** The address is
canonical, it is a direct-map pointer, and the target page is `usable` RAM well
inside a memory region. Architecturally that read should simply succeed; if the
page were merely absent it should raise **#PF**, not **#GP**. On ordinary
hardware this same over-read is harmless, which is why upstream considers it safe.

Two candidate explanations, **neither confirmed**:

- **L1VH/MSHV memory donation.** These are L1VH root-partition hosts
  (`Hyper-V: running as L1VH partition`, `mshv_root` loaded, and the log contains
  1433 × `using unsupported MSHV_CREATE_PARTITION ioctl`). If pages donated to a
  child partition are removed from the root partition's access, an over-read into
  a neighbouring VM-owned page would fault. This would make the crash
  **L1VH-specific** rather than a generic networking bug.
- **A genuinely corrupt skb length**, per the original CVE-2026-74705 theory,
  where the walk runs far past the buffer and eventually reaches an inaccessible
  page. The 100 % page-straddle statistic does **not** discriminate between these
  two: `RDI` is 4-byte aligned, so with 8-byte steps every page crossing is a
  straddle either way.

Evidence **against** simple VM-adjacency: during the controlled run the only
running VMs (`vm-pool-fedora-0` since 21:43, `probe`) were on **7rn6g**, the node
that never crashed, while VM-less `l7njd` crashed four times. That weakens, but
does not eliminate, the donation hypothesis — `mshv_root` is loaded and
partition ioctls occur on both nodes regardless of VM placement.

Ruled out from the log: no `hv_balloon` activity, no memory hot-add/hot-remove,
and no Hyper-V intercept messages.

### Revised next steps

- [ ] Determine why a canonical direct-map read of `usable` RAM raises **#GP**
      instead of succeeding. This is the crux; everything above is now measured.
- [ ] Establish whether the physical pages adjacent to the faulting buffers are
      donated to L1VH child partitions / otherwise removed from the root
      partition's mappings.
- [ ] Get a `vmlinux` for this exact build to confirm `csum_partial+0xe5` is the
      tail path and to check the `skb_segment+0x667` caller's length handling.
- [ ] Re-test the offload mitigation with the fixed reproducer; if software
      tunnel segmentation is avoided, the over-read never happens.
- [ ] When reporting upstream, lead with the **page-straddling tail over-read on
      an L1VH host**, not with "non-canonical pointer".

## Why only the Geneve path? (offload flags)

> **SUPERSEDED by `issues/2026-09-09-csum-under-ovs-not-geneve.md`.** Eleven
> locally-captured panics show Geneve appears in only 8/11 call chains, while
> `__skb_checksum` and an OVS frame appear in 11/11. One path involves no tunnel
> and no GSO at all. The offload-flag reasoning below is still correct about *why*
> the guest must checksum in software; the "only Geneve" conclusion is not.


`csum_partial` is called constantly, so the obvious objection is that this should
crash everywhere. It does not, and the captured offload flags explain why.
Verbatim `ethtool -k eth0` on `l7njd` (the MANA VF `enP30832s1` is identical):

```
tx-checksumming: on
        tx-checksum-ipv4: on
        tx-checksum-ip-generic: off [fixed]
        tx-checksum-ipv6: on
tx-udp_tnl-segmentation: off [fixed]
tx-udp_tnl-csum-segmentation: off [fixed]
tx-gso-partial: off [fixed]
```

1. **Plain TCP is offloaded.** `tx-checksum-ipv4/ipv6: on`, so ordinary TX is
   `CHECKSUM_PARTIAL` and the NIC computes the checksum; `csum_partial` never
   touches the payload. It is called often, but almost never over bulk data.
2. **Encapsulated traffic cannot be.** `tx-checksum-ip-generic: off [fixed]`
   means the inner checksum cannot be offloaded, and both `tx-udp_tnl-*` flags
   are `off [fixed]`, so Geneve-encapsulated TCP must be segmented **and**
   checksummed in software inside the guest.
3. **This is the only path that runs `__skb_checksum` over
   `skb_shinfo->frags[]`** — page-allocator pages, where a frag ending exactly
   on a 4 KiB boundary is routine and the tail over-read steps into an unrelated
   neighbouring physical page.

So the Geneve path is not special because it is Geneve; it is the only
high-volume producer of **software checksums over page-frag payloads**. OVS
matters only as the thing driving the encapsulation.

**Caveat:** "frag, not slab" is not provable from the dump alone. Both live in
the direct map, and an 884-byte kmalloc-1k object can also end exactly on a page
boundary. This is the leading explanation, not a proven one.

### Bearing on the earlier bare-metal L1VH testing

Bare-metal L1VH/MSHV/QEMU testing without OVS/Geneve would leave checksums to
the NIC, so `__skb_checksum`-over-frags essentially never executes. That testing
therefore **does not exonerate L1VH** — it never exercised this path, and it also
used a different kernel and a different VMM. It is still useful as a negative: it
argues against "any over-read into a neighbouring page is fatal on L1VH", which
would have surfaced broadly in perf work.

## `mshv_root` unload experiment — INCONCLUSIVE

Hypothesis under test: L1VH/MSHV memory donation makes the neighbouring page
inaccessible, so removing `mshv_root` should stop the crashes with the kernel
held constant.

Design was A/B/A on `l7njd` (sender), identical load each time
(`MITIGATE=false STREAMS=64 POLL=10`), `mshv_root` refcount 0 and no VMs on the
node, so it unloaded cleanly:

| Round | `mshv_root` | Duration | Geneve TX | Resets |
|-------|-------------|---------:|----------:|-------:|
| A  (22:03) | loaded   | 600 s  | –        | **3** |
| B  (00:07) | unloaded | 600 s  | ~5.5 TB  | 0 |
| B′ (00:18) | unloaded | 900 s  | ~8.2 TB  | 0 |
| A′ (00:34) | reloaded | 600 s  | –        | **0** |

**The control round A′ also produced zero resets, so the B result is not
attributable to unloading `mshv_root`.** The experiment says nothing about the
L1VH hypothesis, in either direction.

What actually changed is the background state: both nodes entered a stable phase
(`7rn6g` 23:33, `l7njd` 23:38) *before* the test started at 00:07 and stayed up
for over an hour, spanning all three rounds. Earlier the same evening both nodes
were resetting every few minutes with no synthetic load at all.

This matches the historical spread — the 09-03 data has uptimes from **137 s to
60,302 s** — so the crash rate is strongly boot- and time-dependent, and 10-15
minute rounds are badly underpowered. Load alone does not determine the outcome:
rounds B and B′ pushed ~13.7 TB through the Geneve path with zero crashes.

Weak, non-conclusive observations recorded for completeness:

- `MSHV_CREATE_PARTITION` ioctls: 7 in the last crashing boot vs 1 in the current
  stable boot. Suggestive of partition churn correlating with instability, but
  the boots differ in length and this is far from evidence.
- The faulting physical addresses are spread widely — tens of MB to hundreds of
  GB apart, within a boot and across boots. That argues **against** a small fixed
  set of poisoned pages and weakens the simplest "one donated page" story.

**Design lesson:** the A/B/A control is what caught this. A/B alone would have
produced a confident and wrong "unloading `mshv_root` fixes it" claim. Any future
attempt needs runs long enough to cover the observed variance, repetition across
many boots, or a deterministic trigger.

State was restored: `mshv_root` reloaded, `/dev/mshv` present, both nodes
advertising `devices.kubevirt.io/mshv`, virt-handler Running on both, HCO
Available, load namespace removed.

## kdump: no vmcore yet, but a network-independent reproducer of the fault

Goal was a vmcore to inspect the page tables at fault time. kdump is now enabled
on the pool (`make mshv-kdump`, `scripts/16-mshv-kdump.sh`), armed and verified
on both nodes:

```
cmdline_crashkernel=crashkernel=8G,high,crashkernel=256M,low
kexec_crash_size=8858370048   kexec_crash_loaded=1
kdump_enabled=enabled         kdump_active=active
```

**Practical win:** `vmcore-dmesg.txt` is now captured to `/var/crash` on every
panic. The full panic log no longer depends on the Azure serial console, which is
blocked by the managed-RG deny assignment. That removes the evidence-access
problem from the 09-01 and 09-03 reports.

**But `makedumpfile` cannot complete a dump — and why it fails is the finding.**

Validated end to end with `echo c > /proc/sysrq-trigger` (five cycles). The crash
kernel boots and saves the dmesg, then:

| core_collector | Result |
|---|---|
| `makedumpfile -l -d 31` (stock, lzo) | **SIGSEGV**, exit 139, after ~190 MB |
| `makedumpfile -c -d 31` (zlib) | **SIGSEGV**, exit 139 — not the compressor |
| `makedumpfile --non-mmap -c -d 31` | clean **exit 1** with an error message |

`--non-mmap` converting a SIGSEGV into a clean error is itself the clue: with
mmap, touching the offending page kills the process; with `read()`, the kernel
returns an error instead. The error:

```
read_from_vmcore: Can't read the dump memory(/proc/vmcore). Bad address
readpage_elf: Can't read the dump memory(/proc/vmcore).
readmem: type_addr: 1, addr:108c90000, size:4096
read_pfn: Can't get the page data.
makedumpfile Failed.
```

`Bad address` is **EFAULT reading a 4 KiB page of ordinary System RAM**.

Checks done on that address:

- `0x108c90000` (~4.14 GiB) is inside `BIOS-e820 [mem 0x100000000-0xfbfffffff] usable`
  and inside `/proc/iomem` `100000000-fbfffffff : System RAM`. Nothing special.
- It is **not** in either crashkernel reservation
  (`0x1f000000-0x2effffff` low, `0xbeff000000-0xc0feffffff` high), so this is not
  a reservation artifact.
- The failing address **moves between crashes**: `0x108c90000` (~4.1 GiB) on one,
  `0x610a8b0000` (~388 GiB) on the next. It is not one fixed poisoned page.

### What I initially concluded, and why it was wrong

I first read this as a network-independent demonstration that pages of ordinary
System RAM are inaccessible on this host, which would have neatly explained the
`#GP`. **A follow-up probe on the running kernel disproved that** — see the
retraction immediately below. Keeping the reasoning here because the failure mode
is still real and still blocks vmcore capture; only the interpretation changed.

### Caveats — this is not yet proof

- `/proc/vmcore` reads *old* (pre-crash) memory through the crash kernel's own
  mapping. The EFAULT may reflect that mapping rather than a hardware- or
  hypervisor-level inaccessibility. It has **not** been shown that the same page
  is unreadable from a normally running kernel.
- Nothing here ties the unreadable pages to `mshv`/L1VH specifically. There is no
  balloon or hot-plug activity, and `/sys/kernel/debug/mshv/partition` exists but
  was not correlated with the failing addresses.
- **Still no vmcore**, so the page tables and the skb at fault time remain
  uninspected. `makedumpfile` 1.7.8 has no ignore-read-error option, so the
  unreadable page aborts the whole dump.

### Notes for anyone repeating this

- `kdump.sh` expands `$CORE_COLLECTOR` **unquoted**, so an inline
  `/bin/sh -c '...'` wrapper is word-split and fails instantly with exit 2. The
  collector must be a single word; `scripts/16-mshv-kdump.sh` installs a wrapper
  script and pulls it into the initramfs with `extra_bins`.
- The stock collector writes only to `/dev/console`, i.e. the serial console we
  cannot read. The wrapper saves `makedumpfile.log` next to the dump and
  preserves the exit code, which is what made the EFAULT visible at all.
- Raising `crashkernel` from 2 G to 8 G changed nothing; this was never a
  crash-kernel memory problem.

### Attempts to unblock the dump (all failed)

Eight sysrq-triggered crash cycles, one variable at a time:

| # | Change | Result |
|---|---|---|
| 1 | stock `-l -d 31`, `crashkernel=2G` | SIGSEGV, exit 139, ~190 MB |
| 2 | `crashkernel` 2G -> 8G | identical — never a memory problem |
| 3 | `-l` -> `-c` (zlib) | identical — not the compressor |
| 4 | inline `sh -c` collector wrapper | exit 2 instantly — `kdump.sh` word-splits `$CORE_COLLECTOR` |
| 5 | wrapper script + `extra_bins` | error finally captured to disk |
| 6 | `--non-mmap` | SIGSEGV -> clean exit 1 with EFAULT message |
| 7 | `KEXEC_ARGS="-s"` -> `""` (kexec_file_load -> kexec_load) | **0.1-52% -> 75.4%, 1.4 GB** |
| 8 | repeat of 7 | 75%-ish again, same failure |

Attempt 7 is the only one that moved the needle, and it is now the script default:
the two load paths build different elfcorehdr `PT_LOAD` ranges, and the userspace
one describes old memory better on this host.

The remaining failures cluster: `0x910b83d000` (~583 GiB) and `0x9197569000`
(~585 GiB), versus the scattered `0x108c90000` / `0x610a8b0000` seen with
`kexec_file_load`. Both of those regions read fine from the live kernel, so this
still looks like a crash-kernel `/proc/vmcore` limitation rather than bad memory.

`makedumpfile` 1.7.8 has **no option to continue past a read error** (the full
option list has nothing equivalent), so a single unreadable page aborts the
entire dump. That is the hard blocker.

### Next steps from here

- [x] Test whether the direct map is readable from a **running** kernel. **Done**
      — all 201,325,240 pages readable on both nodes; see the retraction above.
- [ ] Determine whether the unreadable pages correspond to memory the hypervisor
      has taken (mshv deposit / child-partition donation).
- [ ] Get a usable vmcore despite the bad page. Untried ideas, in rough order of
      promise: `--split` (per-range children, so one bad range need not kill the
      others), `-e` (exclude unused vmemmap pages, fewer reads), a patched
      `makedumpfile` that skips read errors, or reporting the `/proc/vmcore`
      EFAULT itself as a kdump bug on this platform.
- [ ] Give the kcore probe a **positive control** so a negative result can be
      trusted: construct a known-inaccessible mapped page and confirm the probe
      reports it.
- [ ] Chase *transient* inaccessibility, which the snapshot scans cannot exclude:
      correlate faults with child-partition memory donation/reclaim.
- [ ] Explain `#GP` rather than `#PF`; no current hypothesis does this cleanly.

### RETRACTED: the live direct map is fully readable

**The "network-independent reproducer" claim above is wrong and is retracted.**

`scripts/17-kcore-directmap-probe.py` reads 8 bytes from every 4 KiB page of
System RAM through `/proc/kcore` at `PAGE_OFFSET + phys` (computable only because
`nokaslr` fixes `PAGE_OFFSET`). Run on a **normally running** kernel:

| node | VMs running | pages probed | read failures | node rebooted |
|---|---|---:|---:|---|
| `l7njd` | none | 201,325,240 | **0** | no |
| `7rn6g` | 2 (`vm-pool-fedora-0`, `probe`) | 201,325,240 | **0** | no |

Every page of all 768 GiB is readable on both nodes, including the one hosting
L1VH child partitions. There is **no persistent set of inaccessible System RAM
pages**, so that cannot be the explanation for the `#GP`.

The `makedumpfile` EFAULT is therefore most likely an artifact of the **crash
kernel's** `/proc/vmcore` old-memory mapping, not a property of the hardware or
hypervisor. The fact that the failing address **moved between crashes**
(`0x108c90000`, then `0x610a8b0000`) fits a transient mapping/resource failure in
the constrained crash kernel far better than it fits specific bad pages.

**Methodological caveat, stated plainly:** this probe has **no positive control**.
I did not demonstrate that it *can* detect a mapped-but-inaccessible page. If
`/proc/kcore` reads that region via `copy_from_kernel_nofault`, a fault surfaces
as `EFAULT` and would have been counted; if instead it silently zero-fills, the
probe would report success regardless. "0 failures" is therefore weaker evidence
than the raw number suggests, though the absence of any panic across 402 million
reads is meaningful on its own.

**Also note this is a snapshot.** Each scan took ~4 minutes. A page that is
inaccessible only *transiently* — for example while being donated to or reclaimed
from a child partition — would very likely be missed.

### Where that leaves the `#GP`

Eliminated: the faulting address is canonical (5-level paging), inside `usable`
e820 System RAM, and demonstrably readable on a running kernel. So the panic is
**not** explained by a permanently inaccessible or invalid page.

What survives:

- **Transient inaccessibility** at the moment of the fault — now the leading
  hypothesis, and specifically not excluded by the scans above.
- **A corrupt skb length** (the CVE-2026-74705 direction), with the walk running
  somewhere that faults. This is weakened by the fact that all System RAM reads
  fine, but not eliminated.

Both still have to explain why the fault is `#GP` rather than `#PF`, which no
current hypothesis does cleanly.

## Reproducer defects found and fixed

The first run of the day reported `resets=0` **while the sender was actually
resetting twice**. Three real defects in `scripts/15-mshv-offload-isolation-test.sh`:

1. **Reset detection was blind to resets.** It compared
   `journalctl --list-boots | wc -l` before/after. On a node that has already
   crashed dozens of times, journal rotation vacuums the oldest boot as each new
   one is appended, so the count stayed pinned (observed: 70 before and after)
   and every reset was reported as zero. Now detection reads the kubelet-reported
   `.status.nodeInfo.bootID` and counts boot-ID **changes**, which also removes
   one `oc debug` pod per node per poll.
2. **Load stopped at the first crash.** Both pods used `restartPolicy: Never`, so
   once the sender rebooted the `flood` pod stayed dead
   (`ContainerStatusUnknown`) and the rest of the window measured an **idle**
   cluster. Both pods now use `restartPolicy: Always`, so load resumes after a
   node reboot; `cmd_load` now explicitly deletes them at the end so the load
   cannot outlive the measurement window.
3. **Reruns collided with the previous run.** `clean` deleted the namespace with
   `--wait=false`, and the dead, immutable pods from the prior run blocked
   `oc apply`, so the next run hung on a readiness wait against a corpse. Deploy
   now deletes any stale `sink`/`flood` first, and `clean` waits.

Also: a not-Ready `flood` pod no longer aborts the run (its node may legitimately
be mid-crash), and the result explicitly notes that two resets between polls are
counted once. `tests/mshv-offload-isolation-tests.sh` covers all of this with
mocked `oc`, including the journal-rotation case that previously hid the resets.

**This means the 2026-09-03 "mitigation test — inconclusive" result is worse than
recorded:** that round used the same broken detection and the same
crash-terminated load, so its `resets` numbers cannot be trusted in either
direction. The mitigation experiment must be re-run with the fixed tooling.

## Unchanged NIC / overlay offload state

Re-captured on both nodes with `scripts/14-mshv-nic-offload-capture.sh`; matches
the 09-03 table exactly, including on the brand-new node:

| Interface | `tx-udp_tnl-segmentation` | `tx-gso-list` | `gro` |
|-----------|---------------------------|---------------|-------|
| `eth0` (hv_netvsc) | `off [fixed]` | `off [fixed]` | on |
| `enP30832s1` (MANA VF) | `off [fixed]` | `off [fixed]` | on |
| `br-ex` | on | on | on |
| `genev_sys_6081` | `off [fixed]` | on | on |
| `ovn-k8s-mp0` | on | on | on |

The uplink still cannot offload tunnel segmentation, so overlay egress is
software-segmented in the guest. The MANA VF still floods
`enP30832s1 selects TX queue N, but real number of TX queues is 32`. That warning
remains **correlational only** — it was previously investigated and set aside as
a red herring, and nothing here changes that.

## What is still open

- [x] Fetch the serial console for the four panic windows above and confirm the
      RIP. **Done** — all 217 oopses fault at `csum_partial+0xe5`; see the
      serial-console analysis section, which also **corrects** the 09-03
      non-canonical-pointer claim.
- [ ] Explain why a canonical direct-map read of `usable` RAM raises **#GP**.
- [ ] Establish whether pages adjacent to the faulting buffers are donated to
      L1VH child partitions or otherwise removed from the root partition.
      The `mshv_root` unload experiment was **inconclusive** (see above); redo it
      with runs long enough to cover the 137 s–17 h variance, or find a
      deterministic trigger first.
- [ ] Explain the bimodal behaviour: both nodes reset every few minutes for hours,
      then stay up for over an hour under ~13.7 TB of the exact load that
      previously crashed them. Whatever gates the crash is boot-dependent and is
      probably the shortest path to root cause.
- [ ] Re-run the **mitigation** half with the fixed tooling and a durable
      offload-disable; the 09-03 mitigation result is not trustworthy.
- [ ] Verify whether this kernel carries the CVE-2026-74705
      `__skb_udp_tunnel_segment` fix.
- [ ] Consider enabling `kdump` (MachineConfig + `crashkernel`) to capture a
      vmcore locally instead of depending on Azure serial console. Not done: it
      needs a kernel-argument rollout and node reboots.
- [ ] Report upstream once the RIP is re-confirmed on this kernel.

## Provenance

Evidence under `.checkup-runs/mana-gso-repro-20260908/` (gitignored):
`nokaslr-symbol-map.txt`, `panic-frame-decode-table.txt`, `boot-timeline.txt`,
`run-markers.txt`, `isolation-test-run{,2,3}.log`. NIC captures are the
`nic-offload-*-20260908T2140*.txt` files.

Interventions during this work: ran the load reproducer (which **intentionally**
crashes the sender), and left namespace `ovn-mshv-isolation` in place with its
load pods deleted. The VM workloads on `l7njd` were repeatedly interrupted by
these crashes. No cluster configuration was changed to obtain this result.
