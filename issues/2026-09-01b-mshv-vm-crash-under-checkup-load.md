# 2026-09-01 — Compute suite on `l7njd`: VM crashes were the node hard-resetting (+ a separate console-stall)

> **⚠️ CORRECTION (added after the run finished).** This note was first written
> mid-run under the belief that `l7njd` was a *stable* node and the VM crashes were
> independent guest/qemu instability. **That was wrong.** After the run, `l7njd`'s
> own `journalctl --list-boots` showed it **hard-reset repeatedly starting ~15:47**
> (≈87 min into the compute suite) — the *same* L1VH-under-load reset as `bl5zw`
> (see `issues/2026-09-01-mshv-node-hard-reset-under-load.md`, CORRECTION block).
> The "`l7njd` = 0 reboots" reading was a monitoring artifact: **`prometheus-k8s-0`
> runs on `l7njd`** and was taken down by the resets, so it never recorded them.
>
> Consequences for this note, section by section:
> - The **bulk of the failures** (the growing `The VirtualMachineInstance crashed`
>   / `phase is not Running` / `guest didn't reboot` cluster from ~88 min on) are
>   **downstream of `l7njd` hard-resetting** — when the L1VH node resets, every VM
>   on it dies at once. This is **not** independent "guest instability on a healthy
>   node"; it is the node-reset issue, now shown on `l7njd` too.
> - The **early `test_id:1528` console stalls (14:37–14:41)** *did* occur while
>   `l7njd`'s boot was continuously up (boot `-4`, 23:02→15:47), so they are a
>   **genuinely separate, still-open** intermittent serial-console/VM-stall
>   phenomenon that the reset does not explain. The boot/console rule-outs below
>   (probe VM booted fine, serial healthy) were also collected during that stable
>   window and remain valid.
> - The **`l7njd` stayed stable / re-confirms bl5zw is host-specific** section is
>   **retracted** — see the replacement section below.
>
> Net: this file is retained for the console-stall characterization and the taint
> methodology; its original "healthy node" thesis is superseded by the node-reset
> finding.

## Summary (corrected)

The ocp-virt-validation-checkup **compute** suite was pinned to the MSHV node
`aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd` (by tainting `bl5zw`
`NoSchedule`) to isolate it from the reset-prone `bl5zw`. Two things happened:

1. **Early, during confirmed-stable operation (~14:37–14:41):** a handful of
   `[test_id:1528] should survive guest shutdown, multiple times` failures that
   present as "serial console slowness." These are **not** slow boot or console
   echo lag (ruled out below); root cause is **still open** and was not
   reproducible in isolation.
2. **From ~87 min in (~15:47 onward):** a growing cluster of `The
   VirtualMachineInstance crashed` / `phase is not Running` / `guest didn't reboot`
   failures — which turned out to be **`l7njd` itself hard-resetting under the
   load** (same issue as `bl5zw`), killing all its VMs and ultimately the test
   runner pod (`Exit Code 137`) at ~16:06. See the replacement section
   "What actually happened at ~87 min: `l7njd` reset" below.

## The "console slowness" is not console slowness

The `test_id:1528` failure surfaces as:

```
[FAILED] Expected success, but got an error:
    send to spawned process command reached the timeout 9.960224055s
In [It] at: /upstream/kubevirt/tests/vm_test.go:389
```

The tell-tale timeline for that spec (from the job log) is a **~3-minute gap that
ends in a console EOF + reconnect, after which login succeeds instantly**:

```
14:33:56  Guest shutdown (poweroff sent to a RunStrategy:Always VM)
14:34:12  replacement VMI is Running, serial console obtained
14:34:12  Sent "\n"          <- LoginToAlpine begins
14:34:17  Sent "\n"
   ... ~3 minutes of nothing ...
14:37:17  read closing down: EOF          <- the serial stream died / was reset
14:37:32  Sent "\n"
14:37:38  "localhost login:" matches      <- login now instant after reconnect
```

That is `goexpect` **blocking on a serial-console stream that hung for ~3 min**,
until the stream EOFs, the test reconnects to the VMI, and the (healthy) guest's
`login:` appears instantly. Note the guest **recovered** here — so for this early,
stable-window case it is a **serial-console stream stall, not a guest/qemu crash**
and not slow boot. The console was not "slow" in the echo-latency sense; the
stream stalled entirely, then resumed on reconnect. Root cause remains open (see
the open-items section). (This is distinct from the later failures, where the VMs
died because the whole node reset.)

### Ruled out: slow guest boot

A controlled probe VM (`RunStrategy: Always`, fedora-with-test-tooling, pinned to
`l7njd`, same MSHV device injection as the checkup VMs) restarted 12 times with
race-free VMI-UID detection booted to guest-agent every time, **no multi-minute
stall**:

```
iter  to_Running(s)  Running->AgentConnected(s)  total(s)
01       30.7            78.2                       108.8
02       16.1            96.9                       113.0
03..05   ~13-14          ~38-42                      ~51-57
06       14.6            73.1                        87.6
07       12.7            78.0                        90.7
08..12   ~14-16          ~36-42                      ~51-57
```

