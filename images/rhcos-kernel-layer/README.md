# Day-2 RHCOS custom kernel layer for the `mshv` pool

Day-2 [image mode / RHCOS layering](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/machine_configuration/mco-coreos-layering)
that replaces the RHCOS kernel on the MSHV/CNV nodes using the **on-cluster**
build path (a `MachineOSConfig` custom resource). The Machine Config Operator
(MCO) builds the layered image inside the cluster and rolls it out to the `mshv`
MachineConfigPool.

The `mshv` pool is pinned to the `rhel-10` OS stream
(`scripts/04-mshv-node-setup.sh`). On-cluster builds use `FROM configs AS final`,
which inherits that rhel-10 base automatically, so we never hand-pin
`osImageURL`. (The `osImageURL` caution in `AGENTS.md` is about masking a missing
RHCOS 10 stream, not deliberate layering — this path does not use it.)

Apply and revert with `scripts/12-rhcos-kernel-layer.sh` (or the
`rhcos-kernel-layer` / `revert-kernel-layer` make targets). Verify on the node
with `scripts/12b-verify-kernel-layer.sh`.

## Current pin: L1VH test kernel (RHCOS 10)

`kernel-rpms.lock.tsv` and `l1vh.env` are pinned to Paolo Bonzini's L1VH test
kernel **`6.12.0-211.49.1.1794_2777371478.el10_2`** (x86_64) from
<https://bonzini.fedorapeople.org/kernel-l1vh/>. These are **unsigned developer
RPMs**, so the carrier build must be run with `ALLOW_UNSIGNED_KERNEL_RPMS=true`
(the sha256 lock is still enforced). RHCOS 10 installs all five kernel
subpackages (`kernel`, `kernel-core`, `kernel-modules`, `kernel-modules-core`,
`kernel-modules-extra`), so all five are replaced together.

Recommended (local carrier) flow:

```sh
source images/rhcos-kernel-layer/l1vh.env
# stage the five RPMs outside the repo (see l1vh.env for the exact curl loop)
KERNEL_RPM_DIR=/tmp/kernel-l1vh make build-kernel-rpm-carrier
KERNEL_RPM_SOURCE=local make rhcos-kernel-layer
EXPECTED_KERNEL=6.12.0-211.49.1.1794_2777371478.el10_2 make verify-kernel-layer
```

The COPR/URL alternative (`KERNEL_RPM_SOURCE=copr`, URLs preset in `l1vh.env`)
needs in-cluster build-pod egress to the download host; the local carrier path
avoids that and is preferred for this unsigned kernel.

## ARO: on-cluster build is blocked; use the out-of-cluster path

On ARO 4.22 the **on-cluster** `MachineOSConfig` build (`scripts/12`) fails: the
MCO build pod cannot verify the signed RHCOS release base image required by the
`openshift` `ClusterImagePolicy` (sigstore attachment lookup is disabled in the
build). See `issues/2026-08-24b-oncluster-layering-signature.md`.

Use the **out-of-cluster** path instead, which builds the image locally and
rolls it out via `osImageURL`:

```sh
ALLOW_UNSIGNED_KERNEL_RPMS=true \
KERNEL_RPM_DIR=/absolute/path/to/kernel-l1vh \
  make rhcos-kernel-layer-ooc
EXPECTED_KERNEL=6.12.0-211.49.1.1794_2777371478.el10_2 make verify-kernel-layer
make revert-kernel-layer-ooc   # removes the layer and restores the rhel-10 OS stream
```

This resolves the mshv pool's rhel-10 base, builds `FROM` it with
`rpm-ostree override replace`, pushes to the internal registry, and sets
`osImageURL` on the `mshv` role. Because `osImageURL` and a pool `osImageStream`
are mutually exclusive, the script removes the pool's `osImageStream` (stored on
the MachineConfig and restored on revert).

## Two kernel RPM sources

`KERNEL_RPM_SOURCE=copr` (default): the in-cluster build fetches the kernel RPMs
directly from URLs. Provide space/newline-separated direct `.rpm` URLs (a COPR
build, a Red Hat hotfix, or any HTTPS mirror) in `KERNEL_RPM_URLS`. Rendered from
`Containerfile.copr`. The build pod needs egress to those URLs.

```sh
KERNEL_RPM_SOURCE=copr \
KERNEL_RPM_URLS="https://download.copr.fedorainfracloud.org/results/<user>/<project>/rhel-10-x86_64/<build>/kernel-6.12.0-55.el10.x86_64.rpm
https://download.copr.fedorainfracloud.org/results/<user>/<project>/rhel-10-x86_64/<build>/kernel-core-6.12.0-55.el10.x86_64.rpm
https://download.copr.fedorainfracloud.org/results/<user>/<project>/rhel-10-x86_64/<build>/kernel-modules-6.12.0-55.el10.x86_64.rpm
https://download.copr.fedorainfracloud.org/results/<user>/<project>/rhel-10-x86_64/<build>/kernel-modules-core-6.12.0-55.el10.x86_64.rpm
https://download.copr.fedorainfracloud.org/results/<user>/<project>/rhel-10-x86_64/<build>/kernel-modules-extra-6.12.0-55.el10.x86_64.rpm" \
  make rhcos-kernel-layer
```

`KERNEL_RPM_SOURCE=local`: locally-provided, signed RPMs. Because on-cluster
builds cannot upload a local build context, `scripts/12a-build-kernel-rpm-carrier.sh`
verifies the RPMs (sha256 + Red Hat signature `fd431d51`) against
`kernel-rpms.lock.tsv`, packs them into a minimal `scratch` carrier image
(`carrier.Containerfile`), and pushes it to the internal registry. The
`MachineOSConfig` (rendered from `Containerfile.local`) pulls that carrier as an
extra `FROM ... AS rpms` stage. RPM binaries are never committed; stage them in
`KERNEL_RPM_DIR` outside this repository.

```sh
KERNEL_RPM_DIR=/absolute/path/to/kernel-rpms make build-kernel-rpm-carrier
KERNEL_RPM_SOURCE=local make rhcos-kernel-layer
```

## Caveats (documented, not worked around)

- **MSHV/L1VH risk**: `mshv_root` is built against a specific kernel. A custom
  kernel that lacks MSHV support will break `/dev/mshv` and L1VH partitioning on
  these nodes. `scripts/12b-verify-kernel-layer.sh` re-runs the MSHV host checks
  from `scripts/04-mshv-node-setup.sh`; if they fail, capture it under `issues/`
  and keep the issue open rather than patching around it.
- Real-time kernel and extension RPMs can conflict with machine-config-installed
  RPMs and degrade the MCO (per the OCP docs).
- A kernel change forces an image rebuild and a node reboot.
- On-cluster layering's `ImagePulledFromRegistry` status is Technology Preview;
  the cluster already runs `TechPreviewNoUpgrade`.
