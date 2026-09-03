# 2026-09-01 — MSHV/L1VH nodes hard-reset under KubeVirt conformance load (no in-guest panic)

> **SUPERSEDED 2026-09-03 — the "no in-guest panic / host hard-reset" premise was
> wrong.** Azure serial-console logs show every reset is actually a **guest kernel
> panic**: a general-protection fault at `csum_partial+0xe5/0x110` while
> software-checksumming a GSO segment of a Geneve(UDP-tunnel) packet on the OVS TX
> path (`Kernel panic - not syncing: Fatal exception in interrupt` → reboot). It
> looked like a silent host reset only because the panic is in interrupt context
> and never flushed to journald — it printed to the serial console only. See
> `issues/2026-09-03-mshv-reboots-are-guest-gso-csum-panics.md`. The load/Geneve
> correlation and both-nodes-reset findings below remain valid; the mechanism is
> a guest crash, **not** a faulty Azure Hyper-V host. The underlying reboot issue
> stays open.
>
> **TL;DR (as originally corrected):** MSHV/L1VH worker nodes hard-reset under sustained
> OpenShift Virtualization load. Originally thought to be one bad host (`bl5zw`),
> but the second node (`l7njd`) **also** resets once it carries the load — see the
> CORRECTION block below. This is a general L1VH-under-load reset, no in-guest panic.

## Summary

Under sustained OpenShift Virtualization workload (the ocp-virt-validation-checkup
compute suite rapidly creating/destroying `hyperv-direct` VMs), the MSHV node
`aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw` (`Standard_D192ds_v6`,
running the bonzini L1VH kernel `6.12.0-211.49.1.1794_2798046552.el10_2`)
**hard-resets repeatedly** — roughly every 4–30 minutes. This presents at the
cluster level as the node flapping `Ready=Unknown`; on the node it is an actual
reboot (`uptime` resets, new boot IDs).

The single-VM smoke test (`issues/2026-08-31b`) was stable; only **sustained
multi-VM load** triggers the resets.

## ⚠️ CORRECTION (2026-09-01, later run): BOTH MSHV nodes reset — this is not a bad-host

An initial reading of this issue (preserved below) concluded that `bl5zw` was a
uniquely faulty host because the second MSHV node `l7njd` "stayed stable under the
same kernel + load." **That conclusion was wrong.** It was an artifact of `l7njd`
not actually being under sustained VM load at the time (the first checkup run
scheduled the bulk of VMs onto `bl5zw`).

When the checkup **compute** suite was later pinned entirely to `l7njd` (by
tainting `bl5zw` `NoSchedule`; see `issues/2026-09-01b`), `l7njd` **also
hard-reset — repeatedly — with the identical signature** (abrupt reset, no clean
shutdown, no in-guest panic, MANA `selects TX queue …` storm as the last kernel
line). It simply tolerated far more load before failing:

```
l7njd boot history (journalctl --list-boots):
 -4  Aug31 23:02 -> Sep01 15:47   (~16.7h up — but essentially idle of VM churn)
 -3  15:48 -> 15:52   (~4 min)     <- compute suite pinned here at 14:20;
 -2  15:52 -> 16:06   (~14 min)       first reset ~87 min in, then repeated
 -1  16:06 -> 16:09   (~3 min)
  0  16:10 -> ...
```

Meanwhile `bl5zw`, once tainted and thus **idle**, stayed **up 15h39m** with zero
resets. So the corrected conclusion is symmetric and load-driven:

> **Both MSHV/L1VH nodes are stable when idle and hard-reset under sustained MSHV
> L2 guest churn**, on this platform, with the same signature. The per-host
> difference is only **time-to-first-reset** (`bl5zw` within minutes; `l7njd`
> ~87 min of compute-suite churn), which may reflect host variability or the
> lighter compute-only load on `l7njd` vs. compute+network+storage on `bl5zw`.

