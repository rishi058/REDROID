#!/usr/bin/env python3
"""Capture an HTTP request made by an Android app after a user-supplied intent.

This is a capture-and-filter tool.  It never creates, signs, or replays an HTTP
request: the selected Android package makes its own request after receiving the
intent.  ``--method`` and ``--request-body`` select the captured request to
export; they cannot force an arbitrary app to use that method or body.

Examples:
  python deeplink_capture.py --pkg com.example.app --uri https://example.test/item/42
  python deeplink_capture.py --pkg com.example.app --uri myapp://open/42 \
      --method POST --request-body-file body.json --host api.example.test
  python deeplink_capture.py --pkg com.example.app --uri myapp://open \
      --extra source=share --extra mode=preview --path-contains /v1/items

Prerequisites:
  - ``adb`` is connected to the intended Android device.
  - ``mitmdump`` is on PATH.
  - The mitmproxy CA is trusted by the selected app/device when HTTPS capture is
    required.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Iterable


def adb_prefix(serial: str | None) -> list[str]:
    return ["adb", "-s", serial] if serial else ["adb"]


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, capture_output=True, text=True)


def text_or_binary(message) -> str:
    """Return readable mitmproxy content without attempting application decryption."""
    if not message or not message.content:
        return ""
    try:
        return message.get_text(strict=False)
    except Exception:
        return f"<{len(message.content)} bytes binary>"


def parse_extra(value: str) -> tuple[str, str]:
    key, separator, item = value.partition("=")
    if not separator or not key:
        raise argparse.ArgumentTypeError("intent extras must use KEY=VALUE")
    return key, item


def read_request_body(args: argparse.Namespace) -> str | None:
    if args.request_body is not None:
        return args.request_body
    if args.request_body_file is not None:
        try:
            return Path(args.request_body_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise SystemExit(f"cannot read --request-body-file: {exc}") from exc
    return None


def matches(flow, args: argparse.Namespace, expected_body: str | None) -> bool:
    request = flow.request
    if args.host and request.host != args.host:
        return False
    if args.method and request.method.upper() != args.method.upper():
        return False
    if args.path_contains and args.path_contains not in request.path:
        return False
    if expected_body is not None and text_or_binary(request) != expected_body:
        return False
    return True


def serialise(flow) -> dict:
    request, response = flow.request, flow.response
    return {
        "method": request.method,
        "url": request.pretty_url,
        "req_headers": dict(request.headers),
        "req_body": text_or_binary(request),
        "status": response.status_code if response else None,
        "resp_headers": dict(response.headers) if response else {},
        "resp_body": text_or_binary(response),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Trigger a user-supplied Android intent and save matching HTTP flows.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--pkg", required=True, help="Android package to receive the intent")
    parser.add_argument("--uri", required=True, help="intent data URI, for example myapp://open/42")
    parser.add_argument("--action", default="android.intent.action.VIEW", help="Android intent action")
    parser.add_argument(
        "--extra", action="append", type=parse_extra, default=[], metavar="KEY=VALUE",
        help="string intent extra; repeat for multiple extras",
    )
    parser.add_argument("--method", help="only export flows with this HTTP method")
    body = parser.add_mutually_exclusive_group()
    body.add_argument(
        "--request-body", help="only export flows whose decoded request body exactly matches this text"
    )
    body.add_argument(
        "--request-body-file", help="read the exact expected request body from this UTF-8 file"
    )
    parser.add_argument("--host", help="only export flows whose request host exactly matches this host")
    parser.add_argument("--path-contains", help="only export flows whose request path contains this text")
    parser.add_argument("--wait", type=float, default=15, help="seconds to wait after launching (default: 15)")
    parser.add_argument("--port", type=int, default=8080, help="local mitmdump port (default: 8080)")
    parser.add_argument("--serial", help="ADB serial; omit only when exactly one device is selected")
    parser.add_argument("--cap", default="captures/intent_capture.mitm", help="raw mitmproxy capture output")
    parser.add_argument("--out", default="captures/intent_capture.json", help="matching flows JSON output")
    parser.add_argument("--no-force-stop", action="store_true", help="do not stop the package before launch")
    parser.add_argument(
        "--leave-proxy", action="store_true", help="leave Android's previous proxy setting unrestored"
    )
    return parser.parse_args()


def read_proxy(adb: list[str]) -> str:
    previous = run(adb + ["shell", "settings", "get", "global", "http_proxy"]).stdout.strip()
    return previous if previous and previous.lower() != "null" else ":0"


def set_proxy(adb: list[str], value: str) -> None:
    run(adb + ["shell", "settings", "put", "global", "http_proxy", value])


def main() -> int:
    args = parse_args()
    if args.wait < 0:
        raise SystemExit("--wait must be zero or greater")
    expected_body = read_request_body(args)
    cap_path, out_path = Path(args.cap), Path(args.out)
    cap_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if cap_path.resolve() == out_path.resolve():
        raise SystemExit("--cap and --out must name different files")
    if cap_path.exists():
        cap_path.unlink()

    adb = adb_prefix(args.serial)
    try:
        previous_proxy = read_proxy(adb)
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise SystemExit(f"could not read Android proxy setting: {exc}") from exc

    mitm = None
    try:
        print(f"[*] preserving Android proxy: {previous_proxy!r}")
        run(adb + ["reverse", f"tcp:{args.port}", f"tcp:{args.port}"])
        set_proxy(adb, f"127.0.0.1:{args.port}")

        command = ["mitmdump", "-p", str(args.port), "-q", "--set", "block_global=false", "-w", str(cap_path)]
        print(f"[*] starting mitmdump on :{args.port} -> {cap_path}")
        mitm = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
        if mitm.poll() is not None:
            raise SystemExit("mitmdump stopped before the intent was launched; check its installation and port")

        if not args.no_force_stop:
            run(adb + ["shell", "am", "force-stop", args.pkg])
        intent = adb + ["shell", "am", "start", "-a", args.action, "-d", args.uri]
        for key, value in args.extra:
            intent.extend(["--es", key, value])
        intent.append(args.pkg)
        print(f"[*] launching {args.pkg}: {args.action} {args.uri}")
        run(intent)
        print(f"[*] waiting {args.wait:g} second(s) for app-generated traffic")
        time.sleep(args.wait)
    finally:
        if mitm is not None:
            mitm.terminate()
            try:
                mitm.wait(timeout=10)
            except subprocess.TimeoutExpired:
                mitm.kill()
                mitm.wait()
        if not args.leave_proxy:
            try:
                set_proxy(adb, previous_proxy)
                print("[*] restored Android proxy setting")
            except (subprocess.CalledProcessError, FileNotFoundError) as exc:
                print(f"[!] could not restore Android proxy: {exc}", file=sys.stderr)

    if not cap_path.exists():
        raise SystemExit("mitmdump did not write a capture file")

    try:
        from mitmproxy import http
        from mitmproxy.io import FlowReader
    except ImportError as exc:
        raise SystemExit("mitmproxy is required to read the capture: pip install mitmproxy") from exc

    data: list[dict] = []
    with cap_path.open("rb") as handle:
        for flow in FlowReader(handle).stream():
            if isinstance(flow, http.HTTPFlow) and matches(flow, args, expected_body):
                data.append(serialise(flow))

    with out_path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
    print(f"[+] exported {len(data)} matching HTTP flow(s) -> {out_path}")
    if not data:
        print("[i] No flow matched. Check the URI/package, wait time, CA trust, and optional filters.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
