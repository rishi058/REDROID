# Diskwala/ReDroid Resource Investigation and TalsecKill v1.3 Handoff

**Last updated:** 2026-09-06 08:18 UTC
**Primary FastAPI repository:** `D:\PROJECT\_TRASH\REDROID\DW-fast-api`  
**Reverse-engineering/module repository:** `D:\PROJECT\_TRASH\REDROID\rev-eng`  
**Production host:** `141.148.151.172`  
**Diskwala package:** `com.diskwalaapp` v24.5 (`versionCode=854`)  
**Production LSPosed module:** `com.recon.talsecbypass` v1.5 (`versionCode=8`)
**Current artifact:** `..\rev-eng\modules\talseckill.apk`
**Artifact SHA-256:** `b27dbb9fb76681bba2f2c57b47b2702d7b12ef63699b493847c133a0e8262fa1`

> [!IMPORTANT]
> TalsecKill v1.5 is deployed and production is serving traffic. Five-minute
> validation confirms the dominant Talsec scheduler leak is fixed: 342 intents
> reused one scheduler, numbered pool workers remained exactly 62, and total
> threads fell from 354 to 299 rather than growing 2.7–2.9 threads/second. The
> automatic five-minute timer still recycled this healthy process, so a longer
> same-PID validation is still required before calling the incident closed.
>
> **UPDATE (2026-09-06): see §§24–26.** v1.4.2 proved the dominant creator was
> Talsec/freeRASP `R2.P`, not an ad SDK. v1.5 reuses that exact scheduler while
> preserving its periodic task and pause cancellation semantics.

> [!CAUTION]
> This document intentionally contains no API keys, OpenObserve credentials,
> private-key contents, authorization headers, captured direct media URLs, or
> integrity tokens. Keep the ignored `data/` reports and LSPosed backups private.
>
> The session's production load tests sent `API_KEY_ADMIN` to the public HTTP
> endpoint because the HTTPS router was unavailable. The value is not recorded
> here, but it must be treated as potentially exposed in transit and rotated.
> `scripts/load_test_video.py` now refuses remote plaintext HTTP.

## 1. Executive summary

The production incident initially looked like a FastAPI memory/CPU leak and a
Docker restart loop. Live evidence showed a different primary failure:

1. `dw-fast-api` remained comparatively small and stable and had zero Docker
   restarts/OOM kills.
2. The **Diskwala Android process** accumulated hundreds to thousands of Java
   and native threads, grew toward 1 GiB RSS, saturated the ReDroid CPU, and
   eventually crashed or was force-stopped by recovery.
3. An ART dump proved that most of the threads were idle executor workers. In a
   676-thread snapshot, 459 were `pool-N-thread-M`; 410 were parked indefinitely
   in `ScheduledThreadPoolExecutor$DelayedWorkQueue.take()`.
4. The app bundles AppLovin MAX plus many mediation adapters. Repeated ad load,
   reload, and banner-refresh behavior creates substantial adapter activity.
5. Legacy behavior accidentally hid this app leak by force-stopping Diskwala on
   nearly every 502/503/504 recovery and on `/adb/connect`. The September 5
   changes correctly removed restart storms, but consequently allowed the
   leaking app process to live long enough to deteriorate.
6. The September 5 deployment also shortened capture budgets, introduced a
   bounded queue, temporarily disabled response caching, and removed serial
   fallback behavior. Recent traffic was about 17% higher, while estimated
   device work was about 34% higher during the cache-disabled period.

The work in this session therefore had three tracks:

- make host/API ADB repair non-destructive and rate-limited;
- quantify real traffic and one-device capacity with controlled load tests;
- reduce Android ad-SDK resource churn with a narrowly scoped LSPosed module.

## 2. Pre-v1.4 production status

Snapshot at **2026-09-05 23:18:37 UTC**:

| Item | Value |
| --- | --- |
| API status | `ok` |
| API Docker restarts | `0` |
| API OOM killed | `false` |
| Effective Diskwala concurrency | `3` |
| Active / pending captures | `0 / 0` at snapshot |
| ADB ready | `true` |
| Response cache | enabled and persistent |
| Cache entries | approximately 298,179 |
| Cache bytes | 157,286,004 / 157,286,400 (effectively full) |
| Diskwala PID | `2503` |
| Diskwala threads | `1,005` |
| Diskwala RSS | 843,104 KiB |
| Diskwala high-water RSS | 923,496 KiB |
| TalsecKill version | `1.3` / code `4` |

The deployed FastAPI code is commit `be7507e` and includes both ADB repair
commits documented below.

### Current effective runtime settings

The values observed from the deployed container during this session were:

```dotenv
MAX_CONCURRENT=3
CAPTURE_TIMEOUT=30
CAPTURE_FIRE_RETRY_INTERVAL=30
CAPTURE_RECOVERY_RETRIES=0
CAPTURE_QUEUE_TIMEOUT=30
CAPTURE_QUEUE_MAX_PENDING=50
CAPTURE_QUEUE_RETRY_AFTER=0
ADB_CONNECT_ATTEMPTS=1
ADB_CONNECT_COOLDOWN_SECONDS=30
RECOVERY_COOLDOWN_SECONDS=60
RECOVERY_DRAIN_TIMEOUT=20
RESPONSE_CACHE_ENABLED=true
RESPONSE_CACHE_MAX_BYTES=157286400
```

`CAPTURE_FIRE_RETRY_INTERVAL == CAPTURE_TIMEOUT` intentionally means the primary
deep link is not re-fired within one attempt. Startup currently logs a warning
about this, but for the present stability experiment this is deliberate.

The uncommitted `.env.example` does **not** match production in multiple fields,
including primary timeout/refire, response cache, and Flezen tunnel/sidecar
settings. More importantly, the tracked file contains plaintext credential-like
values for APIs, OpenObserve, and decryption. It is not protected by the `.env`
ignore rule. Sanitize it and rotate affected credentials before treating it as
a committable template; changing only `CAPTURE_TIMEOUT` is insufficient.

## 3. Initial symptoms and evidence

### 3.1 What production looked like

- Host load repeatedly reached roughly 14 on a two-vCPU host.
- Both ReDroid containers consumed most available CPU; primary ReDroid often
  remained near 100% CPU.
- `dw-fast-api` generally used about 120–133 MiB before cache hydration and had
  a stable Python thread/FD count relative to request load.
- With the persistent 150 MiB response cache hydrated (about 298k entries), API
  container memory rose to roughly 424–507 MiB. This is expected cache overhead,
  not the Android thread leak.
- Android/ReDroid PID counts grew because Linux cgroups count threads as tasks.
- Docker showed zero API restarts and no OOM kill. Several host reboots in the
  incident window were clean/manual shutdowns, not kernel panic/OOM reboots.

### 3.2 Diskwala process growth

Early production measurements on one process showed:

- 784 threads and roughly 720 MiB RSS shortly after launch;
- about 1,235 threads a few minutes later;
- 1,484 threads shortly after that;
- 1,894 threads and roughly 953 MiB RSS within minutes;
- 735 distinct numbered pools and 1,351 numbered pool threads in one snapshot.

Later runs reached 2,000–2,600 threads and around 1 GiB RSS. A force-stop then
returned the next process to roughly 242 threads, proving that the retained
resources belonged to the Android app process rather than Uvicorn.

### 3.3 Android crashes

The Android exit history recorded:

- force-stop exits (`reason=10`) from configuration/recovery paths;
- a runtime crash (`reason=4`) at 2026-09-05 21:07 UTC;
- a React Native fatal stack containing:

```text
Maximum update depth exceeded. This can happen when a component repeatedly
calls setState inside componentWillUpdate or componentDidUpdate.
```

The app also repeatedly launched/crashed `com.android.vending` with a
configuration-related `NullPointerException`. That crash loop is a secondary CPU
source and remains unresolved.

### 3.4 Root process inspection

ReDroid is KernelSU rooted with LSPosed and Zygisk Next. `adb shell` itself did
not receive KernelSU root (`su 0 id` failed), but `docker exec` into the ReDroid
container runs as UID 0 and can inspect `/data`, `/proc`, LSPosed, APKs, and ANR
traces.

There were not multiple orphan Diskwala processes. There was one live package
PID with a very large thread set. A companion “cleaner” APK cannot safely kill
individual ART/JNI threads inside another process. A cgroup `pids.max`,
`RLIMIT_NPROC`, or hard CPU quota would deny thread creation or increase latency;
it would not reclaim existing workers and would likely trigger more app crashes
and retries.

## 4. Incident timeline (UTC)

| Approximate time | Event |
| --- | --- |
| Before Sep 5 changes | Legacy recovery force-stopped Diskwala for most 502/503/504 failures and `/adb/connect`; cache was commonly enabled. |
| 17:31–17:39 | Host watchdog reported the configured ADB serial as missing and performed targeted ADB/adbd recovery. Its script was edited around 17:38 UTC to use the effective loopback serial. |
| 17:52, 18:44, 19:17, 19:56 | Clean/manual VPS reboot events observed in journal history. |
| 20:23 | API deployment started Diskwala, then host watchdog called `/adb/connect`, causing the old duplicate second force-stop. |
| 20:26–20:32 | Diskwala thread/RSS growth and adapter thread proliferation confirmed. |
| 21:06 | API commits `59c6b38` and `be7507e` deployed. Host `/adb/connect` became non-destructive and was rate-limited. |
| 21:07 | Diskwala React Native maximum-update-depth crash recorded. |
| 21:23 | Capture recovery force-stopped Diskwala; this was not host `/adb/connect`. |
| 21:42 | Production moved to concurrency 3, timeout 30, cache enabled, no primary recovery retries. |
| 21:47–21:55 | Cache-aware concurrency-3 and 5-RPS tests executed. |
| 22:09 | A later force-stop recycled a roughly 2,500-thread / 1-GiB app process to a fresh process. |
| 22:39–22:42 | TalsecKill v1.1 AppLovin guard activated and was A/B tested. |
| 22:57–23:02 | TalsecKill v1.2 owner-level BidMachine hook tested; no configured-pool callback was observed. |
| 23:08 onward | TalsecKill v1.3 constructor-owner telemetry deployed and tested. |

## 5. FastAPI/host watchdog fixes

Two source fixes were committed and deployed:

### `59c6b38` — Make watchdog ADB reconnect non-destructive

- `/adb/connect` now restores ADB transport, reverse mapping, and proxy state
  without closing capture admission or force-stopping Diskwala.
- Startup retains an intentional app setup; genuine capture recovery remains the
  only destructive configuration path.
- In SSH tunnel mode, ADB always targets `127.0.0.1:<configured-port>` rather than
  accidentally bypassing the tunnel through a stale hostname.
- Health exposes configured and effective ADB serials separately.

### `be7507e` — Rate-limit watchdog ADB reconnects

- `/adb/connect` is single-flight.
- Default reconnect cooldown is 30 seconds.
- Calls inside the cooldown normally return cached readiness without repeating a
  full reconnect.
- A bounded `adb reverse --list` may bypass the cooldown once only when it
  positively confirms that an ADB server reset erased the required reverse
  mapping.
- An inconclusive/slow probe does not escalate into more ADB work.
- A failed confirmed-reset bypass is consumed for that cooldown window and
  cannot loop.

Post-deployment evidence confirmed that the host watchdog call was rate-limited
and did not create a new `reason=10` app exit. ADB transport, reverse mapping, and
proxy were healthy.

### External host watchdog

The host script is `/usr/local/sbin/redroid-api-network`, run by
`redroid-api-network.service`. The inspected behavior was:

- health interval: 30 seconds;
- failures before recovery: 2;
- recovery cooldown: 300 seconds;
- API connect timeout: 45 seconds;
- optional targeted `adbd` restart: once per recovery;
- systemd service restart: always, with a 5-second delay.

The service calls `/adb/connect` after an API container replacement or ADB
server repair. This is why making that endpoint non-destructive was essential.

## 6. What changed relative to the legacy code

Legacy baseline used for comparison: `d487f1f`. Current API: `be7507e`.

### 6.1 Destructive recovery stopped masking the app leak

Legacy `services/media.py` treated configured 502/503/504 responses as device
recovery events. Recovery ran full ADB configuration and `ensure_home()`, which
called `am force-stop com.diskwalaapp` before relaunching it.

The September 5 sequence introduced explicit fault domains and then correctly
removed destructive behavior for producer/no-flow timeouts:

