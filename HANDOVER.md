# REDROID / DW-fast-api Handover

Updated: 2026-10-03

## 1. Current project objective

DW-fast-api resolves Diskwala links using six independently enrolled ReDroid principals. Normal traffic uses cached device Bearers plus DW-SIGNER-generated per-request AndroidKeyStore proofs. ReDroid UI capture remains available for bearer bootstrap, fresh enrollment, and principal rotation.

The current unresolved problem is that Diskwala now returns CDN URLs with multiple server-selected delivery policies. Some are usable through a normal relay with an OkHttp User-Agent. Others are bound to the network/proxy session that requested the URL and cannot be replayed from Oracle, Cloudflare, a different Rayobyte exit, or Decodo.

## 2. Infrastructure and topology

### Oracle / Coolify VPS

```text
SSH: ssh -i "C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key" ubuntu@141.148.151.172
Public health: http://dsm89t26p1mhjww7bkvldkwq.141.148.151.172.sslip.io/health
Self-hosted relay: http://relay.141.148.151.172.sslip.io/
```

### GCP ReDroid VPS

```text
SSH: ssh -i "C:/Users/Rishi/.ssh/redroid-vm-20260919" Rishi@35.188.214.74
```

| Device ID | Container | VPS ADB port | FastAPI local tunnel | Local signer forward |
|---|---|---:|---:|---:|
| redroid15-pixel8-v1 | redroid15-pixel8-v1 | 5555 | 5555 | 39026 |
| redroid15-pixel8-source | redroid17_64only | 5557 | 5557 | 39027 |
| redroid15-pixel8-v2 | redroid15-pixel8-v2 | 5559 | 5559 | 39028 |
| redroid15-pixel8-v3 | redroid15-pixel8-v3 | 5556 | 5560 | 39029 |
| redroid15-pixel8-v4 | redroid15-pixel8-v4 | 5558 | 5558 | 39030 |
| redroid15-pixel8-v5 | redroid15-pixel8-v5 | 6000 | 6000 | 39031 |

Local port 5556 belongs to mitmdump; therefore v3 remote 5556 maps to local 5560.

All clones share:

```text
integrity_identity_group = gcp-cloned-profile-keybox-1
```

## 3. Completed work

### Six-device pool

- New GCP IP configured for every member.
- Unique ADB and signer forwards configured.
- App, auth preference, signer listener, and signer secret were verified on all six containers.
- Per-device signer secrets are loaded from each app-private `signer.secret` when environment overrides are absent.

### DW-SIGNER

- Standalone app-UID signer uses the real non-exportable AndroidKeyStore key.
- Fast framework-only principal rotation validated at approximately 23 seconds for the mutation/enrollment helper.
- Production rotation uses staged `--apply`, FastAPI enrollment verification, and `--finalize`.
- `--rollback` restores SSAID/auth and verifies app, signer, Zygisk, and framework health.
- `--recover` is idempotent and handles deployment-interrupted staged rotations.
- Latest helper target:

```text
/usr/local/sbin/rotate-diskwala-principal-fast
```

### Rotation governor

Current local configuration:

```json
{
  "soft_limit": 50,
  "hard_limit": 75,
  "retry_max_attempts": 4,
  "retry_min_wait_seconds": 30,
  "retry_max_wait_seconds": 60
}
```

Important: a deployed config used `retry_max_wait_seconds: 75`, but the strict parser allows at most 60. That caused a Coolify deployment failure before container creation. Local source is corrected to 60.

- Rotation attempts persist in SQLite by shared integrity group.
- Only one group lease can rotate at a time.
- Failed rotations use linear waits capped at 60 seconds.
- Startup recovery now checks all devices for interrupted staged rotations before ADB configuration.
- Dockerfile uses SIGTERM and Uvicorn has a 120-second graceful-shutdown allowance. Coolify/Docker stop grace should also be at least 120 seconds.

### ADB reverse and proxy persistence

