# 2026-05-09 — A/B isolation: upstream KubeVirt v1.8.2 vs CNV 4.99 nightly on the same RHCOS 10 mshv node

## Goal

Determine whether the QEMU `invalid intercept access type: execute` /
`failed to handle mmio` / `Failed to run on vcpu 0` crash documented in
`issues/2026-05-09.md` originates from:

- The OpenShift Virtualization (CNV 4.99 nightly) packaging — i.e. its
  specific virt-launcher / libvirt / qemu-kvm builds, its HCO defaults,
  the auto-applied `host-model` CPU expansion — or
- The MSHV stack on this Azure L1VH host — `mshv_root.ko` reporting an
  unvalidated Hyper-V version, the `MSHV_CREATE_PARTITION` ioctl path,
  the host kernel/firmware combination.

Approach: keep the same RHCOS 10 mshv MachineConfigPool, the same
mshv node (`weinongw-9i76-kqbm6-worker-mshv-centralus1-jgt9n`), the same
TechPreviewNoUpgrade FeatureGate, the same `/dev/mshv` device,
the same `mshv_root` kernel module — and swap the userspace operator
stack from CNV to **upstream community KubeVirt v1.8.2** (no HCO,
no CDI, no SSP, no virt-operator-rhel9 image — just the upstream
`quay.io/kubevirt/*:v1.8.2` images).

Per `AGENTS.md`, this is a diagnostic isolation, not a path forward
for production validation. No workaround was applied to the original
crash.

## TL;DR

The crash is **not exclusive to OpenShift Virtualization**, but the
two stacks fail at *different layers*:

| Stack | Failure layer | Outcome |
|---|---|---|
| CNV 4.99 nightly (`virt-launcher-rhel9` / libvirt 11.10.0-12.el9_8 / qemu-kvm-10.1.0-17.el9_8) | QEMU runtime (`-accel mshv`, vcpu 0) | VMI reaches `phase: Running`, then crashes inside the MSHV accelerator |
| Upstream KubeVirt v1.8.2 (`virt-launcher:v1.8.2` / libvirt 11.9.0 / qemu-kvm 10.1.0) | virt-handler init container `node-labeller.sh`, *before any VMI* | virt-handler on the mshv node never starts; `devices.kubevirt.io/mshv` is not advertised |

Conclusion: in upstream, `virsh domcapabilities --machine q35 --arch x86_64 --virttype hyperv` returns

> `error: invalid argument: the accel 'tcg' is not supported by '/usr/libexec/qemu-kvm' on this host`

so the upstream `virt-launcher:v1.8.2` image's bundled **libvirt 11.9.0**
does not understand the `hyperv` libvirt driver type at all — it falls
back to TCG and that accelerator is not built into its qemu-kvm. The
qemu binary itself **does** support `mshv` (`-accel help` lists
`tcg / mshv / kvm`), but libvirt cannot get there. CNV's
`virt-launcher-rhel9` image ships **libvirt 11.10.0** with downstream
patches that add the `hyperv` driver type, which is why CNV gets all
the way to a running QEMU before crashing inside it.

So:

- The MSHV/QEMU vcpu-0 crash that ended the CNV smoke test is **not
  reproduced by upstream** — but only because upstream cannot get far
  enough to reproduce it. This experiment **does not falsify** the
  hypothesis that the crash is downstream-of-CNV.
- It also **does not falsify** the hypothesis that the host MSHV
  stack is at fault. The host-side `using unsupported MSHV_CREATE_PARTITION
  ioctl` warnings still fire on every VM-launch attempt regardless of
  which stack is on top.

This A/B was therefore inconclusive on H2/H3 but produced a separate,
clean upstream-side product issue worth reporting:

- `kubevirt/kubevirt` upstream `v1.8.2` advertises support for the
  `ConfigurableHypervisor` feature gate and the `hypervisors:[{name:
  hyperv-direct}]` config (`virt-operator` correctly plumbs
  `PREFERRED_VIRTTYPE=hyperv` and `HYPERVISOR_DEVICE=mshv` env vars
  into the `node-labeller.sh` init container), but the upstream
  `virt-launcher` image at the same tag does not ship a libvirt
  build that knows the `hyperv` driver type, making the labeller
  fail before virt-handler can register the `mshv` device plugin.

