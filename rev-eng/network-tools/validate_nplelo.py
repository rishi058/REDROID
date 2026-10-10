#!/usr/bin/env python3
"""Validate that each enrolled delegated principal can mint a bearer (token/refresh
via on-device refresh-assertion) and sign np_lelo -> HTTP 200, through DW-SIGNER.

Reads principals from the registry, uses the on-device DW-SIGNER daemon
(app_process, no app launch) to produce the refresh assertion and the DW1 np_lelo
proof, and routes every call through the residential gateway (production path).
Never prints secrets (master key, bearer, refresh token, signer secret).
"""
from __future__ import annotations

import asyncio
import datetime
import os
import sys

sys.path.insert(0, "/home/Rishi/delegated-tools/svc")

import aiohttp

from services.dw_signer import DiskwalaSignerClient
from services.virtual_principals.client import VirtualPrincipalBackendClient
from services.virtual_principals.crypto import MasterKey
from services.virtual_principals.gateway import ResidentialFetchGateway
from services.virtual_principals.registry import VirtualPrincipalRegistry
from services.virtual_principals.types import PrincipalCredential

DB = os.environ["VP_DB"]
BASE_URL = os.environ.get("DW_BASE_URL", "https://api.diskwala.com/api/v2/android")
BACKEND = os.environ.get("RESIDENTIAL_GATEWAY_BACKEND", "phone")
SIGNER_PORT = int(os.environ.get("SIGNER_PORT", "39026"))
SIGNER_SECRET = os.environ["SIGNER_SECRET"]
LINKS_FILE = os.environ["LINKS_FILE"]
PER = int(os.environ.get("PER_PRINCIPAL", "2"))


def link_id(url: str) -> str:
    return url.strip().rstrip("/").rsplit("/", 1)[-1]


def np_body(lid: str, did: str) -> bytes:
    import json
    t = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    return json.dumps(
        {"id": lid, "t": t, "c_i": {}, "user": {}, "s": False, "dID": did},
        separators=(",", ":"),
    ).encode("utf-8")


async def main() -> int:
    links = [l.strip() for l in open(LINKS_FILE, encoding="utf-8") if l.strip()]
    mk = MasterKey.from_environment()
    reg = VirtualPrincipalRegistry(DB, master_key=mk)
    snaps = [s for s in reg.snapshots() if s.status == "active" and s.delegated]
    print(f">> {len(snaps)} active delegated principals; {len(links)} links; {PER} links each")

    signer = DiskwalaSignerClient(
        host="127.0.0.1", port=SIGNER_PORT, secret=SIGNER_SECRET, timeout_seconds=20
    )
    try:
        st = await signer.status()
        print(f">> signer: alias_present={st.get('alias_present')} port={st.get('port')} default_kid={str(st.get('kid'))[:14]}")
    except Exception as exc:  # noqa: BLE001
        print(f"!! signer daemon unreachable: {type(exc).__name__}: {exc}")
        reg.close()
        return 2

    total = 0
    ok200 = 0
    async with aiohttp.ClientSession() as session:
        gateway = ResidentialFetchGateway(session)
        client = VirtualPrincipalBackendClient(gateway, backend=BACKEND, backend_base_url=BASE_URL)
        for i, s in enumerate(snaps):
            kid = s.kid
            tag = f"[{i + 1}/{len(snaps)}] did={s.did} pid={s.pid} kid={kid[:14]} tier={s.tier}"
            try:
                sm = reg.secret_material(s.uid)
            except Exception as exc:  # noqa: BLE001
                print(f"{tag} SECRET FAIL: {type(exc).__name__}: {exc}")
                continue
            principal = PrincipalCredential(
                device_id=s.did, key_id=kid, access_token="", refresh_token=sm.refresh_token, tier=s.tier
            )

            async def assertion_signer(inp, _kid=kid):
                _, assertion = await signer.refresh_assertion(inp.challenge, _kid)
                return assertion

            try:
                tr = await client.refresh_token(principal, assertion_signer)
                cred = tr.credential
                print(f"{tag} refresh=OK (bearer minted)")
            except Exception as exc:  # noqa: BLE001
                print(f"{tag} refresh=FAIL {type(exc).__name__}: {exc}")
                total += PER
                continue

            async def dw_signer(path, body, _kid=kid):
                proof = await signer.sign(path, body, kid=_kid)
                return proof.headers()

            chosen = links[PER * i: PER * i + PER] or links[:PER]
            for lk in chosen:
                lid = link_id(lk)
                total += 1
                try:
                    resp = await client.np_lelo_raw(cred, np_body(lid, s.did), dw_signer)
                    mark = "OK" if resp.status == 200 else ""
                    if resp.status == 200:
                        ok200 += 1
                    print(f"{tag} np_lelo link={lid} -> HTTP {resp.status} {mark}")
                except Exception as exc:  # noqa: BLE001
                    print(f"{tag} np_lelo link={lid} -> ERROR {type(exc).__name__}: {exc}")

    reg.close()
    print(f"\nSUMMARY: {ok200}/{total} np_lelo returned HTTP 200 "
          f"across {len(snaps)} principals")
    return 0 if ok200 == total and total > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