Before rotation finalization FastAPI verifies:

```text
ADB online
tcp:5556 -> tcp:5556 reverse exists
Android proxy = 127.0.0.1:5556
device can connect through reverse to mitmdump
app-generated request returned HTTP 200
captured kid == live signer kid
```

The health loop continues checking and repairing this path after later ADB reconnects.

### Bearer bootstrap and startup

- App bootstrap proxy now prefers Rayobyte rather than Decodo.
- Startup and background bearer warmups run concurrently per device.
- Each ReDroid has an independent targeted refresh lock.
- Normal untargeted cold misses retain process-wide single-flight.
- Interrupted rotation recovery remains marked `recovery_warmup` until a bearer is harvested.

### Direct signed request capacity

- Cold Android/UI capacity remains 1 per device.
- Direct signer capacity is 4 per device.
- Six-device direct capacity is 24 concurrent requests.
- Queue capacity is 48.
- Safety budgets were raised for a 12-RPS peak:

```text
60 seconds: 180/device, 1080 global
3600 seconds: 1500/device, 9000 global
```

### Egress optimization

Default order is:

```text
Rayobyte -> Decodo -> Direct -> Mobile
```

- Round-robin is disabled by default in favor of reliability order.
- Three attempts, eight seconds each, inside a 29-second logical deadline.
- Transport cooldown is 30 seconds and probe lease is 10 seconds.
- Probe/cooldown contention skips to another egress/device rather than returning immediately.
- Rotating proxy pools (Rayobyte, Decodo, Mobile) no longer open pool-wide or device-pair breakers from one bad exit.
- Persisted legacy rotating-proxy breaker rows are deleted at governor startup.
- Direct is a fixed egress and retains breaker protection.

### Response cache

- OpenObserve is no longer used as L2 cache.
- No byte, entry-count, per-entry, or LRU size limit.
- Diskwala responses cache until the earliest explicit CDN `e` or relay `exp` expiry.
- Unsigned Flezen responses use a six-hour expiry.
- Expired entries are removed on startup, lookup, put, random selection, and a five-minute background sweep.
- Rotation random fallback and `RETURN_DISKWALA_RANDOM=true` use only the local persistent cache.
- Random fallback never writes the random response under the requested key.

### Relay

FastAPI supports:

```env
RELAY_PREFIXES="[http://relay.141.148.151.172.sslip.io/]"
RELAY_HMAC_SECRET=<same 32+ character secret as relay>
RELAY_MAX_TTL_SECONDS=21600
```

- Multiple prefixes are selected round-robin.
- HMAC signs `<exp>\n<exact-original-url>`.
- Supports signed/unsigned Diskwala CDN URLs and `*.fzcdn.cloud` URLs.
- Preserves Range requests.
- Sanitizes trailing `\\` and `%5C` Ctrl-click artifacts.
- Worker/self-hosted relay must allowlist CDN hosts and must not operate as an open proxy.

### OpenObserve

Only these HTTP fields are delivered:

```text
_timestamp
action
cache_status
client_ip
method
path
request_body
response_body
status_code
x_api_key
```

Internal lifecycle, warmup, signer, 429/403 diagnostic, duration, request ID, build, instance, byte-count, and duplicate timestamp fields are not delivered.

Detailed live diagnostics remain available through `/diskwala/traffic` and local logs.

## 4. CDN signature findings

### Public research

No public Diskwala CDN signing implementation was found for:

```text
e, d, s, n
X-DW-Sig: net
X-DW-Sig: bad_sig
```

Comparable official policies show that IP-bound CDN authorization validates the real TCP source IP; spoofed `X-Forwarded-For` cannot change it.

Useful references:

- AWS CloudFront IP policies: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-creating-signed-url-custom-policy.html
- Bunny IP locking: https://docs.bunny.net/docs/cdn/security/token-authentication/advanced
- Cloudflare request headers: https://developers.cloudflare.com/fundamentals/reference/http-headers/