## Cluster state at the time of this run

- Self-managed OCP 4.22.0-rc.3 (installer-provisioned). Note: the
  validation goal originally pinned to `4.22.0-rc.0` in the older
  `AGENTS.md`/`README.md` text predates this run; this cluster was
  pre-provisioned at `rc.3` by the operator and the experiment is
  documented at the version that was actually exercised.
- FeatureGate: `TechPreviewNoUpgrade`
- mshv node: `weinongw-9i76-kqbm6-worker-mshv-centralus1-jgt9n`
  (`Standard_D192ds_v6`, `centralus-1`, RHCOS 10.2.20260423-0
  Coughlan, kernel `6.12.0-211.7.1.el10_2.x86_64`)
- `mshv_root` module loaded; `/dev/mshv` and `/dev/vhost-net` present
- mshv MachineConfigPool unchanged
- CNV operator removed (HC, sub, CSV, OG, namespace, catalogsource,
  CRDs); `kubevirt`/`cdi`/`hco`/`ssp`/`hostpath-provisioner`/`aaq`/
  `networkaddons` CRDs all deleted
- Upstream KubeVirt installed via `scripts/06c-upstream-kubevirt-install.sh`
- Cluster is being **left in upstream-KubeVirt state** for further
  iteration (per session instruction).

## Steps taken

1. Snapshotted `csv,sub,hco,kubevirt,cdi,catalogsource,operatorgroup,namespace`
   plus all CNV-owned CRDs into
   `.smoke-runs/20260509T211503-pre-uninstall/`.
2. Deleted `HyperConverged/kubevirt-hyperconverged` →
   `Subscription/hco-operatorhub` →
   `ClusterServiceVersion/kubevirt-hyperconverged-operator.4.99.0-2781` →
   `OperatorGroup` → `Namespace/openshift-cnv` →
   `CatalogSource/cnv-nightly-catalog-source` (in that order).
3. Deleted all CNV/HCO-owned CRDs that survived (HCO already swept
   most operand CRDs when the HC CR was deleted).
4. Confirmed cluster clean: no `kubevirt|cdi` CRDs, no relevant
   webhooks, no relevant clusterroles.
5. **Tried `kubevirt/hyperconverged-cluster-operator` from upstream
   `main` branch first** via `scripts/06b-community-hco-install.sh`
   (which `deploy/operator.yaml` pins to KubeVirt v1.8.2). Aborted:
   HCO `main` is `1.19.0-unstable` and the
   `hyperconverged-cluster-operator` Pod immediately crashlooped on
   `failed to determine if *v1alpha1.MigController is namespaced:
   no matches for kind "MigController" in version
   "migrations.kubevirt.io/v1alpha1"` — that CRD is not part of the
   upstream `deploy/deploy.sh` set. We did not chase this further;
   the goal was the kernel/userspace A/B, not debugging upstream HCO
   `main`. Cleaned up the deployment fully (namespace, webhooks,
   CRDs, clusterroles, cert-manager). The `06b` script is kept in
   the repo with a `WARNING` header noting it reproduces this
   failure.
6. Installed upstream `kubevirt/kubevirt` v1.8.2 directly with
   `scripts/06c-upstream-kubevirt-install.sh` (operator.yaml + CR).
7. Patched the `KubeVirt/kubevirt` CR to mirror the CNV smoke-run
   knobs: `hypervisors=[hyperv-direct]`, `evictionStrategy=None`,
   feature gates `ConfigurableHypervisor`, `WithHostModelCPU`,
   `HypervStrictCheck`, `HostDevices`.
8. Waited for KubeVirt phase=`Deployed`.
9. Observed `virt-handler` on the mshv node is stuck in
   `Init:CrashLoopBackOff`.

## Evidence

### `virt-operator` correctly plumbs MSHV env vars

```yaml
initContainers:
- args: [node-labeller.sh]
  env:
  - name: PREFERRED_VIRTTYPE
    value: hyperv
  - name: HYPERVISOR_DEVICE
    value: mshv
  image: quay.io/kubevirt/virt-launcher:v1.8.2
```

So the `ConfigurableHypervisor` plumbing **is** present in upstream
v1.8.2 — virt-operator reacts to the `hypervisors=[hyperv-direct]`
spec by injecting these env vars, exactly as we expected and
exactly the same way the CNV operator does.

