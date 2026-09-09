#!/usr/bin/env bash
# =============================================================================
# 16-mshv-kdump.sh - Enable kdump on the mshv pool to capture a vmcore from the
# Geneve/GSO csum_partial panic.
#
# Why: the panic is a fatal exception in interrupt context, so it never reaches
# journald, /sys/fs/pstore is empty, and the Azure serial console only gives the
# oops text. The central open question --
#   why does a CANONICAL direct-map read of `usable` RAM raise #GP? --
# can only be answered by inspecting the page tables and the skb at fault time,
# which requires a vmcore. See
# issues/2026-09-08b-gso-panic-reproduced-with-nokaslr.md.
#
# RHCOS already ships kexec-tools with a usable /etc/kdump.conf
# (path /var/crash, core_collector makedumpfile -l -d 31) and a kdump.service
# whose ExecCondition requires `crashkernel` on the kernel command line. So the
# only changes needed are the kernel argument and enabling the unit; this script
# deliberately does NOT overwrite the distro kdump configuration.
#
# ⚠️ Enabling this reboots every node in the mshv pool (kernel argument change).
#
# Usage:
#   ./scripts/16-mshv-kdump.sh enable    # apply MachineConfig, wait for rollout
#   ./scripts/16-mshv-kdump.sh verify    # check kdump is armed on every node
#   ./scripts/16-mshv-kdump.sh list      # list captured vmcores
#   ./scripts/16-mshv-kdump.sh disable   # remove the MachineConfig (reboots)
#
# Tunables (env): MSHV_MCP_NAME (default mshv),
#   CRASHKERNEL_HIGH (default 2G), CRASHKERNEL_LOW (default 256M).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

check_command oc || exit 1
check_command jq || exit 1

MSHV_MCP_NAME="${MSHV_MCP_NAME:-mshv}"
MC_NAME="${MC_NAME:-99-${MSHV_MCP_NAME}-kdump}"
# A 192-vCPU / 755 GiB guest needs a high reservation; plain `crashkernel=2G`
# would try to fit under 4 GiB and can fail to reserve.
CRASHKERNEL_HIGH="${CRASHKERNEL_HIGH:-2G}"
CRASHKERNEL_LOW="${CRASHKERNEL_LOW:-256M}"
# -d 31 keeps kernel data (~23 GiB here) and drops free/cache/user pages.
# --non-mmap avoids makedumpfile taking SIGSEGV on inaccessible pages.
CORE_COLLECTOR="${CORE_COLLECTOR:-makedumpfile --non-mmap -c -d 31 --message-level 7}"
COLLECT_WRAPPER="${COLLECT_WRAPPER:-/usr/local/bin/kdump-collect}"
# "-s" = kexec_file_load (kernel builds the elfcorehdr describing old memory);
# empty = kexec_load, where kexec-tools builds it from /proc/iomem instead. The
# two produce different PT_LOAD ranges, which matters when /proc/vmcore reads
# return EFAULT. Everything else here mirrors the RHCOS stock file, which is
# overwritten wholesale because it is shell-sourced and has no drop-in support.
# Default to kexec_load (empty) rather than the RHCOS stock "-s"
# (kexec_file_load): measured on these nodes, kexec_file_load aborted the dump
# after ~0.1-52% while kexec_load reached ~75%, because the two build different
# elfcorehdr PT_LOAD ranges. ${VAR-default} so an explicitly empty value survives.
KEXEC_ARGS="${KEXEC_ARGS-}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"
DEBUG_TIMEOUT="${DEBUG_TIMEOUT:-240}"

oc_() { oc --request-timeout="${REQUEST_TIMEOUT}s" "$@"; }

