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
> Serial-console logs for the new panic windows are **still required** to confirm
> the faulting instruction and fault addresses; nothing here re-confirms the
> `csum_partial` signature on its own. The underlying kernel defect remains
> **open and unfixed**.

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

- [ ] Fetch the serial console for the four panic windows above and confirm the
      RIP equals `0xffffffff81e8cc05` (`csum_partial+0xe5`) using the decode table.
      **Owner: user is re-fetching boot diagnostics.**
- [ ] Compare the non-canonical fault addresses across panics now that they are
      comparable, to test whether they derive from a stable kernel address.
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
