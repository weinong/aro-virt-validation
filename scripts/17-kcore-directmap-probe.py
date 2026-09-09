#!/usr/bin/env python3
"""Probe direct-map memory through /proc/kcore looking for unreadable pages.

Why this exists: the MSHV/L1VH nodes panic with a #GP on a *canonical* direct-map
address (see issues/2026-09-08b). Separately, makedumpfile in the crash kernel
gets EFAULT reading ordinary System RAM. Those are different faults via different
paths, so this probes the direct map from a NORMALLY RUNNING kernel to see whether
inaccessible pages exist there too.

nokaslr is what makes this possible: PAGE_OFFSET is the fixed 5-level default, so
a physical address maps to a known kernel virtual address.

Read-only. It only reads; it never writes kernel memory.
"""
import os
import struct
import sys
import time

PAGE_OFFSET = 0xFF11000000000000  # 5-level paging default, valid only with nokaslr
STEP = int(sys.argv[1]) if len(sys.argv) > 1 else 2 << 20
LIMIT_SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 600


def kcore_loads(fd):
    """PT_LOAD segments of /proc/kcore as (vaddr, file_offset, size)."""
    hdr = os.pread(fd, 64, 0)
    if hdr[:4] != b"\x7fELF":
        sys.exit("/proc/kcore is not ELF")
    e_phoff = struct.unpack_from("<Q", hdr, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", hdr, 0x36)[0]
    e_phnum = struct.unpack_from("<H", hdr, 0x38)[0]
    out = []
    for i in range(e_phnum):
        ph = os.pread(fd, e_phentsize, e_phoff + i * e_phentsize)
        if struct.unpack_from("<I", ph, 0)[0] != 1:  # PT_LOAD
            continue
        out.append((
            struct.unpack_from("<Q", ph, 0x10)[0],  # p_vaddr
            struct.unpack_from("<Q", ph, 0x08)[0],  # p_offset
            struct.unpack_from("<Q", ph, 0x20)[0],  # p_filesz
        ))
    return out


def system_ram():
    ranges = []
    for line in open("/proc/iomem"):
        if not line.rstrip().endswith("System RAM"):
            continue
        lo, hi = (int(v, 16) for v in line.split(":")[0].strip().split("-"))
        ranges.append((lo, hi))
    return ranges


def main():
    fd = os.open("/proc/kcore", os.O_RDONLY)
    loads = kcore_loads(fd)
    print(f"/proc/kcore PT_LOAD segments: {len(loads)}")

    def to_offset(vaddr):
        for base, off, size in loads:
            if base <= vaddr < base + size:
                return off + (vaddr - base)
        return None

    ram = system_ram()
    total = sum(hi - lo + 1 for lo, hi in ram)
    print(f"System RAM ranges: {len(ram)}  total: {total/2**30:.1f} GiB")
    print(f"step: {STEP/2**20:.2f} MiB   time limit: {LIMIT_SECONDS}s")
    print(f"PAGE_OFFSET: 0x{PAGE_OFFSET:x}\n")

    started = time.time()
    probed = unmapped = failed = 0
    failures = []
    for lo, hi in ram:
        for phys in range(lo, hi, STEP):
            if time.time() - started > LIMIT_SECONDS:
                print("!! time limit reached, stopping early")
                break
            off = to_offset(PAGE_OFFSET + phys)
            if off is None:
                unmapped += 1
                continue
            probed += 1
            try:
                os.pread(fd, 8, off)
            except OSError as exc:
                failed += 1
                if len(failures) < 20:
                    failures.append((phys, exc.errno, exc.strerror))
        else:
            continue
        break

    elapsed = time.time() - started
    print(f"probed          : {probed}")
    print(f"not in kcore    : {unmapped}")
    print(f"READ FAILURES   : {failed}")
    print(f"elapsed         : {elapsed:.1f}s")
    if failures:
        print("\nfirst failures (physical address -> errno):")
        for phys, errno, msg in failures:
            print(f"  phys 0x{phys:012x}  vaddr 0x{PAGE_OFFSET+phys:016x}  errno={errno} ({msg})")
    else:
        print("\nno read failures at this sampling density")


if __name__ == "__main__":
    main()