Full guest boot-to-agent ranged **37-97 s** (≈2.6× variance) with **no >3 min
outlier** — so the extreme stall in the checkup is **not** in the basic
boot/agent path.

### Ruled out: console echo lag

On the same probe VM (agent connected = guest fully up), the serial console was
**healthy in 6/6 checks** — the `login:` prompt returned within the window every
time (consistent 32 bytes/round):

```
round  serial_bytes_in_10s  saw_prompt
01..06        32               yes   (all six)
```

Normal serial login in the checkup itself is likewise ~2 s (the ~7 s measured
includes `LoginToAlpine`'s fixed 5 s newline wait). So it is binary: **either a
fast/healthy console, or a full multi-minute stall when the VM crashes** — never
gradual lag.

## The failure cluster from ~87 min: VMs die because the node resets

> **Corrected framing.** This cluster of failures is **downstream of `l7njd`
> hard-resetting** (see the correction banner and the replacement section below),
> not independent guest instability. When the L1VH partition resets, every VM on
> it dies simultaneously — which is exactly what these signatures show.

The failures from ~88 min on share one proximate symptom — VMs not staying
Running:

| failure signature (job log)                                   | meaning                                  |
| ------------------------------------------------------------- | ---------------------------------------- |
| `The VirtualMachineInstance crashed.` (event) → `phase=Failed`| qemu/guest died                          |
| `send to spawned process command reached the timeout`         | serial stream to a dead qemu (test_id:1528) |
| `expected guest to reboot (boot_id change)`                   | guest reboot did not take effect         |
| `skipping vmi/pod ... phase is not Running` (many)            | VMI/launcher never reached Running       |
| `pgrep -f "monitor.*uid <uid>" ... exit code 1`               | qemu monitor process gone for a VMI      |

Live confirmation of a crash on `l7njd`:

```
$ oc get events -n kubevirt-test-default1 --sort-by=.lastTimestamp | grep -iE "crash|Stopped"
Warning  Stopped  virtualmachineinstance/testvmi-wpn9f-...  The VirtualMachineInstance crashed.
$ oc get vmi -n kubevirt-test-default1 -o json | jq -r '.items[]|select(.status.phase!="Running")|"\(.metadata.name) \(.status.phase)"'
testvmi-wpn9f-... Failed
```

The **qemu-level crash reason was not separately captured** — but the correction
below shows why: the "crashes" are the **node resetting under it**, so there is no
per-VM qemu fault to find for that cluster. (A genuinely separate, still-open item
is the early `test_id:1528` console stall during confirmed-stable operation.)

## What actually happened at ~87 min: `l7njd` reset (retraction of "node stayed stable")

**Retracted claim:** an earlier version of this note asserted `l7njd` "never reset
(0 reboots in 3h)" and concluded the crashes proved a *guest* issue on a *healthy*
node, distinct from `bl5zw`'s host resets. **Both halves are false.**

`l7njd`'s own boot history (authoritative — the node's persistent journal, not
Prometheus) shows it hard-reset repeatedly once the compute suite loaded it:

```sh
oc debug node/aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd -- \
  chroot /host journalctl --list-boots --no-pager | tail -6
# -4  Aug31 23:02 -> Sep01 15:47   (~16.7h up, but idle of heavy VM churn)
# -3  15:48 -> 15:52   (~4 min)     <- compute suite pinned here 14:20; ~87 min to 1st reset
# -2  15:52 -> 16:06   (~14 min)
# -1  16:06 -> 16:09   (~3 min)
#  0  16:10 -> ...
```

Each reset boot ends abruptly (no clean shutdown, no in-guest panic) with the same
MANA `enP30832s1 selects TX queue N, but real number of TX queues is 32` storm as
`bl5zw` — i.e. the **identical L1VH-under-load reset signature**. The test runner
pod was killed by these resets with `Exit Code 137` /
`ContainerStatusUnknown: The container could not be located`, and the job ended
`Failed` at ~106 min with **no results ConfigMap written**.

**Why the original "0 reboots" reading was wrong:** the check used
`changes(node_boot_time_seconds[3h])` via Prometheus, but **`prometheus-k8s-0`
runs on `l7njd`** and was taken down by the resets, so the monitoring stack never
scraped the new boot times. Always cross-check node resets with the node's own
`uptime` / `journalctl --list-boots`.

**Corrected conclusion:** the mass VM "crashes" here are the **same node-reset
issue as `bl5zw`, now demonstrated on `l7njd`** — see
`issues/2026-09-01-mshv-node-hard-reset-under-load.md`. Both MSHV nodes are stable
when idle and reset under sustained MSHV load; `l7njd` merely tolerated ~87 min of
compute-suite churn before its first reset (and `bl5zw`, once tainted and idle,
stayed up 15h39m). What remains genuinely *separate and open* is only the early
`test_id:1528` serial-console stall observed during `l7njd`'s stable window.

