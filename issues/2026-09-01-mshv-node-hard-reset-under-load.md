# 2026-09-01 — MSHV/L1VH node hard-resets under KubeVirt conformance load (no in-guest panic)

## Summary

Under sustained OpenShift Virtualization workload (the ocp-virt-validation-checkup
compute suite rapidly creating/destroying `hyperv-direct` VMs), the MSHV node
`aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw` (`Standard_D192ds_v6`,
running the bonzini L1VH kernel `6.12.0-211.49.1.1794_2798046552.el10_2`)
**hard-resets repeatedly** — roughly every 4–30 minutes. This presents at the
cluster level as the node flapping `Ready=Unknown`; on the node it is an actual
reboot (`uptime` resets, new boot IDs).

The single-VM smoke test (`issues/2026-08-31b`) was stable; only **sustained
multi-VM load** triggers the resets. The second MSHV node (`l7njd`) stayed up for
90+ minutes because the checkup's test VMs were scheduled onto `bl5zw`.

## The reset comes from below the guest kernel (Hyper-V host), not a kernel panic

Evidence that this is a host/hypervisor-level reset of the L1VH partition, not an
in-guest crash:

- **No kernel panic / oops / soft-lockup / Call Trace** anywhere before each reset.
  Every boot's last log lines are ordinary VM network activity, then the log ends
  abruptly with no shutdown sequence.
- `sysctl kernel.panic_on_oops = 1`, `kernel.panic = 10` — a real oops/panic would
  **print a stack trace and delay 10s** before rebooting. The abrupt end with no
  trace and no 10s delay rules out an in-guest panic.
- `RuntimeWatchdogUSec = 0` and no `/dev/watchdog*` device — **not** a
  software/hardware watchdog reset either.
- The node boots as `Hyper-V: running as L1VH partition` (Azure Hyper-V,
  `Host Build 10.0.26102.3641`). With no guest panic and no watchdog, the reset
  originates from the Hyper-V host / L1 hypervisor resetting the L1VH partition
  when its MSHV (L2) guests run under load.

### Crash cadence (boot end = reset time), correlated with VM load

```
-6  2026-08-31 20:14 -> 23:20   (stable 3h — BEFORE the checkup created VMs here)
-5  2026-08-31 23:21 -> 23:33   (~12 min)
-4  2026-08-31 23:34 -> 23:43   (~9 min)
-3  2026-08-31 23:44 -> 23:48   (~4 min)
-2  2026-08-31 23:49 -> 00:20   (~31 min)
-1  2026-09-01 00:21 -> 00:33   (~12 min)
 0  2026-09-01 00:34 -> ...
```

The resets began at 23:20, exactly when the checkup started scheduling
`hyperv-direct` test VMs onto `bl5zw`. Each boot ends during heavy VM traffic.

### Node facts

- Kernel: `6.12.0-211.49.1.1794_2798046552.el10_2` (bonzini L1VH), RHCOS 10.2.
- `Hyper-V: running as L1VH partition`, `Nested features: 0x0`,
  `Hyper-V: Disabling IBT because of Hyper-V bug`, `Host Build 10.0.26102.3641`.
- VM size `Standard_D192ds_v6` (192 vCPUs, ~755 GiB). Load/memory were low at
  reset time (load ~1.3, 15 GiB/755 used) — not resource exhaustion.
- The stock `using unsupported MSHV_CREATE_PARTITION ioctl` message is present on
  each VM start (benign for a single VM per `issues/2026-08-31b`, but every VM
  creation exercises this path).

### Possibly-related network warnings

Immediately before each reset the kernel floods (rate-limited, 1000+ suppressed):

```
enP30832s1 selects TX queue 172, but real number of TX queues is 32
```

`enP30832s1` is the Azure accelerated-networking VF. The node has 192 CPUs but the
NIC exposes 32 TX queues, so per-CPU queue selection picks indices > 31. This is a
symptom of heavy VM network traffic and may or may not be involved in the host
reset; worth flagging to the kernel/MSHV team as a correlated signal.

## Impact

- **Invalidates the validation checkup**: when `bl5zw` resets, its test VMs die,
  so compute specs fail with `skipping vmi ...: phase is not Running` and retry
  (`flake-attempts=3`). Results are dominated by node-reset fallout rather than
  clean pass/fail. Az `run-command`/boot-diagnostics are blocked by the ARO deny
  assignment, so host-side reset logs require Red Hat SRE / Azure host access.
- This is a **platform/L1VH stability issue under load**, not a repo or cluster
  misconfiguration.

## Diagnosis commands

```sh
oc debug node/<mshv-node> -- chroot /host bash -c '
  uptime; journalctl --list-boots --no-pager | tail -8
  sysctl kernel.panic_on_oops kernel.panic; cat /proc/sys/kernel/... 
  journalctl -b -1 --no-pager | grep -iE "panic|Oops|lockup|Call Trace|shutdown" | tail
  journalctl -b -1 --no-pager | tail -20   # ends abruptly, no panic/shutdown
  dmesg | grep -iE "L1VH|Hyper-V|Host Build"'
```

## Next steps

- Report to bonzini / Red Hat MSHV + kernel team: the Azure Hyper-V host resets
  the L1VH partition when its MSHV guests run under sustained load, with no
  in-guest panic. Provide the crash cadence, the "no panic / no watchdog" ruling,
  the host build (`10.0.26102.3641`), and the L1VH kernel NVR.
- Ask Red Hat SRE for host-side (Hyper-V) reset logs / dumps for `bl5zw`, since
  ARO denies tenant access to VM run-command and boot diagnostics.
- Investigate whether the accelerated-NIC TX-queue mismatch (192 CPU vs 32 queues)
  is a contributing trigger; test with accelerated networking disabled or a
  smaller SKU as a bisection.
- The checkup cannot produce a clean full-suite result until the node stops
  resetting; the single-VM boot test remains the stable signal for the kernel +
  CPU-model work.
