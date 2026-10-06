# net-capture — app traffic capture (VPN Gate)

Two capture modes for the Redroid container on the Oracle VPS. Use the **MITM
mode** for detailed, decrypted request/response data (the DiskWala-style setup).

| mode | script | what you get | decrypts TLS? |
|------|--------|--------------|---------------|
| **MITM (primary)** | [`capture_mitm.sh`](capture_mitm.sh) | full URLs, req/resp headers + bodies, timings | ✅ yes |
| endpoint inventory | [`capture_vpngate.sh`](capture_vpngate.sh) | hostnames + IP:port only (incl. QUIC/UDP the proxy can't see) | ❌ no |

Target app: **VPN Gate** `com.giamping.sevpn` on `127.0.0.1:5559` (production
Pixel 8 container). Override `PKG`/`APP`/`ACTIVITY` for other apps.

---

## MITM mode (decrypting) — `capture_mitm.sh`

Same technique as the DiskWala capture: `mitmdump` runs on the host and the
device reaches it through `adb reverse` + the Android global HTTP proxy, with
mitmproxy's CA trusted in the device system store. Every flow is written with
full headers + bodies by the proven addon
[`../rev-eng/network-tools/capture-live-networks.py`](../rev-eng/network-tools/capture-live-networks.py).

```
 device app ──http_proxy 127.0.0.1:8080──► adb reverse ──► host mitmdump ──► internet
                                                               │
                                              out/vpngate-mitm-<ts>.json (full flows)
```

### Prereqs

- SSH tunnel up + `adb connect 127.0.0.1:5559` (see [../VPS_access_guide.md](../VPS_access_guide.md)).
- `mitmdump --version` works locally (mitmproxy installed).
- mitmproxy CA (hash **c8750f0d**) trusted on the device. Already installed in
  the conscrypt APEX store. If it ever goes missing, re-add it:
  ```bash
  ./install_ca.sh      # pushes certs/c8750f0d.0 and installs via docker exec (root)
  ```

### Run

```bash
cd net-capture
./capture_mitm.sh          # 35s decrypting capture of VPN Gate launch
./capture_mitm.sh 60       # custom window (seconds)
```

Output: `out/vpngate-mitm-<timestamp>.json` (+ `.mitmlog`, + `vpngate-mitm.latest.json`).

### Inspect

```bash
python analyze.py                      # host summary + TLS-error count
python analyze.py --host giamping.com  # full req/resp detail for a host
python analyze.py --errors             # only flows that failed to decrypt (pinning)
```

### JSON shape (one object per flow)

```jsonc
{
  "method": "GET", "url": "https://giamping.com/repository/zrequestandroid.php?...",
  "status": 200,
  "req_headers": { ... }, "req_body": "...", "req_body_bytes": 0,
  "resp_headers": { ... }, "resp_body": "...", "resp_body_bytes": 782040,
  "request": { "scheme","host","port","path","http_version","started_at","ended_at" },
  "response": { "reason","http_version","started_at","ended_at" },
  "client": {...}, "server": { "peername","sni","tls_version","cipher" },
  "error": null
}
```
Binary/compressed bodies are stored as base64 with a `*_base64` field.

### Findings for VPN Gate (launch)

- **0 TLS errors** — nothing is certificate-pinned; everything decrypts.
- App backend: `giamping.com/repository/zrequestandroid.php?message=<blob>` —
  both the `message` param and the ~780 KB response are **application-layer
  encrypted on top of TLS** (the app's own cipher), so TLS decryption shows the
  envelope but not the plaintext payload.
- Dynamic endpoint discovery: fetches a GitHub gist
  (`gist.githubusercontent.com/mastervnc/.../raw/kerberos`) that returns a
  Cloudflare Worker URL (`*.workers.dev`).
- Remainder is ad/analytics/mediation: Unity Ads, Google Ads / DoubleClick,
  Vungle.

---

## Endpoint mode (no decryption) — `capture_vpngate.sh`

`tcpdump` inside the container → pcap → parsed with `tshark` on the VPS into an
endpoints JSON (DNS, TLS SNI, destination IP:port). Useful because it also
captures **QUIC/UDP 443** traffic that an HTTP proxy cannot see, and needs no
proxy/CA. See [`parse_endpoints.py`](parse_endpoints.py). Note: on Android 15
this device uses DNS-over-TLS, so plaintext DNS is usually empty — hostnames
come from TLS SNI.

```bash
./capture_vpngate.sh 30    # 30s endpoint inventory -> out/vpngate-<ts>.json
```

---

## Notes

- All privileged VPS/ssh commands run through [../access.py](../access.py).
- Everything here is read-only w.r.t. the device: packet capture, a temporary
  proxy setting (restored on exit), and launching the app. No reboots or module
  changes.
