# ADB-worm incident — `com.hagaseca.thost9` (2026-08-09)

`redroid14` kept going **`device offline`**. Cause: the **`com.hagaseca.thost9` ADB
worm** hijacked TCP/5555 so real `adbd` couldn't bind it. These are the exact
scripts used to diagnose and fix it. Canonical write-up + recovery steps live in
[`../setup-guide-coolify.md`](../setup-guide-coolify.md) ("ADB became offline" and
"Recovery: device offline / ADB worm").

## Root cause
Internet-exposed ADB. `ufw` allowed `5555/tcp` **and** Docker published
`0.0.0.0:5555` (Docker's published ports bypass `ufw`). A generic ADB worm scans
the internet for open 5555 and installs itself over unauthenticated `adb`. The
redroid image **ships a root adb shell** and `ro.adb.secure` is **OFF by default**
(redroid-doc [#694], [#769]), so an exposed port = unauthenticated root in the
container. It was **not** a leaked key (the `DW-fast-api` repo is private,
sole-access; the worm needs no key). The July-24 `redroid` instance — predating
that repo — was infected the same way.

Confirmed by the redroid project itself: [#634] (same package), [#498]
(Docker-bypasses-ufw exposure), [#694] (image ships root adb), [#769] (adb
key-auth is off by default).

[#634]: https://github.com/remote-android/redroid-doc/issues/634
[#498]: https://github.com/remote-android/redroid-doc/issues/498
[#694]: https://github.com/remote-android/redroid-doc/issues/694
[#769]: https://github.com/remote-android/redroid-doc/issues/769

## Applied on the VPS (persistent)
- **`redroid-adb-firewall.service`** — `DOCKER-USER` drop of external `:5555`
  (allows only `172.16.0.0/12` + localhost); re-applied after boot and docker
  restarts.
- **`redroid-worm-guard.timer`** → `/usr/local/sbin/redroid-worm-guard` — every
  2 min, symptom-based (rename-proof) detect + uninstall the 5555 hijacker/IOCs,
  restore `adbd`, reconnect the API. Conservative: only auto-removes a package
  that is hijacking 5555 or matches a known IOC name; logs anything else.
- Removed the `ufw allow 5555`; uninstalled the worm + IOCs.

## Still recommended
- Close `5555` in the **Oracle Cloud Security List** (console — Docker can't
  rewrite it).
- Cleaner long-term than the DOCKER-USER rule: publish `127.0.0.1:5555:5555`
  (redroid-doc [#498]) and reach it via SSH tunnel.
- Keep `ro.adb.secure=1` (already on) as defense-in-depth.

## Scripts
Run from Windows: `python access.py ssh -i <key> ubuntu@<vps> 'bash -s' < <script>`

Diagnostics (read-only):
| Script | Purpose |
|---|---|
| `diag-offline.sh` | Initial triage: watchers, container, 5555 owner, packages |
| `diag-attack-surface.sh` | Port exposure + rogue-package evidence capture |
| `diag-inside-outside.sh` | ADB auth posture, authorized keys, inside-reinstaller/host hunt |
| `diag-attribution.sh` | Confirm FastAPI key, shell history, cross-instance presence |
| `diag-exposure.sh` | Map internet-exposed services (Coolify/Traefik/FastAPI) |
| `diag-coolify.sh` | Coolify users/tokens/apps/activity (compromise check) |

Fixes (mutating):
| Script | Purpose |
|---|---|
| `fix1-lock-port.sh` | One-shot `DOCKER-USER` drop + remove `ufw` allow |
| `fixA-persist-firewall.sh` | Install `redroid-adb-firewall.service` |
| `fixB-remove-malware.sh` | Uninstall worm + IOCs, restore `adbd`, verify API |
| `fixC-worm-guard.sh` | Install `redroid-worm-guard` timer |

## IOCs
Packages: `com.hagaseca.thost9`, `com.hagaseca.thost4` (family `com.hagaseca.thostN`),
dropped `com.android.secure`, `com.roblox.client`. APK SHA-256
`30f4e1bc0cd96d4210765b18533eb0c5343f155a36b1a567132538242487d09c`. A `/data/local/tmp`
replaced by a file containing the string `hacker`. An app bound to TCP 5555 with
`adbd` offline; an unexpected enabled AccessibilityService.
