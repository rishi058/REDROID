import asyncio, os, sys, json
sys.path.insert(0, "/app")
from services.dw_signer import DiskwalaSignerClient
from services.np_lelo_client import fetch_raw
from services.diskwala_token import parse_bearer
import aiohttp

BEARER = open("/tmp/bearer.txt").read().strip()
LINK = os.environ.get("LINK", "6a610de906ba7ea03d7ad610")
DID = str(parse_bearer(BEARER).get("did") or "")
SECRET = os.environ["SIG_SECRET"]
PORT = int(os.environ["SIG_PORT"])
DECODO = os.environ.get("DECODO", "")

async def main():
    print("dID", DID, "bearer_len", len(BEARER))
    signer = DiskwalaSignerClient(host="127.0.0.1", port=PORT, secret=SECRET, timeout_seconds=8)
    async with aiohttp.ClientSession() as s:
        for label, proxy in [("ORACLE_DIRECT", None), ("DECODO", DECODO or None)]:
            try:
                st, txt = await fetch_raw(s, "np_lelo", BEARER, DID, LINK, signer=signer, proxy_url=proxy, timeout=30)
                print(label, "status", st, "body", txt[:140].replace(chr(10), " "))
            except Exception as e:
                print(label, "ERR", repr(e))

asyncio.run(main())
