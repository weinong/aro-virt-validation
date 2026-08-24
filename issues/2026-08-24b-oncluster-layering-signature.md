# 2026-08-24 — On-cluster RHCOS layering (MachineOSConfig) blocked on ARO by release-image signature policy

## Summary

Day-2 RHCOS kernel layering on the `mshv` pool using the **on-cluster** image
mode (`MachineOSConfig`, `scripts/12-rhcos-kernel-layer.sh`) fails on this ARO
4.22.4 cluster. The MCO build pod cannot pull the `FROM configs` base (the
mshv pool's RHCOS 10 release image) because the cluster's `openshift`
`ClusterImagePolicy` requires a Red Hat signature for the release image, and the
build's buildah has sigstore-attachment lookup disabled, so it cannot satisfy
the policy when pulling the base from the ARO mirror.

The `MachineOSBuild` fails and the build pods land in `Init:Error`:

```
Error: creating build container: unable to copy from source
docker://quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:2dcf831...:
Source image rejected: A signature was required, but no signature exists
```

We delivered the custom kernel instead via the **out-of-cluster** method
(`scripts/12c-rhcos-kernel-layer-out-of-cluster.sh`), which is a documented OCP
layering path. This issue tracks the on-cluster path being unusable on ARO.

## Environment

- ARO 4.22.4, resource group `aro-virt-test-rg-o98l`, cluster `aro-virt-test`, `centralus`.
- `mshv` MachineConfigPool pinned to the `rhel-10` OS stream (`scripts/04`).
- mshv node: `aro-virt-test-8gpzs-worker-mshv-centralus1-6rjd2` (roles `mshv,worker`), `Standard_D192ds_v6`.
- mshv base image (rhel-10 stream): `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:2dcf831e5a3ce8416cde288979fbf9d97e9fe2f9315198588259e7da543f4ac8` (RHCOS `rhel-10.2`, `containers.bootc=1`).

## Root cause

The cluster ships a `ClusterImagePolicy` named `openshift` (4.22 sigstore image
verification) that requires a Red Hat **PublicKey** signature for these scopes:

```
quay.io/openshift-release-dev/ocp-release
quay.io/openshift-release-dev/ocp-v4.0-art-dev   <- the mshv base lives here
quay.io/openshift-release-dev/ocp-v5.0-art-dev
```

An `ImageDigestMirrorSet` mirrors these to `arosvc.azurecr.io/...`. When the MCO
on-cluster build (buildah) pulls the base:

1. It resolves the source to the ARO mirror `arosvc.azurecr.io/...` and pulls the manifest fine (auth OK).
2. The signature policy for scope `quay.io/openshift-release-dev/ocp-v4.0-art-dev` requires a signature.
3. The build log shows `Not looking for sigstore attachments: disabled by configuration`, so buildah falls back to the legacy detached-signature store, finds none, and rejects the image: `A signature was required, but no signature exists`.

Regular nodes verify these same images successfully (cri-o is configured to
fetch the signatures), but the MCO on-cluster build environment is not, so the
base-image pull inside the build cannot be verified. There is no `MachineOSConfig`
field to relax the build's signature policy, and relaxing the cluster
`ClusterImagePolicy` is a cluster-wide security change we did not make.

### Evidence

```sh
oc get clusterimagepolicy openshift -o yaml         # PublicKey rootOfTrust; scopes include ocp-v4.0-art-dev
oc get imagedigestmirrorset image-digest-mirror -o yaml   # quay.io/openshift-release-dev/* -> arosvc.azurecr.io
oc -n openshift-machine-config-operator logs <build-pod> -c image-build   # "Source image rejected: A signature was required, but no signature exists"
```

## Impact

- `scripts/12-rhcos-kernel-layer.sh apply` cannot complete on ARO: the
  `MachineOSBuild` fails and the mshv MCP goes `RenderDegraded`/`Degraded` while
  the failed `MachineOSConfig` exists (deleting the `MachineOSConfig` clears it).
- On-cluster layering (`MachineOSConfig`) is effectively unusable on ARO 4.22 for
  any pool whose base is a signed release image, i.e. all of them.

## Workaround used (documented, not a fix)

`scripts/12c-rhcos-kernel-layer-out-of-cluster.sh` builds the layer out-of-cluster:

1. Resolve the mshv base from its rendered MachineConfig `osImageURL` and rewrite
   it to the `ImageDigestMirrorSet` mirror.
2. `podman build` locally `FROM` that base (pulled with the cluster global pull
   secret, which has `arosvc.azurecr.io` credentials), swapping the kernel with
   `rpm-ostree override replace` — outside the cluster, so the in-build
   `ClusterImagePolicy` check does not apply.
3. Push the layered image to the internal registry.
4. Apply a `MachineConfig` for the `mshv` role that sets `osImageURL` to the
   built image. Because `osImageURL` and a pool `osImageStream` are mutually
   exclusive (`cannot override MachineConfig osImageURL and set MachineConfigPool
   spec.osImageStream.name simultaneously`), the script removes the pool's
   `osImageStream` (stashing it on the MachineConfig for revert).

Verified: the mshv node rebooted into the L1VH kernel
`6.12.0-211.49.1.1794_2777371478.el10_2` and the MSHV/L1VH host state
(`/dev/mshv`, `mshv_root`, "running as L1VH partition") remained intact
(`scripts/12b-verify-kernel-layer.sh`).

Caveats of the workaround:
- Removing the pool `osImageStream` means the pool no longer auto-tracks the
  rhel-10 stream across upgrades; the pool is pinned to the custom `osImageURL`
  until reverted. `revert` restores the `osImageStream`.
- The layered image is built from unsigned developer RPMs
  (`ALLOW_UNSIGNED_KERNEL_RPMS=true`); the sha256 lock is still enforced.

## Status / next steps

- **Open.** On-cluster `MachineOSConfig` layering does not work on ARO 4.22
  because the MCO build cannot verify the signed release base image. This is an
  MCO/on-cluster-build limitation (sigstore attachments disabled in the build
  environment) rather than a repo bug.
- Follow-ups:
  - File an OCP bug against the MCO on-cluster build for not honoring sigstore
    signature verification of the base image on clusters with a release-image
    `ClusterImagePolicy` + mirror (ARO).
  - Re-test on-cluster layering once the build environment can verify the base;
    then the `scripts/12` path can replace the `scripts/12c` workaround.
