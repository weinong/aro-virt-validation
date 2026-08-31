# 2026-08-31 — MSHV VM boot validation (L1VH kernel refresh + defaultCPUModel)

## Result: PASS

A `hyperv-direct` VM boots and runs stably on the mshv node after refreshing the
L1VH kernel to `6.12.0-211.49.1.1794_2798046552.el10_2` and setting the HCO
`defaultCPUModel`. On the previous kernel (`issues/2026-04-23.md`), every
`hyperv-direct` VM crashed within ~1s. Now the VM reaches `Running` / `Ready` and
stays up.

## What was validated

- **Kernel**: mshv node running `6.12.0-211.49.1.1794_2798046552.el10_2` (bonzini
  L1VH build), `/dev/mshv` + `mshv_root` + "running as L1VH partition" intact.
- **Default CPU model**: `spec.virtualization.virtualMachineOptions.defaultCPUModel:
  Nehalem` on the HCO propagated to KubeVirt `spec.configuration.cpuModel: Nehalem`,
  and was applied to the VM automatically (domain XML:
  `<cpu mode='custom' match='exact' check='full'><model fallback='forbid'>Nehalem</model>`).
- **Smoke VM**: a cirros `VirtualMachineInstance` (no CPU model specified, so it
  inherited the Nehalem default) scheduled onto the mshv node and booted:
  - `phase=Running`, `Ready=True`, stable for >2 minutes.
  - virt-launcher: `qemu version: qemu-kvm-10.1.0-17.el9_8.5`, `libvirt 11.10.0`,
    `kernel: 6.12.0-211.49.1.1794_2798046552.el10_2`, domain event
    `started / detail="booted"`.

### Note: `MSHV_CREATE_PARTITION` dmesg message persists but is now non-fatal

The node still logs `using unsupported MSHV_CREATE_PARTITION ioctl` when a VM is
created, but unlike the old kernel this no longer crashes the guest — the VM
boots and runs. Worth confirming with bonzini/Red Hat whether this warning is
expected/benign on this L1VH build.

## Full validation checkup is blocked by a placement/checkup mismatch (separate issue)

`scripts/08-cnv-validation-checkup.sh` (ocp-virt-validation-checkup) fails in its
`SynchronizedBeforeSuite`:

```
[FAILED] Timed out after 360.001s.
timed out waiting for worker nodes to become schedulable
node aro-virt-test-8gpzs-worker-centralus1-kx9tj is not kubevirt.io/schedulable=true
-> Ran 0 of 1396 Specs
```

Cause: `scripts/07-mshv-hco-patch.sh` pins KubeVirt workloads (incl. virt-handler)
to the mshv role (`spec.deployment.nodePlacements.workload.nodeSelector:
node-role.kubernetes.io/mshv`), so virt-handler only runs on the mshv node and
only that node gets `kubevirt.io/schedulable=true`. The checkup's BeforeSuite
waits for **all** worker-role nodes (the plain `Standard_D8s_v5` ARO workers) to
be KubeVirt-schedulable and times out. This is the same "Ran 0 of N specs"
bogus-pass pattern flagged in `issues/2026-04-23.md`.

Options to run the full suite (not yet decided):
- Build the cluster with only mshv-capable worker nodes (no plain D8 workers), or
  scale the default worker MachineSets to 0 during the checkup, so every
  worker-role node runs virt-handler.
- Relax the mshv-only workload placement (let virt-handler run on all workers);
  `hyperv-direct` VMs still land on mshv nodes because they require `/dev/mshv`.
- Check whether the checkup supports scoping to a node subset.

The single-VM boot test above is the meaningful signal for the kernel + CPU-model
work; the checkup gap is a topology/harness concern to resolve next.