### Parameter analysis

- `e`: Unix-seconds expiry, normally approximately six hours.
- `s`: 43 unpadded Base64URL characters = 32 bytes; consistent with an HMAC-SHA-256-sized tag, algorithm not proven.
- `d`: stable across unrelated files for a device/principal; likely device/principal/shard selector, not proven.
- `n`: dynamic delivery-policy class. It is not deterministically derived from `d`.
- Do not reorder, decode/re-encode, or modify the returned CDN target URL.

### Existing 39-URL audit

For 39 then-current signed URLs:

```text
normal client -> 403
User-Agent okhttp/4.12.0 -> 206
relay -> 206
```

This proved a UA-gated policy existed, but not that all policies are UA-only.

### Strict network-bound URL

A later valid-future URL with `n=14051` returned:

```text
X-DW-Sig: net
```

from direct, Oracle, Rayobyte, and Decodo. The generic body said the link was expired, but `e` still had almost six hours remaining. The actual failure was network binding.

## 5. Controlled signature-policy tests

All controlled tests used only:

```text
Device: redroid15-pixel8-v5
VPS ADB port: 6000
Local ADB: 127.0.0.1:6000
Signer local port: 39031
Signer device port: 39026
```

Results:

| Request mode | API User-Agent / path | Observed n | Relay |
|---|---|---:|---:|
| standalone signed | okhttp/4.12.0 | 212637 | 403 |
| standalone signed | Mozilla/5.0 | 5607 | 403 |
| standalone signed | same local mitmproxy/Rayobyte path | 6568 | 403 |
| standalone signed | app-observed header order | 28753 | 403 |
| genuine app capture | okhttp/4.12.0 | 133982 | variable: one 206, one later 403 |

### Fresh-bearer same-link test

The app was force-refreshed. JWT fingerprint and `iat` changed while `uid/did/pid/kid` remained identical. The same link was sent immediately through DW-SIGNER.

```text
app capture:       n=133982, d=ed1903dd30d97ef2
standalone +9 sec: n=328977, d=ed1903dd30d97ef2
```

Both relay probes were 403 in this run.

Conclusions:

- Fresh bearer alone does not reproduce app policy.
- User-Agent affects `n` but is insufficient.
- Header order and using the same mitmproxy are insufficient.
- Genuine app capture does not always produce a relay-compatible policy.
- Diskwala dynamically combines request/app/session/network context.
- `d` remaining constant supports device/principal association.

Evidence files:

```text
DW-fast-api/data/diskwala-url-audit-20261002.json
DW-fast-api/data/rayobyte-cdn-test-20261002.json
DW-fast-api/data/signature-policy-controlled-tests-20261003.json
DW-fast-api/data/signature-ua-okhttp-20261003.json
DW-fast-api/data/signature-ua-mozilla-20261003.json
DW-fast-api/data/signature-mitm-rayobyte-20261003.json
DW-fast-api/data/signature-app-header-order-20261003.json
DW-fast-api/data/fresh-bearer-sequence-20261003.json
```

## 6. Remaining CDN issue and feasible options

### Not feasible

- Changing `n`, `d`, or `e`: `s` authenticates policy fields.
- Spoofing `X-Forwarded-For`/`CF-Connecting-IP`: strict CDN authorization uses observed network source.
- Establishing through a proxy and switching an existing TCP/TLS download to direct: the connection, sequence state, TLS keys, and source IP belong to the proxy.
- Cloudflare/Oracle relay for a URL bound to another network.
- User-Agent-only workaround for every policy.

### Feasible options

1. **Sticky proxy session for API issuance and complete media fetch**
   - Most reliable for strict network policies.
   - Full media bytes are billed through the proxy.

2. **Owned fixed egress for API issuance and relay**
   - API and media relay must use the same public source IP.
   - Diskwala may return `403 network_not_allowed` for the owned IP.
   - Relay/VPS carries full media bandwidth.

