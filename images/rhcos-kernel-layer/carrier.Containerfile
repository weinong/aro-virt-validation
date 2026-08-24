# Carrier image for locally-provided RHCOS kernel RPMs.
#
# Built with podman by scripts/12a-build-kernel-rpm-carrier.sh and pushed to a
# registry the in-cluster MachineOSConfig build can pull from (by default the
# internal OpenShift registry). It contains nothing but the verified RPM files
# under /rpms so the on-cluster build can COPY --from them. scratch keeps the
# carrier minimal and free of any extra packages.
FROM scratch
COPY rpms/ /rpms/