- `b6616a2`: introduced/refined fault-domain behavior;
- `71ea876`: stopped treating slow `am start` and no captured flow as a device
  fault;
- `48b2c54`: bounded recovery drain and added cooldown;
- `c3b0393`: removed the Diskwala watchdog;
- `59c6b38`: removed app resets from host `/adb/connect`.

Current code resets only on explicit transport/not-ready failures. This is safer
per request but means a degraded/leaking Android process can survive for much
longer. The legacy implementation therefore appeared more stable partly because
it recycled the process aggressively, not because it used fewer resources.

### 6.2 Configuration changed substantially

The Python defaults remained largely unchanged, but deployment/template values
changed:

| Setting | Legacy template | September 5 template/incident |
| --- | ---: | ---: |
| `CAPTURE_TIMEOUT` | 90 | 10 |
| `CAPTURE_QUEUE_TIMEOUT` | 0 (unbounded wait) | 30 |
| `CAPTURE_QUEUE_MAX_PENDING` | 120 | 100 |
| `CAPTURE_RECOVERY_RETRIES` | 2 | 2 initially |
| Response cache | enabled | disabled for a significant period |

The 10-second timeout plus a 6-second in-attempt re-fire and two outer retries
could deliver as many as roughly six VIEW intents for one slow request. The
100-entry queue then retained stale work after clients had timed out.

### 6.3 Other behavior differences

- Legacy ADB configuration tried an active serial, primary serial, and fallback
  serial. Commit `99b32dc` moved to one configured/effective endpoint. This made
  host/API serial agreement more important.
- Diskwala concurrency itself was not newly introduced; the single Android UI
  was already driven concurrently. What changed was timeout/retry/reset/cache
  interaction.
- Shielded shared tasks can continue after the last client disconnects. That
  behavior also existed previously, but became more expensive with short client
  timeouts and queued unique requests.

## 7. Traffic analysis from OpenObserve

Admin load-test traffic was excluded using the admin key from the local
environment; the key value was never written to output.

### 7.1 Two-day production traffic

48-hour natural `/video` requests: **300,284**  
Average: **1.7378 RPS**

| Fixed bucket | Median RPS | p95 RPS | Maximum RPS |
| --- | ---: | ---: | ---: |
| 1 second | 1.0 | 5.0 | 28.0 |
| 10 seconds | 1.6 | 3.6 | 9.6 |
| 1 minute | 1.7 | 3.4 | 8.25 |
| 5 minutes | 1.72 | 3.38 | 6.14 |
| 15 minutes | 1.70 | 3.36 | 4.53 |

48-hour status totals:

| Status | Requests | Approx. share |
| --- | ---: | ---: |
| 200 | 253,480 | 84.4% |
| 429 | 41,212 | 13.7% |
| 504 | 2,710 | 0.9% |
| 502 | 1,927 | 0.6% |
| 422 | 753 | 0.25% |
| 503 | 202 | 0.07% |

### 7.2 Recent versus preceding 24 hours

- recent 24-hour average: **1.8733 RPS** (161,849 requests);
- preceding 24-hour average: **1.6023 RPS** (138,435 requests);
- increase: approximately **17%**.

The recent period also contained roughly 79,923 records without cache status,
consistent with the cache-disabled interval. Estimated app-facing work grew by
roughly one third, larger than the increase in external RPS.

### 7.3 Current low-load window

In a 15-minute natural-traffic sample after concurrency 3/cache enablement:

- average: 1.1756 RPS;
- one-minute median: 1.1583 RPS;
- one-minute p95: 1.4042 RPS;
- 1,041 / 1,059 responses were HTTP 200;
- 11 were HTTP 429;
- cache hit ratio among labeled requests was about 23.4%.

This configuration can handle the current ~1.2 RPS period, but not the historic
1.7 RPS median or 3.4 RPS minute p95 indefinitely on one device. Queueing can
hide the deficit for a short burst but cannot create device capacity.

## 8. OpenObserve export and load-test tooling

### 8.1 Failure exporter

Modified script: `scripts/query_openobserve_failures.py`

New capabilities:

- concurrent time-shard export;
- pagination inside each shard;
- retries/backoff for OpenObserve 429/5xx/network failures;
- atomic JSON output;
- raw request-body export with duplicate preservation;
- cache summary by API-key environment variable;
- fixed-bucket traffic median/p90/p95/p99/max analysis;
- optional exclusion of admin load tests.

Two-day export command:

```powershell
python scripts/query_openobserve_failures.py `
  --status 429 --path /video --hours 48 `
  --export-request-bodies data/openobserve_video_429_last_2_days.json `
  --page-size 1000 --workers 8 --shard-minutes 60
```

Export result:

- raw 429 rows: 42,877;
- valid Diskwala request bodies: 42,840;
- invalid bodies excluded: 37;
- duplicates preserved;
- unique URLs available to the load script: approximately 20,246.

### 8.2 Load-test script

New script: `scripts/load_test_video.py`

Safety properties:

- reads `API_KEY_ADMIN` from `.env`; does not print or store its value;
- requires `--allow-production` for remote hosts;
- refuses to send the admin key to remote plaintext HTTP endpoints;
- refuses `--insecure` TLS mode for remote endpoints;
- defaults to unique URLs;
- aborts if health is degraded unless explicitly overridden;
- detects enabled response cache unless explicitly acknowledged;
- atomically reserves selected URLs before sending;
- imports previous reports into the used-URL ledger;
- records JSON result and health snapshots;
- supports request count, client concurrency, launch RPS, and client timeout.

Persistent no-reuse ledger:

```text
data/load-used-urls.json
```

At the end of this session it contained **310 reserved URLs**.

### 8.3 Endpoint caveat

The supplied hostname works over HTTP:

```text
http://dsm89t26p1mhjww7bkvldkwq.141.148.151.172.sslip.io/video
```

HTTPS returned `503 no available server` with a self-signed/default certificate.
Traefik labels exposed only the HTTP entrypoint. Historical tests in this session
therefore used HTTP; this was unsafe for a reusable admin credential. Rotate the
admin key and do not repeat that path. Future tests must use trusted HTTPS, a
localhost SSH tunnel, or a disposable least-privilege test credential.

## 9. Load-test history

All tests used admin authentication and JSON bodies from the OpenObserve export.
Unless stated otherwise, selected URLs were unique within the test. Once the
ledger was introduced, URLs from all previous reports were excluded.

### 9.1 Initial stages (concurrency 6 / cache disabled period)

| Stage | Client profile | Result | Wall time | p95 |
| --- | --- | --- | ---: | ---: |
| Small | 6 requests, concurrency 2, 0.5 RPS | 6 × 200 | 44.09s | 16.35s |
| Medium | 18 requests, concurrency 6, 1 RPS | 18 × 200 | 27.24s | 12.26s |
| Heavy | 60 requests, concurrency 12, 2 RPS | 27 × 200, 33 × 429 | 96.42s | 20.37s |

The Android process was already above 2,000 threads during these runs. After the
heavy stage it reached about 2,657 threads and ~1 GiB RSS while ReDroid remained
near 100% CPU.

### 9.2 Concurrency 3 with cache enabled

Report: `data/load-large-concurrency3-cache.json`

- 60 newly selected URLs;
- all 60 returned HTTP 200;
- 15 were pre-existing cache hits;
- 45 were real deep-link captures;
- wall time: 73.67 seconds;
- overall p95: 22.97 seconds;
- real miss average: 13.81 seconds;
- Diskwala threads increased from 609 to 1,271 during/around the run;
- RSS increased from about 769 to 799 MiB and the high-water mark rose further.

This removed the immediate 429 storm but did not remove per-capture Android
resource growth.

### 9.3 Five-RPS saturation burst

Report: `data/load-burst-5rps-timeout30.json`

Profile:

- 100 unique requests;
- 5 launch requests/second;
- client concurrency 100;
- client timeout 30 seconds;
- server concurrency 3 and queue capacity 50.

Client view:

- 55 × HTTP 200;
- 26 × HTTP 429;
- 19 client timeouts;
- p95: 30.78 seconds.

Server/OpenObserve view after all work completed:

- 21 cache-hit 200s;
- 46 cache-miss 200s;
- 33 cache-miss 429s.

The discrepancy is important: when the client test ended, the server still had
3 active and 24 pending requests. Those “ghost” operations continued after 19
clients disconnected and took roughly another 54 seconds to drain. This is why
the server retry budget must not exceed the client deadline for unique work.

Android impact during that burst:

- threads: 1,588 to 1,861;
- RSS: roughly 842 to 923 MiB;
- no process/API restart during the test;
- ReDroid remained near one saturated CPU.

Five RPS is conclusively above one-device capacity. Two RPS can be absorbed as a
short queued burst, but observed sustainable throughput is closer to the current
1–1.2 RPS low-load window and deteriorates as Android resources accumulate.

### 9.4 Failed and diagnostic-only attempts

These attempts are recorded so they are not repeated or mistaken for production
load:

- The first small load invocation used HTTPS. It produced six local TLS
  certificate errors and did **not** reach FastAPI. A direct check then showed
  HTTPS returning `503 no available server`; all real load tests used HTTP.
- A three-minute “recent 429” export after enabling cache returned zero rows. It
  was retained only as `data/openobserve_video_429_recent_cache_misses.json` and
  was not useful as a test corpus.
- The on-device `sqlite3` binary aborted when reading the LSPosed database. No DB
  mutation occurred from that command. Subsequent work used a frozen `lspd`, a
  complete host copy, Python `sqlite3`, WAL checkpoint, integrity check, and
  read-back verification.
- One v1.2 LSPosed repair attempt referenced `/tmp/patch_lspd.py` after a reboot
  had cleared `/tmp`. The script was not run, the error path resumed `lspd`, the
  patcher was uploaded again, and the complete repair was rerun successfully.
- A fresh local JADX decompilation was started but aborted after confirming the
  complete extracted sources already existed under `rev-eng/apk-extractor`.
- v1.2's direct `GAMTaskLoader` constructor hook installed but observed no pool
  instances. v1.3's generic scheduled-executor owner telemetry then saw only the
  LSPosed trampoline (`LSPHooker_#constructor`), so neither attempt proved the
  runtime owner or applied a BidMachine timeout.

## 10. Android/APK reverse-engineering findings

Existing reverse-engineering assets were reused rather than recreated:

- Java sources: `..\rev-eng\apk-extractor\jadx-java-src\sources`;
- Hermes output: `..\rev-eng\apk-extractor\hermes-dec-output\decompiled_bundle.js`;
- existing LSPosed source: `..\rev-eng\mod_build`;
- existing deployment modules: `..\rev-eng\modules`.

All README files under `rev-eng` were reviewed before modifying the module.

### 10.1 AppLovin behavior

The decompiled Hermes bundle shows:

- `initAppLovinSDK` initializes MAX for non-premium users;
- the global `AdProvider` registers full-screen listeners and immediately loads
  two interstitial and two rewarded units;
- hidden and failed-to-display callbacks reload those ad units without visible
  JS backoff;
- download/video/player paths contain additional load/reload calls;
- banner and MREC components set `autoRefresh: true`;
- an independent ad-block detector checks Google/AppLovin endpoint reachability
  and treats three or more failures as blocking.

This ruled out firewalling or DNS-blocking ad hosts. The limiter had to stay at
the local MAX bridge and leave endpoint reachability/networking real.

Relevant bridge methods from `NativeAppLovinMAXModuleSpec`:

```java
loadInterstitial(String adUnitId)
loadRewardedAd(String adUnitId)
```

Relevant view method:

```java
AppLovinMAXAdView.setAutoRefreshEnabled(boolean)
```

### 10.2 ART thread dump

Diagnostic trace captured at:

```text
C:\Users\Rishi\AppData\Local\Temp\kilo\diskwala-trace-2244.txt
```

Snapshot summary:

- total threads: 676;
- anonymous `pool-*`: 459 (67.9%);
- 410 parked indefinitely in scheduled delayed-work queues;
- 36 parked in linked blocking queues;
- 9 timed scheduled-queue waits;
- 4 priority-queue waits;
- zero anonymous workers were runnable/actively executing.

The trace proves retained idle workers but idle worker stacks contain only JDK
executor frames, so they do not expose the object owner directly.

### 10.3 BidMachine hypothesis

The strongest source match was:

```text
io.bidmachine.ads.networks.gam.GAMLoader$GAMTaskLoader
```

