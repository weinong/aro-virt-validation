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
docs/
  6070641.md                  # Red Hat KB 6070641 - Installing pre-release CNV
scripts/
  env.sh                      # Shared environment variables and helper functions
  00-prereqs.sh               # Phase 0: Validate Azure prerequisites
  01-aro-infra.sh             # Phase 1: Create ARO cluster with managed identities
  02-cnv-pull-secret.sh       # Phase 2: Add quay.io/openshift-cnv pull secret
  03-cnv-install.sh           # Phase 3: Install CNV nightly operator
  04-upgrade-cluster.sh       # Phase 4: Upgrade OCP one minor version at a time
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

## Caveats

- **Unsupported by Microsoft.** Upgrading beyond versions listed in `az aro get-versions` puts the cluster in a Microsoft-unsupported state. The ARO Operator may degrade. This is acceptable for lab/validation clusters only.
- **No rollback.** There is no supported rollback path from a failed minor upgrade.
- **CNV nightly is unsupported by Red Hat.** Pre-release CNV cannot be upgraded to a GA version and must not be used in production.
- **Update graph lag.** When a new OCP version (e.g. `4.22.0-rc.0`) appears in the graph after the script has already selected an older version (e.g. `4.22.0-ec.5`), simply re-run `oc adm upgrade --to=<newer>` to pick it up. The `candidate-X.Y` channel polls the graph automatically.

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