This is therefore a **general L1VH-under-load partition-reset bug**, not a single
bad host. The `bl5zw`-vs-`l7njd` "contrast" section below is **retained for the
record but its bad-host conclusion is superseded by this correction**. Note also
that the Prometheus `changes(node_boot_time_seconds)` readings that showed `l7njd
= 0 reboots` were unreliable: **`prometheus-k8s-0` runs on `l7njd`** and was taken
down by the very resets it should have recorded, so the monitoring stack missed
them. The node's own `journalctl --list-boots` / `uptime` is authoritative.

Reproduce the correction (run for `l7njd`):

```sh
oc debug node/aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd -- chroot /host bash -c '
  uptime
  journalctl --list-boots --no-pager | tail -8
  # each reset boot ends abruptly with the MANA storm, no clean shutdown:
  journalctl -b -1 -k --no-pager -o short-precise | tail -2
  journalctl -b -1 --no-pager | grep -icE "systemd-shutdown|Reached target.*Shutdown"   # 0
  journalctl -b -1 --no-pager | grep -icE "kernel panic|Call Trace|machine check|mce:"  # 0 real'
```

---

The original (now-superseded on the bad-host point) analysis follows.

## Key contrast (SUPERSEDED — see correction above): the 2nd node *looked* stable

> **Superseded:** the table/conclusion in this section reflect the moment when
> `l7njd` was not yet under sustained load. `l7njd` later reset repeatedly under
> the compute suite (see the CORRECTION block at the top). Kept for the record.

`l7njd` is the same everything (kernel `…2798046552`, `Standard_D192ds_v6`,
zone 1 / fault-domain 1, same OS layer) and it **did** run MSHV VMs and **did**
see the identical accelerated-NIC warning storm — yet it never reset:

| node  | uptime    | MSHV_CREATE_PARTITION | `selects TX queue >32` warnings | crash-reboots |
| ----- | --------- | --------------------- | ------------------------------- | ------------- |
| bl5zw | minutes   | many (dense)          | thousands                       | ~6 and counting |
| l7njd | 105 min   | 9                     | 12017                           | 0             |

Reproduce the per-node counts (run for each `NODE`):

```sh
NODE=aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd   # then repeat for bl5zw
oc debug node/$NODE -- chroot /host bash -c '
  echo "uptime: $(uptime)"
  echo "MSHV_CREATE_PARTITION: $(journalctl -k --no-pager | grep -c MSHV_CREATE_PARTITION)"
  echo "TX-queue>32 warnings:  $(journalctl -k --no-pager | grep -c "selects TX queue")"
  echo "crash reboots:"; journalctl --list-boots --no-pager | tail -8'
```

