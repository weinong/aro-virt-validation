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
clears it if a previous run set it). This makes **gate 1** pass — virt-handler
runs on all workers, so all non-control-plane nodes report
`kubevirt.io/schedulable=true`.

## The BeforeSuite has a SECOND, contradictory gate

After gate 1 passes, `EnsureHypervisorPresent()` (`fixture.go`) fails within 120s:

```
Both mshv and vhost-net devices are required for testing, but are not present on cluster nodes
```

```go
for _, pod := range virtHandlerPods {          // every node running virt-handler
    node := Nodes().Get(pod.Spec.NodeName)
    ready = ready && node.Allocatable["devices.kubevirt.io/mshv"]     > 0
                  && node.Allocatable["devices.kubevirt.io/vhost-net"] > 0
}
```

So gate 2 requires **every virt-handler node** to advertise the mshv + vhost-net
devices. The plain D8 workers advertise `devices.kubevirt.io/mshv: 0` (no L1VH
kernel, no `/dev/mshv`), so once virt-handler runs there (needed for gate 1),
gate 2 fails.

### The two gates are contradictory unless every worker is MSHV-capable

- **Gate 1** (`WaitForWorkerNodesSchedulable`): virt-handler must run on **every**
  non-control-plane node.
- **Gate 2** (`EnsureHypervisorPresent`): **every** node running virt-handler must
  advertise `devices.kubevirt.io/mshv > 0`.

Together: **every non-control-plane (worker) node must be MSHV-capable** (L1VH
kernel + `/dev/mshv`). This heterogeneous cluster (1 mshv D192 + 3 plain D8
workers) cannot satisfy both, regardless of workload placement — pinning
virt-handler to mshv fails gate 1; running it everywhere fails gate 2.

Live evidence:

```
mshv node:    devices.kubevirt.io/mshv=1k  vhost-net=1k
plain worker: devices.kubevirt.io/mshv=0
```

## What it takes to actually run the checkup (topology)

The ocp-virt-validation-checkup is the upstream KubeVirt conformance suite and
requires a homogeneous virt cluster. To run it against MSHV, **all worker nodes
must be mshv nodes** — no plain/infra workers. Even a realistic "infra workers +
mshv workers" split fails (the infra workers have no mshv device). Options:

1. Provision the validation cluster with an all-mshv worker pool (2+ mshv nodes,
   no default D8 workers) so both gates pass and multi-node tests (live
   migration, placement) have somewhere to run. This is the correct topology.
2. Scale the default worker MachineSets to 0 so the mshv node is the only worker
   (consolidates registry/ingress/monitoring onto the mshv node + control plane;
   watch ingress/registry replica anti-affinity and ARO worker minimums). This
   lets the compute suite run but leaves a single VM node, so migration/multi-node
   specs still can't pass.

Keeping `scripts/07` free of the mshv-only placement is still correct (the mshv
device constraint keeps VMs on mshv nodes, and it satisfies gate 1); the
remaining blocker is purely the presence of non-mshv worker nodes. The single-VM
boot test in `issues/2026-08-31b-mshv-vm-boot-validation.md` remains the targeted
signal for the kernel + CPU-model work.
