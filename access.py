#!/usr/bin/env python3

# THE USER CAN NOW MONITOR THE SCRIPTS AND ALLOWS/DENIES AI AGENT : MIDDLEWARE FOR AUTO MODE
# USE THIS SCRIPT FOR EXECUTING COMMANDS

import subprocess
import sys
import shlex

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