## Test intervention used (NOT a fix)

To force all checkup test VMs onto `l7njd` and off the reset-prone `bl5zw` while
keeping both BeforeSuite gates satisfied (which require *every* worker node to be
`kubevirt.io/schedulable=true` and MSHV-capable — see
`issues/2026-08-31c-checkup-node-schedulable.md`), `bl5zw` was **tainted
`NoSchedule`**:

```sh
oc adm taint nodes aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw \
  hypervisor-reset-suspect=true:NoSchedule --overwrite
```

`virt-handler` only tolerates `CriticalAddonsOnly`, so the already-running
virt-handler pod on `bl5zw` is **not** evicted by `NoSchedule` (that effect does
not evict running pods) — both nodes keep `kubevirt.io/schedulable=true`, so both
gates still pass, but the checkup's test VMs (which carry no matching toleration)
are repelled and all land on `l7njd`.

This is a **deliberate experiment scaffold to isolate the two problems**, not a
fix for either. To revert:

```sh
oc adm taint nodes aro-virt-test-8gpzs-worker-mshv-centralus1-bl5zw \
  hypervisor-reset-suspect- 
```

## How to reproduce

Prereqs: `oc` as cluster-admin, `podman` + quay.io login, `jq`, and `virtctl`
(download from the cluster):

```sh
curl -sk -o /tmp/virtctl.tar.gz \
  "https://hyperconverged-cluster-cli-download-openshift-cnv.$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')/amd64/linux/virtctl.tar.gz"
tar xzf /tmp/virtctl.tar.gz -C /tmp && chmod +x /tmp/virtctl
```

### A) Run the compute suite pinned to a single MSHV node

```sh
oc adm taint nodes <reset-prone-mshv-node> hypervisor-reset-suspect=true:NoSchedule --overwrite
TEST_SUITES=compute ./scripts/08-cnv-validation-checkup.sh
# watch failures accrue:
JOB=$(oc get jobs -n ocp-virt-validation -o name | head -1)
oc logs -n ocp-virt-validation $JOB | grep -oE '•|\[FAILED\]' | sort | uniq -c
```

### B) See the VM crashes directly

```sh
oc get events -n kubevirt-test-default1 --sort-by=.lastTimestamp | grep -iE 'crash|Stopped'
oc get vmi -n kubevirt-test-default1 -o json \
  | jq -r '.items[]|select(.status.phase!="Running")|"\(.metadata.name) \(.status.phase)"'
```

### C) Confirm boot / console are healthy in isolation (rule-outs, stable window only)

Create a `RunStrategy: Always` probe VM pinned to the node and measure
reboot→AgentConnected latency (race-free via VMI UID change) and serial-console
responsiveness. During `l7njd`'s stable window these were **healthy** (12 reboots
booted to guest-agent in 37–97 s, no multi-minute stall; serial console returned
the login prompt in 6/6 checks) — which is what rules out *slow boot* and *console
echo lag* for the early `test_id:1528` stall. (Harness: `/tmp/opencode/reboot-latency.py`
and inline `virtctl restart`/`virtctl console` loops; probe VM in the
`console-latency` namespace.) NB: these rule-outs say nothing about the later
failures, which were the node resetting.

## Impact

- The compute suite **cannot produce a clean result on MSHV**: the run on `l7njd`
  was destroyed by `l7njd` **hard-resetting under the load** (~87 min in, then
  repeatedly), which killed the test VMs and the test runner pod (`Exit Code 137`)
  and left no results ConfigMap.
- This is the **same L1VH-under-load node-reset problem** as `bl5zw`, not a
  separate "guest crash" issue — see `issues/2026-09-01-mshv-node-hard-reset-under-load.md`.
  The only genuinely separate, still-open observation here is the early
  `test_id:1528` serial-console stall seen during confirmed-stable operation.

## Open items / next steps

- **Primary:** this folds into the node-reset issue
  (`issues/2026-09-01-mshv-node-hard-reset-under-load.md`) — both MSHV nodes reset
  under sustained load; pursue the host-side reset root cause via the Red Hat /
  Microsoft support case described there.
- **Separate open item — the early `test_id:1528` console stall:** during `l7njd`'s
  confirmed-stable window (14:37–14:41), the post-`poweroff` replacement VMI's
  serial `login:` intermittently stalled ~3 min then recovered after a console
  EOF+reconnect. Not slow boot, not echo lag (ruled out above), and not reproduced
  in isolation. Needs a dedicated repro (guest poweroff/reboot loops on an
  otherwise-idle node, watching for the serial stream to hang while the guest is
  up). Candidate factors: the `Nehalem` `defaultCPUModel`, serial-console
  proxy/mshv ttyS0 handling under churn.
- **Methodology note:** never rely on Prometheus alone for node-reset counts on a
  single-node-pinned run — the monitoring pod may be on the node that resets.
  Cross-check with `uptime` / `journalctl --list-boots` on the node.
- Revert the `bl5zw` `NoSchedule` taint when the isolation experiment is done.
