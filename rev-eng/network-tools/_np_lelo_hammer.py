import asyncio, os, sys, time, json
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
N = int(os.environ.get("N", "15"))

async def main():
    signer = DiskwalaSignerClient(host="127.0.0.1", port=PORT, secret=SECRET, timeout_seconds=8)
    ok = bad = 0
    async with aiohttp.ClientSession() as s:
        for i in range(N):
            t = time.time()
            try:
                st, txt = await fetch_raw(s, "np_lelo", BEARER, DID, LINK, signer=signer, proxy_url=None, timeout=25)
                try:
                    err = json.loads(txt).get("error", "")
                except Exception:
                    err = ""
                if st == 200:
                    ok += 1
                else:
                    bad += 1
                print(i, "status", st, "err", err, "dt", round(time.time() - t, 2))
                if st == 403:
                    print("  -> 403 body:", txt[:160])
            except Exception as e:
                print(i, "EXC", repr(e))
            await asyncio.sleep(0.25)
    print("SUMMARY ok", ok, "non200", bad, "of", N)

asyncio.run(main())
