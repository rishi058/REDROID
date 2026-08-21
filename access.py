#!/usr/bin/env python3

# THE USER CAN NOW MONITOR THE SCRIPTS AND ALLOWS/DENIES AI AGENT : MIDDLEWARE FOR AUTO MODE
# USE THIS SCRIPT FOR EXECUTING COMMANDS
#
# Usage:
#   python access.py [--quiet] <command> [args...]
#
# --quiet / -q : suppress the banner and Exit Code lines so output can be
#   parsed directly in shell scripts (e.g. STATUS=$(python access.py -q ...))

import subprocess
import sys
import shlex

# Force UTF-8 on Windows consoles (default cp1252 crashes on box-drawing / unicode
# output from tools like docker).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def _safe_print(text, end="\n", flush=False):
    """Print to stdout, swallowing OS-level write errors (e.g. broken pipe,
    Windows Invalid argument / errno 22 on large or binary-like output)."""
    try:
        sys.stdout.write(text + end)
        if flush:
            sys.stdout.flush()
    except (OSError, BrokenPipeError):
        # stdout is broken (pipe closed, Windows handle invalid, etc.).
        # Don't crash — the data was already captured in output[].
        pass


def main():
    args = sys.argv[1:]

    # Strip --quiet / -q flag before passing the rest to the subprocess.
    quiet = False
    if args and args[0] in ("--quiet", "-q"):
        quiet = True
        args = args[1:]

    if not args:
        print("Usage:")
        print("  python access.py [--quiet|-q] <command> [args...]")
        sys.exit(1)

    cmd = args

    if not quiet:
        _safe_print("=" * 80)
        _safe_print("Executing:")
        _safe_print(" ".join(shlex.quote(arg) for arg in cmd))
        _safe_print("=" * 80)

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
            _safe_print(line, end="", flush=True)
            output.append(line)

        process.wait()
    except KeyboardInterrupt:
        process.terminate()
        process.wait()

    if not quiet:
        _safe_print("\n" + "=" * 80)
        _safe_print(f"Exit Code: {process.returncode}")

    sys.exit(process.returncode)


if __name__ == "__main__":
    main()