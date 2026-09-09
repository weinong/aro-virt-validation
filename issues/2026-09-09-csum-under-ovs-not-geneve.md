# 2026-09-09 — The trigger is software checksumming under OVS, not Geneve

> **TL;DR:** Eleven real panics were captured **locally via kdump** (no serial
> console needed) and their call chains disprove the "Geneve/tunnel" framing.
> The invariants across all eleven are `csum_partial`, `__skb_checksum`, and an
> **OVS transmit frame**. `__skb_udp_tunnel_segment` appears in only **8/11**, and
> GSO segmentation in only **9/11**. Three distinct call paths reach the same
> fault, one of which involves **no GSO and no tunnel at all**.
>
> This also explains why the offload/GSO mitigation never worked: one of the
> paths is `skb_checksum_help`, which does not use GSO.
>
> The underlying defect remains **open**.

## How this evidence was obtained

`make mshv-kdump` (`scripts/16-mshv-kdump.sh`) writes `vmcore-dmesg.txt` to
`/var/crash` on every panic, so the full oops and call trace are available on the
node. This removes the dependency on Azure serial boot diagnostics, which is
blocked by the ARO managed-RG deny assignment.

Dumps are copied off with `scripts/16-mshv-kdump.sh collect`, because
node-local `/var/crash` is destroyed when a node is replaced — exactly how the
first real panic dump was lost.

## The three call paths

All eleven panics fault at `csum_partial+0xe5` on an 8-byte read straddling a
4 KiB page boundary, but they arrive there three different ways.

**Path 1 — Geneve tunnel GSO (8/11):**

```
csum_partial <- __skb_checksum <- skb_segment <- tcp_gso_segment
  <- inet_gso_segment <- skb_mac_gso_segment
  <- __skb_udp_tunnel_segment <- skb_udp_tunnel_segment
  <- geneve_xmit_skb [geneve] <- ovs_execute_actions [openvswitch]
```

**Path 2 — OVS upcall GSO, no tunnel (1/11):**

```
csum_partial <- __skb_checksum <- skb_segment <- tcp_gso_segment
  <- inet_gso_segment <- skb_mac_gso_segment <- __skb_gso_segment
  <- queue_gso_packets <- ovs_dp_upcall <- ovs_dp_process_packet
  <- ovs_vport_receive <- internal_dev_xmit [openvswitch]
```

**Path 3 — plain software checksum, no GSO, no tunnel (2/11):**

```
csum_partial <- __skb_checksum <- skb_checksum <- skb_checksum_help
  <- validate_xmit_skb <- sch_direct_xmit <- __dev_queue_xmit
  <- do_execute_actions <- ovs_execute_actions <- ovs_dp_process_packet
  <- ovs_vport_receive <- internal_dev_xmit [openvswitch]
```

## Frame frequency across the 11 panics

| frame | count |
|---|---|
| `csum_partial` | **11/11** |
| `__skb_checksum` | **11/11** |
| any OVS frame (`ovs_*` / `internal_dev_xmit`) | **11/11** |
| `skb_segment` | 9/11 |
| `__skb_gso_segment` / `skb_mac_gso_segment` | 9/11 |
| `__skb_udp_tunnel_segment` (Geneve) | **8/11** |
| `ovs_dp_upcall` / `queue_gso_packets` | 1/11 |

## What this changes

**Corrected characterisation.** The trigger is **software checksumming of skb
payload via `__skb_checksum` on the OVS transmit path**. Geneve is merely the
most common reason the kernel ends up doing that; it is not required. Neither is
GSO segmentation.

The previous framing — "Geneve is the only high-volume producer of software
checksums over page frags" — was too narrow. The correct statement is that the
uplink cannot offload generic checksums:

```
tx-checksum-ip-generic: off [fixed]      (both eth0/hv_netvsc and the MANA VF)
tx-udp_tnl-segmentation: off [fixed]
tx-udp_tnl-csum-segmentation: off [fixed]
```

so **any** packet on the OVS path that needs a generic checksum is checksummed in
software by the guest, and `skb_checksum_help` (path 3) does exactly that with no
tunnel and no GSO involved.

**Why the GSO/offload mitigation could never work.** Disabling
`gso/gro/tso/tx-gso-list` only removes paths 1 and 2. Path 3 has no GSO frame at
all, so the crash survives the mitigation. This retroactively explains the
"mitigation test — inconclusive" result from 2026-09-03: it was aimed at a
mechanism that is not necessary for the fault. A live `nogso` block in this
run reset a node at t=142 s, consistent with that.

## Differential experiment (partial, and the arms do not isolate)

`scripts/18-mshv-fault-differential.sh` interleaves three arms in 10-minute
blocks so the drifting background crash rate cannot be confounded with the arm.
Partial results:

| arm | blocks | resets |
|---|---:|---:|
| `overlay` | 2 | 2 |
| `nogso` | 2 | 1 |
| `hostnet` | 1 | 1 |

**These arms are not clean controls, and the results should not be read as
"every arm crashes equally".** Two design faults:

1. **`hostnet` does not avoid OVS.** On OVN-Kubernetes the uplink `eth0` is
   enslaved to the `br-ex` OVS bridge, so host-network traffic still traverses
   OVS. Path 3 above was captured during the `hostnet` block.
2. **Background overlay traffic never stops.** Cluster components keep generating
   Geneve traffic during every block, so no arm removes the suspect path; it only
   removes *our* contribution to it.

Designing an arm that genuinely avoids OVS is difficult here, because the uplink
itself lives in OVS.

