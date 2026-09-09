#!/usr/bin/env python3
"""Stream MSHV deposit/withdraw tracepoints to disk, append-only, from boot.

Why not snapshot /sys/kernel/tracing/trace periodically: that file is a view of
the ring buffer, so anything that wraps before the next snapshot is lost, and the
resulting ledger has holes you cannot see. Reading trace_pipe CONSUMES events, so
the buffer cannot wrap behind our back and the on-disk record is complete for as
long as this process has been running.

Durability: the panic loses page-cache writes, so the file is fsync()ed. Events
are batched briefly to keep fsync cost sane under bursts.

Written per boot so a ledger can never be mistaken for one from another boot.
"""
import os
import sys
import time

TRACE_DIR = "/sys/kernel/tracing"
OUT_ROOT = "/var/log/mshv-deposit"
FSYNC_INTERVAL = 1.0  # seconds


def boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as fh:
            return fh.read().strip()
    except OSError:
        return "unknown"


def ensure_events_enabled():
    """Belt and braces: the kernel cmdline should have done this already."""
    base = os.path.join(TRACE_DIR, "events/mshv_deposit")
    if not os.path.isdir(base):
        return False
    try:
        with open(os.path.join(base, "enable"), "w") as fh:
            fh.write("1")
        with open(os.path.join(TRACE_DIR, "tracing_on"), "w") as fh:
            fh.write("1")
    except OSError:
        pass
    return True


def main():
    out_dir = os.path.join(OUT_ROOT, "boot-" + boot_id())
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "trace.log")
    meta = os.path.join(out_dir, "meta.txt")

    have_events = ensure_events_enabled()
    with open(meta, "w") as fh:
        fh.write(f"boot_id={boot_id()}\n")
        fh.write(f"started_uptime={open('/proc/uptime').read().split()[0]}\n")
        # Wall clock lets a panic be matched to the right boot: uptimes restart
        # at 0, and the last trace timestamp only marks the last EVENT, not the
        # end of the boot (a quiet period looks identical to a dead ledger).
        fh.write(f"started_wall={time.time():.0f}\n")
        fh.write(f"events_present={have_events}\n")
        try:
            fh.write(f"cmdline={open('/proc/cmdline').read().strip()}\n")
        except OSError:
            pass
    if not have_events:
        return 1

    # Record how much uptime elapsed before we attached. A ledger is only
    # complete if this is small; anything donated earlier is invisible.
    pipe_path = os.path.join(TRACE_DIR, "trace_pipe")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    last_sync = time.time()
    try:
        with open(pipe_path, "r", errors="replace") as pipe:
            for line in pipe:
                os.write(fd, line.encode())
                now = time.time()
                if now - last_sync >= FSYNC_INTERVAL:
                    os.fsync(fd)
                    last_sync = now
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.fsync(fd)
            os.close(fd)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