Its JADX source creates a per-loader scheduled executor with 2–4 core workers,
uses it only for immediate `submit()`, and never shuts it down. This matches the
dominant pool size/signature. However, the current production runtime has not
confirmed that those exact constructors own the growing pools.

## 11. TalsecKill module iterations

### 11.1 Existing module baseline (v1.0)

The module already targeted Talsec/freeRASP reaction paths and process self-kill
behavior. It did not previously hook AppLovin, mediation adapters, generic
executors, or threads.

The deployed source is not only a resource guard. Pre-existing enabled behavior
also includes blanket AppiCrypt `NOK -> OK` mutation, RASP threat/execution
channel desynchronization, self-SIGKILL/reaction guards, multiple integrity and
identifier diagnostic hooks, and RevenueCat cached-customer-info resolution.
Those paths were not introduced as part of the AppLovin experiment, but they
share the same APK and therefore share rollback risk. A future maintainer must
review every enabled toggle near the top of `Hook.java`; rolling back the
resource guard also rolls back those integrity/runtime behaviors.

Original APK SHA-256:

```text
730472b0539a7097c25524d6127436ed0c025f6ee278354366315f574b7e2022
```

### 11.2 v1.1 — AppLovin bridge limiter

Artifact SHA-256:

```text
2dec98ed3f4516f62b20786a9f9c38474fc7d08eda0b7d5654079d9d3ce6f8e3
```

Changes:

- permit one `loadInterstitial` per format/ad unit every 10 monotonic minutes;
- permit one `loadRewardedAd` per format/ad unit every 10 monotonic minutes;
- suppress duplicate void bridge calls without fake success/failure events;
- rewrite `AppLovinMAXAdView.setAutoRefreshEnabled(true)` to `false`;
- preserve initial loads, initialization, readiness, events, networking, and
  ad-block endpoint checks;
- sample suppression logs and hash ad-unit IDs before logging;
- fix manifest target substitution and module metadata/version;
- synchronize pre-existing `firedThreats` access;
- correct LSPosed scope helper defaults and DB checkpoint validation.

Runtime logs proved all three AppLovin hooks loaded. They also proved one
rewarded reload was suppressed and banner/MREC auto-refresh was disabled.

Controlled test (`data/load-applovin-guard-30.json`):

- 30 / 30 HTTP 200;
- 18 real misses, 12 hits;
- miss average: 1.40 seconds;
- overall p95: 2.48 seconds;
- immediate total threads: 547 to 549;
- anonymous pool workers: 116 to 261;
- after another 90 seconds of natural traffic: 685 total threads and 440 pool
  workers.

Interpretation: functional and promising latency/thread containment, but the
anonymous pool count still grew.

### 11.3 v1.2 — owner-level BidMachine hook

Artifact SHA-256:

```text
35ffa32e1012584443e05c794ae041ef0c4f4ba8fb7e191763154f2709dfac56
```

The module hooked constructors of `GAMLoader$GAMTaskLoader`, read its private
`executorService`, and intended to apply:

```java
setKeepAliveTime(30, TimeUnit.SECONDS)
allowCoreThreadTimeOut(true)
setRemoveOnCancelPolicy(true)
```

This does not shut down executors, cancel work, alter queue/rejection policy, or
change core/max size. It is safe for the inspected GAM class because the class
uses immediate submission and no delayed/periodic scheduling.

However, runtime emitted only “guard installed”; it emitted no “configured pool”
messages. Therefore the target constructor did not run through the observed
hook path during the A/B.

Controlled test (`data/load-bidmachine-guard-v12-30.json`):

- 29 × 200 and one upstream-style 502;
- 22 real miss 200s, 7 hits, one miss 502;
- miss average: 1.03 seconds;
- p95: 1.93 seconds;
- immediate total threads: 466 to 545;
- pool workers: 135 to 243;
- after another 75 seconds: 583 total threads and 332 pool workers.

### 11.4 v1.3 — scheduled-executor constructor attribution

Current artifact SHA-256:

```text
4f7d7420890112928639518dd7016ddbfbe8f89b45b9424e73e8df1ff1664c18
```

Version: `1.3`, code `4`.

v1.3 retained v1.1/v1.2 behavior and added a target-process hook on
`ScheduledThreadPoolExecutor` constructors. It captures the construction stack,
records owner counts, and applies the 30-second idle timeout only if the exact
verified BidMachine GAM owner is present. Unknown pools are telemetry-only.

Observed owner log:

```text
[TalsecKill] scheduled executor owner=LSPHooker_#constructor count=1
```

LSPosed's constructor trampoline hid the original owner. No
`BidMachine GAM idle-core timeout configured` message appeared. Therefore:

- v1.3 is not currently changing anonymous scheduled-pool timeout behavior;
- the active optimization remains the AppLovin reload/auto-refresh guard;
- generic constructor telemetry adds some pool-construction overhead and should
  be removed or improved after the diagnostic period.

Controlled test (`data/load-executor-probe-v13-30.json`):

- 30 / 30 HTTP 200;
- 23 true misses and 7 hits;
- miss average: 1.12 seconds;
- overall p95: 1.93 seconds;
- immediate total threads: 544;
- pool workers: 232;
- 60 seconds later: 556 total threads and 327 pool workers.

At 23:18 UTC, natural production traffic had raised the same process to 1,005
threads and 843 MiB RSS. This confirms that v1.3 has not eliminated long-term
growth.

## 12. Why no “thread cleaner APK” was built

Killing individual threads in another Android process is not a supported or safe
operation even with root:

- Java/native threads share heap, locks, Binder/JNI state, and runtime metadata;
- signaling an arbitrary thread can deadlock or corrupt the whole process;
- cgroup PID limits reject future `clone()` calls but do not reclaim workers;
- forcing the entire package restarts all ad SDKs and can destroy active capture
  work.

The correct containment layers are:

1. prevent unnecessary ad reload/refresh work at a narrow in-process bridge;
2. make genuinely idle, verified executor workers eligible for natural timeout;
3. reduce duplicate/refire/orphan capture work in FastAPI;
4. if still required, recycle the whole package only through FastAPI's quiescent
   admission gate and a strict cooldown/circuit breaker.

## 13. Build, artifact verification, and deployment

### 13.1 Source files changed in `rev-eng`

```text
rev-eng/mod_build/AndroidManifest.xml
rev-eng/mod_build/README.md
rev-eng/mod_build/build_module.sh
rev-eng/mod_build/fix_lspd_scope.sh
rev-eng/mod_build/patch_lspd.py
rev-eng/mod_build/scope_talseckill.sh
rev-eng/mod_build/src/com/recon/talsecbypass/Hook.java
rev-eng/modules/talseckill.apk
rev-eng/modules/talseckill.apk.idsig
```

Build from the parent `D:\PROJECT\_TRASH\REDROID` repository root (not from
`DW-fast-api`):

```powershell
Push-Location 'D:\PROJECT\_TRASH\REDROID'
& 'C:\Program Files\Git\bin\bash.exe' 'rev-eng/mod_build/build_module.sh'
Pop-Location
```

The build now defaults to `com.diskwalaapp`, substitutes that target into both
`Hook.java` and a generated manifest, compiles Java 11, runs D8, links, aligns,
and signs the APK.

Verification performed:

- Java compilation succeeded;
- APK signature verified under v1/v2/v3 schemes;
- manifest scope is `com.diskwalaapp`;
- no `com.target-appapp` placeholder remains in `classes.dex`;
- AppLovin and BidMachine hook strings are present;
- LSPosed DB integrity returned `ok` after every patch;
- installed module path and scope were re-read from a copied read-only DB.

The D8 warnings about Xposed API types not being present during desugaring were
also present in the established build style; Xposed provides those types at
runtime. They did not prevent a valid signed APK or runtime module loading.

### 13.2 Production installation process used

1. Copy APK to VPS `/tmp`.
2. `docker cp` it into primary ReDroid `/data/local/tmp`.
3. Run `pm install -r` as container root.
4. Resolve the randomized new `pm path`.
5. Stop (`SIGSTOP`) `lspd` briefly.
6. Copy the complete LSPosed config directory to the VPS host.
7. Run `patch_lspd.py` against the copied DB.
8. Commit/checkpoint WAL and run `PRAGMA integrity_check`.
9. Copy the patched main DB back, remove stale device-side WAL/SHM, restore
   root ownership/mode.
10. Copy the DB out again and verify module path/scope read-only.
11. Reboot the full VPS so LSPosed/Zygote loads the new module into a fresh app
    process.

The `SIGSTOP lspd` section must have failure cleanup. Any failed copy, Python
patch, checkpoint, integrity check, copy-back, or verification must run
`kill -CONT <lspd-pid>` before retrying or aborting. Leave `lspd` stopped only
after every verification succeeds and when the full reboot is the immediate
next command. This cleanup path was exercised successfully when a temporary
patch script was missing.

On-device `/system/bin/sqlite3` is ABI-broken and aborts. Always use the
host-side Python patch workflow unless that binary is independently fixed.

## 14. Backups and rollback

### 14.1 VPS backup location

```text
/home/ubuntu/dw-resource-guard-backup-20260905T2233Z/
```

Contents:

```text
talseckill-v1.0.apk
talseckill-v1.1.apk
talseckill-v1.2.apk
lspd-config/
lspd-config-v1.1/
lspd-config-v1.2/
lspd-config-before.tar.gz
lspd-config-v1.1.tar.gz
lspd-config-v1.2.tar.gz
```

### 14.2 Local backup location

```text
C:\Users\Rishi\AppData\Local\Temp\kilo\
```

Notable files:

```text
talseckill-v1.0-backup.apk
talseckill-v1.1.apk
talseckill-v1.2.apk
lspd-config-before-20260905T2233Z.tar.gz
lspd-config-v1.1.tar.gz
lspd-config-v1.2.tar.gz
```

Verified hashes:

| Artifact | SHA-256 |
| --- | --- |
| v1.0 APK | `730472b0539a7097c25524d6127436ed0c025f6ee278354366315f574b7e2022` |
| v1.1 APK | `2dec98ed3f4516f62b20786a9f9c38474fc7d08eda0b7d5654079d9d3ce6f8e3` |
| v1.2 APK | `35ffa32e1012584443e05c794ae041ef0c4f4ba8fb7e191763154f2709dfac56` |
| v1.3 APK | `4f7d7420890112928639518dd7016ddbfbe8f89b45b9424e73e8df1ff1664c18` |
| Original LSPosed config archive | `9cfd281b7a7cc3f10651b6a8f8d318c9d1ad4c5405c847a11a19834370ce76dd` |
| v1.1 LSPosed config archive | `54df116369c385cc330d3a5b2f623c367a105893543365a1843dc22e1e29f4d5` |
| v1.2 LSPosed config archive | `0e10744ce3a02b9dbf7ac792ecacba09628a3d4d8db238cb506e094b373eefde` |

### 14.3 Rollback rules

For normal module rollback, prefer reinstalling a chosen backup APK and patching
the current LSPosed DB to the newly randomized package path. Do not blindly
restore an old DB whose `apk_path` points to an obsolete `/data/app/~~...` path.

High-level rollback:

1. choose v1.2, v1.1, or original v1.0 APK;
2. copy into ReDroid `/data/local/tmp`;
3. run `pm install -r -d <apk>` (the `-d` permits version-code downgrade);
4. resolve `pm path com.recon.talsecbypass`;
5. use the same frozen-`lspd` host-copy/`patch_lspd.py` workflow;
6. verify DB integrity, enabled state, current APK path, and
   `com.diskwalaapp,user_id=0` scope;
7. perform a full VPS reboot;
8. verify TalsecKill load logs and both capture types.

Restore a complete LSPosed config backup only if the current database itself is
damaged. Re-patch the module APK path afterward.

## 15. Current repository state and ownership

### 15.1 `DW-fast-api` repository

Current branch is at deployed commit `be7507e`, synchronized with `origin/main`.
Uncommitted work:

```text
M  .env.example
M  scripts/query_openobserve_failures.py
?? scripts/load_test_video.py
?? TALSEC_v1.3.md
```

The `data/` directory is ignored and contains private local test/export artifacts.
The tracked `.env.example` contains credential material even in repository
history. Do not stage or publish it until values are replaced with inert
placeholders and affected credentials are rotated.

### 15.2 Parent `REDROID` / `rev-eng` repository

Uncommitted module work is listed in Section 13. There is also a pre-existing,
unrelated user modification:

```text
M scripts/wsl-dev.sh
```

That file was not modified during this work and must not be staged with the
module changes accidentally.