## Interventions during this work

- **MachineHealthCheck was disabled** so crashing nodes reboot in place instead of
  being deleted and recreated. Repeated panics were triggering MHC, which
  destroyed `/var/crash` evidence and prevented the pool from holding two nodes
  long enough to run a block:
  ```sh
  oc patch cluster.aro.openshift.io cluster --type=merge \
    -p '{"spec":{"operatorflags":{"aro.machinehealthcheck.enabled":"false","aro.machinehealthcheck.managed":"false"}}}'
  oc delete machinehealthcheck aro-machinehealthcheck -n openshift-machine-api
  ```
  This is a deliberate, documented change to the cluster and **must be reverted**
  before drawing any conclusion about normal ARO self-healing behaviour. It is
  not a fix for anything.
- kdump remains enabled on the `mshv` pool.
- Node churn from MHC replaced `l7njd` -> `b2h7w` -> `c5mm2` -> `66wzs` before it
  was disabled. That MHC replaces these nodes under sustained panics is itself
  worth noting for production: the failure is disruptive beyond the reboot.

## The page tables were VALID at fault time

`makedumpfile --non-mmap --vtop <addr> /proc/vmcore <scratch>` walks the crashed
kernel's page tables for a single address. It runs in the crash kernel *before*
the full dump, so it still produces an answer when the dump later aborts. Nine
panics produced a successful walk:

| timestamp | fault vaddr | level | entry | P | RW | PS | offset in huge page |
|---|---|---|---|---|---|---|---|
| 06:00:15 | `0xff1100025d6cffff` | PMD | `0x800000025d6001e3` | 1 | 1 | 1 | 851967 / 2 MiB |
| 07:17:15 | `0xff1100920fce7fff` | PUD | `0x80000092000001e3` | 1 | 1 | 1 | 265191423 / 1 GiB |
| 04:22:50 | `0xff110032ce247ffd` | PUD | `0x80000032c00001e3` | 1 | 1 | 1 | 237273085 / 1 GiB |
| 04:56:06 | `0xff110062129f7ffc` | PMD | `0x80000062128001e3` | 1 | 1 | 1 | 2064380 / 2 MiB |
| 04:59:26 | `0xff11006248e7fffc` | PUD | `0x80000062400001e3` | 1 | 1 | 1 | 149422076 / 1 GiB |
| 05:02:40 | `0xff110091970ffffc` | PMD | `0x80000091970001e3` | 1 | 1 | 1 | 1048572 / 2 MiB |
| 06:03:22 | `0xff1100920fb07ffc` | PMD | `0x800000920fa001e3` | 1 | 1 | 1 | 1081340 / 2 MiB |
| 07:13:50 | `0xff11006215d3fffa` | PMD | `0x8000006215c001e3` | 1 | 1 | 1 | 1310714 / 2 MiB |
| 07:21:02 | `0xff110001cc077ffc` | PUD | `0x80000001c00001e3` | 1 | 1 | 1 | 201818108 / 1 GiB |

**Every fault address was Present, Writable, and mapped by a huge page**
(`0x1e3` = P|RW|A|D|PS, plus NX). Translation succeeded in all nine cases.

### This eliminates the guest's paging state as the cause

Three consequences, all measured rather than inferred:

1. **The faulting address was mapped and valid.** A `#GP` cannot be blamed on an
   absent or malformed guest PTE.
2. **The direct map here uses 2 MiB and 1 GiB huge pages.** A single entry covers
   the whole region, so the neighbouring 4 KiB the tail over-read touches is
   mapped *by the same entry*. The "over-read steps into an unmapped page" theory
   is therefore **dead**: within a huge page there is nothing to step into.
3. **No fault landed in the last 4 KiB of its huge page** (0/9), so the over-read
   never crossed a huge-page (or page-table) boundary either.

Combined with the earlier `/proc/kcore` probe — all 201,325,240 pages of System
RAM readable on a live kernel — the guest kernel's memory management is
exonerated.

### The remaining coherent hypothesis

The 4 KiB boundary is meaningless to the guest's page tables here (huge pages),
yet **217/217 faults straddle a 4 KiB boundary**. Something is enforcing 4 KiB
granularity, and it is not the guest.

That points at the hypervisor's second-level address translation, which *is*
4 KiB granular: the guest reads 8 bytes crossing into the next 4 KiB frame, that
frame is not currently backed in the L1VH/MSHV stage-2 mapping, and the resulting
fault surfaces in the guest as `#GP`.

**This is a hypothesis, not a measurement.** It explains the 4 KiB straddle, the
valid guest PTEs, the canonical addresses, the live readability, and why no
guest-side mitigation has worked. It has not been confirmed, and confirming it
needs host-side or hypervisor-level visibility that this cluster does not expose.
It also does not explain why the exception is `#GP` rather than an intercept.

## Still open

- [ ] Why does a **canonical, mapped, live-readable** direct-map address raise
      `#GP` rather than succeeding? Still unexplained; see `2026-09-08b`.
- [ ] Get a usable vmcore. `makedumpfile` still aborts on an unreadable page;
      `--vtop` now runs with `--non-mmap` but has not yet produced a successful
      page-table walk.
- [ ] Find a mitigation that covers path 3. Since the NIC cannot offload generic
      checksums (`off [fixed]`), software checksumming appears unavoidable on this
      platform, which makes a NIC/driver-level fix or a kernel fix necessary.
- [ ] Report upstream with the corrected framing: **software `__skb_checksum` on
      the OVS transmit path**, three call paths, page-straddling tail over-read.
