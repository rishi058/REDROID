import re
import html
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: parse_ui.py <dump.xml>")
        sys.exit(1)
    s = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    for n in re.findall(r"<node[^>]*/>", s):
        t = re.search(r'text="([^"]*)"', n)
        d = re.search(r'content-desc="([^"]*)"', n)
        b = re.search(r'bounds="([^"]*)"', n)
        txt = html.unescape(t.group(1)) if t else ""
        desc = html.unescape(d.group(1)) if d else ""
        if txt.strip() or desc.strip():
            bounds = b.group(1) if b else ""
            print(f"TEXT={txt!r:50} DESC={desc!r:30} BOUNDS={bounds}")


if __name__ == "__main__":
    main()
