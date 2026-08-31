# 2026-08-31 — ocp-virt-validation-checkup: "Ran 0 of N specs" from mshv-only virt-handler placement

## Summary

`scripts/08-cnv-validation-checkup.sh` (the ocp-virt-validation-checkup, which
wraps the upstream KubeVirt functional test binary `kubevirt.test`) failed in its
`SynchronizedBeforeSuite` and ran **0 of 1396 specs**:

```
[FAILED] Timed out after 360.001s.
timed out waiting for worker nodes to become schedulable
The function passed to Eventually failed at .../tests/testsuite/kubevirtresource.go:203 with:
  node aro-virt-test-8gpzs-worker-centralus1-kx9tj is not kubevirt.io/schedulable=true
-> Ran 0 of 1396 Specs
```

This is the same bogus "reported pass with 0 specs" trap noted in
`issues/2026-04-23.md`.

## Root cause (from the upstream source)

`tests/testsuite/kubevirtresource.go` selects the node set and waits:

```go
func workerNodes(...) []string {
    // ALL non-control-plane nodes
    nodes := Nodes().List(LabelSelector: "!node-role.kubernetes.io/control-plane")
    ...
}
func WaitForWorkerNodesSchedulable() {
    for _, name := range workerNodes(...) {
        Eventually(...).Should(Equal("true"))  // node.Labels["kubevirt.io/schedulable"] for EVERY node
    } // 360s -> "timed out waiting for worker nodes to become schedulable"
}
```

`kubevirt.io/schedulable=true` is set by **virt-handler** on the nodes it runs on.
`scripts/07-mshv-hco-patch.sh` used to pin virt workloads to the mshv role
(`spec.deployment.nodePlacements.workload.nodeSelector: node-role.kubernetes.io/mshv`),
so virt-handler only ran on the single mshv node. The three plain
`Standard_D8s_v5` ARO workers therefore never became `kubevirt.io/schedulable`,
and the BeforeSuite (which requires **every** non-control-plane node) timed out.

The test binary exposes no node-scoping flag (only suite/storage/focus/skip), so
this cannot be narrowed from the checkup side.

## Fix

The mshv-only workload placement was **redundant**: under the `hyperv-direct`
hypervisor, every virt-launcher pod requests the `devices.kubevirt.io/mshv`
device-plugin resource, which only mshv nodes advertise, so VMs are already
constrained to mshv nodes by scheduling. Verified live: with virt-handler running
on all four workers, a generic VMI still landed on the mshv node and its launcher
requested `devices.kubevirt.io/mshv: 1` (plus the `cpu-model.node.kubevirt.io/Nehalem`
selector from the default CPU model).

`scripts/07-mshv-hco-patch.sh` no longer sets the workload nodePlacement (and
clears it if a previous run set it). virt-handler then runs on all workers, so
all non-control-plane nodes report `kubevirt.io/schedulable=true` and the
BeforeSuite passes, while VMs remain constrained to mshv nodes by the mshv device
requirement.

```
# before: only the mshv node schedulable -> BeforeSuite times out
# after:  all four workers schedulable, VMs still land on the mshv node
oc get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o custom-columns=NAME:.metadata.name,SCHED:.metadata.labels.kubevirt\.io/schedulable
```

## Remaining limitation (topology)

This cluster has a single mshv node plus three plain workers. Even with the
BeforeSuite passing, the checkup is the upstream KubeVirt conformance suite and
assumes a homogeneous, multi-node virt cluster: tests that require a second
VM-capable node (live migration, node placement/anti-affinity) cannot pass with
only one mshv node, and any VM the suite tries to pin to a non-mshv worker will
fail (no `/dev/mshv`). For a fully meaningful checkup run the validation cluster
should use an all-mshv worker pool with 2+ mshv nodes (no plain workers). The
single-VM boot test in `issues/2026-08-31b-mshv-vm-boot-validation.md` remains the
targeted signal for the kernel + CPU-model work.
