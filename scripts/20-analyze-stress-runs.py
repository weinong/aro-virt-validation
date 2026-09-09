#!/usr/bin/env python3
"""Post-process veth csum-stress runs from on-disk data only.

Deliberately does NOT talk to the cluster. Every run directory holds the raw
telemetry, so a parsing mistake costs a re-run of this script (seconds) rather
than a re-run of the experiment (up to 15 minutes). Safe to iterate on freely.

Inputs, per run directory under .checkup-runs/veth-csum-stress/<run_id>/:
  meta.tsv        run parameters, recorded before anything could crash
  node-facts.tsv  kernel / l1vh / mshv_root / nokaslr / cpu / memory
  poll.tsv        external polling: elapsed, boot id, Ready
  telemetry.tsv   ON-NODE, ON-DISK samples; survives the panic and reboot

Usage:
  python3 scripts/20-analyze-stress-runs.py [runs_dir] [--verbose]
"""
import os
import sys

RUNS_DIR = "/.checkup-runs/veth-csum-stress"


def read_kv(path):
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            out[parts[0]] = parts[1]
    return out


def read_poll(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, errors="replace") as fh:
        header = fh.readline()
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 4:
                rows.append({"utc": p[0], "elapsed": p[1], "boot": p[2], "ready": p[3]})
    return rows


def read_telemetry(path):
    """Returns (comments, samples) where samples are (uptime, rx_bytes, rx_packets)."""
    comments, samples = [], []
    if not os.path.exists(path):
        return comments, samples
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("#"):
            comments.append(line.lstrip("# ").strip())
            continue
        p = line.split("\t")
        if len(p) >= 4 and p[0] == "SAMPLE":
            try:
                samples.append((float(p[1]), int(p[2]), int(p[3])))
            except ValueError:
                # Truncated final line is expected: the node panicked mid-write.
                continue
    return comments, samples


def first_reset(poll):
    """Elapsed seconds at the first observed boot-ID change."""
    base = None
    for r in poll:
        if r["boot"] in ("unknown", ""):
            continue
        if base is None:
            base = r["boot"]
        elif r["boot"] != base:
            return int(r["elapsed"])
    return None


def analyse(run_dir):
    meta = read_kv(os.path.join(run_dir, "meta.tsv"))
    facts = read_kv(os.path.join(run_dir, "node-facts.tsv"))
    poll = read_poll(os.path.join(run_dir, "poll.tsv"))
    comments, samples = read_telemetry(os.path.join(run_dir, "telemetry.tsv"))

    reset_at = first_reset(poll)
    # Bytes actually pushed before the node died, from the on-node record.
    peak_bytes = max((s[1] for s in samples), default=None)
    peak_pkts = max((s[2] for s in samples), default=None)
    last_uptime = max((s[0] for s in samples), default=None)

    bytes_at_reset = None
    if reset_at is not None and samples:
        # telemetry uptime is node uptime; align via the recorded load start.
        start_uptime = None
        for c in comments:
            if c.startswith("load_start_uptime="):
                try:
                    start_uptime = float(c.split("=", 1)[1])
                except ValueError:
                    pass
        if start_uptime is not None:
            cand = [b for (u, b, _) in samples if u - start_uptime <= reset_at]
            bytes_at_reset = max(cand, default=None)
        else:
            bytes_at_reset = peak_bytes

    return {
        "run_id": os.path.basename(run_dir.rstrip("/")),
        "node": meta.get("node", "?"),
        "streams": meta.get("streams", "?"),
        "duration": meta.get("duration", "?"),
        "kernel": facts.get("kernel", "?"),
        "l1vh": facts.get("l1vh", "?"),
        "mshv_root": facts.get("mshv_root", "?"),
        "reset_at": reset_at,
        "samples": len(samples),
        "peak_bytes": peak_bytes,
        "peak_pkts": peak_pkts,
        "bytes_at_reset": bytes_at_reset,
        "last_uptime": last_uptime,
    }


def gib(n):
    return "-" if n is None else f"{n / 2**30:.1f}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    verbose = "--verbose" in sys.argv
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    runs_dir = args[0] if args else repo + RUNS_DIR
    if not os.path.isdir(runs_dir):
        sys.exit(f"no runs directory: {runs_dir}")

    dirs = sorted(d for d in (os.path.join(runs_dir, x) for x in os.listdir(runs_dir))
                  if os.path.isdir(d))
    if not dirs:
        sys.exit(f"no run directories under {runs_dir}")

    rows = [analyse(d) for d in dirs]

    hdr = f"{'run_id':<34}{'l1vh':>5}{'strm':>5}{'dur':>6}{'reset@s':>9}{'GiB@reset':>11}{'peakGiB':>9}{'samples':>9}"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{r['run_id']:<34}{r['l1vh']:>5}{r['streams']:>5}{r['duration']:>6}"
              f"{(r['reset_at'] if r['reset_at'] is not None else '-'):>9}"
              f"{gib(r['bytes_at_reset']):>11}{gib(r['peak_bytes']):>9}{r['samples']:>9}")

    print("\n--- volume hypothesis ---")
    crashed = [r for r in rows if r["reset_at"] is not None and r["bytes_at_reset"]]
    if len(crashed) >= 2:
        vals = [r["bytes_at_reset"] / 2**30 for r in crashed]
        lo, hi = min(vals), max(vals)
        print(f"  runs that reset with byte data: {len(crashed)}")
        print(f"  GiB pushed before reset: min={lo:.1f} max={hi:.1f} spread={hi/lo:.1f}x"
              if lo else "  insufficient data")
        print("  A tight spread supports a volume threshold; a wide one refutes it.")
    else:
        print(f"  only {len(crashed)} run(s) with both a reset and byte data; need >=2 to compare")

    survived = [r for r in rows if r["reset_at"] is None]
    if survived:
        print("\n--- runs that did NOT reset (negative controls) ---")
        for r in survived:
            verdict = "MEANINGFUL" if r["peak_bytes"] else "NO TRAFFIC: void, prove the load ran"
            print(f"  {r['run_id']:<34} l1vh={r['l1vh']} pushed {gib(r['peak_bytes'])} GiB "
                  f"in {r['duration']}s -> {verdict}")

    if verbose:
        print("\n--- per-run telemetry headers ---")
        for d, r in zip(dirs, rows):
            comments, _ = read_telemetry(os.path.join(d, "telemetry.tsv"))
            print(f"  {r['run_id']}")
            for c in comments:
                print(f"      {c}")


if __name__ == "__main__":
    main()
