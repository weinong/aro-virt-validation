# Hybrid virt-launcher QEMU experiment

Diagnostic only. This image is not a supported OpenShift Virtualization build
and must not be described as a product fix.

The image keeps the current CNV virt-launcher, virt-launcher-monitor, libvirt,
configuration, RPM database, and default `/usr/libexec/qemu-kvm`. It adds the
upstream KubeVirt v1.8.2 QEMU runtime payload and its selected library, module,
firmware, and ROM paths under `/opt/qemu-upstream/rootfs`, and exposes this wrapper:

```text
/opt/qemu-upstream/bin/qemu-kvm
```

The wrapper uses the copied upstream dynamic loader and `/usr/lib64` tree, plus
the copied QEMU modules, BIOS, OVMF, and ROM data. It does not replace the CNV
QEMU used by normal VMIs. This permits a side-by-side direct-QEMU A/B before any
unsupported operator or launcher override is attempted.

## Build and verify

```sh
scripts/09-build-hybrid-virt-launcher.sh
scripts/10-verify-hybrid-virt-launcher.sh
```

Source images are pinned to amd64 child-manifest digests in `images.lock.env`.
Override variables are available for deliberate experiments:

```sh
CNV_LAUNCHER_IMAGE_OVERRIDE=<digest> \
UPSTREAM_LAUNCHER_IMAGE_OVERRIDE=<digest> \
HYBRID_IMAGE_OVERRIDE=<image> \
  scripts/09-build-hybrid-virt-launcher.sh
```

Set `PUSH_IMAGE=true` only after authenticating Podman to the target registry.

## Cluster smoke

Push the image, then run:

```sh
KUBECONFIG=<kubeconfig> \
HYBRID_IMAGE_OVERRIDE=<pullable-image-by-digest> \
HYBRID_IMAGE_PULL_SECRET_FILE=<dockerconfig-json> \
  scripts/11-hybrid-virt-launcher-smoke.sh
```

The pull secret is created only in the temporary smoke namespace. The script
uses a cleanup trap and does not modify HCO, KubeVirt, virt-operator, the CSV,
or the global cluster pull secret. It requires a digest-pinned image, confirms
the running pod's `imageID`, disables core dumps for expected abort probes, and
fails unless all probes produce their expected exit codes and signatures.
