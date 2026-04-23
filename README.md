# ARO OpenShift Virtualization Validation

End-to-end automation for deploying an Azure Red Hat OpenShift (ARO) cluster, installing a pre-release (nightly) build of OpenShift Virtualization (CNV), and upgrading the cluster to the latest OCP version via the candidate channel.

## Prerequisites

- Azure CLI >= 2.84.0, logged in (`az login`)
- `oc` client >= 4.6.0
- `jq`, `base64`, `curl`
- A Red Hat pull secret (`.pull-secret.txt` at repo root) — download from [console.redhat.com](https://console.redhat.com/openshift/install/azure/aro-provisioned)
- A quay.io account that has been invited to the `openshift-cnv` organization (request via your Red Hat SA/TAM)

## Repository Structure

```
.env                          # Quay.io credentials (gitignored)
.pull-secret.txt              # Red Hat pull secret (gitignored)
.upgrade-snapshots/           # Pre/post upgrade ClusterVersion snapshots (gitignored)
issues/
  2026-04-21.md               # Bug: virt-handler cert mount + QEMU machine type mismatch
  2026-04-22.md               # MSHV L1VH: RHCOS 9.8 kernel lacks support, resolved with RHCOS 10.2
scripts/
  env.sh                      # Shared environment variables and helper functions
  00-prereqs.sh               # Phase 0: Validate Azure prerequisites
  01-aro-infra.sh             # Phase 1: Create ARO cluster with managed identities
  02-cnv-pull-secret.sh       # Phase 2: Add quay.io/openshift-cnv pull secret
  03-cnv-install.sh           # Phase 3: Install CNV nightly operator
  04-upgrade-cluster.sh       # Phase 4: Upgrade OCP one minor version at a time
  05-cnv-validation-checkup.sh # Phase 5: Run CNV validation checkup
  06-mshv-machineset.sh       # Phase 6: Create D192ds_v6 machineset for MSHV
  07-mshv-hco-patch.sh        # Phase 7: Patch HCO for hyperv-direct
  08-mshv-rhcos10-setup.sh    # Phase 8: MSHV node with RHCOS 10 + L1VH partition
```

## Setup

Create a `.env` file at the repo root with your quay.io credentials:

```
QUAY_USERNAME=<your quay.io username>
QUAY_PASSWORD=<your encrypted password from quay.io Account Settings>
```

The encrypted password is generated at quay.io → Account Settings → Generate Encrypted Password.

## Workflow

### Phase 0-1: Create the ARO cluster

```bash
./scripts/00-prereqs.sh       # Validate Azure prerequisites
./scripts/01-aro-infra.sh     # Create resource group, VNet, managed identities, ARO cluster
```

This creates an ARO cluster with managed identities, DSv5 workers (8 cores each), and the latest ARO-supported OCP version. Takes ~30-45 minutes.

After creation, log in:

```bash
API_SERVER=$(az aro show -g aro-virt-test-rg -n aro-virt-test --query apiserverProfile.url -o tsv)
PASSWORD=$(az aro list-credentials -g aro-virt-test-rg -n aro-virt-test --query kubeadminPassword -o tsv)
oc login "$API_SERVER" -u kubeadmin -p "$PASSWORD"
```

### Phase 2: Add quay.io/openshift-cnv pull secret

```bash
./scripts/02-cnv-pull-secret.sh
```

This adds the `quay.io/openshift-cnv` auth entry to the cluster's global pull secret and waits for the MachineConfigPool rollout to complete (10-20 minutes, involves node reboots).

The script is idempotent — re-running it skips the update if the auth is already present.

Reference: [Red Hat KB 6070641](https://access.redhat.com/articles/6070641) Steps 4-5.

### Phase 3: Install CNV nightly

```bash
./scripts/03-cnv-install.sh
```

By default this installs `CNV_VERSION=4.99` (latest development build from upstream main branches). Override with:

```bash
CNV_VERSION=4.18 ./scripts/03-cnv-install.sh
```

The script:
1. Applies a CatalogSource pointing to `quay.io/openshift-cnv/nightly-catalog:${CNV_VERSION}`
2. Waits for the catalog to become READY
3. Extracts the starting CSV from the `nightly-${CNV_VERSION}` channel
4. Creates the `openshift-cnv` Namespace, OperatorGroup, and Subscription
5. Waits for the CSV to reach `Succeeded`
6. Deploys the HyperConverged CR
7. Waits for HyperConverged to become `Available`

Reference: [Red Hat KB 6070641](https://access.redhat.com/articles/6070641) Steps 6-9 (CLI path).

### Phase 4: Upgrade the cluster

```bash
./scripts/04-upgrade-cluster.sh 4.21
./scripts/04-upgrade-cluster.sh 4.22
```

Upgrades the cluster one minor version at a time using the `candidate-X.Y` channel. Only N→N+1 minor upgrades are allowed (the script refuses skip-level jumps).

The script:
1. Validates the hop is exactly current_minor + 1
2. Runs pre-flight health checks (ClusterOperators, MachineConfigPools)
3. Saves a pre-upgrade snapshot to `.upgrade-snapshots/`
4. Sets the `candidate-X.Y` channel
5. Resolves admin-ack blockers (cloud-credential annotation, API removal acks)
6. Picks the latest patch version from `availableUpdates`, `conditionalUpdates`, or falls back to querying Red Hat's update graph API directly
7. Triggers the upgrade (using `--to-image` with `--allow-explicit-upgrade` when no graph edge exists from the current version)
8. Polls until completion (~60 minutes per hop)
9. Prints a post-upgrade health summary including ARO Operator and CNV status

Each hop takes approximately 60 minutes. A full 4.20→4.22 upgrade requires two hops (~2 hours total).

## Tested Upgrade Path

The following upgrade path was validated on 2026-04-21:

```
4.20.15 (ARO GA)
  → 4.21.11 (via candidate-4.21 channel, ~63 min)
    → 4.22.0-ec.5 (via --to-image from update graph API, ~63 min)
      → 4.22.0-rc.0 (via candidate-4.22 availableUpdates, ~57 min)
```

Final state:
- **OCP**: 4.22.0-rc.0 (Kubernetes v1.35.3, RHCOS 9.8)
- **ARO Operator**: Available=True, Degraded=False
- **CNV**: kubevirt-hyperconverged-operator.4.99.0-2739, Succeeded
- **HyperConverged**: Available
- **All nodes**: Ready
- **All ClusterOperators**: Available, not Degraded

### Phase 5: Run the CNV validation checkup

```bash
./scripts/05-cnv-validation-checkup.sh
```

Runs the [ocp-virt-validation-checkup](https://github.com/openshift-cnv/ocp-virt-validation-checkup) tool against the cluster. The script:

1. Extracts the checkup container image from the installed CNV CSV's `relatedImages`
2. Logs in to quay.io and generates the validation resources (namespace, ServiceAccount, RBAC, PVC, Job)
3. Applies the resources and waits for the Job to complete
4. Deploys an nginx results viewer with an OpenShift Route

Configure test scope with environment variables:

```bash
TEST_SUITES=compute,network,storage  # default
STORAGE_CLASS=managed-csi            # default (Azure Disk RWO)
DRY_RUN=true                        # generate manifests without applying
```

Artifacts are saved to `.checkup-runs/<timestamp>/`.

**Known issue (CNV 4.99.0-2739):** The virt-launcher container's QEMU does not support the default `pc-q35-rhel9.8.0` machine type. Before running the checkup, override it:

```bash
oc annotate --overwrite hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  'kubevirt.kubevirt.io/jsonpatch=[{"op":"add","path":"/spec/configuration","value":{"architectureConfiguration":{"amd64":{"machineType":"pc-q35-rhel9.6.0"}}}}]'
```

See [issues/2026-04-21.md](issues/2026-04-21.md) for full details and test results.

### Phase 6-8: MSHV (hyperv-direct) validation with RHCOS 10

These phases set up an MSHV node running RHCOS 10.2 with L1VH partition support for testing KubeVirt with the `hyperv-direct` hypervisor.

#### Prerequisites

- Azure quota for `Standard_D192ds_v6` (192 vCPUs in the Ddsv6 family + sufficient total regional vCPUs)
- OCP 4.21+ payload containing the `rhel-coreos-10` image

#### Phase 6: Create MSHV machineset (RHCOS 9.8 — for initial testing only)

```bash
./scripts/06-mshv-machineset.sh
```

Creates a `Standard_D192ds_v6` machineset with the Azure tag `platformsettings.host_environment.nodefeatures.hierarchicalvirtualizationv1=True`. This tag requests placement on an L1VH-capable host.

> **Note:** With RHCOS 9.8 (kernel 5.14), the node will NOT boot in L1VH mode — the kernel lacks MSHV patches. Use Phase 8 instead.

#### Phase 7: Patch HCO for hyperv-direct

```bash
./scripts/07-mshv-hco-patch.sh
```

Annotates the HyperConverged CR with the kubevirt jsonpatch to enable `ConfigurableHypervisor`, set `hypervisorConfiguration.name=hyperv-direct`, configure `qemu64-v1` CPU model, and related feature gates. Only run this after the node is confirmed to be in L1VH mode.

#### Phase 8: MSHV node with RHCOS 10 + L1VH (recommended)

```bash
./scripts/08-mshv-rhcos10-setup.sh
```

This is the recommended approach. The script:

1. Enables `TechPreviewNoUpgrade` featureset (**irreversible** — cluster cannot be upgraded afterward)
2. Waits for the `rhel-10` OS stream to become available via the `OSImageStream` CRD
3. Creates a dedicated `mshv` MachineConfigPool with `osImageStream.name: rhel-10`
4. Creates a `Standard_D192ds_v6` machineset with:
   - `node-role.kubernetes.io/mshv` label (routes node to the mshv MCP)
   - Azure tag for L1VH host placement
5. Waits for the node to provision, reboot into RHCOS 10.2 (kernel 6.12), and verify L1VH

The node initially boots with RHCOS 9.8 (from the marketplace image), then the MCO rebases it to RHCOS 10.2. This takes ~10–15 minutes after the VM is provisioned.

Configure with environment variables:

```bash
MSHV_VM_SIZE=Standard_D192ds_v6  # default
MSHV_DISK_SIZE_GB=256            # default
MSHV_ZONE=1                      # default
```

After Phase 8 completes, run Phase 7 to patch the HCO, then Phase 5 to run validation.

See [issues/2026-04-22.md](issues/2026-04-22.md) for the full investigation and kernel upgrade process.

## Caveats

- **Unsupported by Microsoft.** Upgrading beyond versions listed in `az aro get-versions` puts the cluster in a Microsoft-unsupported state. The ARO Operator may degrade. This is acceptable for lab/validation clusters only.
- **No rollback.** There is no supported rollback path from a failed minor upgrade.
- **CNV nightly is unsupported by Red Hat.** Pre-release CNV cannot be upgraded to a GA version and must not be used in production.
- **Update graph lag.** When a new OCP version (e.g. `4.22.0-rc.0`) appears in the graph after the script has already selected an older version (e.g. `4.22.0-ec.5`), simply re-run `oc adm upgrade --to=<newer>` to pick it up. The `candidate-X.Y` channel polls the graph automatically.
- **TechPreviewNoUpgrade is irreversible.** Phase 8 (MSHV/RHCOS 10) enables TechPreviewNoUpgrade, permanently preventing minor version upgrades. Only use on clusters you are willing to tear down.

## CNV Upgrades

Within the same minor version, new nightly builds are polled automatically every 8 hours (configured in the CatalogSource `registryPoll.interval`).

To upgrade CNV to a new minor version, patch the CatalogSource:

```bash
oc patch CatalogSource cnv-nightly-catalog-source -n openshift-marketplace \
  --patch '{"spec":{"image":"quay.io/openshift-cnv/nightly-catalog:<NEW_VERSION>"}}' \
  --type=merge
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LOCATION` | `centralus` | Azure region |
| `RESOURCEGROUP` | `aro-virt-test-rg` | Azure resource group |
| `CLUSTER` | `aro-virt-test` | ARO cluster name |
| `WORKER_VM_SIZE` | `Standard_D8s_v5` | Worker node VM size (must support nested virt) |
| `WORKER_COUNT` | `3` | Number of worker nodes |
| `CNV_VERSION` | `4.99` | CNV nightly version to install |
| `QUAY_USERNAME` | (from `.env`) | quay.io username with openshift-cnv org access |
| `QUAY_PASSWORD` | (from `.env`) | quay.io encrypted password |
| `MSHV_VM_SIZE` | `Standard_D192ds_v6` | MSHV worker node VM size |
| `MSHV_DISK_SIZE_GB` | `256` | MSHV worker OS disk size |
| `MSHV_ZONE` | `1` | Azure availability zone for MSHV node |

## References

- [Installing pre-release versions of OpenShift Virtualization (CNV)](https://access.redhat.com/articles/6070641) — Red Hat KB article covering the nightly CNV installation workflow (requires Red Hat login)
- [How to test RHCOS 10 on OpenShift 4.21 and 4.22](https://access.redhat.com/articles/7139678) — Red Hat KB article on enabling RHCOS 10 via OS Streams Tech Preview
