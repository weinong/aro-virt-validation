# ARO OpenShift Virtualization Validation

End-to-end automation for creating an Azure Red Hat OpenShift (ARO) validation
cluster, preparing an MSHV/RHCOS 10 node, installing a nightly OpenShift
Virtualization build, enabling `hyperv-direct`, and running validation only after
the infrastructure path is understood.

The current workflow is ordered to keep cluster upgrades and irreversible feature
gates ahead of CNV installation, and to avoid treating manual interventions as
normal setup.

## Prerequisites

- Azure CLI >= 2.84.0, logged in with `az login`
- `oc` client >= 4.6.0
- `jq`, `base64`, `curl`, `podman`
- A Red Hat pull secret at repo root: `.pull-secret.txt`
- A quay.io account with access to the `openshift-cnv` organization
- Azure quota in `centralus` for both the base cluster and `Standard_D192ds_v6`

Create `.env` at repo root with quay.io credentials:

```sh
QUAY_USERNAME=<your quay.io username>
QUAY_PASSWORD=<your encrypted password from quay.io Account Settings>
```

## Repository Structure

```text
.env                           # Quay.io credentials (gitignored)
.pull-secret.txt               # Red Hat pull secret (gitignored)
.upgrade-snapshots/            # Pre/post upgrade snapshots (gitignored)
.checkup-runs/                 # Validation run artifacts (gitignored)
issues/                        # Dated findings and issue reports
scripts/
  env.sh                       # Shared environment variables and helpers
  00-prereqs.sh                # Validate local/Azure prerequisites and quota
  01-aro-infra.sh              # Create ARO cluster with managed identities
  02-upgrade-cluster.sh        # Upgrade OCP one minor version at a time
  03-techpreview-setup.sh      # Enable and verify TechPreviewNoUpgrade
  04-mshv-node-setup.sh        # Declarative MSHV MCP/MachineSet/RHCOS 10 setup
  05-cnv-pull-secret.sh        # Add quay.io/openshift-cnv pull secret
  06-cnv-install.sh            # Install CNV nightly operator and HCO
  07-mshv-hco-patch.sh         # Enable KubeVirt hyperv-direct through HCO
  08-cnv-validation-checkup.sh # Run ocp-virt-validation-checkup
```

## Revised Workflow

Run commands from the repo root and source `.env` where credentials are needed.
Do not run the validation checkup until the MSHV node and KubeVirt device path
are verified.

### Phase 0: Prerequisites

```sh
./scripts/00-prereqs.sh
```

This checks Azure login, required providers, base DSv5 quota, Ddsv6 quota for the
`Standard_D192ds_v6` MSHV node, local tooling, and `.pull-secret.txt`.

Set `TARGET_OCP_VERSION` to the intended 4.22 payload before creating a cluster
for TechPreview/MSHV validation. The prereq check blocks known-bad payloads, such
as `4.22.0-rc.3`, before any Azure resources are created:

```sh
TARGET_OCP_VERSION=<newer-4.22-version> ./scripts/00-prereqs.sh
```

If `TARGET_OCP_VERSION` is omitted, the prereq phase warns and later phases still
block known-bad upgrade or TechPreview targets.

### Phase 1: Create ARO

```sh
./scripts/01-aro-infra.sh
```

The script creates the resource group, VNet, managed identities, role
assignments, and ARO cluster. After it completes, log in with the command printed
by the script and verify baseline state:

```sh
oc whoami
oc get clusterversion version
oc get co
oc get mcp
az aro show -g "$RESOURCEGROUP" -n "$CLUSTER" -o table
```

### Phase 2: Upgrade To Target OCP

If the cluster is not already on the target 4.22 build, upgrade before enabling
TechPreviewNoUpgrade or installing CNV:

```sh
./scripts/02-upgrade-cluster.sh 4.21
./scripts/02-upgrade-cluster.sh 4.22
```

The script only allows `N -> N+1` minor upgrades. Wait for each hop to complete
and for ClusterOperators and `master/worker` MCPs to settle before proceeding.

### Phase 3: Enable TechPreviewNoUpgrade

```sh
./scripts/03-techpreview-setup.sh
```

This is intentionally after minor-version upgrades and before CNV/MSHV setup.
`TechPreviewNoUpgrade` is irreversible and prevents future minor-version
upgrades on this cluster.

Do not use `4.22.0-rc.3` or older 4.22 pre-release payloads for this phase. They
are blocked by a known TechPreview payload issue where CVO can try to apply
`CRIOCredentialProviderConfig` before its CRD is served. Upgrade to a newer 4.22
payload first. `scripts/02-upgrade-cluster.sh 4.22` also refuses to select those
known-bad targets. To intentionally reproduce the issue for investigation only,
set `ALLOW_KNOWN_BAD_TECHPREVIEW_PAYLOAD=true`.

The script waits for operators, MCPs, and ClusterVersion to settle, then verifies
TechPreview-gated extension CRDs needed by the next phases:

```text
criocredentialproviderconfigs.config.openshift.io
dnsnameresolvers.network.openshift.io
osimagestreams.machineconfiguration.openshift.io
```

