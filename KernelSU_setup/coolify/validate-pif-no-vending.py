#!/usr/bin/env python3
"""Validate a ReDroid PIF archive before staging it through KernelSU."""

import argparse
import zipfile
import zlib
from pathlib import Path


TEXT_NAMES = {
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
}
SKIP_MARKER = b"Play Store is excluded from PIF specialization"
REQUIRED_NATIVE = {
    "zygisk/arm64-v8a.so",
    "zygisk/armeabi-v7a.so",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()

    failures: list[str] = []
    with zipfile.ZipFile(args.archive) as archive:
        names = set(archive.namelist())
        missing = REQUIRED_NATIVE.difference(names)
        if missing:
            failures.append(f"missing native payloads: {sorted(missing)}")

        module_prop = archive.read("module.prop").decode("utf-8")
        module_prop_crc = f"{zlib.crc32(module_prop.encode('utf-8')) & 0xFFFFFFFF:x}".encode()
        expected_metadata = (
            "id=playintegrityfix",
            "name=Play Integrity Fix [REDROID NO-VENDING]",
            "version=v4.7-1-redroid.2",
            "versionCode=47102",
        )
        for expected in expected_metadata:
            if expected not in module_prop.splitlines():
                failures.append(f"module.prop is missing {expected!r}")
        if "updateJson=" in module_prop:
            failures.append("module.prop must not permit an upstream auto-update")

        for native_name in sorted(REQUIRED_NATIVE.intersection(names)):
            native_payload = archive.read(native_name)
            if SKIP_MARKER not in native_payload:
                failures.append(f"{native_name} lacks the Play Store early-skip marker")
            if module_prop_crc not in native_payload:
                failures.append(
                    f"{native_name} does not embed module.prop CRC {module_prop_crc.decode()}"
                )

        for name in sorted(names):
            if not (
                name.endswith((".sh", ".prop"))
                or name in TEXT_NAMES
            ):
                continue
            payload = archive.read(name)
            if payload.startswith(b"\xef\xbb\xbf"):
                failures.append(f"{name} has a UTF-8 BOM")
            if b"\r\n" in payload or b"\r" in payload:
                failures.append(f"{name} is not LF-normalized")

    if failures:
        raise SystemExit("PIF archive validation failed:\n- " + "\n- ".join(failures))
    print(f"Validated hardened PIF archive: {args.archive}")


if __name__ == "__main__":
    main()