mshv_nodes() {
  oc_ get nodes -l "node-role.kubernetes.io/${MSHV_MCP_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

on_node() {
  local node="$1"; shift
  timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --quiet \
    --request-timeout="${REQUEST_TIMEOUT}s" -- chroot /host bash -c "$*" 2>&1 |
    grep -avE 'Starting pod|Removing debug|To use host|^Warning'
}

cmd_enable() {
  oc_ whoami >/dev/null || { log_error "Not logged in."; exit 1; }
  oc_ get mcp "${MSHV_MCP_NAME}" >/dev/null || {
    log_error "MachineConfigPool ${MSHV_MCP_NAME} not found."; exit 1; }

  log_warn "Enabling kdump changes a kernel argument: every ${MSHV_MCP_NAME} node will drain and reboot."
  log_info "Reserving crashkernel=${CRASHKERNEL_HIGH},high + ${CRASHKERNEL_LOW},low"

  # kdump.sh expands $CORE_COLLECTOR unquoted and pipes its output to
  # /dev/console, which on ARO is only reachable via serial boot diagnostics
  # (blocked by the managed-RG deny assignment). So the collector is a one-word
  # wrapper script, pulled into the kdump initramfs with extra_bins, that saves
  # makedumpfile's output next to the dump and preserves its exit code.
  log_info "core_collector: ${CORE_COLLECTOR}"
  local wrapper kdump_conf
  wrapper="$(cat <<WRAP
#!/bin/sh
log="\${2%/*}/makedumpfile.log"
${CORE_COLLECTOR} "\$1" "\$2" >"\$log" 2>&1
rc=\$?
cat "\$log" >/dev/console 2>/dev/null
exit \$rc
WRAP
)"
  kdump_conf="$(printf '%s\n' 'auto_reset_crashkernel yes' 'path /var/crash' \
    "extra_bins ${COLLECT_WRAPPER}" "core_collector ${COLLECT_WRAPPER}")"

  log_info "KEXEC_ARGS: '${KEXEC_ARGS}' ($([[ -n "${KEXEC_ARGS}" ]] && echo kexec_file_load || echo kexec_load))"
  local sysconfig_kdump
  sysconfig_kdump="$(cat <<SYSCONF
KDUMP_KERNELVER=""
KDUMP_COMMANDLINE=""
KDUMP_COMMANDLINE_REMOVE="hugepages hugepagesz slub_debug quiet log_buf_len swiotlb cma hugetlb_cma ignition.firstboot"
KDUMP_COMMANDLINE_APPEND="irqpoll nr_cpus=1 reset_devices cgroup_disable=memory mce=off numa=off udev.children-max=2 panic=10 acpi_no_memhotplug transparent_hugepage=never nokaslr hest_disable novmcoredd cma=0 hugetlb_cma=0 pcie_ports=compat kfence.sample_interval=0 initramfs_options=size=90%"
FADUMP_COMMANDLINE_APPEND=""
KEXEC_ARGS="${KEXEC_ARGS}"
KDUMP_IMG="vmlinuz"
KDUMP_IMG_EXT=""
VMCORE_CREATION_NOTIFICATION="yes"
SYSCONF
)"

  oc_ apply -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: ${MC_NAME}
  labels:
    machineconfiguration.openshift.io/role: ${MSHV_MCP_NAME}
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
        - path: ${COLLECT_WRAPPER}
          mode: 0755
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,$(printf '%s\n' "${wrapper}" | base64 -w0)"
        - path: /etc/sysconfig/kdump
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,$(printf '%s\n' "${sysconfig_kdump}" | base64 -w0)"
        - path: /etc/kdump.conf
          mode: 0644
          overwrite: true
          contents:
            source: "data:text/plain;charset=utf-8;base64,$(printf '%s\n' "${kdump_conf}" | base64 -w0)"
    systemd:
      units:
        - name: kdump.service
          enabled: true
  kernelArguments:
    - crashkernel=${CRASHKERNEL_HIGH},high
    - crashkernel=${CRASHKERNEL_LOW},low
EOF

  log_info "Waiting for the ${MSHV_MCP_NAME} pool to roll out (nodes will reboot)..."
  # The pool briefly still reports Updated=True before the render lands.
  sleep "${ROLLOUT_SETTLE_SECONDS:-30}"
  oc_ wait "mcp/${MSHV_MCP_NAME}" --for=condition=Updated=True --timeout=45m
  log_ok "Rollout complete."
  cmd_verify
}

cmd_verify() {
  local node failed=0
  for node in $(mshv_nodes); do
    log_info "---- ${node} ----"
    local out
    out="$(on_node "${node}" '
      printf "cmdline_crashkernel=%s\n" "$(grep -o "crashkernel=[^ ]*" /proc/cmdline | tr "\n" "," )"
      printf "kexec_crash_size=%s\n"    "$(cat /sys/kernel/kexec_crash_size)"
      printf "kexec_crash_loaded=%s\n"  "$(cat /sys/kernel/kexec_crash_loaded)"
      printf "kdump_enabled=%s\n"       "$(systemctl is-enabled kdump 2>&1)"
      printf "kdump_active=%s\n"        "$(systemctl is-active kdump 2>&1)"
      printf "vmcore_path=%s\n"         "$(awk "/^path/{print \$2}" /etc/kdump.conf)"
      printf "var_crash_free=%s\n"      "$(df -h --output=avail /var/crash 2>/dev/null | tail -1 | tr -d " ")"
    ')" || true
    printf '%s\n' "${out}" | sed 's/^/  /'
    # kexec_crash_loaded==1 is the only proof the crash kernel is actually armed.
    if ! grep -q '^kexec_crash_loaded=1$' <<< "${out}"; then
      log_error "${node}: crash kernel is NOT armed; a panic here will NOT produce a vmcore."
      failed=1
    fi
  done
  if (( failed )); then
    log_error "kdump is not armed on every node. Inspect 'systemctl status kdump' / 'journalctl -u kdump'."
    return 1
  fi
  log_ok "kdump armed on all ${MSHV_MCP_NAME} nodes."
}

cmd_list() {
  local node
  for node in $(mshv_nodes); do
    log_info "---- ${node} ----"
    on_node "${node}" 'ls -lhR /var/crash 2>/dev/null | head -40 || echo "(no /var/crash)"' | sed 's/^/  /'
  done
}

cmd_disable() {
  oc_ delete mc "${MC_NAME}" --ignore-not-found
  log_info "Waiting for the ${MSHV_MCP_NAME} pool to roll back (nodes will reboot)..."
  sleep "${ROLLOUT_SETTLE_SECONDS:-30}"
  oc_ wait "mcp/${MSHV_MCP_NAME}" --for=condition=Updated=True --timeout=45m
  log_ok "kdump MachineConfig removed."
}

case "${1:-verify}" in
  enable)  cmd_enable ;;
  verify)  cmd_verify ;;
  list)    cmd_list ;;
  disable) cmd_disable ;;
  *) log_error "Unknown action '${1}'. Use: enable|verify|list|disable"; exit 1 ;;
esac
