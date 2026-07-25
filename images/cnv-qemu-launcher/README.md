# CNV launcher with QEMU 10.1.0-17.el9_8.3

Diagnostic only. This derives from the current CNV virt-launcher and atomically
updates only the eight QEMU RPMs already installed in that image.

The target build is published by Red Hat advisory
[RHBA-2026:28656](https://access.redhat.com/errata/RHBA-2026:28656), which
includes the fix `RHEL-184951: MSHV backport onto QEMU 10.1.0 is not able to
launch MSHV guests`.

RPM binaries are not committed. Place the eight signed x86_64 RPMs in an
external directory and set `QEMU_RPM_DIR` when building. The build script
checks SHA-256, signature key `fd431d51`, NEVRA, architecture, and source RPM
before copying them into a temporary build context.

The base image is pinned in the `Containerfile`. `QEMU_RPM_DIR` must point
outside the repository. The RPM transaction uses all eight packages together
and does not erase packages or use `--nodeps`, `--force`, `--replacefiles`, or
`--replacepkgs`.