3. **Proxy fetch once, cache, serve many**
   - Pay proxy bandwidth once per unique object.
   - Serve repeated clients from owned storage/CDN.
   - Use only if caching/re-distribution is authorized.

4. **Continue reverse engineering app-policy selection**
   - Capture exact app versus standalone headers, connection reuse, and token-refresh sequence.
   - Current evidence says bearer freshness, UA, mitm transport, and header order are individually insufficient.

### Can ReDroid be removed?

Not completely with the current authentication model.

FastAPI can eventually own challenge/refresh/bootstrap orchestration. DW-SIGNER could be extended to read the app-private refresh token and sign refresh assertions. ReDroid would then be used as an identity/HSM appliance rather than for every request.

ReDroid remains required for:

- Non-exportable AndroidKeyStore private key.
- Android key attestation certificate chain.
- Play Integrity during fresh enrollment.
- SSAID/principal rotation.
- App-private refresh-token storage unless securely migrated.

Removing app UI requests does not by itself solve CDN network binding.

## 7. Isolated one-ReDroid test procedure

Do not run this against a ReDroid simultaneously used by production. Drain/quarantine the selected device first.

The controlled tests used v5 only.

### 7.1 Create a one-device config

PowerShell from `DW-fast-api`:

```powershell
$source = Get-Content .\diskwala_config.json -Raw | ConvertFrom-Json
$source.diskwala.devices | ForEach-Object {
  $_.enabled = ($_.id -eq "redroid15-pixel8-v5")
}
$source.diskwala.principal_rotation.enabled = $false
$source.diskwala.upstream.max_attempts = 1
$source.diskwala.upstream.state_db_path = "$env:LOCALAPPDATA/Temp/kilo/isolated-upstream.sqlite3"
$source.diskwala.upstream.local_test_bypass.enabled = $true
$source.diskwala.upstream.local_test_bypass.run_id = "isolated-v5-test"
$source | ConvertTo-Json -Depth 30 | Set-Content "$env:LOCALAPPDATA\Temp\kilo\isolated-v5-config.json"
```

Ensure the temp directory exists before writing.

### 7.2 Open one ADB tunnel

In a separate terminal:

```powershell
ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" `
  -o ExitOnForwardFailure=yes `
  -o ServerAliveInterval=15 `
  -o ServerAliveCountMax=2 `
  -N -L 6000:127.0.0.1:6000 `
  Rishi@35.188.214.74
