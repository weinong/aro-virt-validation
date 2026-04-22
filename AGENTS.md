# Goal

Run the OpenShift Virtualization validation checkup ([openshift-cnv/ocp-virt-validation-checkup](https://github.com/openshift-cnv/ocp-virt-validation-checkup)) against an existing ARO cluster running OCP 4.22.0-rc.0 with nightly CNV 4.99.0-2739. Investigate and document any issues encountered.

# Instructions

- **Run commands directly** — don't ask the user to execute things; only stop when input is needed.
- **Stage and commit often** so changes can be reviewed and reverted.
- **Source `.env`** from repo root for credentials.
- **Reuse helpers from `scripts/env.sh`** (`log_info`, `log_ok`, `log_warn`, `log_error`, `check_command`).
- **Idempotent scripts** — safe to re-run.
- **Numbered script naming**: follows `scripts/0N-...sh` convention.
- **Verify cluster state** before proceeding — use CLI commands (`oc`, `az`) to confirm the current state of the cluster, CNV installation, and login status. Do not assume.
- Bug reports go under `issues/` directory in `YYYY-MM-DD.md` format, capturing relevant node labels and summarizing the issue.
- Do NOT work around test validation failures. Your responsibility is to run tests, investigate failures, and document findings.