No module or documentation changes from this session have been committed.

## 16. Remaining FastAPI findings

These were found during the initial audit but were not addressed by the focused
ADB/module work:

1. OpenObserve delivery creates one background task and one `aiohttp` session per
   request with no bounded queue; an observability outage can grow tasks/sockets.
2. Observability buffers the entire request body before applying its 50 KiB
   telemetry limit.
3. Diskwala signal files have no global age/count/byte retention and can fill
   temporary storage over time.
4. Successful SSH tunnel processes retain an unread stderr pipe.
5. Subscription-store startup failure can leak its dedicated executor.
6. Shutdown can exceed orchestrator grace and leave detached SSH/mitmdump
   children if SIGKILL arrives first.
7. Subscription check/consume is not one atomic reservation and can over-admit
   concurrent quota traffic.
8. Public live ADB readiness probes can queue default-executor work under ADB
   contention.
9. Large signal-file parsing/decryption performs synchronous filesystem/JSON
   work on the event loop.

These are real hardening items but are not the cause of the thousands of Android
threads observed here.

## 17. Recommended next work

### P0 — observe current v1.3 without more heavy bursts

Collect a sample every 5 minutes for at least 30–60 minutes:

- Diskwala PID;
- `Threads`, `VmRSS`, `VmHWM`;
- numbered `pool-*` worker count and distinct pool IDs;
- ReDroid cgroup PIDs/memory/CPU;
- capture active/pending counts;
- AppLovin suppression counters;
- app crash/force-stop history.

Success is a stable PID with a thread/RSS plateau. At the current snapshot of
1,005 threads, v1.3 has not yet met that bar.

### P0 — improve executor owner attribution outside production

The generic constructor hook currently sees `LSPHooker_#constructor`, not the
original caller. Safer next experiments:

1. hook the `Executors.newScheduledThreadPool(...)` factory and inspect its
   caller before returning;
2. hook the outer `GAMLoader` constructor and reach
   `gamTaskLoader.executorService` after all field initialization;
3. log a bounded full constructor stack once in staging;
4. apply idle-core timeout only after runtime attribution is proven.

Do not enable core timeout globally for every scheduled executor. The APK
contains other delayed/periodic schedulers where broad mutation is unsafe.

### P0 — split request retry policy by fault class

Current `CAPTURE_RECOVERY_RETRIES=0` avoids ghost work but also disables useful
transport recovery inside a request. Introduce separate budgets:

- explicit ADB transport/not-ready fault: one coordinated retry;
- producer/no-correlated-flow timeout: zero extra full attempts while saturated;
- upstream/decryption fault: fail fast.

Also cap deep-link refires explicitly instead of relying only on the interval.

### P1 — stop orphan unique work after client disconnect

Shared tasks are shielded. Track waiter count by capture key and cancel only at a
safe checkpoint when the last waiter disconnects. Let an already-running ADB
subprocess finish, but do not start another refire/retry with zero waiters.

### P1 — controlled app recycle as a circuit breaker

If the app still grows after request-path fixes, implement recycle in
`dw-fast-api`, not in a cleaner APK:

- sample PID, thread count, and RSS at most every 30 seconds;
- failed/slow samples are telemetry only and never trigger restart;
- require two same-PID samples 30 seconds apart above soft limits;
- proposed soft limits: 1,200 threads or 900 MiB RSS;
- proposed emergency eligibility: 1,600 threads or 1 GiB RSS;
- close admission and drain to zero using the existing quiescent gate;
- recheck same PID/resource pressure before force-stop;
- call only targeted Diskwala `ensure_home()`—never restart ReDroid/adbd/API;
- 30-minute recycle cooldown;
- maximum two automatic recycles per six hours;
- open a six-hour circuit after failed post-recycle verification;
- expose cached recycler state through `/health` with no live health probe.

This recreates the useful containment effect of legacy resets without allowing a
failure-driven restart storm.

### P1 — cache and queue

- Keep response cache enabled; it currently avoids about 23–25% of app captures.
- The cache is full and evicts on nearly every write. Increasing it may improve
  hit ratio but also raises API startup/RSS because all entries are hydrated.
- For a fixed 30-second client timeout, prefer queue timeout around 10 seconds
  and pending depth around 10–20 rather than 50–100.
- Keep fixed `Retry-After` disabled unless clients implement randomized
  exponential backoff.

### P2 — Play Store crash loop

Investigate the repeated `com.android.vending` configuration NPE. Do not simply
disable Play Store in production until billing, integrity, and Diskwala startup
are validated in a clone/staging ReDroid.

## 18. Monitoring and diagnostic commands

The commands below intentionally read credentials from existing files/environment
and do not print secret values.

### API health

```powershell
$remote = @'
name=$(docker ps --filter "name=dw-fast-api" --format "{{.Names}}" | head -n1)
docker exec "$name" python -c 'import json,urllib.request; print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:8001/health")),indent=2))'
'@
& ssh -i '<private-key-path>' ubuntu@141.148.151.172 $remote
```

### Diskwala threads/RSS

```sh
api=$(docker ps --filter 'name=dw-fast-api' --format '{{.Names}}' | head -n1)
pid=$(docker exec "$api" adb -s 127.0.0.1:5555 shell pidof com.diskwalaapp)
docker exec "$api" adb -s 127.0.0.1:5555 shell cat "/proc/$pid/status"
```

Inspect `Threads`, `VmRSS`, and `VmHWM`.

### App exit history

```sh
docker exec "$api" adb -s 127.0.0.1:5555 \
  shell dumpsys activity exit-info com.diskwalaapp
```

### Module logs

```sh
red=$(docker ps --filter 'name=redroid14' --format '{{.Names}}' | head -n1)
docker exec "$red" logcat -d -v brief | \
  awk '/TalsecKill.*(AppLovin|BidMachine|scheduled executor)/{print}'
```

### Traffic analysis

```powershell
python scripts/query_openobserve_failures.py `
  --path /video --hours 48 --traffic-summary `
  --exclude-api-key-env API_KEY_ADMIN `
  --page-size 5000 --workers 8 --shard-minutes 15 `
  --traffic-output data/openobserve_traffic_48h.json
```

### Controlled unique-URL load test

Never send the reusable admin key to the public HTTP route. In terminal A,
resolve the current API container address and open an encrypted SSH forward:

```powershell
$key = '<private-key-path>'
$apiIp = (& ssh -i $key ubuntu@141.148.151.172 `
  'name=$(docker ps --filter "name=dw-fast-api" --format "{{.Names}}" | head -n1); docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "$name"').Trim()
& ssh -N -i $key -L "18001:${apiIp}:8001" ubuntu@141.148.151.172
```

Then run the test through localhost in terminal B:

```powershell
python scripts/load_test_video.py `
  --input data/openobserve_video_429_last_2_days.json `
  --endpoint http://127.0.0.1:18001/video `
  --profile medium --requests 30 --concurrency 6 --rate 1 `
  --request-timeout 120 --allow-cache `
  --used-urls-file data/load-used-urls.json `
  --report data/load-next-controlled.json
```

Do not run another 5-RPS production burst until the current process-growth slope
is understood.

## 19. Artifact/report index

Local ignored data currently includes:

```text
data/openobserve_video_429_last_2_days.json
data/openobserve_traffic_15m.json
data/openobserve_traffic_24h.json
data/openobserve_traffic_48h.json
data/load-small.json
data/load-medium.json
data/load-large.json
data/load-large-concurrency3-cache.json
data/load-burst-5rps-timeout30.json
data/load-applovin-guard-30.json
data/load-bidmachine-guard-v12-30.json
data/load-executor-probe-v13-30.json
data/load-used-urls.json
```

Temporary reverse-engineering artifacts on this workstation:

```text
C:\Users\Rishi\AppData\Local\Temp\kilo\diskwala-base.apk
C:\Users\Rishi\AppData\Local\Temp\kilo\index.android.bundle
C:\Users\Rishi\AppData\Local\Temp\kilo\index.android.decompiled.js
C:\Users\Rishi\AppData\Local\Temp\kilo\diskwala-trace-2244.txt
```

## 20. Handoff checklist

Before continuing:

1. Read this document and `..\rev-eng\mod_build\README.md`.
2. Confirm production still runs TalsecKill v1.3/code4 and record its artifact
   hash.
3. Verify API health, ADB reverse/proxy, current Diskwala PID, threads, and RSS.
4. Confirm all rollback APK/config backups exist locally and on the VPS.
5. Preserve the unrelated `scripts/wsl-dev.sh` modification.
6. Rotate `API_KEY_ADMIN` because it crossed public HTTP during this session.
7. Sanitize `.env.example`, audit its Git history exposure, and rotate every
   credential-like value it contained.
8. Do not stage ignored `data/` reports or secrets.
9. Do not assume the BidMachine timeout is active without a
   `BidMachine GAM idle-core timeout configured` log.
10. Do not use PID/thread caps or kill individual threads.
11. Prefer request-path amplification fixes and evidence-driven executor hooks.
12. Treat controlled package recycling as a bounded fallback, not throughput.

The central unresolved question is now narrow: **which runtime constructors own
the anonymous scheduled pools that continue to grow, and can those exact idle
workers be given a safe keep-alive without touching delayed/periodic executors?**

## 21. v1.4 — scheduled-pool containment and production result

**Status:** deployed at approximately 2026-09-06 06:08 UTC. Artifact
`..\rev-eng\modules\talseckill.apk`, versionName `1.4`,
versionCode `5`, SHA-256 `81d2baba23051efbf29eb4b881416f2f02afa33c265ac019ac63527405651d98`.
The originally supplied v1.4 artifact (`186c8cf9…`) is preserved locally, but a
pre-deployment review found source/artifact divergence plus a periodic-backoff
race and unbounded AppLovin maps. The current artifact was rebuilt after holding
trim/backoff mutations under one lock, bounding AppLovin unit state to 64, and
verifying identical `classes.dex` and manifest payload hashes across builds.

### 21.1 Owner attribution — implemented, runtime coverage incomplete

The v1.3 probe stopped at `LSPHooker_#constructor` because it did not skip the
LSPosed trampoline frame. Decompiled ground truth (`rev-eng/apk-extractor`)
identifies the real owners:

- `io.bidmachine.ads.networks.gam.GAMLoader$GAMTaskLoader` — field
  `executorService = Executors.newScheduledThreadPool(CORE_POOL_SIZE)`,
  `.submit(...)` (immediate), never shut down.
- `io.bidmachine.ads.networks.gam_dynamic.TaskExecutorImpl` — same field pattern,
  `.schedule(runnable, delayMs)` (one-shot), never shut down. **This is the one
  the app actually exercises** (why v1.3's `gam.GAMTaskLoader` field-hook never
  fired — it hooked the wrong package).

`CORE_POOL_SIZE = max(2, min(CPU-1, 4))` = **2** on the 2-vCPU host, so each
pool parks 2 core workers forever in `DelayedWorkQueue.take()`. ~229 pools ≈ the
459 pool threads the ART dump saw.

Production monitoring after deployment did not observe either GAM owner. It
observed and trimmed `io.bidmachine.utils.task.BackgroundTaskManager` instead.
Therefore the static GAM attribution remains a source-backed hypothesis for a
different ad path, not proof that those classes own the dominant current pools.

Verified across all 44k decompiled classes: **`io.bidmachine` does zero periodic
scheduling** (`scheduleAtFixedRate`/`scheduleWithFixedDelay`) and never calls
`shutdown()` on these pools — so retiring their idle workers is unconditionally
safe.

Technique provenance: the constructor-hook + stack-attribution approach matches
the only real LSPosed prior art, which is **diagnostic-only** (xanderwang/
performance `ThreadTool.kt`, 5ec1cff/StethoX `AsyncTrace.kt`); the `LSPHooker_`
frame is LSPlant's generated stub class, skipped past by real modules (StethoX,
SimpleHook, uTag) exactly as `isInfrastructureFrame` does here. No off-the-shelf
module caps pools / forces `allowCoreThreadTimeOut` — the taming policy is
necessarily DIY, which is what v1.4 implements.

### 21.2 The fix (`Hook.java`, `hookScheduledPoolContainment`)

- **Catch-all interception:** `hookAllConstructors(ScheduledThreadPoolExecutor)`.
  Both `Executors.newScheduledThreadPool` and any direct `new
  ScheduledThreadPoolExecutor(...)` route through a constructor, so this sees
  every scheduled pool in the process (constructor-only avoids the double-count a
  separate factory hook would add).
