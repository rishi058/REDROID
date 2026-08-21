#!/usr/bin/env python3
"""Rewrite redroid /data/misc/ethernet/ipconfig.txt to set a valid default-route
gateway (and optional DNS). ReDroid's ipconfigstore writes gateway=0.0.0.0 when it
cannot detect a gateway from /proc/net/route at boot, which leaves Android netd
without a default route -> DNS fails with ENONET. This edits only the stored
gateway/dns, preserving the Android IpConfigStore v3 binary layout exactly.

Usage: fix-ipconfig-gateway.py <path> <gateway-ip> [dns1] [dns2]
Round-trips (decode->encode) and verifies against the original before applying
any change, so a format mismatch aborts safely.
"""
import struct
import sys


def decode(b):
    i = 0

    def ri():
        nonlocal i
        v = struct.unpack(">i", b[i:i + 4])[0]
        i += 4
        return v

    def ru():
        nonlocal i
        n = struct.unpack(">H", b[i:i + 2])[0]
        i += 2
        s = b[i:i + n].decode("utf-8")
        i += n
        return s

    doc = {"version": ri(), "links": [], "routes": [], "dns": [], "order": []}
    while i < len(b):
        key = ru()
        doc["order"].append(key)
        if key == "eos":
            break
        if key == "ipAssignment":
            doc["ipAssignment"] = ru()
        elif key == "linkAddress":
            doc["links"].append((ru(), ri()))
        elif key == "gateway":
            r = {"hasDest": ri()}
            if r["hasDest"] == 1:
                r["dest"] = ru()
                r["destPrefix"] = ri()
            r["hasGw"] = ri()
            if r["hasGw"] == 1:
                r["gw"] = ru()
            doc["routes"].append(r)
        elif key == "dns":
            doc["dns"].append(ru())
        elif key == "proxySettings":
            doc["proxy"] = ru()
        elif key == "id":
            doc["id"] = ru()
        else:
            raise ValueError("unknown key %r at %d" % (key, i))
    if i != len(b):
        raise ValueError("trailing bytes: consumed %d of %d" % (i, len(b)))
    return doc


def encode(doc):
    out = bytearray()

    def wi(v):
        out.extend(struct.pack(">i", v))

    def wu(s):
        e = s.encode("utf-8")
        out.extend(struct.pack(">H", len(e)))
        out.extend(e)

    wi(doc["version"])
    li = 0
    di = 0
    ri = 0
    for key in doc["order"]:
        wu(key)
        if key == "eos":
            break
        if key == "ipAssignment":
            wu(doc["ipAssignment"])
        elif key == "linkAddress":
            addr, prefix = doc["links"][li]
            li += 1
            wu(addr)
            wi(prefix)
        elif key == "gateway":
            r = doc["routes"][ri]
            ri += 1
            wi(r["hasDest"])
            if r["hasDest"] == 1:
                wu(r["dest"])
                wi(r["destPrefix"])
            wi(r["hasGw"])
            if r["hasGw"] == 1:
                wu(r["gw"])
        elif key == "dns":
            wu(doc["dns"][di])
            di += 1
        elif key == "proxySettings":
            wu(doc["proxy"])
        elif key == "id":
            wu(doc["id"])
    return bytes(out)


def main():
    path = sys.argv[1]
    gw = sys.argv[2]
    dns = sys.argv[3:]
    orig = open(path, "rb").read()
    doc = decode(orig)
    if encode(doc) != orig:
        raise SystemExit("ABORT: round-trip mismatch; parser does not match file")
    print("parsed OK; version", doc["version"], "links", doc["links"],
          "routes", doc["routes"], "dns", doc["dns"], "id", doc.get("id"))
    changed = False
    for r in doc["routes"]:
        if r.get("hasDest") == 1 and r.get("dest") == "0.0.0.0" and r.get("destPrefix") == 0:
            if r.get("hasGw") == 1:
                print("gateway %r -> %r" % (r.get("gw"), gw))
                r["gw"] = gw
            else:
                print("adding gateway %r to default route" % gw)
                r["hasGw"] = 1
                r["gw"] = gw
            changed = True
    if dns:
        print("dns %r -> %r" % (doc["dns"], dns))
        doc["dns"] = dns
        changed = True
    if not changed:
        raise SystemExit("no default route found to fix")
    new = encode(doc)
    if decode(new) is None:
        raise SystemExit("re-decode failed")
    open(path, "wb").write(new)
    print("wrote", len(new), "bytes to", path)


if __name__ == "__main__":
    main()
