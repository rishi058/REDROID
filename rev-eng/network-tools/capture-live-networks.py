
"""Capture Android HTTP(S) traffic through mitmproxy into a timestamped JSON file.

Run this file normally.  It starts mitmdump, points the connected Android device
at it through ``adb reverse`` and the global HTTP proxy, then continuously writes
the same request/response-oriented JSON shape used by ``captures/*.json``.

The device must already trust mitmproxy's CA in the *system* certificate store;
see install_cert.sh.  This tool records payloads as mitmproxy sees them.  It does
not decrypt application-level encrypted fields such as ciphertext in JSON.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent


def iso_time(timestamp: float | None) -> str | None:
    if timestamp is None:
        return None
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def address(connection: Any) -> dict[str, Any]:
    """Return the useful connection facts without serialising mitmproxy objects."""
    peer = getattr(connection, "peername", None)
    sock = getattr(connection, "sockname", None)
    return {
        "peername": list(peer) if peer else None,
        "sockname": list(sock) if sock else None,
        "sni": getattr(connection, "sni", None),
        "tls_version": getattr(connection, "tls_version", None),
        "cipher": str(getattr(connection, "cipher", "")) or None,
    }


def headers(message: Any) -> dict[str, str]:
    # ``fields`` preserves duplicate headers; browsers usually display the last
    # value, so expose all values joined with a comma while keeping a JSON object.
    return {key: value for key, value in message.headers.items(multi=False)}


def body(message: Any, prefix: str) -> dict[str, Any]:
    """Return a readable body plus the exact bytes when the body is non-text."""
    try:
        content = getattr(message, "content", b"") or b""
    except Exception:
        # A malformed content-encoding must not abort the entire capture.
        content = getattr(message, "raw_content", b"") or b""
    result: dict[str, Any] = {
        prefix: "",
        f"{prefix}_bytes": len(content),
    }
    if not content:
        return result
    try:
        result[prefix] = message.get_text(strict=True)
        result[f"{prefix}_encoding"] = "text"
    except Exception:
        # Do not silently discard a body just because it is binary/compressed.
        result[prefix] = f"<binary, {len(content)} bytes>"
        result[f"{prefix}_encoding"] = "base64"
        result[f"{prefix}_base64"] = base64.b64encode(content).decode("ascii")
    return result


class JsonCapture:
    """mitmproxy addon that atomically updates the requested capture JSON."""

    def __init__(self) -> None:
        self.output: Path | None = None
        self.started_at: str | None = None
        self.records: dict[str, dict[str, Any]] = {}
        self.order: list[str] = []

    def load(self, loader: Any) -> None:
        loader.add_option("capture_json", str, "", "JSON file written by capture-live-networks.py")

    def configure(self, updated: set[str]) -> None:
        if "capture_json" not in updated:
            return
        # Import here so ``python capture-live-networks.py --help`` works even
        # on a machine that has not installed mitmproxy yet.
        from mitmproxy import ctx

        output = getattr(ctx.options, "capture_json", "")
        if not output:
            raise ValueError("capture_json is required")
        self.output = Path(output)
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.started_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        self.flush()

    def request(self, flow: Any) -> None:
        self.record(flow)

    def response(self, flow: Any) -> None:
        self.record(flow)

    def error(self, flow: Any) -> None:
        self.record(flow)

    def websocket_message(self, flow: Any) -> None:
        self.record(flow)

    def tcp_message(self, flow: Any) -> None:
        # HTTP proxy traffic normally reaches request/response hooks.  Keep an
        # explicit entry for any raw TCP flow mitmproxy exposes as well.
        flow_id = str(flow.id)
        record = self.records.setdefault(flow_id, {"id": flow_id, "type": "tcp"})
        if flow_id not in self.order:
            self.order.append(flow_id)
        record.update(
            {
                "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "client": address(flow.client_conn),
                "server": address(flow.server_conn),
                "messages": [
                    {
                        "from_client": message.from_client,
                        "content_base64": base64.b64encode(message.content).decode("ascii"),
                    }
                    for message in flow.messages
                ],
            }
        )
        self.flush()

    def record(self, flow: Any) -> None:
        request = flow.request
        flow_id = str(flow.id)
        record = {
            # Keep these fields compatible with the existing captures/*.json files.
            "method": request.method,
            "url": request.pretty_url,
            "req_headers": headers(request),
            **body(request, "req_body"),
            "status": flow.response.status_code if flow.response else None,
            "resp_headers": headers(flow.response) if flow.response else {},
            **(body(flow.response, "resp_body") if flow.response else {"resp_body": "", "resp_body_bytes": 0}),
            # Browser-network style details that are useful when replaying/debugging.
            "id": flow_id,
            "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "request": {
                "scheme": request.scheme,
                "host": request.host,
                "port": request.port,
                "path": request.path,
                "http_version": request.http_version,
                "started_at": iso_time(getattr(request, "timestamp_start", None)),
                "ended_at": iso_time(getattr(request, "timestamp_end", None)),
            },
            "response": (
                {
                    "reason": getattr(flow.response, "reason", None),
                    "http_version": getattr(flow.response, "http_version", None),
                    "started_at": iso_time(getattr(flow.response, "timestamp_start", None)),
                    "ended_at": iso_time(getattr(flow.response, "timestamp_end", None)),
                }
                if flow.response
                else None
            ),
            "client": address(flow.client_conn),
            "server": address(flow.server_conn),
            "error": str(flow.error) if flow.error else None,
        }
        if flow.websocket:
            record["websocket_messages"] = [
                {
                    "from_client": message.from_client,
                    "timestamp": iso_time(message.timestamp),
                    **body_from_bytes(message.content),
                }
                for message in flow.websocket.messages
            ]
        if flow_id not in self.records:
            self.order.append(flow_id)
        self.records[flow_id] = record
        self.flush()

    def flush(self) -> None:
        if not self.output:
            return
        payload = [self.records[flow_id] for flow_id in self.order]
        # A replace makes the file valid JSON even if it is opened while capture is live.
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=self.output.parent, delete=False, suffix=".tmp"
        ) as temp:
            json.dump(payload, temp, indent=2, ensure_ascii=False)
            temp.write("\n")
            temp_path = Path(temp.name)
        os.replace(temp_path, self.output)

    def done(self) -> None:
        self.flush()


def body_from_bytes(content: bytes) -> dict[str, Any]:
    try:
        return {"body": content.decode("utf-8"), "body_encoding": "text", "body_bytes": len(content)}
    except UnicodeDecodeError:
        return {
            "body": f"<binary, {len(content)} bytes>",
            "body_encoding": "base64",
            "body_base64": base64.b64encode(content).decode("ascii"),
            "body_bytes": len(content),
        }


addons = [JsonCapture()]


def adb_command(adb: str, serial: str | None, *args: str) -> list[str]:
    return [adb, *( ["-s", serial] if serial else []), *args]


def run_adb(adb: str, serial: str | None, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(adb_command(adb, serial, *args), text=True, check=check)


def connected_devices(adb: str) -> list[str]:
    """Return usable ADB serials, excluding offline/unauthorized entries."""
    result = subprocess.run(
        [adb, "devices"],
        text=True,
        capture_output=True,
        check=True,
    )
    devices: list[str] = []
    for line in result.stdout.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device":
            devices.append(fields[0])
    return devices


def resolve_serial(adb: str, serial: str | None) -> str | None:
    """Resolve an omitted serial when exactly one device is connected."""
    if serial:
        return serial
    devices = connected_devices(adb)
    if len(devices) == 1:
        return devices[0]
    if not devices:
        raise ValueError("no usable ADB device is connected")
    raise ValueError(
        "multiple ADB devices are connected; pass --serial with one of: "
        + ", ".join(devices)
    )


def get_proxy(adb: str, serial: str | None) -> str:
    result = subprocess.run(
        adb_command(adb, serial, "shell", "settings", "get", "global", "http_proxy"),
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def restore_proxy(adb: str, serial: str | None, old_proxy: str, port: int) -> None:
    current_proxy = get_proxy(adb, serial)
    our_proxy = f"127.0.0.1:{port}"
    if current_proxy != our_proxy:
        return
    if old_proxy and old_proxy.lower() not in {"null", ":0"}:
        run_adb(adb, serial, "shell", "settings", "put", "global", "http_proxy", old_proxy)
    else:
        run_adb(adb, serial, "shell", "settings", "delete", "global", "http_proxy")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8080, help="Local mitmproxy/ADB reverse port (default: 8080)")
    parser.add_argument("--serial", help="ADB device serial when more than one device is connected")
    parser.add_argument("--adb", default="adb", help="ADB executable (default: adb on PATH)")
    parser.add_argument("--mitmdump", default="mitmdump", help="mitmdump executable (default: mitmdump on PATH)")
    parser.add_argument("--output-dir", type=Path, default=SCRIPT_DIR / "captures")
    parser.add_argument("--name", default="network", help="Filename prefix (default: network)")
    parser.add_argument("--no-adb-proxy", action="store_true", help="Do not change ADB reverse/global HTTP proxy")
    parser.add_argument("--leave-proxy", action="store_true", help="Leave the Android proxy/reverse mapping after capture")
    parser.add_argument("--addon", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.addon:
        # mitmdump imports this file and discovers ``addons`` above.
        return 0
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    if not shutil.which(args.mitmdump) and not Path(args.mitmdump).exists():
        parser.error(f"mitmdump was not found: {args.mitmdump!r}. Install mitmproxy or pass --mitmdump.")

    try:
        args.serial = resolve_serial(args.adb, args.serial)
    except (FileNotFoundError, subprocess.CalledProcessError, ValueError) as exc:
        parser.error(f"ADB device selection failed: {exc}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().astimezone().strftime("%Y%m%d_%H%M%S_%f")
    output = args.output_dir / f"{args.name}_{stamp}.json"
    old_proxy = ""
    proxy_configured = False

    try:
        if not args.no_adb_proxy:
            old_proxy = get_proxy(args.adb, args.serial)
            run_adb(args.adb, args.serial, "reverse", "tcp:%d" % args.port, "tcp:%d" % args.port)
            run_adb(args.adb, args.serial, "shell", "settings", "put", "global", "http_proxy", f"127.0.0.1:{args.port}")
            proxy_configured = True
            print(f"Android proxy set to 127.0.0.1:{args.port} through adb reverse.")

        command = [
            args.mitmdump,
            "--listen-port", str(args.port),
            "--set", "block_global=false",
            "--set", f"capture_json={output.resolve()}",
            "-s", str(Path(__file__).resolve()),
        ]
        print(f"Capturing to: {output.resolve()}")
        print("Use the app now; press Ctrl+C to stop. The JSON is updated after each flow.")
        return subprocess.run(command).returncode
    except FileNotFoundError as exc:
        print(f"Could not start {exc.filename!r}. Check --adb/--mitmdump and PATH.", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print(f"ADB command failed ({exc.returncode}): {' '.join(exc.cmd)}", file=sys.stderr)
        return exc.returncode or 1
    finally:
        if proxy_configured and not args.leave_proxy:
            try:
                restore_proxy(args.adb, args.serial, old_proxy, args.port)
                run_adb(args.adb, args.serial, "reverse", "--remove", f"tcp:{args.port}", check=False)
                print("Restored the Android global HTTP proxy and removed this adb reverse mapping.")
            except (FileNotFoundError, subprocess.CalledProcessError) as exc:
                print(f"Warning: could not restore Android proxy automatically: {exc}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