- **Correct attribution:** walk the live construction stack, skipping JDK,
  ART/Android runtime, our own package, and **every Xposed/LSPosed frame incl.
  any class containing `LSPHooker`** — the first surviving frame is the SDK owner.
- **Targeted reclaim:** for a pool whose owner matches
  `SCHEDULED_POOL_TRIM_OWNER_PREFIXES` (default `io.bidmachine.`),
  `setKeepAliveTime(60s)` + `allowCoreThreadTimeOut(true)` +
  `setRemoveOnCancelPolicy(true)`. Idle core workers retire; the pool recreates
  one on the next submit. Task semantics unchanged.
- **Safety net for broadening:** `scheduleAtFixedRate`/`scheduleWithFixedDelay`
  are hooked; any pool that ever takes a periodic task has its core-timeout
  reverted and is never re-trimmed, so widening the allowlist to other ad SDKs
  (gms.ads, vungle, mbridge, pangle… which *do* schedule periodic work) can never
  starve a periodic task.

**Safety basis (confirmed against OpenJDK master + current AOSP/libcore + the
OpenJDK bug DB).** On JDK 9+/current AOSP, a queued delayed/periodic task is NOT
permanently orphaned when `corePoolSize ≥ 1`, guaranteed by three complementary
guards:
1. `ThreadPoolExecutor.getTask()` exits a worker only when
   `(wc > maximumPoolSize || (timed && timedOut)) && (wc > 1 || workQueue.isEmpty())`
   — the **last** worker (`wc == 1`) never exits while the queue is non-empty; it
   just re-polls every keep-alive.
2. `ensurePrestart()` (called from `delayedExecute`/`reExecutePeriodic` on every
   enqueue) adds a worker if the count is 0.
3. `processWorkerExit()` sets `min = allowCoreThreadTimeOut ? 0 : corePoolSize;
   if (min == 0 && !workQueue.isEmpty()) min = 1;` and replaces a worker that
   exited with a non-empty queue.

So `keepAlive < remaining delay/period` is **not** an orphaning condition — it
only causes extra wakeups. The one genuinely unsafe combination is
**`corePoolSize == 0` + allowCoreThreadTimeOut** (the literal-orphan JDK-7091003,
fixed JDK 8; the endless-thread/hot-spin JDK-8022642 / JDK-8129861, fixed JDK 9),
which is exactly what the JavaDoc "almost never a good idea… allowCoreThreadTimeOut"
warning encodes. v1.4 therefore **skips any pool with `getCorePoolSize() < 1`**
outright (it also has no core workers to reclaim); BidMachine's pools are
`corePoolSize == 2`. The periodic auto-backoff is retained as defense-in-depth
(and to make widening the owner allowlist bulletproof), though per the guards
above it is not strictly required for `corePoolSize ≥ 1`. `setKeepAliveTime` must
be > 0 before `allowCoreThreadTimeOut(true)` or it throws — 60 s satisfies that.

### 21.3 Monitoring (the "track the surge" ask)

`grep "[TalsecKill]" logcat`:
- `POOL MONITOR threads=<procThreads> scheduledPoolsSeen=N trimmed=M periodicBackedOff=K topOwners=[...]`
  — emitted (throttled 60 s, piggybacked on pool creation) with the live process
  thread count from `/proc/self/status`. Watch `threads=` plateau instead of
  climbing past ~1,600.
- `scheduled pool NEW owner=<class#method> trimTarget=<bool>` — first sighting of
  every owner, so a new significant leaker can be verified one-shot and added to
  the allowlist.
- `scheduled-pool idle-core timeout applied owner=… trimmedPools=…`
- `scheduled-pool periodic task detected -> idle-core timeout REVERTED …`

### 21.4 Relationship to the FastAPI recycle

The recycle in `dw-fast-api` (`_diskwala_recycle_loop`, §17 P1) remains the
belt-and-braces circuit breaker: even if the module fails to load, mis-attributes,
or a new un-allowlisted SDK leaks, the recycle still bounds the device. v1.4 is
an attempted source containment; current owner coverage is incomplete. The
recycle is presently the mechanism actually bounding the process.

### 21.5 Deployment and verification

The reviewed artifact was installed using §13.2: v1.3 backup, `pm install -r`,
randomized-path resolution, frozen-`lspd` host-side DB patch, WAL checkpoint,
integrity/read-back verification, and full VPS reboot. Production confirmed
version 1.4/code5, API health `ok`, and all constructor/periodic/AppLovin hook
installation logs.

**Inlining caveat (troubleshooting).** LSPlant hooks can silently register but
never fire if ART inlined the callee into an already-compiled caller — the fix is
to deoptimize the *caller*, not the callee (LSPosed #1123, #2370;
`XposedBridge.deoptimizeMethod`). This does NOT currently affect us: v1.3 already
proved `hookAllConstructors(ScheduledThreadPoolExecutor)` fires on this Redroid
image (it logged owners), and this hooks pool *creation*, not the hot per-task
path. The tell if it ever regresses on a new image: `POOL MONITOR` shows
`scheduledPoolsSeen=0` while ads load. Remedy then: `deoptimizeMethod` on
`Executors.newScheduledThreadPool` (and/or add a hook on that factory as a second
creation choke point — note it would double-count `scheduledPoolsSeen` since the
constructor hook also fires; trimming stays idempotent via the `trimmedPools`
set). The `dw-fast-api` recycle remains the backstop meanwhile.

### 21.6 Natural-traffic monitoring result

The monitor was stopped after six valid one-minute samples. The health-print
subcommand had a quoting-only syntax error; PID/thread/RSS/pool/CPU measurements
were valid and production was unaffected.

v1.4 activated and applied a 60-second idle-core timeout to two pools owned by:

```text
io.bidmachine.utils.task.BackgroundTaskManager#<init>
```

It did not log a trim for `gam_dynamic.TaskExecutorImpl` or
`gam.GAMTaskLoader`. Other observed scheduled-pool owners included AppLovin,
IronSource, Chartboost, MBridge, GMS/Firebase, and PairIP, all telemetry-only.

Measured process/pool slopes between FastAPI recycle events:

| PID | Interval | Total threads | Pool threads | Approx. pool growth |
| --- | --- | ---: | ---: | ---: |
| 5926 | 06:12:59 → 06:15:06 | 408 → 719 | 88 → 403 | ~2.5 threads/s |
| 11398 | 06:16:09 → 06:17:11 | 361 → 532 | 66 → 246 | ~2.9 threads/s |

ReDroid CPU reached roughly 80–115%. FastAPI recycle state after approximately
seven minutes showed:

```text
intent_total=511
recycles=3
failures=0
last_reason=intent-soft(105)
```

Observed recycle events:

| Time UTC | PID before recycle | Reason/sample |
| --- | ---: | --- |
| 06:12:19 | 2749 | `intent-soft(146)`, 620 threads, 891,000 KiB RSS |
| 06:15:42 | 5926 | `intent-soft(229)`, 812 threads, 871,108 KiB RSS |
| 06:17:17 | 11398 | `intent-soft(105)`, 529 threads, 802,272 KiB RSS |

Conclusion: v1.4 is active and safely trims the pools it positively attributes,
but it does **not** stop the dominant production thread surge. The existing
100-intent FastAPI recycler is preventing the process from reaching the former
1,600–2,600-thread range by force-stopping it every roughly 1.5–3.5 minutes.
Further allowlist broadening must be evidence-based; do not globally trim every
scheduled pool.

## 22. Deep external research and revised root-cause plan

**Research completed:** 2026-09-06
**Production changes during this research phase:** none beyond the already
documented v1.4 deployment.
**Recommendation:** stop broadening the v1.4 mutation allowlist. Build a
telemetry-only v1.5 that attributes ordinary and scheduled executors before any
additional pool behavior is changed.

### 22.1 Research scope

Five independent research tracks covered:

1. official AppLovin MAX, BidMachine, Google Mobile Ads/GAM, and mediated-network
   lifecycle/release documentation;
2. OpenJDK and Android libcore executor implementations and bug history;
3. GitHub, Stack Overflow, Reddit availability, and English/Chinese community
   reports;
4. LSPosed/LSPlant, libxposed, JVMTI, Frida, Perfetto, simpleperf, and heap-owner
   attribution techniques;
5. all local JADX/Hermes sources, the 676-thread ART trace, v1.4 telemetry, and
   the latest FastAPI recycler commit.

No credible public source proves that AppLovin MAX or BidMachine by itself
creates thousands of threads. Public mediated-ad reports commonly show 100–300
threads with disputed attribution. The local evidence is stronger than public
anecdotes, but it still proves the executor type and retention pattern—not the
creator of every pool.

### 22.2 Facts established by primary sources

#### Default thread names are not attribution

`pool-N-thread-M` comes from `Executors.defaultThreadFactory()`. It is not an
AppLovin/BidMachine name. A worker parked in
`ScheduledThreadPoolExecutor$DelayedWorkQueue.take()` is idle and consumes a
thread/PID slot and stack/runtime memory, but it is not directly burning CPU.

Sources:

