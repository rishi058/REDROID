#!/usr/bin/env python3

# THE USER CAN NOW MONITOR THE SCRIPTS AND ALLOWS/DENIES AI AGENT : MIDDLEWARE FOR AUTO MODE
# USE THIS SCRIPT FOR EXECUTING COMMANDS

import subprocess
import sys
import shlex

# Force UTF-8 on Windows consoles (default cp1252 crashes on box-drawing / unicode
# output from tools like docker).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python access.py <command> [args...]")
        sys.exit(1)

    cmd = sys.argv[1:]

    print("=" * 80)
    print("Executing:")
    print(" ".join(shlex.quote(arg) for arg in cmd))
    print("=" * 80)

    process = subprocess.Popen(
        cmd,
        stdin=sys.stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",   # decode child output as UTF-8, not the locale default
        errors="replace",   # never crash on an undecodable byte
        bufsize=1,
    )

    output = []

    try:
        for line in process.stdout:
            print(line, end="", flush=True)
            output.append(line)

        process.wait()
    except KeyboardInterrupt:
        process.terminate()
        process.wait()

    print("\n" + "=" * 80)
    print(f"Exit Code: {process.returncode}")

    sys.exit(process.returncode)


if __name__ == "__main__":
    main()