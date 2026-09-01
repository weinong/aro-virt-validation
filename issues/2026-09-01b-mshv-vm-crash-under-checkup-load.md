# 2026-09-01 — MSHV/L1VH guest VMs crash intermittently under checkup load (the "console slowness" is a symptom)

## Summary

While running the ocp-virt-validation-checkup **compute** suite pinned to the
*stable* MSHV node `aro-virt-test-8gpzs-worker-mshv-centralus1-l7njd` (see
`issues/2026-09-01-mshv-node-hard-reset-under-load.md` for why the other MSHV node
`bl5zw` was excluded), the suite still produces a cluster of failures — **~15 and
counting at 88 min** — that all trace back to **individual guest VMs crashing
intermittently** (`The VirtualMachineInstance crashed.` → VMI `phase=Failed`).

The node itself never reset (`l7njd` = **0 reboots in 3h** under the full VM
churn), so this is a **guest/qemu-level instability on MSHV under load**, distinct
from the `bl5zw` host-reset problem. Crucially, what first looked like "serial
console slowness" in the `[test_id:1528] should survive guest shutdown, multiple
times` spec turned out to be a **downstream symptom** of these VM crashes, not a
console problem.

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

That is `goexpect` **blocking on a serial stream whose qemu died mid-test**, until
the stream EOFs and the test reconnects to the *replacement* VMI. The console was
never "slow" — the VM behind it crashed.

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

## The underlying failure: VMs crash under load (on a healthy node)

The 15 failures share one root cause — VMs not staying Running:

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

The **qemu-level crash reason has not yet been captured** — the virt-launcher pods
(including the `compute` and `guest-console-log` containers that would hold the
qemu/libvirt logs and any in-guest panic) are torn down immediately on crash, so
grabbing them requires either catching a crash live at the right instant or
deliberately reproducing a crash on a probe VM. **This is an open item, not a
resolved root cause.** Candidate directions to investigate: the `Nehalem`
`defaultCPUModel` (set in `scripts/07a-hco-default-cpu-model.sh`), the MSHV L2
guest path under rapid lifecycle churn, or the specific operations the failing
specs perform (guest reboot, freeze/unfreeze, shutdown loops).

## Node stayed stable (re-confirms bl5zw is host-specific)

Throughout the run, `l7njd` never reset:

```sh
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=15m)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'query=changes(node_boot_time_seconds{instance=~".*mshv.*"}[3h])' \
  "https://$THANOS/api/v1/query" | jq -r '.data.result[]|"\(.metric.instance) \(.value[1])"'
# -> bl5zw 0   l7njd 0
```

So the compute suite fully exercised `l7njd` with the same VM churn that
hard-resets `bl5zw`, and `l7njd` stayed up — the VM crashes here are a *guest*
issue, and `bl5zw`'s node resets remain a *host*-specific issue.

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

### A) Run the compute suite pinned to the stable node

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

### C) Confirm boot / console are healthy in isolation (rule-outs)

Create a `RunStrategy: Always` probe VM pinned to the stable node and measure
reboot→AgentConnected latency (race-free via VMI UID change) and serial-console
responsiveness — both are healthy, proving the checkup failures are crashes, not
slow boot or slow console. (Harness used: `/tmp/opencode/reboot-latency.py` and
the inline `virtctl restart`/`virtctl console` loops; the probe VM lives in the
`console-latency` namespace.)

## Impact

- The compute suite cannot produce a clean result on MSHV even on a **healthy
  host**: intermittent guest VM crashes fail multiple compute specs
  (`test_id:1528` and the `phase is not Running` / guest-reboot family), and the
  `flake-attempts=3` retries are consumed by the crashes.
- The `bl5zw` node-reset issue and this guest-crash issue are **two independent
  MSHV/L1VH problems**; fixing the host that resets `bl5zw` would still leave
  these guest crashes.

## Open items / next steps

- **Capture the qemu-level crash reason** (primary open item): catch a crashing
  virt-launcher's `compute` + `guest-console-log` container logs at the instant of
  crash, or reproduce a crash on a long-lived probe VM (reboot/freeze/shutdown
  loops) so the launcher logs can be read at leisure. Look for a guest kernel
  panic vs a qemu/libvirt abort vs an MSHV hypercall error.
- Test whether the crashes correlate with the `Nehalem` `defaultCPUModel`, with a
  specific operation (guest-initiated reboot, `freeze`/`unfreeze`), or with
  concurrency/churn rate.
- Report to the CNV/KubeVirt MSHV team with the crash reason once captured, plus
  the `l7njd`-stable-node context (rules out host/hardware).
- Revert the `bl5zw` `NoSchedule` taint when the isolation experiment is done.