- [AOSP/libcore Executors source](https://android.googlesource.com/platform/libcore/+/refs/heads/main/ojluni/src/main/java/java/util/concurrent/Executors.java)
- [ScheduledThreadPoolExecutor Javadoc](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ScheduledThreadPoolExecutor.html)
- [ThreadPoolExecutor Javadoc](https://docs.oracle.com/javase/8/docs/api/java/util/concurrent/ThreadPoolExecutor.html)

This means production has two related but distinct problems:

1. retained worker/stack/PID/RSS growth from repeatedly created executors;
2. real CPU work from SDK initialization/loading, React updates, WebView/ad work,
   Play Store crashes, and frequent whole-app cold starts.

#### Scheduled-pool core timeout is not a universal fix

Android/libcore normally retains scheduled core workers. Modern implementations
protect delayed-task liveness, but official Javadoc still discourages combining
scheduled executors with core timeout. A pool can collapse to one timed-polling
worker and lose warm parallel capacity. Never apply `allowCoreThreadTimeOut` to
unknown scheduled pools globally.

Relevant implementation/bug references:

- [Android 8.1 STPE source](https://android.googlesource.com/platform/libcore/+/android-8.1.0_r1/ojluni/src/main/java/java/util/concurrent/ScheduledThreadPoolExecutor.java)
- [Android 14 STPE source](https://android.googlesource.com/platform/libcore/+/android-14.0.0_r1/ojluni/src/main/java/java/util/concurrent/ScheduledThreadPoolExecutor.java)
- [Android 14 TPE source](https://android.googlesource.com/platform/libcore/+/android-14.0.0_r1/ojluni/src/main/java/java/util/concurrent/ThreadPoolExecutor.java)
- [JDK-7091003](https://bugs.openjdk.org/browse/JDK-7091003)
- [JDK-8022642](https://bugs.openjdk.org/browse/JDK-8022642)
- [JDK-8065320](https://bugs.openjdk.org/browse/JDK-8065320)
- [JDK-8129861](https://bugs.openjdk.org/browse/JDK-8129861)
- [JDK-8352118](https://bugs.openjdk.org/browse/JDK-8352118)
- [Stack Overflow: core timeout with STPE](https://stackoverflow.com/questions/48424367/allowing-core-thread-timeout-with-scheduledthreadpoolexecutor)

`setRemoveOnCancelPolicy(true)` is valid for an attributed scheduled executor
whose cancelled delayed tasks are retained, but it removes cancelled queue
entries—it does not retire workers. `purge()` is a bounded compatibility tool,
not continuous housekeeping.

#### SDK lifecycle requirements are explicit

AppLovin documents that banner/MREC/native resources must be stopped/destroyed,
that banners/MRECs auto-refresh, and that fullscreen managers should be reused
with bounded retry/backoff:

- [MAX banner/MREC lifecycle and refresh](https://developers.applovin.com/en/max/android/ad-formats/banner-and-mrec-ads/)
- [MAX native-ad destruction](https://developers.applovin.com/en/max/android/ad-formats/native-ads/)
- [MAX interstitial sample/retry lifecycle](https://developers.applovin.com/en/max/android/ad-formats/interstitial-ads/)
- [MAX rewarded sample/retry lifecycle](https://developers.applovin.com/en/max/android/ad-formats/rewarded-ads/)
- [MAX app-open single-manager guidance](https://developers.applovin.com/en/max/android/ad-formats/app-open-ads/)
- [MAX selective initialization](https://developers.applovin.com/en/max/android/overview/advanced-settings/)
- [MAX Mediation Debugger/network isolation](https://developers.applovin.com/en/max/android/testing-networks/mediation-debugger/)

MAX documents an auto-refresh pause workaround: set
`allow_pause_auto_refresh_immediately=true` before `stopAutoRefresh()` when the
SDK otherwise ignores an immediate pause. v1.1-v1.4 currently rewrite the React
Native auto-refresh property to false but do not invoke every documented destroy
path.

BidMachine likewise documents explicit destruction/unregister requirements and
has historical lifecycle fixes:

- [BidMachine Android changelog](https://developers.bidmachine.io/sdk/general/android/android-changelog)
- [BidMachine banner lifecycle](https://developers.bidmachine.io/sdk/general/android/banner)
- [BidMachine native lifecycle](https://developers.bidmachine.io/sdk/general/android/native)
- [BidMachine interstitial lifecycle](https://developers.bidmachine.io/sdk/general/android/interstitial)
- [BidMachine MAX adapter](https://developers.bidmachine.io/sdk/max/android/bidding-adapter)

The extracted Diskwala APK contains BidMachine `3.7.1`, including the older
context-leak fixes. Upgrading it blindly is therefore not a sufficient diagnosis.
The exact MAX core, GMA/GAM, and every adapter version still need a resolved
inventory.

Google documents required banner/native destruction and warns against immediate
load retry loops. GMA 24 enables initialization/load optimization by default;
older versions require manifest flags:

- [GMA initialization/load optimization](https://developers.google.com/admob/android/optimize-initialization)
- [GMA Android release notes](https://developers.google.com/admob/android/rel-notes)
- [Google banner destruction](https://developers.google.com/admob/android/banner)
- [Google native-ad destruction/retry guidance](https://developers.google.com/admob/android/native)

The BidMachine GAM dynamic integration release documented support for GMA
21–23. A `gam_dynamic` artifact paired with GMA 24/25 is a concrete compatibility
red flag that must be checked in the extracted APK.

### 22.3 Public incident evidence and its limits

Useful but non-conclusive reports:

- [MAX Flutter #297](https://github.com/AppLovin/AppLovin-MAX-Flutter/issues/297):
  mediated GMA initialization/load caused main-thread Binder/ANR work; a
  server-side/background-initialization mitigation was reported.
- [MAX Unity #594](https://github.com/AppLovin/AppLovin-MAX-Unity-Plugin/issues/594):
  production ANRs and 236-thread dumps; AppLovin disputed thread ownership and
  stated its own pools were bounded.
- [MAX Unity #464](https://github.com/AppLovin/AppLovin-MAX-Unity-Plugin/issues/464):
  roughly 300 threads after a broad SDK/adapter upgrade, but no minimal repro or
  confirmed owner.
- [MAX Unity #463](https://github.com/AppLovin/AppLovin-MAX-Unity-Plugin/issues/463):
  “MAX-associated” ANRs whose stacks actually pointed at SafeDK, Unity Ads,
  WebView, and fullscreen lifecycle code.
- [Historical AppLovin/Pangle report](https://github.com/JohnnyWangMiura/Pangle_iOS_SDK_Integration_Guideline/issues/1):
  generic scheduled pools and thread exhaustion, but no vendor-confirmed cause.

Chinese CSDN/Juejin/SegmentFault searches produced only generic executor-memory
articles, not a reproducible AppLovin/BidMachine incident. Reddit endpoints were
blocked and no Reddit claim is used as evidence. No relevant solved Stack
Overflow case attributed the surge to one ad SDK.

Adapter changelogs nevertheless show repeated historical context/ownership
fixes across AppLovin, BidMachine, Chartboost, ironSource, InMobi, Mintegral,
Liftoff/Vungle, and Pangle Google adapters:

- [Google mediation adapter changelogs](https://github.com/googleads/googleads-mobile-android-mediation/tree/main/ThirdPartyAdapters)

This justifies exact version auditing and paired upgrades, not blaming one SDK
from a parked stack.

### 22.4 Revised local owner assessment

Current local evidence:

| Candidate | Executor/signature | Lifecycle evidence | v1.4 coverage/status |
| --- | --- | --- | --- |
| Unknown dominant scheduled pools | 410 ART workers in `DelayedWorkQueue.take()` | Creator absent from idle worker stack | Still unresolved |
| BidMachine `BackgroundTaskManager` | scheduled, 2 core | singleton-like; no shutdown visible | Runtime-confirmed; only two pools trimmed, quantitatively insufficient |
| BidMachine `gam_dynamic.TaskExecutorImpl` | scheduled, 2 core | per-instance one-shot schedule; no shutdown | Source-perfect candidate; not observed in production |
| BidMachine `gam.GAMTaskLoader` | scheduled, 2 core | per-instance immediate submit; no shutdown | v1.2/v1.4 did not observe it |
| Chartboost `p7 -> n2` | ordinary TPE, 4 core, `PriorityBlockingQueue` | no shutdown visible | Missed by v1.4; ART has one exact four-worker priority-queue signature |
| IronSource `getThreadPoolExecutor()` | ordinary TPE, 2 core | returns a newly constructed pool; no shutdown visible | Missed by v1.4 |
| BidMachine native executors | ordinary TPE, 4 core | some singleton/bounded, some no shutdown | Missed by v1.4 |
| BidMachine `AdsType` | ordinary TPE, 8 core | enum-owned baseline, no shutdown shown | Missed by v1.4; not the paired dominant shape |
| OMID adapter copies | ordinary one-core pools | multiple separately shaded libraries | Missed by v1.4 |

The 676-thread ART trace contained:

- 410 indefinite scheduled-queue workers;
- 9 timed scheduled-queue workers;
- 36 ordinary linked-queue workers;
- 4 ordinary priority-queue workers.

v1.4 hooks only scheduled constructors. It does not observe fixed, cached,
single-thread, priority-queue, or other ordinary `ThreadPoolExecutor` pools.

### 22.5 Why CPU remained high while workers were parked

The retained workers explain PID/RSS pressure, not all CPU. CPU remained high
because production simultaneously performed:

- repeated MAX/adapter initialization and ad load callbacks;
- React Native state/event work, including the observed maximum-update-depth
  crash path;
- WebView/Chromium/ad rendering work;
- repeated Play Store process crashes;
- deep-link captures and proxy/decryption traffic;
- whole-app recycle/cold initialization.

The latest FastAPI recycler materially changes the experiment. In the first
seven minutes after v1.4 boot it counted 511 intents and recycled Diskwala three
times:

```text
2749 -> 5926 -> 11398 -> 13338
```

Observed reasons were `intent-soft(146)`, `intent-soft(229)`, and
`intent-soft(105)`. Recycles occurred every roughly 1.5–3.5 minutes. This bounds
the process, but repeated cold initialization itself creates CPU/ad-SDK churn
and prevents a long enough same-PID observation to prove a plateau.

### 22.6 New staged plan

#### Phase 0 — preserve production containment

Until better attribution is deployed:

- keep concurrency at 3;
- keep response cache enabled;
- keep primary refire disabled (`interval == timeout`);
- keep producer retry amplification at zero;
- retain the current resource/intent recycler as a temporary safety net;
- do not expand v1.4's `io.bidmachine.*` mutation allowlist;
- do not add cgroup PID limits, CPU quotas, thread killing, executor shutdown, or
  generic core timeout.

The production source of truth is the `/health` snapshot observed after v1.4
startup, not the stale local `.env` or `.env.example` files:

```text
MAX_CONCURRENT=3
CAPTURE_TIMEOUT=30
CAPTURE_FIRE_RETRY_INTERVAL=30
CAPTURE_RECOVERY_RETRIES=0
CAPTURE_QUEUE_MAX_PENDING=50
response_cache.enabled=true
DISKWALA_RECYCLE_EVERY_INTENTS=100
DISKWALA_RECYCLE_THREADS_SOFT=1200
DISKWALA_RECYCLE_THREADS_EMERGENCY=1600
DISKWALA_RECYCLE_RSS_SOFT_MIB=900
DISKWALA_RECYCLE_RSS_EMERGENCY_MIB=1024
```

The local ignored `.env` and tracked `.env.example` contain older/different
values and must not be used to label production experiment results.

v1.4 may remain only until telemetry-only v1.5 is ready. Its scheduled-core
timeout changes timing/parallel capacity and contaminates attribution even though
it currently matches only two small BidMachine pools. v1.5 must set the trim
owner allowlist empty and perform no executor mutation. Retain the AppLovin
reload/refresh guard as the known production baseline; if its effect must be
isolated, do that as a separate short cohort with the same safety cutoff.

#### Phase 1 — build telemetry-only v1.5

The next module must observe behavior before changing it.

Hook successfully completed constructors for:

1. `ThreadPoolExecutor`;
2. `ScheduledThreadPoolExecutor`;
3. optionally `ForkJoinPool` as a separate census.

Deduplicate scheduled executors because their superclass constructor also
passes through `ThreadPoolExecutor`. Add `Executors` factory hooks only for
provenance (`newFixedThreadPool`, `newCachedThreadPool`, `newSingleThreadExecutor`,
`newScheduledThreadPool`, and work-stealing factories).

For each unique pool, capture once:

- identity hash via weak identity record;
- concrete runtime class;
- factory method context;
- exact constructor parameters;
- core/max pool size and keepalive;
- queue concrete class;
- rejection handler;
- thread-factory concrete class;
- default factory private `namePrefix` where available (for example
  `pool-230-thread-`), so ART thread names map directly back to one executor;
- first non-infrastructure owner frame;
- first frame outside `java.util.concurrent`;
- 6–12 normalized creator frames and a stack fingerprint;
- construction timestamp and creating thread.

Use a weak-reference registry and a bounded owner/signature map. Never retain an
executor or app object strongly for telemetry. Poll public metrics at low
frequency:

- current/largest/active pool size;
- queue size;
- completed task count;
- shutdown/terminated state;
- scheduled remove-on-cancel and core-timeout flags.

One named daemon monitor thread is acceptable. It must not create another
anonymous executor. Unknown owners remain telemetry-only.

Before trusting absence of an owner, v1.5 must pass a hook-completeness canary on
the exact production Android/ART image. After all hooks are installed, exercise
every installed constructor/factory hook with tiny, explicitly named pools:

- direct `ThreadPoolExecutor` and `ScheduledThreadPoolExecutor`;
- `newFixedThreadPool` (both overloads);
- `newCachedThreadPool` (both overloads);
- `newSingleThreadExecutor` (both overloads/wrapper provenance);
- `newScheduledThreadPool` (both overloads);
- `newSingleThreadScheduledExecutor` (both overloads/wrapper provenance);
- `newWorkStealingPool` overloads and direct `ForkJoinPool`, if those hooks are
  enabled on the target API.

Each path must emit exactly one canonical constructor record plus the expected
factory/wrapper provenance; scheduled subclasses must not be double-counted
through the TPE super-constructor hook. Submit one no-op task, verify completion,
call `shutdownNow()`, and verify termination. If any installed hook lacks its
canary record, attribution coverage is failed and no production mutation may be
inferred from telemetry. This also detects ART/LSPlant constructor/inlining gaps.

Target success criterion: attribute at least 90% of the increase in numbered
pool workers to concrete pool identities and creator stacks.

Sources for the instrumentation design:

- [LSPlant deoptimization/inlining guidance](https://github.com/LSPosed/LSPlant#5-deoptimize)
- [LSPosed constructor-hook issue #1123](https://github.com/LSPosed/LSPosed/issues/1123)
- [libxposed API](https://github.com/libxposed/api/blob/master/api/src/main/java/io/github/libxposed/api/XposedInterface.java)
- [Android JVMTI guide](https://developer.android.com/ndk/guides/jvmti)
- [JVMTI tagging/heap specification](https://docs.oracle.com/en/java/javase/21/docs/specs/jvmti.html#Heap)
- [Android Studio Memory Profiler](https://developer.android.com/studio/profile/memory-profiler)
- [simpleperf documentation](https://android.googlesource.com/platform/system/extras/+/main/simpleperf/doc/README.md)
- [Frida API](https://frida.re/docs/javascript-api/)

#### Phase 2 — obtain ownership proof

On a fresh Diskwala PID with v1.5:

1. Record pre-MAX baseline.
2. Record after MAX initialization.
3. Record after first interstitial/rewarded/banner/MREC loads.
4. Record after a fixed number of uncached captures.
5. Pause new test traffic and observe a 5–15 minute idle window.
6. Take a second ART dump and map `pool-N` names through captured factory
   `namePrefix` values.
7. Capture HPROF before/after growth and use dominator paths from
   `ThreadPoolExecutor$Worker` / executor / queue / queued task to the retaining
   SDK object.

Heap evidence answers “what retains this pool”; constructor telemetry answers
“where it was created.” Both are required before mutation.

Because production currently recycles every ~100 intents, v1.5 must provide a
time-limited diagnostic-window controller rather than relying on a person to
watch the threshold:

- attribution-window duration: at most 10 minutes;
- temporarily suspend only the intent-count trigger;
- keep emergency resource recycling armed;
- add a stricter diagnostic cutoff at 1,100 threads or 850 MiB RSS;
- sample every five seconds during the window;
- on cutoff, close admission for new cache misses immediately, allow active work
  a short bounded settle, and capture final metrics/thread/heap artifacts;
- while admission remains closed, invoke the existing forced package recycle and
  require a new PID plus a verified post-recycle state below 600 threads and
  750 MiB RSS before reopening cache misses;
- if recycle or verification fails, keep cache misses closed, continue serving
  safe cache hits, restore the intent trigger, and require manual intervention;
- a `finally`/watchdog timer must restore the intent trigger after timeout,
  cancellation, monitor failure, or API shutdown, but may reopen cache misses
  only after the same safe-state verification;
- do not force the process past the cutoff merely to complete a 30-minute test.

This hard stop is separate from the current soft recycler, which waits for an
idle lull and therefore is not a reliable test-window bound under load. Do not
disable all recycler protections.

#### Phase 3 — version/compatibility audit

Complete the dependency matrix before network cohorts or executor mutation, so
an unsupported adapter combination is not misdiagnosed as a lifecycle defect.

Extract and record:

- AppLovin MAX core version;
- every `com.applovin.mediation:*` adapter version;
- Google Mobile Ads/GAM version;
- BidMachine and BidMachine GAM adapter versions;
- Chartboost, ironSource, InMobi, MBridge, Vungle, Pangle, and Yandex versions.

Pin a compatible matrix. Do not update only the base SDK. Check specifically:

- whether local GMA is outside BidMachine `gam_dynamic`'s documented 21–23
  range;
- whether GMA initialization/load optimization is enabled;
- whether adapter versions include documented context/destroy fixes;
- whether Pangle packages include unnecessary App Events functionality;
- whether Yandex automatic initialization is needed.

If the third-party APK cannot be rebuilt normally, SDK replacement/repacking is
high risk because of PairIP/Talsec/signature behavior. Prefer configuration and
narrow lifecycle hooks unless a fully repeatable resign/integrity flow exists.

#### Phase 4 — isolate mediated networks

If MAX dashboard access and a staging/test ad unit are available, use the
Mediation Debugger and one-network waterfall/ad-unit cohorts. Disable one network
at a time while keeping endpoints reachable so Diskwala's ad-block detector
remains satisfied. Dashboard access alone is not an environment boundary.

Any production dashboard cohort must use the same explicit maintenance controls
as a hook-based cohort: close cache-miss admission, use fixed test inputs, enforce
a short hard time limit, and automatically restore the original waterfall/config
on timeout, failure, or operator disconnect.

If dashboard/test-ad-unit access is unavailable, do **not** suppress live adapter
initialization/load in production: “diagnostic-only” hooks still change fill,
callbacks, waterfall state, and app behavior. Skip this phase until a staging
clone or vendor-controlled test ad unit is available. A production cohort is
allowed only during an explicit maintenance window with cache-miss admission
closed, fixed test inputs, a short time limit, and automatic APK/config rollback.
Do not firewall adapter endpoints.

Measure for each cohort:

- executor creation rate by owner;
- worker and RSS slope;
- active CPU, not only parked workers;
- capture success/p95/429 rate;
- ad-block state and React errors.

#### Phase 5 — apply owner-specific fixes

Only after Phase 2/3/4 evidence:

- **Ordinary TPE, immediate work, repeated instances, empty idle queue:** finite
  keepalive plus `allowCoreThreadTimeOut(true)` is defensible for that exact
  owner.
- **Scheduled pool with cancelled-task retention:** enable
  `setRemoveOnCancelPolicy(true)` or bounded `purge()` after known cancellation
  batches. This does not reduce workers.
- **Scheduled per-object pool with one-shot/delayed work:** prefer documented SDK
  destroy/reuse or a vendor upgrade. Do not apply global timeout.
- **Per-object pool created before first submission and never shut down:** prefer
  vendor lifecycle correction or upgrade. Do not replace a private executor with
  a shared module pool merely because no shutdown call is visible; ordering,
  object isolation, delayed-task semantics, rejection, thread factory, and
  lifecycle ownership must all be contractually proven first.
- **Banner/MREC/native objects:** call vendor-supported pause/remove/destroy
  lifecycle methods symmetrically.
- **Fullscreen ads:** one manager/load job per ad unit; capped exponential retry;
  cancel retries when no active host/screen requires them.

High-priority local candidates for telemetry are Chartboost `n2` (four-core
priority TPE), IronSource's newly returned two-core TPE, BidMachine ordinary
executors, and shaded OMID one-core pools.

Before enabling any owner-specific mutation, define a measurable functional
canary for that owner. Constructor counts and aggregate completed-task counters
cannot prove callback delivery. Instrument exact submit/schedule and corresponding
task `run()` or SDK loaded/failed/display callbacks, then require:

- submitted = started + explicitly cancelled/rejected;
- every expected one-shot callback completes before its deadline;
- periodic cadence/order remains within its baseline tolerance;
- no ad load/display callback disappears;
- no increase in executor rejection or SDK error callbacks.

If exact task/callback correlation cannot be measured, the owner is not safe to
mutate in production.

#### Phase 6 — reduce FastAPI amplification

Independent of SDK ownership:

1. Split retry budgets by fault class: one retry only for confirmed ADB transport
   recovery; zero full retries for producer/no-flow timeout; upstream errors
   fail fast.
2. Add an explicit maximum intent-fire count per request.
3. Stop shared unique work at a cancellation checkpoint after its final client
   disconnects; do not begin a refire/retry with zero waiters.
4. Lower queue timeout/pending depth to remain inside the client deadline.
5. Keep cache enabled and measure whether a larger cache improves hit rate enough
   to justify its API memory cost.

#### Phase 7 — replace frequent intent recycling

The current `DISKWALA_RECYCLE_EVERY_INTENTS=100` setting caused three app cold
starts in about seven minutes. Cold starts reinitialize every SDK and can create
the same pools again.

The pre-fix attribution run uses Phase 2's 10-minute controller. Post-fix
validation uses a separate parameterized controller with a 45-minute hard TTL,
the same five-second sampling and 1,100-thread/850-MiB cutoff, the same
close-admission/capture/recycle/verify sequence, and unconditional restoration of
the count trigger. This controlled override is required to measure one PID and
is not a permanent configuration change.

After an owner-specific fix completes a 30-minute controlled window without
hitting the diagnostic cutoff:

- disable routine count-based recycling;
- retain resource sampling as a circuit breaker;
- require trend confirmation for soft resource limits;
- use at least a 30-minute recycle cooldown;
- cap automatic recycles per six-hour window;
- keep the existing quiescent/drop-aware gate and never reset ADB/ReDroid/API.

### 22.7 Validation gates before calling the issue fixed

Use natural traffic first, then controlled ramps through trusted TLS/SSH with a
disposable or rotated credential.

The fix is accepted only if one Diskwala PID meets all of these:

| Gate | Target |
| --- | --- |
| Natural observation | 30 minutes with count trigger suspended by the bounded diagnostic controller; any cutoff is a failed run |
| Thread warm-up plateau | post-warm-up slope below 0.1 thread/s |
| Numbered pool attribution | at least 90% of growth mapped to pool identities/owners |
| Thread ceiling | below 1,000 for the complete window |
| RSS | below 900 MiB with no persistent upward slope |
| ReDroid CPU | below 70% sustained outside short bursts |
| App lifecycle | zero crash/force-stop during the window |
| Capture quality | p95 below 30 seconds |
| HTTP quality | 429 rate below 2%; no new 5xx regression |
| Ad behavior | no ad-block warning and no missing delayed/periodic callbacks |

After natural validation, ramp 0.5, 1.0, 1.5, then 2.0 RPS for at least ten
minutes per stage. Run each stage inside a fresh 15-minute bounded controller
window with the count trigger suspended, all resource cutoffs active, and a
guaranteed restore/recycle path before the next stage. Stop immediately on
monotonic thread/RSS growth, React maximum-update-depth errors, missed scheduled
callbacks, or cutoff/recycler activation. Do not repeat the 5-RPS burst until
the plateau gate passes.

### 22.8 Decision summary

The next release should **not** be another broad “executor cleanup” APK. It
should be a telemetry-only attribution release covering both TPE and STPE. The
dominant fix will then be one or more exact lifecycle/owner patches, likely
combining:

1. AppLovin view/native/fullscreen lifecycle cleanup;
2. exact ordinary-pool timeout for proven immediate-work SDK owners;
3. documented lifecycle correction or compatible vendor update for a proven
   per-object scheduler;
4. lower FastAPI work amplification;
5. resource-only recycling as the final safety net.

That sequence is slower than globally timing out workers, but it is the only
plan supported by both the local evidence and primary Java/Android/vendor
semantics—and therefore the only defensible path to scaling one ReDroid without
silently losing SDK callbacks or replacing a thread leak with another failure
mode.

## 23. Five-minute timer deployment and same-PID validation

Commit `12d6a6b` (`Use five-minute Diskwala recycle timer`) was pushed to `main`
and auto-deployed successfully. Full validation before push: **139 tests passed**.

New code defaults:

```text
DISKWALA_RECYCLE_EVERY_INTENTS=0
DISKWALA_RECYCLE_MAX_INTENTS=0
DISKWALA_RECYCLE_EVERY_SECONDS=300
DISKWALA_RECYCLE_COOLDOWN=300
```

Resource soft/emergency thresholds remain enabled. Timer age now starts when the
recycle task starts rather than after startup grace. The five-minute timer is a
soft trigger that waits for the first idle window; uninterrupted load forces the
timer at ten minutes. A forced ten-minute timer overrides a resource-soft reason
that is waiting forever for idle, while a resource emergency retains priority.

Production confirmed that there are no explicit environment overrides for these
settings. `/health` reported the new defaults after deployment.

### Same-PID natural-traffic result

PID `58329` was observed under normal production traffic until the timer recycle:

| Time UTC | Threads | Pool threads | Distinct pools | RSS KiB | Intents |
| --- | ---: | ---: | ---: | ---: | ---: |
| 07:02:20 | 469 | 155 | 74 | 701,744 | 45 |
| 07:02:56 | 526 | 248 | 123 | 717,464 | 97 |
| 07:03:36 | 618 | 357 | 181 | 731,804 | 157 |
| 07:04:11 | 709 | 473 | 240 | 825,672 | 214 |
| 07:04:44 | 803 | 563 | 286 | 836,020 | 260 |
| 07:05:17 | 954 | 640 | 323 | 802,772 | 297 |
| 07:05:52 | 1,059 | 740 | 373 | 865,412 | 348 |
| 07:06:26 | 1,129 | 858 | 432 | 898,696 | 406 |

The final recycler sample saw 1,216 threads at 07:06:51. At the first idle
window after five minutes, it performed:

```text
reason=timer-soft(336s)
recycles=1
failures=0
```

The next PID was `64488`, initially 195 threads and 517,292 KiB RSS.

Measured same-PID slope:

- total threads: approximately **2.7 threads/second**;
- numbered pool workers: approximately **2.9 threads/second**;
- ReDroid CPU: roughly **40–101%**, with most loaded samples near saturation.

This validates the new five-minute containment behavior and proves the recycler
can reset cleanly without an intent-count loop. It also proves v1.4 does not
reduce the dominant creation slope: the constructor telemetry still showed only
the initial PairIP scheduled pool while hundreds of numbered workers appeared.
The v1.5 ordinary/scheduled executor attribution plan in §22 remains required.

## 24. Dominant surge pinpointed by v1.4.2 telemetry

**Diagnostic module:** v1.4.2/code7, executor mutation disabled  
**APK SHA-256:** `fb4f076136a0fd7ba5ca4cd5746c08b1b7ead0669c09164e21ce6363bba88813`  
**Canary:** `ordinaryDelta=4/4 scheduledDelta=5/5 factoryDelta=4/4 PASS`

v1.4.1 first proved that the ART/LSPosed build bypassed base constructor hooks
for both `Executors` scheduled factory paths. v1.4.2 therefore added bounded
factory-exit telemetry, delegated-wrapper unwrapping, strict weak-identity pool
dedupe, exact default thread-factory prefixes, queue/core/max/factory metadata,
and a correlated ten-frame creator stack for every recorded pool.

### 24.1 Exact telemetry result

In 225 seconds, one repeating path created **308 separate schedulers**:

```text
Executors.newScheduledThreadPool(4)
R2.P:43
h4.g.b:68
wd.M.onHostResume:12
ReactContext.onHostResume
ReactHostImpl.onHostResume
ReactLifecycleStateManager.moveToOnHostResume
ReactActivityDelegate.onResume
```

Every object had the same shape:

```text
class=ScheduledThreadPoolExecutor
core=4
max=Integer.MAX_VALUE
keepAliveMs=10
allowCoreTimeout=false
queue=ScheduledThreadPoolExecutor$DelayedWorkQueue
factory=Executors$DefaultThreadFactory
origin=Executors.newScheduledThreadPool
```

Factory/pool ID/prefix correlation was complete for `pool-176-thread-` through
`pool-483-thread-`:

- 308 `POOL CREATE` records;
- 308 correlated `POOL STACK` records;
- 308 correlated `POOL FACTORY` records;
- 1.36 new schedulers/second;
- 1,232 configured core-worker slots;
- 614 live workers from these objects at snapshot time;
- 57.17% of all 1,074 process threads explained;
- 73.36% of all numbered pool workers explained.

No named AppLovin, BidMachine, Fresco, Chartboost, IronSource, or Google owner had
an increasing construction count. Those pools were bounded baseline objects.

The initial `HookBridge#invokeOriginalMethod` frame is PairIP/instrumentation
plumbing. The concrete allocation site is `R2.P`, reached from the Talsec React
Native lifecycle listener.

### 24.2 Raw class resolution

Targeted JADX extraction resolved the obfuscated classes:

```text
R2      -> defpackage.R2 (classes10.dex)
h4.g    -> p112h4.g
wd.M    -> TalsecReactNativeSecurityPluginModule LifecycleEventListener
```

`wd.M` explicitly belongs to:

```text
com.talsecreactnativesecurityplugin.TalsecReactNativeSecurityPluginModule
```

Its lifecycle behavior is:

```java
onHostResume() -> Ea.d.c() -> h4.g.b()
onHostPause()  -> Ea.d.c() -> h4.g.a()
```

`h4.g.b()` iterates registered accessibility-view/listener entries and calls
`R2.P(listener)`.

Readable decompilation of the responsible methods:

```java
// R2.P(listener): first active listener
if (!listeners.contains(listener)) {
    synchronized (R2.class) {
        listeners.add(listener);
        if (cachedState != null) listener.a(cachedState);
        if (listeners.size() == 1) {
            future = Executors.newScheduledThreadPool(4)
                .scheduleWithFixedDelay(T(), 0L, 3L, TimeUnit.SECONDS);
        }
    }
}

// R2.M(listener): final listener removed on pause
synchronized (R2.class) {
    listeners.remove(listener);
    if (listeners.isEmpty()) {
        future.cancel(true);
    }
}
```

This is the defect:

1. every React host resume after the listener set was emptied creates a new
   four-core scheduled executor;
2. only the `ScheduledFuture` is stored;
3. pause removes the listener and cancels the future;
4. the executor itself is never retained, shut down, or reused;
5. its core workers keep the executor reachable and remain parked in
   `DelayedWorkQueue.take()`;
6. the next resume repeats the allocation.

The surge is therefore caused by the **Talsec/freeRASP accessibility-state
monitor lifecycle**, not the ad SDK pools. Deep links/ad activities amplify it
because they repeatedly pause/resume the React host.

### 24.3 Evidence artifacts

```text
C:\Users\Rishi\AppData\Local\Temp\kilo\talsec-v142-pools.log
C:\Users\Rishi\AppData\Local\Temp\kilo\talsec-v142-tasknames.txt
C:\Users\Rishi\AppData\Local\Temp\kilo\talsec-v142-trace.txt
C:\Users\Rishi\AppData\Local\Temp\kilo\raw-R2.java
C:\Users\Rishi\AppData\Local\Temp\kilo\raw-R2-auto.java
C:\Users\Rishi\AppData\Local\Temp\kilo\raw-h4-g.java
C:\Users\Rishi\AppData\Local\Temp\kilo\raw-wd-M.java
```

### 24.4 Exact v1.5 fix

Do not apply generic executor timeout. Intercept only
`Executors.newScheduledThreadPool(int)` when the live caller stack contains
`R2.P` (optionally require the `wd.M.onHostResume` lifecycle chain as a second
guard).

Return one process-wide shared `ScheduledThreadPoolExecutor` with the originally
requested core size (`4`) instead of allocating a new pool on every resume:

```java
private static final Object raspSchedulerLock = new Object();
private static ScheduledThreadPoolExecutor raspScheduler;

// in a before-hook for Executors.newScheduledThreadPool(int)
if (requestedCore == 4 && stackContains("R2", "P")) {
    synchronized (raspSchedulerLock) {
        if (raspScheduler == null || raspScheduler.isShutdown()) {
            raspScheduler = new ScheduledThreadPoolExecutor(
                4, namedFactory("TalsecA11yMonitor-"));
            raspScheduler.setRemoveOnCancelPolicy(true);
        }
        param.setResult(raspScheduler);
    }
}
```

Why this is the narrowest fix:

- `R2.P` continues scheduling the same fixed-delay task every three seconds;
- `R2.M` continues cancelling the same future on pause;
- the cancelled future is removed immediately;
- the scheduler remains reusable on the next resume;
- the original four-thread parallel capacity is preserved;
- no unknown SDK executor, delayed task, callback, queue, or thread factory is
  modified;
- pool count becomes one per process instead of one per resume.

The direct source-level equivalent is to add a scheduler field to `R2`, create it
once, reuse it in `P`, and call `shutdown()` only at the true module/process
destroy boundary—not on every host pause.

### 24.5 v1.5 acceptance test

1. Start a cold Diskwala process with the five-minute FastAPI recycler.
2. Require the executor canary to pass.
3. Require exactly one `TalsecA11yMonitor-*` scheduler creation.
4. Drive natural traffic/deep-link resumes for five minutes.
5. Assert repeated `R2.P` interceptions reuse the same executor identity.
6. Assert listener callbacks continue every three seconds while active.
7. Assert pause cancels the periodic future and resume schedules a new future.
8. Assert no `RejectedExecutionException`, missed Talsec callback, AppiCrypt
   regression, ad-block warning, or capture regression.
9. Expected thread slope after warm-up: near zero rather than 2.7–2.9/s.
10. Temporarily retain the five-minute recycler until a 30-minute same-PID
    validation passes.

Do not target the bounded named ad-SDK pools identified in this trace. The v1.5
fix should contain only the exact Talsec `R2.P` scheduler reuse plus the existing
AppLovin reload guard, with diagnostic constructor logging removed after
validation.

## 25. v1.5 exact fix candidate

**Status:** built, signed, independently reviewed, and deployed  
**Version:** 1.5 / code 8  
**SHA-256:** `b27dbb9fb76681bba2f2c57b47b2702d7b12ef63699b493847c133a0e8262fa1`

The final candidate implements §24.4 directly:

- hooks only `Executors.newScheduledThreadPool(int)`;
- requires requested core size `4`;
- requires all three exact production runtime frames:
  `R2#P`, `h4.g#b`, and `wd.M#onHostResume`;
- returns one process-wide shared four-core scheduler;
- gives its threads the explicit `TalsecA11yMonitor-*` name;
- enables `setRemoveOnCancelPolicy(true)` so `R2.M`'s cancelled fixed-delay
  future leaves the queue immediately;
- preserves R2's existing three-second `scheduleWithFixedDelay`, listener
  callbacks, pause cancellation, and resume rescheduling;
- leaves all unknown/ad-SDK executors unchanged;
- disables broad TPE/STPE diagnostic instrumentation and all generic executor
  mutation;
- retains the separately validated AppLovin reload/auto-refresh guard;
- fails open to the original factory if stack/core matching or scheduler creation
  fails.

The reviewed source and code8 artifact match. The exact runtime class names come
from production telemetry; `defpackage.R2` and `p112h4.g` are JADX-only aliases
and are deliberately not accepted by the runtime guard.

Required controlled validation after deployment:

1. log exactly one `Talsec R2.P shared scheduler created core=4`;
2. observe repeated `scheduler reused count=` on subsequent host resumes;
3. observe at most four `TalsecA11yMonitor-*` workers;
4. verify `pool-N` creation no longer rises with resume count;
5. verify the listener callback continues every three seconds while active;
6. verify pause cancels its future and next resume schedules on the same executor;
7. run one five-minute natural-traffic PID under the existing timer/resource
   recycler;
8. expected post-warm-up thread slope: near zero instead of 2.7–2.9/s;
9. retain v1.4/v1.4.1/v1.4.2 and LSPosed DB backups until 30-minute validation
   passes.

## 26. v1.5 production validation result

v1.5 was installed after backing up v1.4.2 and its LSPosed configuration. The
module DB path/scope and integrity were verified before reboot.

Runtime activation logs confirmed:

```text
Talsec R2.P scheduler reuse hook installed
Talsec R2.P shared scheduler created core=4
Talsec R2.P scheduler reused count=1..300 id=4529088
broad executor attribution disabled in final fix
```

The scheduler identity remained constant through at least 300 host resumes.

### Same-PID comparison

| Metric | Before fix (v1.4 PID 58329) | v1.5 PID 2522 |
| --- | ---: | ---: |
| Intents observed | 406 before final sample | 342 |
| Total threads, first sample | 469 | 354 |
| Total threads, last sample | 1,129 (then 1,216 recycler sample) | 299 |
| Numbered pool workers, first | 155 | 62 |
| Numbered pool workers, last | 858 | 62 |
| Distinct numbered pools, first | 74 | 29 |
| Distinct numbered pools, last | 432 | 29 |
| Talsec shared workers | not present | exactly 4 |
| Thread slope | ~2.7 threads/s | negative after warm-up |
| Pool-worker slope | ~2.9 threads/s | 0 threads/s |

During the five-minute v1.5 window:

- thread count sampled `354 -> 332 -> 300 -> 295 -> 299 -> 299`;
- numbered pool workers remained exactly 62 in every sample;
- distinct numbered pools remained exactly 29;
- `TalsecA11yMonitor-*` remained exactly four threads;
- the same shared scheduler ID was reused through at least 300 resume events;
- no recycler/resource failure occurred before the timer;
- the API served 513 HTTP 200 `/video` completions in the final five-minute log
  window, with zero 429 and zero 5xx; one additional completion was a different
  non-5xx status;
- API Docker restarts/OOM remained zero.

At the first idle window after five minutes, FastAPI recycled the otherwise
healthy process:

```text
reason=timer-soft(320s)
recycles=1
failures=0
```

The new PID started with 354 threads and four shared Talsec scheduler workers.

### Conclusion

The exact scheduler reuse eliminated the dominant leak measured by v1.4.2. The
five-minute timer is now the factor preventing longer same-PID proof; it is no
longer needed as rapid containment for this specific leak. Keep resource
thresholds enabled, but the next controlled change should disable or greatly
extend the timer and observe one PID for at least 30 minutes before declaring the
system stable.

## 27. Resource-only recycler deployment

Commit `cef80b5` (`Recycle Diskwala on resource pressure only`) was pushed and
auto-deployed after the successful v1.5 test. Full suite: **140 passed**.

Production now reports:

```text
every_intents=0
max_intents=0
every_seconds=0
on_resource=true
threads_soft=1200
threads_emergency=1600
rss_soft_mib=900
rss_emergency_mib=1024
cooldown=300
```

A healthy PID is no longer recycled by fired-intent count or elapsed time. Only
directly measured thread/RSS thresholds can trigger recycling. The first
post-deployment v1.5 PID (`24130`) created one shared Talsec scheduler and reused
the same identity through at least 50 resumes while `/video` traffic remained
active. API health was `ok`, with zero recycler failures, Docker restarts, or
OOM kills.
