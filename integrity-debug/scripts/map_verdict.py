#!/usr/bin/env python3
# Map Pass/Fail icons to integrity tiers by vertical position. Usage: python map_verdict.py dump.xml
import re, sys
s = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
icons = [(m[0], int(m[2])) for m in re.findall(
    r'content-desc="(Pass|Fail)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', s)]
tiers = {}
for name, y in re.findall(r'text="MEETS_(BASIC|DEVICE|STRONG)_INTEGRITY"[^>]*bounds="\[(?:\d+),(\d+)\]', s):
    tiers[name] = int(y)
for t, ty in tiers.items():
    if icons:
        verdict = min(icons, key=lambda i: abs(i[1] - ty))[0]
        print(f"MEETS_{t}_INTEGRITY: {verdict}")
    else:
        print(f"MEETS_{t}_INTEGRITY: <no icon>")
