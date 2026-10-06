#!/usr/bin/env python3
"""Parse a pcap into a JSON inventory of every endpoint an app contacted.

Runs on the host that has `tshark` (the Oracle VPS). It makes a few targeted
tshark passes over the capture and aggregates them into one endpoints report:

  - DNS queries + answers (hostname -> resolved IPs)
  - TLS ClientHello SNI (reveals HTTPS hostnames even when the app pins certs)
  - HTTP host + full request URL (plaintext requests)
  - every outbound TCP connection (SYN) and UDP flow -> dst IP:port

Usage:
    python3 parse_endpoints.py <capture.pcap> [--package PKG] [--app NAME]
                               [--started EPOCH] [--duration SECONDS]
                               > endpoints.json
"""
import argparse
import json
import shutil
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone


def tshark_bin() -> str:
    path = shutil.which("tshark")
    if not path:
        sys.exit("tshark not found on PATH")
    return path


def run_fields(pcap: str, display_filter: str, fields: list[str]) -> list[list[str]]:
    """Run one tshark field-extraction pass. Returns rows of field values."""
    cmd = [tshark_bin(), "-r", pcap, "-n", "-T", "fields",
           "-E", "separator=\t", "-E", "occurrence=a"]
    if display_filter:
        cmd += ["-Y", display_filter]
    for f in fields:
        cmd += ["-e", f]
    out = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    rows = []
    for line in out.stdout.splitlines():
        if line.strip() == "":
            continue
        rows.append(line.split("\t"))
    return rows