### `node-labeller.sh` script gets the right env, then libvirt fails

From the init-container log on the mshv node:

```text
+ KVM_HYPERVISOR_DEVICE=kvm
+ KVM_VIRTTYPE=kvm
+ '[' -z mshv ']'
+ '[' -z hyperv ']'
+ HYPERVISOR_DEV_PATH=/dev/mshv
+ HYPERVISOR_DEV_MINOR=119
+ '[' '!' -e /dev/mshv ']'
+ '[' -e /dev/mshv ']'
+ chmod o+rw /dev/mshv
+ VIRTTYPE=hyperv
+ virtqemud -d
+ virsh domcapabilities --machine q35 --arch x86_64 --virttype hyperv
error: failed to get emulator capabilities
error: invalid argument: the accel 'tcg' is not supported by
       '/usr/libexec/qemu-kvm' on this host
```

So:

- The script detected `/dev/mshv` and chose `VIRTTYPE=hyperv`.
- It then asked libvirt for domcapabilities with `--virttype hyperv`.
- Libvirt **silently lowered to `tcg`** (because it does not know
  `hyperv` driver type at all in this build) and then rejected `tcg`
  because the qemu binary in the same image is built without TCG
  acceleration backend.
- The init container exits non-zero, virt-handler can never start,
  no device plugin advertises `mshv`.

### The qemu binary in upstream `virt-launcher:v1.8.2` *does* know mshv

Run from a one-off probe pod off the same image:

```text
$ /usr/libexec/qemu-kvm -accel help
Accelerators supported in QEMU binary:
tcg
mshv
kvm
```

So the QEMU build ships with the `mshv` accelerator compiled in. The
problem is exclusively in the **libvirt** layer of the same image,
which does not register a `hyperv` connection driver type.

### Libvirt in `virt-launcher:v1.8.2` is 11.9.0 (vs CNV's 11.10.0)

```text
$ virsh version
Compiled against library: libvirt 11.9.0
Using library:            libvirt 11.9.0
Using API:                QEMU 11.9.0
Running hypervisor:       QEMU 10.1.0
```

For comparison, CNV 4.99.0-2781 ships **libvirt 11.10.0** (package
`libvirt-11.10.0-12.el9_8`) and **qemu-kvm 10.1.0-17.el9_8** in
`virt-launcher-rhel9`, and that is the build that successfully
made it past `domcapabilities` and into a running QEMU before the
vcpu-0 crash. (Both versions are quoted from the CNV smoke
launcher logs in `.smoke-runs/20260509T204214/launcher-compute.log`.)

### Probing the three libvirt `--virttype` values from the upstream image

```text
=== virttype=kvm ===
error: invalid argument: the accel 'kvm' is not supported by
       '/usr/libexec/qemu-kvm' on this host

=== virttype=hyperv ===
error: invalid argument: the accel 'tcg' is not supported by
       '/usr/libexec/qemu-kvm' on this host

=== virttype=qemu ===
<domainCapabilities>
  <path>/usr/libexec/qemu-kvm</path>
  <domain>qemu</domain>
  <machine>pc-q35-rhel9.8.0</machine>
  ...
```

Only `--virttype qemu` works. There is no `hyperv` in upstream
libvirt 11.9.0 in this image.

### Node allocatable

```json
{
  "devices.kubevirt.io/kvm": "0",
  "devices.kubevirt.io/mshv": "0",
  "devices.kubevirt.io/tun": "1k",
  "devices.kubevirt.io/vhost-net": "1k"
}
```

`mshv` is `0` (vs `1k` under CNV). `kvm` is also `0` because there
is no `/dev/kvm` on this MSHV-only host — that's expected.

## Hypotheses revisited

| # | Hypothesis | Result |
|---|---|---|
| H1 | `mshv_root` Hyper-V version mismatch (`current 26102 < min 27744`) breaks any user of `MSHV_CREATE_PARTITION` regardless of userspace | **Not falsified.** Host-side warnings continue to fire under upstream too. |
| H2 | QEMU's MSHV accelerator can't handle the `EPYC-Turin` host-model intercept | **Could not be tested under upstream.** Upstream never reached the vcpu-execute path because libvirt rejected the probe earlier. |
| H3 | The CNV-specific qemu-kvm/libvirt build is incompatible with this MSHV/Hyper-V combo | **Could not be tested under upstream.** Different, earlier failure mode. |
| H4 | `pc-q35-rhel9.8.0` machine type vs `el10` host kernel | **Could not be tested under upstream.** |

