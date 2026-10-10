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
import urllib.parse
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


def proof(secret: str, path: str, body: bytes, port: int, timeout: float,
          kid: str | None = None) -> dict[str, object]:
    payload = {
        "secret": secret,
        "op": "sign",
        "path": path,
        "body_b64": base64.b64encode(body).decode("ascii"),
    }
    if kid:
        payload["kid"] = kid
    result = bridge_request(port, payload, timeout)
    if result.get("ok") is not True:
        raise RuntimeError(f"bridge rejected signing request: {result.get('error', 'unknown')}")
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "sign", "call", "refresh"))
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--timeout", type=float, default=15)
    secret = parser.add_mutually_exclusive_group()
    secret.add_argument("--secret")
    secret.add_argument("--secret-file")
    parser.add_argument("--path")
    parser.add_argument("--kid", help="select one enrolled identity (multi-alias daemon)")
    parser.add_argument("--challenge", help="token/refresh challenge (for the refresh command)")
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

    if args.command == "refresh":
        if not args.challenge:
            raise SystemExit("--challenge is required for the refresh command")
        payload = {"secret": secret, "op": "refresh_assertion", "challenge": args.challenge}
        if args.kid:
            payload["kid"] = args.kid
        result = bridge_request(args.port, payload, args.timeout)
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok") is True else 2

    if not args.path or not args.path.startswith("/api/v2/android/"):
        raise SystemExit("--path must be an allowlisted /api/v2/android/... path")
    body = body_bytes(args)
    signed = proof(secret, args.path, body, args.port, args.timeout, kid=args.kid)
    if args.command == "sign":
        print(json.dumps(signed, indent=2))
        return 0

    bearer = read_value(args.bearer, args.bearer_file, "DW_ACCESS_TOKEN")
    target_url = API_ORIGIN + args.path
    proxy_url = os.environ.get("DISKWALA_CALL_PROXY_URL", "").strip()
    gateway = (
        os.environ.get("RESIDENTIAL_GATEWAY_BASE_URL", "").strip().rstrip("/")
        if not proxy_url else ""
    )
    request_url = (
        gateway + "/phone/fetch?" + urllib.parse.urlencode({"url": target_url})
        if gateway else target_url
    )
    request = urllib.request.Request(
        request_url,
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
    if proxy_url:
        import requests

        response = requests.post(
            target_url,
            data=body,
            headers=dict(request.header_items()),
            proxies={"http": proxy_url, "https": proxy_url},
            timeout=args.timeout,
        )
        print(f"HTTP {response.status_code}")
        sys.stdout.buffer.write(response.content + (b"" if response.content.endswith(b"\n") else b"\n"))
        return 0 if response.status_code < 400 else 2
    opener = (
        urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy_url, "https": proxy_url})
        )
        if proxy_url
        else urllib.request.build_opener()
    )
    try:
        with opener.open(request, timeout=args.timeout) as response:
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
