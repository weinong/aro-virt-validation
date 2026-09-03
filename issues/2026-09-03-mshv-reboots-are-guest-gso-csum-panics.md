# 2026-09-03 — MSHV/L1VH node reboots are a guest kernel GSO/checksum panic (`csum_partial` GPF), not a silent host reset

> **TL;DR:** The repeated MSHV/L1VH worker reboots under OpenShift Virtualization
> load are a **reproducible guest kernel panic**, not an invisible Azure
> Hyper-V host hard-reset. Azure boot-diagnostics **serial-console** logs (which
> capture kmsg that never reached journald) show every reboot is preceded by an
> identical **general-protection fault at `csum_partial+0xe5/0x110`**, taken
> while software-checksumming a **GSO segment of a Geneve(UDP-tunnel)-encapsulated
> TCP packet** on the OVS transmit path, ending in
> `Kernel panic - not syncing: Fatal exception in interrupt` → `Rebooting in 10 seconds`.
>
> This **supersedes** the "uniquely faulty host / silent hard-reset" framing in
> `issues/2026-09-01-mshv-node-hard-reset-under-load.md` and
> `issues/2026-09-01b-mshv-vm-crash-under-checkup-load.md`. The reset is a guest
> kernel crash in the networking stack; the underlying node-reset issue remains
> **open** (root cause not yet fixed, not yet reported upstream).

## Affected nodes / environment

| Field | Value |
|-------|-------|
| Cluster | `aro-virt-test` (ARO Classic), RG `aro-virt-test-rg-o98l`, `centralus` |
| Subscription | `L1VH Virt Testing` (`2ad02bfb-c56e-4a34-b46a-b3eaa246d0f3`), tenant `93b21e64-…` |
| Managed (node) RG | `aro-wa2fvt52` |
| Nodes | `aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw`, `…-l7njd` |
| VM size | `Standard_D192ds_v6` (192 vCPU, ~755 GiB) |
| Node label | `node-role.kubernetes.io/worker`, MSHV/L1VH MachineSet `…-worker-mshv-centralus1` |
| Kernel | `6.12.0-211.49.1.1794_2798046552.el10_2.x86_64` (bonzini L1VH) |
| OS | RHCOS 10.2.20260630-0 (Coughlan) |
| Host BIOS | `Hyper-V UEFI Release v4.1 04/22/2026` |
| NIC | Azure MANA (`mana`, `mana_ib`) + `hv_netvsc` synthetic failover |
| Overlay | OVN-Kubernetes Geneve (`geneve`, `udp_tunnel`, `ip6_udp_tunnel`) over OVS |

VM resource IDs:

```
/subscriptions/2ad02bfb-c56e-4a34-b46a-b3eaa246d0f3/resourceGroups/aro-wa2fvt52/providers/Microsoft.Compute/virtualMachines/aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw
/subscriptions/2ad02bfb-c56e-4a34-b46a-b3eaa246d0f3/resourceGroups/aro-wa2fvt52/providers/Microsoft.Compute/virtualMachines/aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd
```

## Evidence and how it was obtained

The prior investigation was journal-based and concluded "abrupt reset, no clean
shutdown, no in-guest panic." That was an artifact of **where** the crash prints:
the panic is a `Fatal exception in interrupt`, so the kernel dies in IRQ context
and never flushes to persistent journald — kmsg only reaches the **emulated
serial console**, captured by Azure boot diagnostics.

Serial-console logs were downloaded for both nodes and analyzed with
`scripts/13-serial-log-panic-analysis.sh`:

```
SUMMARY (bl5zw): kernel_boots=7   gpf_oops=6    panics=6    reboots=6
SUMMARY (l7njd): kernel_boots=76  gpf_oops=79   panics=75   reboots=71
```

