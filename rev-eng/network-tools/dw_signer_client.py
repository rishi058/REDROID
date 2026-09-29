#!/usr/bin/env python3
"""Use the local ADB-forwarded DW26 Gate signer bridge without exporting its key."""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import socket
import sys
import urllib.error
import urllib.request


DEFAULT_PORT = 39026
API_ORIGIN = "https://api.diskwala.com"


def read_value(direct: str | None, file_name: str | None, env_name: str) -> str:
    if direct:
        return direct.strip()
    if file_name:
        return Path(file_name).read_text(encoding="utf-8").strip()
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    raise SystemExit(f"missing value: pass a file or set {env_name}")


def bridge_request(port: int, payload: dict[str, object], timeout: float) -> dict[str, object]:
    frame = (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as connection:
        connection.settimeout(timeout)
        connection.sendall(frame)
        response = bytearray()
        while len(response) <= 32768:
            chunk = connection.recv(4096)
            if not chunk:
                break
            response.extend(chunk)
            if b"\n" in chunk:
                break
    if len(response) > 32768 or b"\n" not in response:
        raise RuntimeError("invalid bridge response")
    result = json.loads(bytes(response).split(b"\n", 1)[0])
    if not isinstance(result, dict):
        raise RuntimeError("bridge response is not an object")
    return result


def body_bytes(args: argparse.Namespace) -> bytes:
    if args.body_file:
        return Path(args.body_file).read_bytes()
    return (args.body or "").encode("utf-8")


def proof(secret: str, path: str, body: bytes, port: int, timeout: float) -> dict[str, object]:
    result = bridge_request(
        port,
        {
            "secret": secret,
            "op": "sign",
            "path": path,
            "body_b64": base64.b64encode(body).decode("ascii"),
        },
        timeout,
    )
    if result.get("ok") is not True:
        raise RuntimeError(f"bridge rejected signing request: {result.get('error', 'unknown')}")
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "sign", "call"))
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--timeout", type=float, default=15)
    secret = parser.add_mutually_exclusive_group()
    secret.add_argument("--secret")
    secret.add_argument("--secret-file")
    parser.add_argument("--path")
    body = parser.add_mutually_exclusive_group()
    body.add_argument("--body")
    body.add_argument("--body-file")
    bearer = parser.add_mutually_exclusive_group()
    bearer.add_argument("--bearer")
    bearer.add_argument("--bearer-file")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    secret = read_value(args.secret, args.secret_file, "DW_SIGNER_SECRET")
    if args.command == "status":
        result = bridge_request(args.port, {"secret": secret, "op": "status"}, args.timeout)
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok") is True else 2

    if not args.path or not args.path.startswith("/api/v2/android/"):
        raise SystemExit("--path must be an allowlisted /api/v2/android/... path")
    body = body_bytes(args)
    signed = proof(secret, args.path, body, args.port, args.timeout)
    if args.command == "sign":
        print(json.dumps(signed, indent=2))
        return 0

    bearer = read_value(args.bearer, args.bearer_file, "DW_ACCESS_TOKEN")
    request = urllib.request.Request(
        API_ORIGIN + args.path,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {bearer}",
            "X-DW-Kid": str(signed["kid"]),
            "X-DW-Ts": str(signed["ts"]),
            "X-DW-Nonce": str(signed["nonce"]),
            "X-DW-Sig": str(signed["sig"]),
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": "okhttp/4.12.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            output = response.read()
            print(f"HTTP {response.status}")
            sys.stdout.buffer.write(output + (b"" if output.endswith(b"\n") else b"\n"))
            return 0
    except urllib.error.HTTPError as error:
        output = error.read()
        print(f"HTTP {error.code}")
        sys.stdout.buffer.write(output + (b"" if output.endswith(b"\n") else b"\n"))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
