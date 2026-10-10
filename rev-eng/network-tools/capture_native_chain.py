#!/usr/bin/env python3
"""Capture and analyze the native attestation chain from a ReDroid device.

Runs attestdump on the device to get the genuine chain, then compares it
against the Yurikey58 keybox chain to identify why the backend rejected
the intercepted enrollment.

Usage:
    python capture_native_chain.py --adb-serial <serial> [--keybox captures/keybox.xml]

Prints: chain structure, cert subjects/issuers, attestation extension
security level, and chain fingerprint comparison.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import serialization


def run_attestdump(adb_serial: str, alias: str = "com.diskwalaapp.attest.ec.v1") -> dict:
    out_path = "/data/data/com.diskwalaapp/files/attestdump/chain.txt"
    cmd = [
        "adb", "-s", adb_serial, "shell",
        f"su 10107 sh -c "
        f"'CLASSPATH=/data/local/tmp/attestdump.jar "
        f"exec app_process /system/bin "
        f"com.recon.attestdump.AttestDump {alias} {out_path}'"
    ]
    subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    cat = subprocess.run(
        ["adb", "-s", adb_serial, "shell", f"cat {out_path}"],
        capture_output=True, text=True, timeout=10
    )
    return parse_attestdump(cat.stdout)


def parse_attestdump(output: str) -> dict:
    result: dict = {"certs": [], "ext_wrapped": []}
    for line in output.strip().splitlines():
        line = line.strip()
        m = re.match(r"CERT\[(\d+)\]=(.*)", line)
        if m:
            result["certs"].append(m.group(2))
        m = re.match(r"ATTEST_EXT_WRAPPED\[(\d+)\]=(.*)", line)
        if m:
            result["ext_wrapped"].append(m.group(2))
        if line.startswith("CHAIN_LEN="):
            result["chain_len"] = int(line.split("=")[1])
    return result


def load_keybox_chain(keybox_path: str, algorithm: str = "ecdsa") -> list[str]:
    root = ET.parse(keybox_path).getroot()
    for key in root.findall(".//Key"):
        if (key.attrib.get("algorithm") or "").lower() == algorithm:
            chain_el = key.find("CertificateChain")
            if chain_el is None:
                continue
            certs = []
            for cert_el in chain_el.findall("Certificate"):
                pem = (cert_el.text or "").strip()
                if pem:
                    cert = x509.load_pem_x509_certificate(pem.encode())
                    b64 = base64.b64encode(
                        cert.public_bytes(serialization.Encoding.DER)
                    ).decode()
                    certs.append(b64)
            return certs
    return []


def analyze_cert(b64_der: str, label: str) -> None:
    der = base64.b64decode(b64_der)
    cert = x509.load_der_x509_certificate(der)
    fp = hashlib.sha256(der).hexdigest()[:16]
    print(f"  {label}:")
    print(f"    Subject : {cert.subject.rfc4514_string()}")
    print(f"    Issuer  : {cert.issuer.rfc4514_string()}")
    print(f"    Serial  : {cert.serial_number:#x}")
    print(f"    Valid   : {cert.not_valid_before_utc} → {cert.not_valid_after_utc}")
    print(f"    PubKey  : {type(cert.public_key()).__name__}")
    print(f"    SHA256  : {fp}...")

    try:
        ext = cert.extensions.get_extension_for_oid(
            x509.ObjectIdentifier("1.3.6.1.4.1.11129.2.1.17")
        )
        raw = ext.value.value
        if raw[:2] == b"\x30\x82":
            version = raw[4] if len(raw) > 4 else -1
            sec_level = raw[7] if len(raw) > 7 else -1
            level_name = {0: "SOFTWARE", 1: "TEE", 2: "STRONGBOX"}.get(sec_level, f"UNKNOWN({sec_level})")
            print(f"    AttestExt: version={version} securityLevel={level_name}")
    except Exception:
        pass


def analyze_ext_wrapped(b64: str) -> None:
    raw = base64.b64decode(b64)
    inner = raw[4:] if raw[:2] == b"\x04\x82" else raw
    if inner[:2] == b"\x30\x82":
        version = inner[4] if len(inner) > 4 else -1
        sec_level = inner[7] if len(inner) > 7 else -1
        level_name = {0: "SOFTWARE", 1: "TEE", 2: "STRONGBOX"}.get(sec_level, f"UNKNOWN({sec_level})")
        print(f"    Extension inner: version={version} securityLevel={level_name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb-serial", required=True)
    parser.add_argument("--keybox", default="captures/keybox.xml")
    parser.add_argument("--alias", default="com.diskwalaapp.attest.ec.v1")
    args = parser.parse_args()

    print("=== Native attestation chain (from device) ===")
    native = run_attestdump(args.adb_serial, args.alias)
    if not native["certs"]:
        print("ERROR: no certs captured. Is attestdump.jar deployed?")
        return

    for i, b64 in enumerate(native["certs"]):
        analyze_cert(b64, f"CERT[{i}]")
    for i, b64 in enumerate(native.get("ext_wrapped", [])):
        analyze_ext_wrapped(b64)

    print()
    print("=== Yurikey58 keybox chain (for comparison) ===")
    keybox_path = Path(args.keybox)
    if not keybox_path.exists():
        script_dir = Path(__file__).parent
        keybox_path = script_dir / "captures" / "keybox.xml"
    if keybox_path.exists():
        keybox_certs = load_keybox_chain(str(keybox_path))
        for i, b64 in enumerate(keybox_certs):
            analyze_cert(b64, f"KEYBOX[{i}]")
    else:
        print(f"  (keybox not found at {keybox_path})")

    print()
    print("=== Chain comparison ===")
    if native["certs"] and keybox_path.exists():
        keybox_certs = load_keybox_chain(str(keybox_path))
        native_intermediates = set(native["certs"][1:]) if len(native["certs"]) > 1 else set()
        keybox_set = set(keybox_certs)
        overlap = native_intermediates & keybox_set
        if overlap:
            print("  OVERLAP: native and keybox share intermediate/root cert(s)")
            print("  → TrickyStore likely uses Yurikey58; issue is in leaf cert construction")
        else:
            print("  NO OVERLAP: native chain uses different intermediates from Yurikey58")
            print("  → Confirms the inconsistency hypothesis (SOFTWARE ext + HARDWARE chain)")
            print("  → Fix: use on-device attestation (AttestGen) for genuine chain")


if __name__ == "__main__":
    main()