The A/B failed to disambiguate H2/H3 because upstream cannot reach
the QEMU runtime stage. To make a proper comparison, we would need
either:

- An upstream `virt-launcher` image rebuilt with libvirt 11.10+ and
  the hyperv driver type registered (i.e. a Red Hat downstream
  package set on top of an otherwise-upstream KubeVirt operator), or
- A CNV variant where we can swap in upstream libvirt/qemu-kvm to
  isolate the QEMU build only.

Both are out of scope for this validation repo. The cleaner next
step is to file the upstream KubeVirt issue (libvirt build in
`virt-launcher:v1.8.2` does not implement the hyperv connection
driver) so the `ConfigurableHypervisor` path is actually testable
against community KubeVirt in future releases.

## Manual interventions / workarounds

None. Per `AGENTS.md`:

- The CNV-side crash documented in `issues/2026-05-09.md` is not
  resolved by switching to upstream KubeVirt; it is also not
  contradicted.
- The upstream-side init-container failure is reported as-is. We did
  not patch the labeller script, the libvirt config, or the qemu
  binary in the upstream image.
- We tried HCO `main` first (it pins KubeVirt v1.8.2 in
  `deploy/operator.yaml`) and abandoned it cleanly when its own HCO
  pod crashlooped on a missing `MigController` CRD — that is a
  separate upstream-HCO-`main`-branch issue, not in scope for the
  MSHV question we set out to answer.

## Open product issues to track (additive to the prior list)

| Surface | Symptom | Evidence |
|---|---|---|
| Upstream `kubevirt/virt-launcher:v1.8.2` libvirt 11.9.0 | Does not register the `hyperv` libvirt connection driver type, so `node-labeller.sh` fails when KubeVirt is configured with `hypervisors:[{name:hyperv-direct}]` and `/dev/mshv` is present | `virsh domcapabilities --machine q35 --virttype hyperv` returns "the accel 'tcg' is not supported by '/usr/libexec/qemu-kvm' on this host" |
| Upstream `kubevirt/hyperconverged-cluster-operator` `main` (`1.19.0-unstable`) | `hyperconverged-cluster-operator` Pod crashloops on missing `MigController` CRD; deploy/deploy.sh does not include the matching CRD | `failed to determine if *v1alpha1.MigController is namespaced: no matches for kind "MigController" in version "migrations.kubevirt.io/v1alpha1"` |

## Artifacts

Saved under `.smoke-runs/20260509T213946-upstream-kubevirt/`:

- `kubevirt.yaml` — KubeVirt CR snapshot (operator-version v1.8.2,
  patched config)
- `pods.txt` — pod state in `kubevirt` namespace
- `virt-handler-init-mshv.log` — init container log on the mshv node
- `virt-handler-describe.txt` — full describe of the failing pod
- `node.json` — full node JSON (with `devices.kubevirt.io/mshv: 0`)
- `upstream-qemu-accel-help.txt` — `qemu-kvm -accel help` output
  (proves QEMU has mshv compiled in)
- `upstream-virsh-probe.txt` — `virsh domcapabilities` for kvm /
  hyperv / qemu virttypes plus `virsh version` (proves libvirt 11.9.0
  in the image does not implement hyperv)

And the pre-uninstall snapshot under
`.smoke-runs/20260509T211503-pre-uninstall/` for cross-reference.

## Cluster final state

```text
$ oc get csv,hyperconverged -A
No resources found

$ oc get kubevirt -n kubevirt
NAME       AGE   PHASE
kubevirt   ...   Deployed

$ oc get nodes -o wide
master-0/1/2 ... RHCOS 9.8 (kernel 5.14)
worker-centralus1-... ... RHCOS 9.8
worker-mshv-centralus1-... mshv,worker  RHCOS 10.2 (kernel 6.12)

$ oc get node <mshv> -o jsonpath='{.status.allocatable["devices.kubevirt.io/mshv"]}'
0
```

The cluster is left in this state intentionally so we can iterate on
the upstream KubeVirt issue, or revisit by reinstalling CNV.