```

### 7.3 Start isolated FastAPI

```powershell
$env:DISKWALA_CONFIG_PATH="$env:LOCALAPPDATA/Temp/kilo/isolated-v5-config.json"
$env:DISKWALA_429_EXPERIMENT="true"
$env:DISKWALA_429_EXPERIMENT_RUN_ID="isolated-v5-test"
$env:DISKWALA_429_EXPERIMENT_BIND_HOST="127.0.0.1"
$env:DISKWALA_429_EXPERIMENT_WORKERS="1"
$env:SUBSCRIPTION_ENABLED="false"
$env:FLEZEN_ENABLED="false"
$env:RESPONSE_CACHE_ENABLED="false"
$env:RETURN_DISKWALA_RANDOM="false"
$env:DISKWALA_MOBILE_PROXY_ENABLED="false"
$env:DISKWALA_DIRECT_EGRESS_ENABLED="false"
$env:DISKWALA_UPSTREAM_PROXY_ENABLED="true"
$env:DISKWALA_DIRECT_DECODO_ENABLED="false"
$env:DISKWALA_RAYOBYTE_ENABLED="true"
$env:DISKWALA_API_USER_AGENT="okhttp/4.12.0"
$env:USE_SSH_TUNNEL="false"
python main.py
```

This uses Decodo/Rayobyte configuration from `.env`/code only for the explicitly selected paths. Current source prefers Rayobyte for app bootstrap and signed requests.

### 7.4 Health and identity checks

```powershell
python -m dotenv -f .env run -- python -c "import json,os,urllib.request; r=urllib.request.Request('http://127.0.0.1:8001/health',headers={'X-API-Key':os.environ['API_KEY_ADMIN']}); print(json.dumps(json.load(urllib.request.urlopen(r)),indent=2))"
```

Redacted identity:

```powershell
python -m dotenv -f .env run -- python -c "import json,os,urllib.parse,urllib.request; u='http://127.0.0.1:8001/diskwala/experiment/identity?'+urllib.parse.urlencode({'device_id':'redroid15-pixel8-v5'}); r=urllib.request.Request(u,headers={'X-API-Key':os.environ['API_KEY_ADMIN']}); print(json.dumps(json.load(urllib.request.urlopen(r)),indent=2))"
```

### 7.5 Controlled scripts

Machine-local diagnostic scripts created during this session:

```text
%LOCALAPPDATA%\Temp\kilo\fresh_bearer_sequence.py
%LOCALAPPDATA%\Temp\kilo\rayobyte_cdn_test.py
%LOCALAPPDATA%\Temp\kilo\probe_app_capture_policy.py
%LOCALAPPDATA%\Temp\kilo\probe_target_proxies.py
%LOCALAPPDATA%\Temp\kilo\audit_diskwala_urls.py
```

Run, for example:

```powershell
python "$env:LOCALAPPDATA\Temp\kilo\fresh_bearer_sequence.py"
```

The script forces an app refresh, records redacted JWT fingerprints, immediately sends the same link through DW-SIGNER, compares `d/n/e`, and performs one-byte Range probes through the configured relay.

### 7.6 Cleanup

Stop FastAPI with Ctrl+C, then restore the selected Android proxy:

```powershell
ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" Rishi@35.188.214.74 `
  "sudo docker exec redroid15-pixel8-v5 settings put global http_proxy :0"
```

Stop the SSH tunnel terminal afterward.

## 8. Production deployment cautions

- Never redeploy while a principal rotation is in `--apply` without giving FastAPI enough shutdown time to roll back.
- Coolify/Docker stop grace must be at least 120 seconds.
- Keep `retry_max_wait_seconds <= 60`; the strict parser rejects larger values.
- Per-device GCP key path in production JSON must be:

```text
/root/.ssh/ssh-key-gcp-redroid-vm.key
```

- Local Windows automatically resolves that path to:

```text
C:\Users\Rishi\.ssh\redroid-vm-20260919
```

- App bootstrap should use Rayobyte; Decodo produced `403 network_not_allowed` during bearer warmup.
- `RETURN_DISKWALA_RANDOM=true` is an explicit emergency mode that skips the full Diskwala device stack at startup.
- With it false, `rotation-random-hit` remains available from the unexpired local cache during known rotation/recovery states.
- FastAPI stores Bearers only in memory. Every process restart requires one warmup per device.
- OpenObserve is observability only; it is not a response cache.

## 9. Known deployment incident

A Coolify deployment failed because the built config had:

```json
"retry_max_wait_seconds": 75
```

The parser permits at most 60. The corrected source uses 60.

A later startup-recovery failure exposed a separate bug in `services/tunnel.py`: helper stdout was returned from an undefined variable. Local source now assigns `stdout, _stderr = proc.communicate(...)` before returning. Ensure the corrected source is deployed rather than relying on container hotpatches.

## 10. Immediate next steps

1. Deploy the corrected local DW-fast-api source and config.
2. Set Coolify stop grace to at least 120 seconds.
3. Confirm startup logs show six concurrent warmup attempts and six ready Bearers.
4. Confirm `/health` reports six healthy devices and direct capacity 24.
5. Confirm `/diskwala/traffic` shows Rayobyte first and no legacy rotating-proxy breaker rows.
6. Decide whether strict network-bound URLs justify sticky proxy streaming, fixed egress relay, or continued app-policy reverse engineering.
