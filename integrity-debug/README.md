# integrity-debug — Play Integrity BASIC / "Device certified" debug harness

Purpose-built tooling to **debug why `redroid-experimental` (5557) fails** Play Integrity
BASIC/DEVICE and Play Store certification, and to build a targeted fix. Everything here targets
**exp only** — `redroid14` (prod) is off-limits.

## Access
- VPS: `ssh -i "C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key" ubuntu@141.148.151.172`
- exp container: `sudo docker ps -q --filter label=coolify.serviceName=redroid-experimental`
- adb (via SSH tunnel already up): `127.0.0.1:5557`

## What we already know (2026-08-26, grounded)
- **Both VPS containers fail; only the local WSL (x86) redroid passes** — same account + same keybox.
  So the differentiator is the **VPS environment (ARM64 / Oracle-KVM / datacenter)**, not config.
- exp live verdict = **all 3 tiers FAIL**. The checker uses the **Classic API** (fresh token/check),
  so it's a **genuine server decline**, not a replay artifact. Token flow works mechanically.
- exp env tells: SELinux `Disabled`, `0 sensors`, `ro.hardware=redroid`, kernel `6.8.12-zksu-multi`,
  CPU Ampere `0x41`. (WSL shares the container-generic ones, so the real diff is arch/kernel/egress —
  capture the WSL snapshot to confirm.)

## Run order (highest signal first)
| Step | Script | Where | Changes exp? |
|---|---|---|---|
| 0. State assessment | `scripts/00_assess.sh` | VPS | no |
| D.1 Decode-once (decisive) | `probe-app/` + `decode-harness/decode_token.py` | device + local | no |
| D.4 Env snapshot + diff | `scripts/d4_env_snapshot.sh`, `scripts/env_diff.py` | exp **and WSL** | no |
| D.2 logcat trace | `scripts/d2_logcat_trace.sh` | VPS | no (bounces GMS) |
| D.3 Frida DroidGuard trace | `scripts/d3_frida_*` | VPS + local frida | no |
| D.5 Net capture | `scripts/d5_net_capture.sh` | VPS host | no |
| verdict capture | `scripts/capture_verdict.ps1` | local (adb UI) | no |
| Phase 2 cert wipe cycle | `scripts/phase2_wipe_cycle.sh` | VPS | yes (Play Store data) |
| Phase 3 PIF A/B (low prio) | `scripts/phase3_pif_ab.sh` | VPS | yes (module swap + restart) |
| Phase M module | `droidguard-tracer/` | exp | yes (diagnostic safe) |

## How to invoke VPS scripts from Windows
```powershell
$Key='C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key'
Get-Content -Raw scripts\00_assess.sh | ssh -i $Key ubuntu@141.148.151.172 "tr -d '\r' | bash -s"
```
Env snapshot inside a container:
```powershell
Get-Content -Raw scripts\d4_env_snapshot.sh | ssh -i $Key ubuntu@141.148.151.172 `
  "C=`$(sudo docker ps -q --filter label=coolify.serviceName=redroid-experimental|head -n1); tr -d '\r' | sudo docker exec -i `$C sh -s" > out_exp_env.txt
```

## Decision gate
Run **D.1 decode-once** first. Its result routes everything:
- `deviceRecognitionVerdict` has `MEETS_*` → checker was wrong; nothing to fix.
- device empty but app **evaluated** → **genuine fail** → D.4/D.3 to find the env signal, then
  the harmonizer module; if attestation/keybox is rejected → **private keybox** is the real fix.
- everything `UNEVALUATED` on a **fresh** token → escalate (rare, given Classic path).

> Constraints: never touch prod; never print keybox contents (sha256 only); never `pm clear` GMS or
> clear `app_dg_cache`; container restart of exp OK, ask before VPS reboot.