So this is **not** "any MSHV VM / the TX-queue mismatch resets the node" — but the
inference drawn here at the time (that `bl5zw`'s host was uniquely faulty) was
**wrong**: `l7njd` reset the same way once it carried the sustained load. The real
differentiator is **time-to-reset under load**, not whether the reset happens.
Both nodes exhibit a **platform/host-side L1VH-under-load reset**, not a
repo/kernel software bug (the kernel would have panicked; it didn't).

### Prometheus telemetry (corroboration)

Reproduce (Prometheus harness defined in "How to reproduce" → B, below):

```sh
# reboots per mshv node over 6h
promql 'changes(node_boot_time_seconds{instance=~".*mshv.*"}[6h])'
# peak concurrent virt-launcher pods (VM density) per node over 3h
promql 'max_over_time(count(kube_pod_info{pod=~"virt-launcher.*"}) by (node)[3h:1m])'
```

Result:

```
changes(node_boot_time_seconds[6h])            bl5zw = 6 reboots   l7njd = 0
max_over_time(count virt-launcher by node)     bl5zw peak = 3 VMs  l7njd peak = 1 VM
```

`bl5zw` peaked at only **3 concurrent VMs** — trivial for a 192‑vCPU / 755 GiB
node — yet still reset 6 times, while `l7njd` ran VMs with zero reboots. A per-host
capacity limit of ~3 VMs is implausibly low, so the evidence leans toward
**`bl5zw`'s underlying Azure Hyper-V host being faulty for L1VH** rather than a
generic density limit.



## The reset comes from below the guest kernel (Hyper-V host), not a kernel panic

Evidence that this is a host/hypervisor-level reset of the L1VH partition, not an
in-guest crash. Reproduce each with `oc debug node/bl5zw -- chroot /host bash -c '<cmd>'`:

- **No kernel panic / oops / soft-lockup / Call Trace** anywhere before each reset.
  Every boot's last log lines are ordinary VM network activity, then the log ends
  abruptly with no shutdown sequence.
  ```sh
  # count panic indicators in the previous boot (returns 0), then eyeball the abrupt end:
  journalctl -b -1 --no-pager | grep -icE "kernel panic|BUG:|Oops|soft lockup|hard LOCKUP|rcu.*stall|watchdog:|general protection|unable to handle kernel|Call Trace"
  journalctl -b -1 --no-pager | grep -icE "Reached target.*(Shutdown|Reboot)|systemd-shutdown|Stopping .* kubelet"   # 0 = no clean shutdown
  journalctl -b -1 --no-pager | tail -20   # last lines are TX-queue warnings, then nothing
  ```
- `sysctl kernel.panic_on_oops = 1`, `kernel.panic = 10` — a real oops/panic would
  **print a stack trace and delay 10s** before rebooting. The abrupt end with no
  trace and no 10s delay rules out an in-guest panic.
  ```sh
  sysctl kernel.panic_on_oops kernel.panic kernel.softlockup_panic kernel.hung_task_timeout_secs
  ```
- `RuntimeWatchdogUSec = 0` and no `/dev/watchdog*` device — **not** a
  software/hardware watchdog reset either. No MCE / hardware error in any boot.
  ```sh
  systemctl show -p RuntimeWatchdogUSec; ls -la /dev/watchdog* 2>/dev/null || echo "no watchdog dev"
  journalctl -k --no-pager | grep -icE "mce|machine check|Hardware Error|GHES|CPER"   # 0
  ```
- The node boots as `Hyper-V: running as L1VH partition` (Azure Hyper-V,
  `Host Build 10.0.26102.3641`). With no guest panic and no watchdog, the reset
  originates from the Hyper-V host / L1 hypervisor resetting the L1VH partition
  when its MSHV (L2) guests run under load.
  ```sh
  journalctl -k --no-pager | grep -iE "L1VH|Hyper-V:|Host Build" | head
  ```

### Crash cadence (boot end = reset time), correlated with VM load

```sh
oc debug node/aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw -- \
  chroot /host journalctl --list-boots --no-pager | tail -8
```

```
-6  2026-08-31 20:14 -> 23:20   (stable 3h — BEFORE the checkup created VMs here)
-5  2026-08-31 23:21 -> 23:33   (~12 min)
-4  2026-08-31 23:34 -> 23:43   (~9 min)
-3  2026-08-31 23:44 -> 23:48   (~4 min)
-2  2026-08-31 23:49 -> 00:20   (~31 min)
-1  2026-09-01 00:21 -> 00:33   (~12 min)
 0  2026-09-01 00:34 -> ...
```

The resets began at 23:20, exactly when the checkup started scheduling
`hyperv-direct` test VMs onto `bl5zw` (confirm which node ran the VMs with
`oc get pods -A -o wide | grep virt-launcher | awk '{print $8}' | sort | uniq -c`).
Each boot ends during heavy VM traffic. The **last kernel line sits at the exact
reset second with no silent gap** (kernel was busy, not hung):

```sh
oc debug node/aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw -- chroot /host bash -c '
  for b in -1 -2 -3; do journalctl -b $b -k --no-pager -o short-precise | tail -1; done'
# -> ...00:33:52.60  kernel: enP30832s1 selects TX queue 172 ...   (then reset; new boot ~00:34)
```

### Node facts

```sh
oc debug node/aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw -- chroot /host bash -c '
  uptime; free -g | head -2
  journalctl -k --no-pager | grep -iE "L1VH|Nested features|Host Build|Disabling IBT"'
oc get machine -n openshift-machine-api aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw \
  -o jsonpath="{.spec.providerSpec.value.vmSize} zone={.spec.providerSpec.value.zone}{\"\n\"}"
```

- Kernel: `6.12.0-211.49.1.1794_2798046552.el10_2` (bonzini L1VH), RHCOS 10.2.
- `Hyper-V: running as L1VH partition`, `Nested features: 0x0`,
  `Hyper-V: Disabling IBT because of Hyper-V bug`, `Host Build 10.0.26102.3641`.
- VM size `Standard_D192ds_v6` (192 vCPUs, ~755 GiB). Load/memory were low at
  reset time (load ~1.3, 15 GiB/755 used) — not resource exhaustion.
- The stock `using unsupported MSHV_CREATE_PARTITION ioctl` message is present on
  each VM start (benign for a single VM per `issues/2026-08-31b`, but every VM
  creation exercises this path).

### Possibly-related network warnings

Immediately before each reset the kernel floods (rate-limited, 1000+ suppressed):

```
enP30832s1 selects TX queue 172, but real number of TX queues is 32
```

`enP30832s1` is the Azure MANA accelerated-networking VF (`hv_netvsc eth0` is the
synthetic failover pair). The node has 192 CPUs but the VF exposes 32 TX queues,
so per-CPU queue selection picks indices > 31. **This is a benign, volume-
independent warning** (it fires based on which CPU transmits, not throughput):
`l7njd` logged **12017** of them without resetting, and measured throughput was
trivial (see below). It is a red herring for the reset, worth flagging to the
kernel team only as noise to fix. Note there is **no VF revoke / adapter reset /
`hv_pci` / `vmbus` device event** — the NIC is not failing:

```sh
oc debug node/aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw -- chroot /host bash -c '
  journalctl -b -1 -k --no-pager | grep -iE "mana |hv_netvsc|hv_pci|vmbus|VF (registered|slot|unregister|removed)|Data path switched|reset adapter" | tail
  journalctl -b -1 -k --no-pager | grep -c "selects TX queue"'   # thousands of the benign warning
```

### Resource exhaustion ruled out (Prometheus, ~2h window)

None of the usual suspects were anywhere near a limit on either node. Reproduce
(Prometheus harness in "How to reproduce" → B):

```sh
promql 'max_over_time( (1 - avg by (instance)(rate(node_cpu_seconds_total{mode="idle",instance=~".*mshv.*"}[2m]))) [120m:1m] )'
promql 'min_over_time( (node_memory_MemAvailable_bytes{instance=~".*mshv.*"}/1073741824) [120m:1m] )'
# find which iface carries VM traffic, then compare nodes:
promql 'topk(6, max_over_time( (rate(node_network_transmit_bytes_total{instance=~".*mshv.*",device!~"lo|veth.*|.*@.*"}[1m])/1048576) [120m:1m] ))'
promql 'topk(6, max_over_time( (rate(node_network_transmit_packets_total{instance=~".*mshv.*",device!~"lo|veth.*"}[1m])) [120m:1m] ))'
```

Result:

```
peak CPU utilization           bl5zw 0.67    l7njd 0.60      (not saturated)
min MemAvailable               bl5zw 738 GiB l7njd 739 GiB   (of 755 — barely used)
peak eth0 TX                   bl5zw 0.39 MB/s / 1708 pps    l7njd 0.85 MB/s / 2469 pps
peak Geneve overlay TX pps     bl5zw 950     l7njd 68        (device genev_sys_6081)
```

Network throughput was **sub-1 MB/s** — this is not a load/throughput reset.
Notably `l7njd` pushed *more* eth0 traffic than `bl5zw` yet never reset. The only
dimensions where `bl5zw` led were **Geneve overlay packet rate (~14×)** and
**VM count (3 vs 1)** — i.e. more MSHV guest lifecycle churn, not more load.

### Refined trigger: MSHV guest lifecycle churn, not resource load

With CPU/memory/network all low and no in-guest fault, the reset correlates with
the **rate of MSHV L2 partition create/destroy operations** (each `virt-launcher`
start issues `MSHV_CREATE_PARTITION` hypercalls to the L1 hypervisor). `bl5zw`
cycled more VMs and reset repeatedly; `l7njd` cycled fewer and stayed up. The
kernel was actively logging (MANA TX warnings) at the exact reset instant with no
gap, so the L1VH partition was **hard-reset mid-operation by the host**, not hung.


## Impact

- **Invalidates the validation checkup**: when `bl5zw` resets, its test VMs die,
  so compute specs fail with `skipping vmi ...: phase is not Running` and retry
  (`flake-attempts=3`). Results are dominated by node-reset fallout rather than
  clean pass/fail. Az `run-command`/boot-diagnostics are blocked by the ARO deny
  assignment, so host-side reset logs require Red Hat SRE / Azure host access.
- This is a **platform/L1VH stability issue under load**, not a repo or cluster
  misconfiguration.

## How to reproduce

Prereqs: `oc` logged in as cluster-admin against this cluster
(`make aro-login`, or `az aro get-admin-kubeconfig -g <rg> -n <cluster> -f ./kubeconfig
&& export KUBECONFIG=$PWD/kubeconfig`), plus `curl` and `jq`.

### A) Node kernel/journal evidence

RHCOS journald is **persistent** (`/var/log/journal/` exists), so the crashed
boots are retained and inspectable after the fact via a debug pod:

```sh
NODE=aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw    # the crashing node
oc debug node/$NODE -- chroot /host bash -c '<command>'
```

Confirm which node the checkup VMs landed on (that is the one that crashes):

```sh
oc get pods -A -o wide | grep virt-launcher | awk "{print \$8}" | sort | uniq -c
```

The exact per-claim commands are inlined next to each finding above (crash cadence,
no-panic/oops, watchdog/MCE ruling, last-kernel-line-at-reset, MANA/VF check).

### B) Prometheus / PromQL harness

The in-cluster monitoring stack retains ~15 days. Query it through the
`thanos-querier` route with a short-lived token for the `prometheus-k8s` SA:

```sh
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=15m)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
promql() {
  curl -sk -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "query=$1" "https://$THANOS/api/v1/query" \
  | jq -r '.data.result[] | "\(.metric.instance // .metric.node // .metric.device // "?")\t\(.value[1])"'
}
# examples (all queries used above accept this helper):
promql 'changes(node_boot_time_seconds{instance=~".*mshv.*"}[6h])'
```

(The bracketed `[…:1m]` subquery ranges in the queries above are relative to "now";
widen the outer range or use the `/api/v1/query_range` endpoint with explicit
`start`/`end` epochs to target the historical reset window, e.g.
`--data-urlencode start=$(date -d '2026-08-31T23:10Z' +%s)`.)

### C) Why host-side evidence is unreachable (even with root on the nodes)

Root **inside** the node only sees the *guest* kernel, which is fully mined above
and shows no in-guest fault — the reset comes from one level below, the Azure
Hyper-V **host/parent partition**, which is a hard virtualization isolation
boundary the guest cannot cross. Host logs/dumps live only in Azure's control
plane, and ARO's **deny assignment** on the managed resource group blocks the
tenant from reaching them. Inspect the deny assignment:

```sh
SUB=<subscription-id>
az rest --method get --url \
 "https://management.azure.com/subscriptions/${SUB}/resourceGroups/aro-wa2fvt52/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01" \
 | jq '.value[0].properties | {actions:.permissions[].actions, dataActions:.permissions[].dataActions, excludes:[.excludePrincipals[].id]}'
# -> actions:    ["*/action","*/delete","*/write"]
#    dataActions: []          <-- data-plane is NOT denied; only management actions/writes/deletes are
#    excludes:    <ARO RP first-party SPs only>   (tenant users are NOT excluded)
```

Consequences, each verified:

- **Managed boot diagnostics** (the ARO path) is retrieved with
  `Microsoft.Compute/virtualMachines/retrieveBootDiagnosticsData/action` — an
  `*/action`, so **denied** even for a Subscription Owner (the deny overrides RBAC).
  Note the two CLI commands behave differently — only the one that hits the action
  is deny-blocked:
  ```sh
  # the MANAGED endpoint -> denied:
  az vm boot-diagnostics get-boot-log-uris -g aro-wa2fvt52 -n <vm>
  #   -> DenyAssignmentAuthorizationFailed (retrieveBootDiagnosticsData/action)
  az rest --method post --url ".../virtualMachines/<vm>/retrieveBootDiagnosticsData?api-version=2023-09-01"
  #   -> DenyAssignmentAuthorizationFailed: "...has permission... however access is denied because of the deny assignment"

  # the COMMON get-boot-log -> NOT deny-blocked, but has no source for managed diags:
  az vm boot-diagnostics get-boot-log -g aro-wa2fvt52 -n <vm>
  #   -> "ERROR: Please enable boot diagnostics."  (reads instanceView.serialConsoleLogBlobUri, which is empty)
  ```
- **Cannot "enable" boot diagnostics to work around it either** — that is a
  `Microsoft.Compute/virtualMachines/write`, and the full VM PUT re-validates a
  linked NIC action that the deny blocks (boot diagnostics is in fact already
  `enabled: true`; the "Please enable" above is just the empty managed URI):
  ```sh
  az vm boot-diagnostics enable -g aro-wa2fvt52 -n <vm>                      # managed re-enable
  az vm boot-diagnostics enable -g aro-wa2fvt52 -n <vm> --storage <account>  # point at our storage
  #   both -> LinkedAuthorizationFailed: has Microsoft.Compute/virtualMachines/write, but
  #           Microsoft.Network/networkInterfaces/join/action on the NIC "is blocked by deny assignments"
  ```
- The **read** paths don't expose it: the VM instance view `bootDiagnostics` is
  empty (the SAS URIs only come from the denied retrieve action):
  ```sh
  az vm get-instance-view -g aro-wa2fvt52 -n <vm> --query instanceView.bootDiagnostics   # {}
  ```
- **Data-plane isn't denied**, but doesn't help here: the managed serial log lives
  in a **Microsoft-owned** storage account (VM `diagnosticsProfile.bootDiagnostics`
  is `{enabled:true}` with **no** `storageUri`), not the cluster account; the
  cluster account (`clusterb5mtjrmc65`) is network-locked (`defaultAction: Deny`)
  and `listKeys` is a denied `*/action`; and ARO worker nodes have **no managed
  identity** to authenticate a data-plane call from in-VNet:
  ```sh
  # on the node: no identity -> no token
  oc debug node/<node> -- chroot /host curl -s -H Metadata:true \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/"
  ```
- **IMDS Scheduled Events** (host maintenance/reboot notices, reachable from
  guest root) were **empty** — Azure did not record a planned host event for the
  resets:
  ```sh
  oc debug node/<node> -- chroot /host curl -s -H Metadata:true \
    "http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01"   # {"DocumentIncarnation":..,"Events":[]}
  ```
- `az aro` exposes no console/boot/serial command (only `get-admin-kubeconfig`).

**Net:** host-side reset logs/dumps require the ARO RP first-party principal
(the only identity excluded from the deny) — i.e. a Red Hat SRE / Microsoft
escalation. Nothing reachable from tenant RBAC or guest root contains the
host's reason for the reset.

### D) This is documented, by-design ARO behavior (not a misconfiguration)

The empirically-observed deny above matches the published ARO contract, so the
escalation path (support case → Red Hat/Microsoft) is the *only* sanctioned way
to get host-side data — this is not something to "fix" on the cluster:

- **Red Hat KB 7024799 — "Azure Red Hat OpenShift - Deny Assignment in
  Resourcegroup"** (<https://access.redhat.com/solutions/7024799>): states that by
  default you **cannot stop/start machines or modify resources** (VMs, disks,
  NICs, storage accounts, etc.) in the managed resource group via the Azure
  Portal or `az` CLI; the **DenyAssignment is documented and expected behavior**;
  the **cluster service principal is the only identity excluded**, everything else
  is denied. The example failure ("access is denied because of the deny
  assignment … on `Microsoft.Compute/virtualMachines/write`") is exactly the
  `LinkedAuthorizationFailed` / `DenyAssignmentAuthorizationFailed` we hit above.
  Tracked upstream as RFE-6779. Root cause per the KB: the **Azure ARO-RP**
  configures the DenyAssignment on the auto-generated managed RG.
- **ARO Support Policy** (`support-policies-v4`,
  <https://learn.microsoft.com/en-us/azure/openshift/support-policies-v4>):
  modifying/managing the resources in the managed resource group is **unsupported**
  and can void support — i.e. even the workarounds we ruled out above are
  off-limits by policy, not just by the deny.
- **ARO Responsibility Assignment Matrix**
  (<https://learn.microsoft.com/en-us/azure/openshift/responsibility-matrix>):
  **Worker nodes**, **Physical Infrastructure and Security**, and **Platform
  monitoring** are **Microsoft + Red Hat** responsibilities (not the customer);
  and for **Logging**, Microsoft/Red Hat "**Provide audit logs upon customer
  request**" while the customer "**Request[s] platform audit logs through a
  support case for researching specific incidents.**" The Hyper-V host reset of a
  worker node's L1VH partition falls squarely in the Microsoft/Red Hat-owned
  layers, and the sanctioned way to obtain the host-side evidence is a **support
  case**, consistent with the deny assignment blocking direct tenant access.

So the correct disposition here is to **open a Red Hat/Microsoft support case** for
the host-side (Hyper-V) reset logs of `bl5zw` — the deny assignment is intended,
documented behavior and there is no supported tenant-side path around it.

## Next steps

- Report to bonzini / Red Hat MSHV + kernel team: the Azure Hyper-V host
  hard-resets the L1VH partition under sustained MSHV guest churn, with no in-guest
  panic, on **both** MSHV nodes tested (`bl5zw` within minutes; `l7njd` after
  ~87 min of compute-suite churn, then repeatedly). Provide the crash cadence for
  both, the "no panic / no watchdog / no MCE" ruling, the host build
  (`10.0.26102.3641`), the L1VH kernel NVR, and the fact that **both nodes are
  stable when idle and reset only under load** (`bl5zw` stayed up 15h39m once
  tainted/idle).
- **Superseded bad-host test:** an earlier plan here was to delete the `bl5zw`
  Machine to test whether a fresh host is stable. That test is no longer
  meaningful as stated — `l7njd` (a different host) also resets under load, so the
  problem is not `bl5zw`-specific. A more useful experiment is to **characterize
  the load threshold / time-to-reset** as a function of VM churn rate and
  concurrency on a given host.
- **Open a Red Hat/Microsoft support case** for host-side (Hyper-V) reset logs /
  dumps and the physical host IDs for **both** `bl5zw` and `l7njd`. Per the ARO
  Responsibility Matrix and KB 7024799 (see § D), the managed-RG deny assignment is
  by-design and the support case is the *only* sanctioned path to host-side
  evidence — ARO denies tenant access to VM run-command and boot diagnostics, and
  modifying managed-RG resources is explicitly unsupported.
- Investigate whether the accelerated-NIC TX-queue mismatch (192 CPU vs 32 queues)
  is a contributing trigger; both nodes log thousands of the same warnings, and it
  is the last kernel line before every reset — worth flagging even if it is only a
  co-factor.
- Reproduce with resource load ruled out: since CPU/memory/network were all low,
  the driver is the MSHV L2 partition create/destroy path — a churn-focused repro
  (rapidly start/stop many small VMs on one node) is the tightest reproducer, and
  should be run long enough (>90 min) to catch the slower-to-reset hosts.
- The checkup cannot produce a clean full-suite result until the nodes stop
  resetting; the single-VM boot test remains the stable signal for the kernel +
  CPU-model work.
