# 2026-09-09 — Matched-pair test: the panic is L1VH-specific, not kernel-specific

> **ROOT CAUSE FOUND — see `issues/2026-09-09d-ROOT-CAUSE-deposited-page-overread.md`.**
> The `#GP` is `csum_partial`'s 8-byte tail over-read crossing a 4 KiB page
> boundary into a page deposited to the hypervisor via `HVCALL_DEPOSIT_MEMORY`
> and still owned by it. Confirmed 3/3 against a complete-from-boot deposit
> ledger (p ~ 6e-13 by chance).


> **TL;DR:** With a **single variable changed** — the Azure L1VH host-feature tag —
> the same kernel, same VM size and same MachineConfig either panics within
> minutes or survives indefinitely. L1VH nodes crashed **4/4 runs**, the fastest
> after only **3.3 GiB**. The non-L1VH control pushed **8,024 GiB** (~2,400x more)
> across 3 runs with **zero** faults.
>
> This also **kills the volume hypothesis**: it is not "enough bytes through the
> software-checksum path", because the control moved thousands of times more.

## The control node

The comparison is only worth anything because the control is a near-clone. It was
created by copying the `mshv` MachineSet and removing exactly one thing:

```sh
# aro-virt-test-8gpzs-worker-nol1vh-centralus1
tags:  platformsettings.host_environment.nodefeatures.hierarchicalvirtualizationv1: "True"   # REMOVED
labels: node-role.kubernetes.io/mshv: ""    # KEPT, so it joins the same MachineConfigPool
```

Keeping the `mshv` node-role means it lands in the same pool and therefore
receives the identical custom kernel, `nokaslr`, and kdump configuration.
Verified on the node itself:

| property | mshv node (`66wzs`) | control (`g8n4k`) |
|---|---|---|
| kernel | `6.12.0-211.49.1.1794_2798046552.el10_2` | **identical** |
| VM size | `Standard_D192ds_v6`, 192 vCPU | **identical** |
| memory | 747 GiB | **identical** |
| `nokaslr` | yes | yes |
| `crashkernel` | `8G,high` | `8G,high` |
| **L1VH partition** | **yes** | **no** |
| **`mshv_root` loaded** | **yes** | **no** |
| **`/dev/mshv`** | **yes** | **no** |

## Result

| node | L1VH | runs | crashed | traffic before crash / total pushed |
|---|---|---:|---:|---|
| `66wzs` | **yes** | 4 | **4** | crashed after as little as **3.3 GiB** |
| `g8n4k` | no | 3 | **0** | **8,024 GiB** with no fault |

Crash times on the L1VH node: 151 s, 151 s, 64 s, 162 s. The control ran a full
900 s at 64 streams (7,588 GiB) and a 60 s burst (435 GiB) without incident.

**Ratio: the control absorbed ~2,400x more traffic through the identical code
path, on the identical kernel, and never faulted.**

## What this establishes

- **Not a generic kernel bug.** The same kernel build is fine without L1VH.
- **Not volume-driven.** 3.3 GiB kills an L1VH node; 8 TiB does nothing to the
  control. Any threshold model has to explain a 2,400x gap.
- **Not OVS, Geneve, overlay, CNV or the physical NIC** — none are in the veth
  reproducer's path at all.
- The variable that matters is **the L1VH platform**: running as a Hyper-V L1VH
  partition with `mshv_root` loaded.

## Caveats

- One node per arm. The arms differ in hardware placement, and I have not ruled
  out a difference in the *host* each VM landed on.
- The control also lacks `mshv_root`, so "L1VH partition" and "mshv_root loaded"
  are not separated by this experiment. The next refinement is a node with the
  L1VH tag but `mshv_root` blacklisted.
- The `#GP` on a **present, writable, huge-page-mapped** address is still
  unexplained; this narrows *where* to look, not *why* it happens.

## Tooling notes (why these numbers are trustworthy)

Earlier negatives in this investigation were worthless because the load silently
never ran. The harness now refuses to produce a quiet result it cannot back up:

- **Preflight**: the run aborts with `SETUP_FAILED` unless it first moves >1 MiB.
- **On-node durable telemetry**: samples are written with `dd conv=fsync`, so
  they survive the panic; plain appends were lost entirely (XFS journals the
  metadata, not the data).
- **Per-run netns/interface names**: a panic leaves `/var/run/netns/<name>` as a
  stale bind mount that `ip netns del` cannot remove, and the orphaned veth kept
  the test IP, so later runs silently moved zero bytes.
- **Crash detection covers both modes**: a boot-ID change *and* a node that stops
  reporting Ready without rebooting (with kdump enabled the crash kernel can sit
  writing a dump for minutes).
- **Analysis is offline** (`scripts/20-analyze-stress-runs.py`) over raw on-disk
  data, with fixture tests, so a parsing bug costs seconds instead of a 15-minute
  re-run. It reports runs as `MEANINGFUL`, `NO TRAFFIC: void` or `SETUP FAILED`
  so a negative can never be mistaken for evidence.

## Next

Instrumented kernel RPMs that log MSHV page donation/return are being layered
onto the `mshv` pool to test the leading hypothesis: that pages donated to MSHV
for a VM are mishandled when returned to the Linux kernel after teardown.
