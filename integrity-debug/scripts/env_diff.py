#!/usr/bin/env python3
"""Phase D.4 - diff two env snapshots produced by d4_env_snapshot.sh.
Usage: python env_diff.py wsl.txt exp.txt
Highlights signals that differ between the PASSING (wsl) and FAILING (exp) device.
"""
import sys, re

def load(path):
    d, multi, key, buf = {}, None, None, []
    for raw in open(path, encoding="utf-8", errors="ignore"):
        line = raw.rstrip("\n")
        if line.endswith("_BEGIN"):
            multi = line[2:-6]; buf = []; continue
        if line.endswith("_END"):
            d[multi] = "\n".join(buf); multi = None; continue
        if multi is not None:
            buf.append(line); continue
        m = re.match(r"@@(\w+)\s?(.*)", line)
        if m:
            d[m.group(1)] = m.group(2)
    return d

def main():
    if len(sys.argv) != 3:
        print("usage: env_diff.py <pass-snapshot> <fail-snapshot>"); sys.exit(1)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    keys = sorted(set(a) | set(b))
    print(f"{'SIGNAL':<16} {'PASS (wsl)':<38} {'FAIL (exp)':<38}")
    print("-" * 92)
    diffs = 0
    for k in keys:
        va, vb = a.get(k, "<absent>"), b.get(k, "<absent>")
        if va == vb:
            continue
        diffs += 1
        if "\n" in va or "\n" in vb:
            print(f"\n### {k} DIFFERS ###")
            print("--- PASS ---\n" + va)
            print("--- FAIL ---\n" + vb)
        else:
            print(f"{k:<16} {va[:37]:<38} {vb[:37]:<38}")
    print(f"\n{diffs} differing signals. Focus DroidGuard-relevant ones: HARDWARE, CPUINFO, HYPERVISOR, SENSORS, DEVNODES, KERNEL, MOUNTS.")

if __name__ == "__main__":
    main()
