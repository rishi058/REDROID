#!/usr/bin/env python3
"""Summarise / drill into a decrypting MITM capture (capture_mitm.sh output).

    python analyze.py                      # newest out/vpngate-mitm-*.json, host summary
    python analyze.py --file out/x.json    # a specific capture
    python analyze.py --host giamping.com  # full req/resp detail for a host substring
    python analyze.py --errors             # only flows with TLS/pin errors
"""
import argparse
import glob
import json
import os


def newest() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    files = glob.glob(os.path.join(here, "out", "vpngate-mitm-*.json"))
    if not files:
        raise SystemExit("no out/vpngate-mitm-*.json captures found")
    return max(files, key=os.path.getmtime)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file")
    ap.add_argument("--host", help="substring filter; prints full detail")
    ap.add_argument("--errors", action="store_true")
    ap.add_argument("--body-chars", type=int, default=800)
    args = ap.parse_args()

    path = args.file or newest()
    flows = json.load(open(path, encoding="utf-8"))
    print(f"# {path}  ({len(flows)} flows)\n")

    if not args.host and not args.errors:
        hosts, errs = {}, 0
        for x in flows:
            if x.get("error"):
                errs += 1
            h = (x.get("request") or {}).get("host") or x.get("url", "")
            hosts[h] = hosts.get(h, 0) + 1
        print(f"TLS/pin errors: {errs}")
        print("flows  host")
        for h, n in sorted(hosts.items(), key=lambda kv: -kv[1]):
            print(f"{n:5d}  {h}")
        return

    for x in flows:
        if args.errors and not x.get("error"):
            continue
        h = (x.get("request") or {}).get("host", "")
        if args.host and args.host not in h:
            continue
        print("=" * 80)
        print(x["method"], x["url"])
        print("status:", x.get("status"), "| error:", x.get("error"))
        if x.get("req_body"):
            print("REQ BODY:", x["req_body"][: args.body_chars])
        print(f"RESP ({x.get('resp_body_bytes', 0)} bytes):")
        print((x.get("resp_body") or "")[: args.body_chars])


if __name__ == "__main__":
    main()
