#!/usr/bin/env python3
"""Find a UI node in a uiautomator dump by text/content-desc regex.

Prints bounds and tap-center coordinates for every match.

usage: find_node.py <dump.xml> <regex> [--desc] [--attr=bounds-only]
examples:
  python find_node.py screen.xml "Play Protect"
  python find_node.py screen.xml "Show JSON" --desc
"""
import html
import re
import sys


def center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    path, pattern = sys.argv[1], sys.argv[2]
    use_desc = "--desc" in sys.argv
    s = open(path, encoding="utf-8", errors="ignore").read()
    rx = re.compile(pattern, re.IGNORECASE)
    found = False
    for n in re.findall(r"<node[^>]*/>", s):
        fields = []
        t = re.search(r'text="([^"]*)"', n)
        d = re.search(r'content-desc="([^"]*)"', n)
        if t and t.group(1) and rx.search(html.unescape(t.group(1))):
            fields.append(("text", html.unescape(t.group(1))))
        if d and d.group(1) and rx.search(html.unescape(d.group(1))):
            fields.append(("desc", html.unescape(d.group(1))))
        if not fields:
            continue
        b = re.search(r'bounds="([^"]*)"', n)
        bounds = b.group(1) if b else ""
        c = center(bounds)
        click = "CLICKABLE" if 'clickable="true"' in n else ""
        for kind, val in fields:
            print(f"[{kind}] {val!r} | BOUNDS={bounds} | CENTER={c} {click}")
            found = True
    if not found:
        print("NO_MATCH")
        sys.exit(2)


if __name__ == "__main__":
    main()