def split_multi(val: str) -> list[str]:
    """A tshark field with occurrence=a joins repeats with commas."""
    if not val:
        return []
    parts = []
    for chunk in val.replace(",", " ").split():
        if chunk:
            parts.append(chunk)
    return parts


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--package", default="")
    ap.add_argument("--app", default="")
    ap.add_argument("--started", type=float, default=0.0)
    ap.add_argument("--duration", type=float, default=0.0)
    ap.add_argument("--local-ip", default="",
                    help="container's own IP(s), comma-separated; used to "
                         "orient UDP flows to their remote peer")
    args = ap.parse_args()

    local_ips = {ip for ip in args.local_ip.split(",") if ip}

    # ip -> set(hostnames) learned from DNS answers and TLS SNI
    ip_to_hosts: dict[str, set[str]] = defaultdict(set)
    dns_queries: set[str] = set()
    sni_hosts: set[str] = set()
    http_calls: list[dict] = []

    # --- DNS: queries + answers -------------------------------------------
    for row in run_fields(
        args.pcap,
        "dns",
        ["dns.flags.response", "dns.qry.name", "dns.a", "dns.aaaa"],
    ):
        row += [""] * (4 - len(row))
        resp, qname, a, aaaa = row[0], row[1], row[2], row[3]
        for name in split_multi(qname):
            dns_queries.add(name.lower())
        for ip in split_multi(a) + split_multi(aaaa):
            for name in split_multi(qname):
                ip_to_hosts[ip].add(name.lower())

    # --- TLS SNI ----------------------------------------------------------
    for row in run_fields(
        args.pcap,
        "tls.handshake.extensions_server_name",
        ["tls.handshake.extensions_server_name", "ip.dst", "ipv6.dst", "tcp.dstport"],
    ):
        row += [""] * (4 - len(row))
        sni, ip4, ip6, _ = row[0], row[1], row[2], row[3]
        for name in split_multi(sni):
            sni_hosts.add(name.lower())
            for ip in split_multi(ip4) + split_multi(ip6):
                ip_to_hosts[ip].add(name.lower())

    # --- HTTP plaintext requests ------------------------------------------
    for row in run_fields(
        args.pcap,
        "http.request",
        ["http.host", "http.request.method", "http.request.full_uri",
         "ip.dst", "tcp.dstport"],
    ):
        row += [""] * (5 - len(row))
        host, method, uri, ipd, port = row
        http_calls.append({
            "host": host,
            "method": method,
            "url": uri,
            "dst": ipd,
            "dst_port": port,
        })
        if ipd and host:
            ip_to_hosts[ipd].add(host.lower())

    # --- Outbound connections: TCP SYN + UDP flows ------------------------
    # endpoint key -> aggregate
    endpoints: dict[tuple, dict] = {}

    def touch(ip: str, port: str, proto: str, epoch: str):
        if not ip or not port:
            return
        key = (ip, port, proto)
        ep = endpoints.get(key)
        ts = None
        try:
            ts = float(epoch)
        except (TypeError, ValueError):
            ts = None
        if ep is None:
            endpoints[key] = {
                "ip": ip,
                "port": int(port) if port.isdigit() else port,
                "protocol": proto,
                "count": 1,
                "first_seen_epoch": ts,
            }
        else:
            ep["count"] += 1
            if ts is not None and (ep["first_seen_epoch"] is None
                                   or ts < ep["first_seen_epoch"]):
                ep["first_seen_epoch"] = ts

    # TCP connection openers (client -> server SYN, no ACK)
    for row in run_fields(
        args.pcap,
        "tcp.flags.syn==1 && tcp.flags.ack==0",
        ["ip.dst", "ipv6.dst", "tcp.dstport", "frame.time_epoch"],
    ):
        row += [""] * (4 - len(row))
        ip4, ip6, port, epoch = row
        ip = (split_multi(ip4) + split_multi(ip6) + [""])[0]
        touch(ip, port, "TCP", epoch)

    # UDP flows (QUIC/HTTP3 on 443, DoT fallbacks, etc.). Both directions of a
    # flow appear in the pcap, so orient each packet to its REMOTE peer: if the
    # destination is us, the peer is the source; otherwise the peer is the
    # destination. This collapses a QUIC conversation to one remote:port
    # endpoint instead of leaking our own ephemeral ports.
    for row in run_fields(
        args.pcap,
        "udp && !mdns && !llmnr",
        ["ip.src", "ip.dst", "ipv6.src", "ipv6.dst",
         "udp.srcport", "udp.dstport", "frame.time_epoch"],
    ):
        row += [""] * (7 - len(row))
        s4, d4, s6, d6, sport, dport, epoch = row
        src = (split_multi(s4) + split_multi(s6) + [""])[0]
        dst = (split_multi(d4) + split_multi(d6) + [""])[0]
        if dst in local_ips and src not in local_ips:
            ip, port = src, sport          # inbound reply -> peer is source
        else:
            ip, port = dst, dport          # outbound -> peer is destination
        if ip in local_ips:
            continue                        # purely local, skip
        touch(ip, port, "UDP", epoch)

    # Attach hostnames + readable first_seen to each endpoint
    endpoint_list = []
    for ep in endpoints.values():
        hosts = sorted(ip_to_hosts.get(ep["ip"], []))
        fs = ep.pop("first_seen_epoch")
        ep["hostnames"] = hosts
        ep["first_seen"] = (
            datetime.fromtimestamp(fs, tz=timezone.utc).isoformat()
            if fs else None
        )
        endpoint_list.append(ep)

    # Sort: named endpoints first, then by first_seen
    endpoint_list.sort(key=lambda e: (not e["hostnames"], e["first_seen"] or ""))

    # Union of all hostnames seen anywhere
    all_hosts = set(dns_queries) | set(sni_hosts)
    for calls in http_calls:
        if calls["host"]:
            all_hosts.add(calls["host"].lower())

    report = {
        "app": args.app or None,
        "package": args.package or None,
        "captured_at": (
            datetime.fromtimestamp(args.started, tz=timezone.utc).isoformat()
            if args.started else None
        ),
        "duration_seconds": args.duration or None,
        "summary": {
            "unique_hostnames": len(all_hosts),
            "dns_queries": len(dns_queries),
            "tls_sni_hosts": len(sni_hosts),
            "http_requests": len(http_calls),
            "ip_endpoints": len(endpoint_list),
        },
        "hostnames": sorted(all_hosts),
        "dns_queries": sorted(dns_queries),
        "tls_sni": sorted(sni_hosts),
        "http_requests": http_calls,
        "endpoints": endpoint_list,
    }

    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
