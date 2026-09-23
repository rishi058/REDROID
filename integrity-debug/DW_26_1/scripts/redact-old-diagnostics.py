#!/usr/bin/env python3
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Redact auth-response bodies from old DW26Gate LSPosed logs")
    parser.add_argument("--data-root", required=True, type=Path,
                        help="Verified Docker volume _data directory")
    args = parser.parse_args()
    root = args.data_root / "adb" / "lspd"
    if not root.is_dir():
        raise SystemExit("Invalid LSPosed data root")
    changed = files = 0
    for folder in (root / "log", root / "log.old"):
        if not folder.is_dir():
            continue
        for path in folder.glob("*.log"):
            if path.is_symlink() or not path.is_file():
                continue
            count = 0
            with path.open("r+b", buffering=0) as stream:
                end = path.stat().st_size
                while stream.tell() < end:
                    start = stream.tell()
                    line = stream.readline()
                    if not line:
                        break
                    auth = b"BODY endpoint=token/refresh " in line or b"BODY endpoint=login " in line
                    if b"[DW26Gate]" not in line or not auth or b" json=" not in line:
                        continue
                    offset = line.index(b" json=") + len(b" json=")
                    length = len(line[offset:].rstrip(b"\r\n"))
                    marker = b"<credential response redacted>"
                    replacement = (marker + b" " * length)[:length]
                    stream.seek(start + offset)
                    stream.write(replacement)
                    stream.seek(start + len(line))
                    count += 1
            changed += count
            files += bool(count)
    print(f"Redacted {changed} records in {files} diagnostic files.")


if __name__ == "__main__":
    main()
