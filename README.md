# ARO OpenShift Virtualization Validation

Makefile-driven automation for OpenShift Virtualization validation on ARO or a
self-managed OpenShift cluster.

Run commands from the repo root. Start with:

```sh
make help
```

## Prerequisites

- Azure CLI >= 2.84.0, logged in with `az login`
- `oc`, `jq`, `base64`, `curl`, and `podman`
- Azure quota in the target region for the base cluster and `Standard_D192ds_v6`

Local secrets are expected in:

```text
.quay-pullsecret  # QUAY_USERNAME and QUAY_PASSWORD
.pullsecret       # Red Hat pull secret
```

For a fresh checkout, download both from Key Vault:

```sh
REGISTRY=arol1vh make download-local-secrets
```

Secret usage:

```text
.pullsecret        Downloaded from Key Vault secret ocp-pullsecret. Used by
                   make aro-up as the ARO cluster pull secret and by make
                   ocp-up for self-managed OpenShift install-config.
.quay-pullsecret   Downloaded from Key Vault secret quay-pullsecret. Sourced by
                   cnv-pull-secret and validation-checkup for QUAY_USERNAME and
                   QUAY_PASSWORD.
```

Upload targets are for maintaining the Key Vault copies, not normal validation
runs:

```sh
make upload-pull-secret
make upload-quay-pullsecret
```

## Recommended Flows

Self-managed OpenShift:

```sh
make ocp-validation-flow
```

ARO:

```sh
TARGET_OCP_VERSION=4.22.4 make aro-validation-flow
```

Prefer the individual phase targets below when investigating failures.

## Self-Managed OCP

Create the cluster and print access details:

```sh
make ocp-up
make cluster-info
```

Run validation phases manually:

```sh
export KUBECONFIG=$PWD/installer/auth/kubeconfig
make techpreview
make mshv-node
make cnv-pull-secret
CNV_VERSION=4.99 make cnv-install
make mshv-hco-patch
make validation-checkup
```

Common overrides:

```sh
LOCATION=<azure-region> make ocp-up
SSH_PUB_KEY=~/.ssh/id_ed25519.pub make ocp-up
RELEASE_IMAGE=<release-image> make setup-tools
SELF_MANAGED_CLUSTER=<cluster-name> make ocp-up
SELF_MANAGED_BASE_DOMAIN=<base-domain> SELF_MANAGED_BASE_DOMAIN_RESOURCE_GROUP=<dns-rg> make ocp-up
```

`make ocp-down` destroys the cluster from local `installer/` state.

## ARO

Pre-check that the pinned upgrade target exists before creating a cluster:

```sh
make check-upgrade-target
```

Create the cluster:

```sh
make aro-up
```

`make aro-up` creates a randomized resource group by default and writes `.aro.env`
so cleanup can find it later.

Common overrides:

```sh
LOCATION=<azure-region> make aro-up
ARO_RESOURCEGROUP_PREFIX=my-aro make aro-up
RESOURCEGROUP=my-rg CLUSTER=my-cluster make aro-up
ARO_STATE_OVERWRITE=true make aro-up
```

After `make aro-up`, log in and run validation phases manually:

```sh
make aro-login
make aro-disable-machineset-reconcile
TARGET_OCP_VERSION=4.22.4 make upgrade-to-4.22.4
make techpreview
make mshv-node
make cnv-pull-secret
CNV_VERSION=4.99 make cnv-install
make mshv-hco-patch
make validation-checkup
```

`make aro-down` deletes the ARO cluster and resource group from `.aro.env`.
Override cleanup explicitly when needed:

```sh
RESOURCEGROUP=my-rg CLUSTER=my-cluster make aro-down
```

## Validation Options

```sh
TEST_SUITES=compute make validation-checkup
TEST_SUITES=compute,network,storage STORAGE_CLASS=managed-csi make validation-checkup
DRY_RUN=true make validation-checkup
```

Artifacts are saved under `.checkup-runs/<timestamp>/`.

## Cleanup

```sh
make aro-down      # delete Makefile-created ARO cluster/resource group
make ocp-down      # destroy self-managed OCP from installer/ state
make clean         # remove installer/ state
make clean-tools   # remove ocp-tools/
```

## Generated Files

Important local/generated files are gitignored:

```text
.quay-pullsecret
.aro.env
.pullsecret
kubeconfig*
installer/
ocp-tools/
.upgrade-snapshots/
.checkup-runs/
.smoke-runs/
```

## Sharing Self-Managed Cluster Credentials

This is optional and not part of the normal validation workflow.

```sh
make upload-cluster-credential
make download-cluster-credential
```

The Key Vault credential secret names are shared within the vault, not per
cluster or location: `kubeadmin-password` and `kubeconfig`. Uploading credentials
for a new self-managed cluster can overwrite the previous values for that vault.

## Documenting Issues

Bug reports and findings go under `issues/` in `YYYY-MM-DD.md` format.

Call out manual interventions explicitly. Do not describe one-off manual changes
as fixes unless the normal declarative/product path works without them.

Do not convert these into normal setup steps without documenting the underlying
issue:

- Direct Machine creation instead of MachineSet reconciliation
- Scaling `machine-api-operator` down to preserve manual controller edits
- Manual rendered MachineConfigs
- Node `machineconfiguration.openshift.io/desiredConfig` annotations
- Manually applying missing payload CRDs
- Removing node role labels by hand after the node joins

## Caveats

- Upgrading beyond versions listed in `az aro get-versions` is unsupported by
  Microsoft and appropriate only for lab validation clusters.
- The ARO validation flow is pinned to exact OCP `4.22.4`; it fails rather than
  falling back to another `4.22.z` payload.
- `TechPreviewNoUpgrade` is irreversible on the cluster.
- CNV nightly builds are unsupported and must not be used in production.
- The MSHV path depends on Azure L1VH placement for `Standard_D192ds_v6` and on
  RHCOS 10 kernel support for `mshv_root`.
