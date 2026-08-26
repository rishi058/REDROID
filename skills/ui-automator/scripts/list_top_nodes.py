#!/usr/bin/env python3
"""List all UI nodes whose top edge is above a y-coordinate threshold.

Useful for finding header/toolbar icons that have no text or content-desc.

usage: list_top_nodes.py <dump.xml> [ymax=170]
"""
import re
import sys


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    ymax = int(sys.argv[2]) if len(sys.argv) > 2 else 170
    s = open(path, encoding="utf-8", errors="ignore").read()
    for n in re.findall(r"<node[^>]*/>", s):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if not b:
            continue
        y1 = int(b.group(2))
        if y1 >= ymax:
            continue
        rid = re.search(r'resource-id="([^"]*)"', n)
        desc = re.search(r'content-desc="([^"]*)"', n)
        txt = re.search(r'text="([^"]*)"', n)
        cls = re.search(r'class="([^"]*)"', n)
        click = "CLICKABLE" if 'clickable="true"' in n else ""
        print(
            f"{b.group(0):28} {cls.group(1).split('.')[-1] if cls else '':18} "
            f"{click:10} rid={rid.group(1)[-40:] if rid and rid.group(1) else '-':40} "
            f"desc={desc.group(1)[:30] if desc and desc.group(1) else '-':30} "
            f"txt={txt.group(1)[:20] if txt and txt.group(1) else '-'}"
        )


if __name__ == "__main__":
    main()