Every panic in both files faults at the **exact same instruction**
`RIP: 0010:csum_partial+0xe5/0x110`, and every fault address is a **non-canonical**
pointer of the form `0xff..7ff?` / `0xff..fff?` (top bits not sign-extended → GPF),
clustered just under a `…8000` boundary — i.e. the checksum routine walked off the
end of a corrupted skb buffer. l7njd panic cadence: min 137 s / median ~1185 s /
max 60302 s of uptime — matching the "every few minutes to ~an hour under load"
observation.

## The signature (identical on every event, both nodes)

```
Oops: general protection fault, maybe for address 0xff20753120d77fff: 0000 [#1] SMP NOPTI
CPU: 18 UID: 0 PID: 0 Comm: swapper/18 Tainted: G  ------ h---  6.12.0-211.49.1.1794_2798046552.el10_2.x86_64
Hardware name: Microsoft Corporation Virtual Machine/Virtual Machine, BIOS Hyper-V UEFI Release v4.1 04/22/2026
RIP: 0010:csum_partial+0xe5/0x110
RAX: ff20753120d77fff  RSI: 0000000000000038  RDI: ff20753120d77b5f   <- summing 0x38 bytes from a bad ptr
Call Trace:
 <IRQ>
 __skb_checksum+0x184/0x330
 skb_segment+0x667/0xf50
 tcp_gso_segment+0xe9/0x4e0
 inet_gso_segment+0x149/0x3c0
 skb_mac_gso_segment+0xaa/0x120
 __skb_udp_tunnel_segment+0x1ba/0x560       <- Geneve/UDP tunnel GSO
 skb_udp_tunnel_segment+0x70/0xc0
 __skb_gso_segment+0x78/0x170
 validate_xmit_skb+0x142/0x280
 sch_direct_xmit+0x17c/0x360
 __dev_queue_xmit+0x43d/0x7f0
 ...ovs_execute_actions / ovs_dp_process_packet [openvswitch]...
 ip_finish_output2+0x23d/0x530
 iptunnel_xmit+0x194/0x240
 geneve_xmit_skb+0x3f2/0x820 [geneve]        <- egress into the overlay
 geneve_xmit+0xa9/0x123 [geneve]
 ...ovs_execute_actions / ovs_dp_process_packet [openvswitch]...
 netdev_frame_hook+0x1f/0x30 [openvswitch]   <- packet was RECEIVED via OVS
 __netif_receive_skb_core / process_backlog / __napi_poll / net_rx_action
 handle_softirqs / __irq_exit_rcu / common_interrupt
 </IRQ>
Kernel panic - not syncing: Fatal exception in interrupt
Rebooting in 10 seconds..
```

### What the call chain says
1. A packet is **received** through OVS on the NAPI/softirq backlog
   (`<IRQ>` … `process_backlog` … `netdev_frame_hook [openvswitch]`).
2. OVS actions **re-transmit** it into the **Geneve overlay**
   (`geneve_xmit_skb`), which requires **GSO segmentation** of the encapsulated
   TCP (`skb_udp_tunnel_segment` → `tcp_gso_segment` → `skb_segment`).
3. Segmentation does a **software checksum** (`__skb_checksum` → `csum_partial`)
   over an skb whose buffer pointer/length is corrupt → reads a non-canonical
   address → **general protection fault** in interrupt context → panic → reboot.

This is the **GRO-receive → re-segment-on-overlay-egress** path. It correlates
directly with the earlier observation that the only load dimension distinguishing
`bl5zw` (which crashed most) was **Geneve overlay packet rate (~14×)** — because
the crash *is* in the Geneve GSO/checksum path.

## Per-node panic tables

Regenerate with:

```sh
./scripts/13-serial-log-panic-analysis.sh \
  ~/Downloads/aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw.txt \
  ~/Downloads/aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd.txt
```

`bl5zw` (6 panics, all `geneve+gso+csum`):

