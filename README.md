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

The self-managed installer service principal is cached at
`~/.azure/osServicePrincipal.json` from Key Vault secret
`osServicePrincipal`. Append and publish a new credential before the current
one expires with:

```sh
make rotate-service-principal-credential
```

The new credential is valid for 90 days by default. Override this with
`SP_CREDENTIAL_DAYS=<days>`. The target retains prior application credentials
so existing clusters are not immediately disrupted, updates Key Vault before
atomically replacing the local file, and never prints the generated secret.
It does not update credentials already embedded in an existing self-managed
cluster; those credentials must remain valid through cluster teardown.

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

`make ocp-up` defaults to stable OCP `4.22.7`, pinned by release image digest.

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
RELEASE_IMAGE=<release-image> make ocp-up
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

Diagnostic QEMU `10.1.0-17.el9_8.3` validation:

Download the eight signed x86_64 RPMs listed in
`images/cnv-qemu-launcher/qemu-rpms.lock.tsv` from Red Hat advisory
`RHBA-2026:28656` into a directory outside this repository. Build and verify a
local image with:

```sh
QEMU_RPM_DIR=/absolute/path/to/qemu-rpms make build-qemu-3-launcher
```

To publish the image, provide a registry tag. The target repeats the build and
verification, pushes the image, and prints the digest-pinned value to use as
`QEMU_3_LAUNCHER_IMAGE`:

```sh
QEMU_RPM_DIR=/absolute/path/to/qemu-rpms \
CNV_QEMU_IMAGE=arol1vh.azurecr.io/aro-virt-validation/cnv-qemu-launcher:10.1.0-17.el9_8.3 \
  make publish-qemu-3-launcher
```

Registry authentication must already be configured. For the default Azure
Container Registry, run `make docker-login-arol1vh` first.

Run validation with the published digest:

```sh
USE_QEMU_3_LAUNCHER=true \
QEMU_3_LAUNCHER_IMAGE=arol1vh.azurecr.io/aro-virt-validation/cnv-qemu-launcher@sha256:7c49c99f1506dce2ed93f7018dc69ed118183a116e4f93011f87dbfcb4b1d1c4 \
QEMU_3_PULL_SECRET_FILE=/path/to/dockerconfig.json \
  make validation-checkup
```

This is an unsupported diagnostic intervention. The override remains active
after validation completes, fails, or reaches the local `JOB_TIMEOUT`; an
in-cluster Job may continue naturally. Restore only when explicitly requested:

```sh
make restore-qemu-3-launcher
```

The apply operation records cluster/resource identities and the original HCO,
CSV, and Deployment values under ignored `.smoke-runs/` state. Explicit restore
refuses stale or concurrent state instead of overwriting it. There is no
automatic restore, including after a partial apply failure; retain the state
file and run the explicit restore after resolving any reported drift.

Artifacts are saved under `.checkup-runs/<timestamp>/`.

## Day-2 RHCOS Custom Kernel Layering (mshv pool)

Apply a custom kernel to the RHCOS 10 MSHV/CNV nodes as a day-2
[image mode / RHCOS layer](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/machine_configuration/mco-coreos-layering)
using the **on-cluster** build path (a `MachineOSConfig` targeting the `mshv`
MachineConfigPool). `FROM configs AS final` inherits the pool's rhel-10 base, so
`osImageURL` is never hand-pinned. See `images/rhcos-kernel-layer/README.md` for
details and caveats (notably the `mshv_root`/L1VH risk of swapping the kernel).

COPR / URL kernel RPMs (build pod fetches them directly):

```sh
KERNEL_RPM_SOURCE=copr \
KERNEL_RPM_URLS="https://.../kernel-6.12.0-55.el10.x86_64.rpm https://.../kernel-core-...rpm https://.../kernel-modules-...rpm" \
  make rhcos-kernel-layer
```

Locally-provided signed RPMs (verified, packed into a carrier image, pushed to
the internal registry, then referenced by the on-cluster build). Fill in
`images/rhcos-kernel-layer/kernel-rpms.lock.tsv` and stage the RPMs outside the
repo:

```sh
KERNEL_RPM_DIR=/absolute/path/to/kernel-rpms make build-kernel-rpm-carrier
KERNEL_RPM_SOURCE=local make rhcos-kernel-layer
```

Preview, verify on the node, and revert:

```sh
make render-kernel-layer                       # print the MachineOSConfig only
EXPECTED_KERNEL=6.12.0-55.el10 make verify-kernel-layer
make revert-kernel-layer                       # roll back to the base image
```

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