If ClusterVersion is still progressing/failing or a required CRD is missing, stop
and document it as an issue. Do not silently apply payload CRDs and call that a
fix.

### Phase 4: Create MSHV Node Declaratively

Run the MSHV setup after the `rhel-10` OS stream is available:

```sh
./scripts/04-mshv-node-setup.sh
```

The script first verifies ClusterVersion is settled, no ClusterOperators are
degraded, and the `rhel-10` OS stream is present. It only disables ARO MachineSet
reconciliation after those preflight checks pass.

The script:

1. Verifies `OSImageStream/cluster` advertises the `rhel-10` stream.
2. Disables ARO MachineSet reconciliation before creating custom MachineSets.
3. Creates the `mshv` MachineConfigPool with `spec.osImageStream.name: rhel-10`.
4. Creates a declarative MachineConfig for persistent
   `/etc/modules-load.d/mshv-root.conf`.
5. Verifies the `mshv` MCP renders before creating the node.
6. Creates a `Standard_D192ds_v6` MachineSet with the L1VH placement tag.
7. Labels the node as `node-role.kubernetes.io/mshv=` while the MCP inherits
   worker MachineConfigs through `machineConfigSelector`.
8. Waits for normal MachineSet and MCP convergence.
9. Verifies RHCOS 10, L1VH, `/dev/mshv`, `/dev/vhost-net`, and `mshv_root`.

This script deliberately does not create direct Machines, hand-built rendered
MachineConfigs, direct `osImageURL` pins, or manual node `desiredConfig`
annotations. If those become necessary, stop and document the
product/declarative-path issue.

Optional environment variables:

```sh
MSHV_VM_SIZE=Standard_D192ds_v6
MSHV_DISK_SIZE_GB=256
MSHV_ZONE=1
MSHV_REPLICAS=1
MSHV_MACHINESET_NAME=<override-name>
```

### Phase 5: Add CNV Pull Secret

```sh
./scripts/05-cnv-pull-secret.sh
```

This adds `quay.io/openshift-cnv` credentials to the global pull secret and waits
for MCP rollout.

### Phase 6: Install CNV Nightly

```sh
CNV_VERSION=4.99 ./scripts/06-cnv-install.sh
```

This applies the nightly CNV CatalogSource, creates the `openshift-cnv`
Namespace/OperatorGroup/Subscription, waits for the CSV, creates the
HyperConverged CR, and waits for HCO availability.

### Phase 7: Enable hyperv-direct

```sh
./scripts/07-mshv-hco-patch.sh
```

Run this only after the MSHV node exposes `/dev/mshv` and `/dev/vhost-net`.
The script uses the HCO `kubevirt.kubevirt.io/jsonpatch` annotation to enable
`ConfigurableHypervisor`, set `hypervisors=[{"name":"hyperv-direct"}]`, and set
`evictionStrategy: None`. It intentionally does not set `cpuModel`.

Afterward verify:

```sh
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o yaml
oc get node -l node-role.kubernetes.io/mshv -o jsonpath='{.items[0].status.allocatable}' | jq
oc logs -n openshift-cnv -l kubevirt.io=virt-handler --tail=200 | grep -i mshv
```

Expected node resources include:

```text
devices.kubevirt.io/mshv=1k
devices.kubevirt.io/vhost-net=1k
devices.kubevirt.io/kvm=0
```

### Phase 8: Validation Checkup

Run a small VM smoke test first and capture VMI events, virt-launcher logs,
libvirt/QEMU logs, guest console, and host dmesg. Only run the full checkup after
the smoke result is understood.

```sh
./scripts/08-cnv-validation-checkup.sh
```

Useful options:

```sh
TEST_SUITES=compute,network,storage
STORAGE_CLASS=managed-csi
DRY_RUN=true
```

Artifacts are saved to `.checkup-runs/<timestamp>/`.

## Stop-And-Document Rules

Do not convert these into normal setup steps without explicitly documenting them
as manual interventions:

- Direct Machine creation instead of MachineSet reconciliation
- Scaling `machine-api-operator` down to preserve manual controller edits
- Manual rendered MachineConfigs
- Node `machineconfiguration.openshift.io/desiredConfig` annotations
- Manually applying missing payload CRDs
- Removing node role labels by hand after the node joins
- Treating `MSHV_CREATE_PARTITION unsupported` as root cause without corroborating
  VM, QEMU, libvirt, or guest evidence

Issue reports go in `issues/YYYY-MM-DD.md` and must separate normal declarative
steps, manual interventions, unresolved product issues, validation failures, and
warnings/red herrings.

## Caveats

- Upgrading beyond versions listed in `az aro get-versions` is unsupported by
  Microsoft and appropriate only for lab validation clusters.
- `TechPreviewNoUpgrade` is irreversible on the cluster.
- CNV nightly builds are unsupported and must not be used in production.
- The MSHV path depends on Azure L1VH placement for `Standard_D192ds_v6` and on
  RHCOS 10 kernel support for `mshv_root`.
