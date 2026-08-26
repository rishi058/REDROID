#!/usr/bin/env python3
"""Detect Pass/Fail verdict icons in a uiautomator dump (Play Integrity checker UI).

usage: check_verdict.py <dump.xml>
exit codes: 0 = parsed, 1 = file error. Prints HAS_PASS / HAS_FAIL booleans.
"""
import re
import sys


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    try:
        s = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    except OSError as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    descs = re.findall(r'content-desc="([^"]{1,40})"', s)
    uniq = sorted(set(d for d in descs if d.strip()))
    print("CONTENT-DESCS:", uniq)
    print("HAS_PASS:", any(d.lower() == "pass" for d in uniq))
    print("HAS_FAIL:", any(d.lower() == "fail" for d in uniq))
    print("PASS_COUNT:", sum(1 for d in descs if d.lower() == "pass"))
    print("FAIL_COUNT:", sum(1 for d in descs if d.lower() == "fail"))


if __name__ == "__main__":
    main()
