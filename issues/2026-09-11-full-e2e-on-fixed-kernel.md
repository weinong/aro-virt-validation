# 2026-09-11 — Full KubeVirt e2e on the fixed (`mgns2`) kernel

**Headline: zero kernel panics across a 14-hour run with 444 specs executed.**
The `csum_partial` `#GP` that previously killed this node within minutes of real
VM traffic did not occur once. The remaining failures are functional MSHV/CNV
gaps, not crashes.

Kernel: `6.12.0-211.49.1.1794_2798046552.mgns2.el10` (direct-map fix, see
[`2026-09-10-mgns2-fix-verified.md`](2026-09-10-mgns2-fix-verified.md)).
Run: `.checkup-runs/20260910-161451/`, job `ocp-virt-validation-job-20260910-161451`.

## Node stability — the thing we were testing

| node | uptime at end | boots | `#GP` / `csum_partial` / panic |
|---|---|---|---|
| `...mshv-centralus1-66wzs` | **67,583 s (18.8 h)** | 35 | **0** |
| `...mshv-centralus1-9tc2v` | **61,883 s (17.2 h)** | 4 | **0** |

Both uptimes span the entire 14-hour suite. For contrast, on `mgns1` the veth
reproducer panicked this same node in ~4 seconds, and ordinary cluster traffic
(a Thanos pod) killed it spontaneously within tens of minutes.

## Results

The suite is the upstream KubeVirt conformance suite. Counts below are parsed
from the job log because **the harness never wrote junit files** (see below).

| suite | passed | failed | specs planned |
|---|---|---|---|
| compute | 128 | 161 | 770 |
| network | **0** | **0** | 152 (never ran) |
| storage | 87 | 68 | — |
| **total** | **215** | **229** | |

Top failure sites:

```
 55  migration/migration.go        20  storage/restore.go
 18  virtctl/guestfs.go            15  compute/cpu.go
 14  libwait/wait.go               14  storage/storage.go
 12  virtiofs/containerpath.go      6  libvmops/run.go
```

66 failures involved a guest console login timeout (`LoginToAlpine` /
`LoginToFedora`) — the VM starts but never reaches a usable prompt.

### At least some guest failures are a GVA→GPA translation fault

A failed test VMI's `virt-launcher` shows:

```
qemu-kvm: Failed to translate gva (ff7a0e6540091008) to gpa
qemu-kvm: failed to translate gva to gpa
qemu-kvm: failed to write memory
```

The same signature appeared in `issues/2026-07-23.md` in an EFI context, so this
is a pre-existing MSHV issue area, now reproduced under BIOS guests at volume.
**Unresolved** — this is the most valuable lead from the run.

## The harness could not produce official results

```
junit file "/results/compute/junit.results.xml" does not exist
junit file "/results/storage/junit.results.xml" does not exist
ERROR: No tests were executed. One or more test suites failed during setup.
Suite "compute" failed during setup (no tests were executed)
```

This verdict is **wrong but explainable**, and the causal chain matters:

1. The compute suite ran 289 specs, then hung in its `AfterSuite`:
   `testCleanup()` → `CleanNamespaces()` → `deleteEventsFromNamespace()`,
   timing out (90 s and 360 s async assertions) and dumping goroutines.
2. Because the suite died there, `junit.results.xml` was never written.
3. Cleanup having failed, the test namespaces survived, so the **network**
   suite's `SynchronizedBeforeSuite` failed instantly with
   `namespaces "kubevirt-test-default1" already exists` → 0 of 152 specs.
4. With no junit anywhere, the checkup wrapper concluded "no tests were
   executed" and skipped creating its results ConfigMap.

So the official checkup output says nothing ran, while 444 specs demonstrably
did. Any future run needs the namespace-cleanup hang addressed first, or the
results are unreportable regardless of how the tests themselves go.

## Topology required to get here

The checkup needs an **all-mshv worker pool**; plain workers fail the
`EnsureHypervisorPresent()` gate with "Both mshv and vhost-net devices are
required for testing, but are not present on cluster nodes". This was already
documented in `2026-08-31c-checkup-node-schedulable.md`, and I re-broke it during
cleanup by restoring the ARO-default worker topology before re-reading that note.

Final topology, which cleared the gate (`SynchronizedBeforeSuite` PASSED in
4.6 s):

* 3 masters
* **2** `Standard_D192ds_v6` mshv nodes, both on `mgns2`, both advertising
  `devices.kubevirt.io/mshv: 1k` and `vhost-net: 1k`
* **0** plain workers (scaled to 0; registry/ingress/monitoring consolidated onto
  the mshv nodes)

Two mshv nodes fit exactly in the `Standard Ddsv6` quota (384 vCPU limit,
192 used per node) and give the migration specs somewhere to go.

## Cluster state restored before the run

Reverted: `99-mshv-deposit-trace`, `99-mshv-kdump`, `99-mshv-nokaslr`
MachineConfigs; MachineHealthCheck reconciliation re-enabled
(`aro.machinehealthcheck.enabled/managed=true`); on-node debris removed
(`/var/log/csumstress`, `/var/log/mshv-deposit`, 4.7 GB of `/var/crash`, stress
netns, ftrace kprobes/instances); stale `kubevirt-test-*` and `console-latency`
namespaces deleted.

Deliberately kept:

* `99-mshv-kernel-osimage` — the `mgns2` layer under test.
* `99-mshv-load-mshv-root` — required for MSHV.
* HCO jsonpatch from `scripts/07` (`ConfigurableHypervisor`, `hyperv-direct`,
  `evictionStrategy: None`) — required for MSHV; it is why HCO reports
  `TaintedConfiguration=True`.
* `aro.machineset.enabled=false` — per `AGENTS.md`, so ARO does not revert the
  custom MSHV MachineSets.
* `99-openshift-machineconfig-worker-psi-karg` — owned by
  `virt-platform-autopilot` (CNV), not ours.

## Caveats

* **`evictionStrategy: None` is set**, which plausibly contributes to the 55
  migration failures. The migration numbers should not be read as a clean
  signal until that interaction is understood.
* **Counts are log-derived, not junit.** They count ginkgo `•` and
  `[FAILED] in [It]` markers; treat them as close, not authoritative.
* **No baseline comparison exists.** This is the first run in this repo to
  execute specs at all, so there is no "expected" pass rate for MSHV to compare
  against — the 215/229 split cannot yet be split into regressions vs known gaps.
* **The run does not prove the fault is impossible**, only that it did not occur
  in 14 hours under this workload.
* Non-crash cluster noise seen during the run: a
  `capz-controller-manager` pod in `CreateContainerConfigError`, unrelated to CNV.
