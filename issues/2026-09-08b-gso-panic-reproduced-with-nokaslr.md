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