```
PANIC | UPTIME(s)    | FAULT ADDRESS        | CONTEXT              | CALL CHAIN
1     | 11204.504461 | 0xff20753120d77fff   | CPU 18  swapper/18   | geneve+gso+csum
2     | 759.120378   | 0xff272c0d8bfdfff9   | CPU 104 kube-rbac-proxy | geneve+gso+csum
3     | 579.146537   | 0xff2e3308d8937fff   | CPU 78  kube-rbac-proxy | geneve+gso+csum
4     | 279.205257   | 0xff344de84ef97fff   | CPU 116 kube-rbac-proxy | geneve+gso+csum
5     | 1899.192483  | 0xff13f333d3157ffa   | CPU 94  kube-rbac-proxy | geneve+gso+csum
6     | 759.200820   | 0xff454935d8f6ffff   | CPU 14  kube-rbac-proxy | geneve+gso+csum
```

`l7njd` (75 panics; first rows shown — all `geneve+gso+csum`):

```
PANIC | UPTIME(s)    | FAULT ADDRESS        | CONTEXT           | CALL CHAIN
1     | 60302.334863 | 0xff27963c7d5f7ffd   | CPU 13  swapper/13 | geneve+gso+csum
2     | 230.021812   | 0xff209550930afffb   | CPU 107 opm        | geneve+gso+csum
3     | 818.090302   | 0xff390750bbff7ffc   | CPU 29  swapper/29 | geneve+gso+csum
...   | ...          | ...                  | ...                | geneve+gso+csum
```

The faulting `Comm` varies (`swapper/N`, `kube-rbac-proxy`, `opm`, `thanos`) —
expected, since the crash is in a softirq that runs on whatever task was current;
it is **not** specific to any one workload.

## Why the previous "silent host reset" reading happened

- `Kernel panic - not syncing: Fatal exception in interrupt` → the box cannot do
  an orderly shutdown or flush journald; the only record is on the serial console.
- `panic_timeout` prints `Rebooting in 10 seconds..` then resets — to journald
  this looks identical to a host-initiated hard reset (uptime resets, new boot ID,
  no clean shutdown).
- `prometheus-k8s-0` running on `l7njd` was itself taken down by the resets, so
  `changes(node_boot_time_seconds)` under-counted (already noted in the 09-01 docs).

## Root-cause direction (hypothesis — not yet proven)

A kernel networking defect in **GSO segmentation + software checksum of
Geneve/UDP-tunnel-encapsulated TCP** on this RHCOS `el10_2` 6.12 L1VH kernel: an
skb with a bad length/fragment is handed to `csum_partial`, which then reads a
non-canonical address. The Azure **MANA** accelerated-NIC offload/GRO behavior is
a strong candidate trigger (recall the earlier `enP…s1 selects TX queue 172, real
number is 32` MANA warnings). Whether the corruption originates in MANA GRO, in
the tunnel-GSO resegmentation, or in their interaction is the open question.

## Next steps

- [ ] `scripts/14-mshv-nic-offload-capture.sh` — capture live NIC offload flags
      (`ethtool -k` on the MANA uplink + OVS bridge), `ip -d link`, OVN Geneve
      config, `ethtool -S`, kernel version, on both MSHV nodes. **(3b)**
- [ ] `scripts/15-mshv-offload-isolation-test.sh` — **diagnostic intervention,
      not a fix:** disable TX/GSO/GRO and tunnel-segmentation offload on the
      uplink of one MSHV node, drive checkup load, and observe whether the panics
      stop. Explicitly reverted afterward; the underlying kernel bug stays open. **(3c)**
- [ ] Upstream-bug search (kernel.org / RHEL / lore.kernel.org) for
      `csum_partial` GPF in `skb_segment` / `skb_udp_tunnel_segment` GSO on
      6.12/el10; feed results into a CNV/RHCOS kernel bug report. **(3d)**
- [ ] Report upstream once the offload-isolation result and upstream-bug search
      give concrete, reproducible data.

## Provenance

- Serial logs: Azure boot-diagnostics serial console for both VMs, downloaded to
  `~/Downloads/aro-virt-test-8gpzs-worker-mshv-centralus1-{bl5zw,l7njd}.txt`
  (retrieved 2026-09-03).
- Analysis tool: `scripts/13-serial-log-panic-analysis.sh` (offline, read-only).
