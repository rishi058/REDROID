# exp (redroid-experimental) — What made MEETS_DEVICE_INTEGRITY pass

Date: 2026-08-26 · Target: `redroid-experimental` (VPS) only · prod `redroid14` untouched

## Result

| Stage | BASIC | DEVICE | STRONG |
|---|---|---|---|
| Before any change | ❌ Fail | ❌ Fail | ❌ Fail |
| **After the TrickyStore fix (below)** | ❌ Fail | ✅ **Pass** | ❌ Fail |
| After identity + MindTheGapps + new Gmail | ❌ Fail | ✅ Pass | ❌ Fail |

**DEVICE integrity started passing immediately after the TrickyStore config fix, and nothing after that changed the verdict.** The later changes (identity module, MindTheGapps, Gmail swap) did **not** affect Device integrity — confirmed by re-testing after each.

## The change that flipped DEVICE → Pass

DEVICE integrity on Android 14 = hardware-backed **key attestation** whose certificate chain must root to Google. On exp that chain is produced by TrickyStore (keybox). Its config was broken/contaminated; fixing it produced a valid chain.

Applied to `/data/adb/tricky_store/` inside exp (all three together, then GMS force-stopped to re-attest):

1. **Removed stale TEESimulator-RS engine files** that were polluting a TrickyStore v1.4.1 install (these are not used by TrickyStore v1.4.1 and corrupted its attestation state):
   - deleted `boot_key.bin`, `boot_hash.bin`, `hbk`, `persistent_keys/`, `logs/`
   - result: dir now matches the passing WSL device (`key_db keybox.xml security_patch.txt target.txt tee_status`)
2. **Added `security_patch.txt`** (was missing) so the KeyMint OS patch level is coherent (Google enforces this since Sep 2025):
   ```
   system=202607
   boot=2026-07-05
   vendor=2026-07-05
   ```
3. **Added `com.android.vending` to `target.txt`** (matching WSL):
   ```
   com.android.vending
   com.google.android.gms!
   gr.nikolasspyr.integritycheck
   ```
4. Activated by `am force-stop com.google.android.gms` (forces fresh attestation). No reboot required for this step.

Script: [integrity-debug/scripts/fix_exp_ts.sh](integrity-debug/scripts/fix_exp_ts.sh)
Backup of the pre-fix dir: on exp at `/data/local/tmp/ts_bak_<timestamp>/`

> Most probable single driver: the **stale-file cleanup + `security_patch.txt`** (attestation coherence). The three were applied together, so they're credited as one fix.

## Keybox / keystore facts (unchanged, already correct)
- keybox `keybox.xml` sha256 `5c9ba17b…` (not on Google public CRL), chains to Google root.
- Engine: TrickyStore v1.4.1 (245-72b2e84), injected into `keystore2`. `teeBroken=false`.

## Changes made AFTER DEVICE already passed (did NOT change the verdict)
Kept because they move exp toward the passing WSL device, but none flipped BASIC:
- **Identity:** installed `redroid_pixel5` global `system.prop` module (full coherent redfin/Pixel 5 identity incl. `ro.product.first_api_level=30`); **disabled PIF** (`playintegrityfix`). Script: [install_redroid_pixel5_exp.sh](integrity-debug/scripts/install_redroid_pixel5_exp.sh)
- **GApps experiment:** MindTheGapps 14.0.0-arm64-20240226 was tested and did not affect the DEVICE verdict. On 2026-09-07 it was permanently removed from `redroid-experimental` and the lighter existing `litegapps` module was re-enabled to reduce persistent disk and runtime footprint.
- **Account:** signed into `rishiqwerty01@gmail.com` (user). Confirmed **not** the cause of DEVICE pass.

## Current exp module stack
`meta-mm` (Magic Mount), `redroid_pixel5` (identity), `litegapps`, `tricky_store` v1.4.1, `zygisksu` (Zygisk Next 1.4.3) — enabled.
`playintegrityfix` — disabled. `mindthegapps` is absent.

## Still open: BASIC fails on exp but passes on WSL
Not changed in this session (documented for the next step, no action taken):
- exp and WSL share the keybox, TrickyStore v1.4.1, security patch, target list (+vending), Pixel 5 identity, and no PIF. Their GApps distributions intentionally differ after experimental returned to LiteGApps.
- Remaining differences exp vs WSL: **arch** (exp arm64 / Oracle-KVM vs WSL x86 / Hyper-V), **kernel** (`6.8.12-zksu-multi` vs `5.15…WSL2-redroid-ksu`), **LSPosed** present on WSL only, **egress IP** (datacenter vs residential).
- BASIC does not use the keybox the way DEVICE does; the remaining gap points at environment/arch rather than the attestation config.

### Ruled-out hypotheses for the BASIC gap (tested, do NOT retry)
- **"Hide/wipe `/data/adb` from GMS" (DroidGuard root-trace visibility):** DISPROVEN. Read-only check of `/proc/<gms pid>/root/data/adb` + mountinfo on both devices shows **WSL's** `com.google.android.gms[.unstable/.persistent]` fully sees `/data/adb` (ksu, ksud, lspd, modules, …) and module mounts, yet **passes BASIC**. exp sees the same class of traces. So a `/data/adb` wipe/reflash or per-app unmount is NOT the fix. Script: [integrity-debug/scripts/gms_root_visibility.sh](integrity-debug/scripts/gms_root_visibility.sh).
- **PIF is required for BASIC:** DISPROVEN. WSL passes BASIC with no PIF (uses `redroid_pixel5` global props). exp failed BASIC both with PIF enabled and with PIF disabled.
- **SUSFS / hidden KernelSU manager / deny-root-to-Google:** DISPROVEN earlier — neither device has SUSFS or a manager app; both have empty su allowlists; WSL passes anyway.
- **LSPosed hooks something that grants BASIC:** DISPROVEN. WSL's LSPosed is inert — `modules_config.db` has **zero tables**, no Xposed module APKs installed (only the manager + the checker). It hooks nothing. Scripts: [lsposed_inspect.sh](integrity-debug/scripts/lsposed_inspect.sh), [parse_lspd.py](integrity-debug/scripts/parse_lspd.py).
- **Datacenter vs residential egress:** DISPROVEN (proxy-tested earlier).

### Nature of the gap (confirmed from raw JSON)
exp's raw verdict returns `deviceIntegrity.deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY"]` and **omits** `MEETS_BASIC_INTEGRITY` (with `appRecognitionVerdict: PLAY_RECOGNIZED`). So BASIC is genuinely withheld by Google, not a display quirk. DEVICE = keybox key-attestation (passes); BASIC = DroidGuard's runtime environment scan (withheld) — independent subsystems.

### Leading remaining hypothesis: the `-multi` kernel variant (not arch, not version)
User data point: **BASIC passed earlier on ARM with `6.8.12-zksu`**, and fails now on `6.8.12-zksu-multi`. Both ARM64, both Linux 6.8.12, both KernelSU + modular Binder. So it is neither arch nor kernel version — it is specifically the **multi-instance kernel variant**. Per `KernelSU_setup/multi-instance-kernel-patch-plan.md`, `-multi` differs from `-zksu` only by:
1. the multi-instance KernelSU boot-lifecycle patch (`ksud_integration.c`: per-PID-namespace boot records + RC proxy; KernelSU hooks stay registered across namespaces instead of one-shot);
2. the unique release string `6.8.12-zksu-multi`.
Running kernel is taint=0; `/proc/version` = `6.8.12-zksu-multi (builder@MSI) #5 … Thu Aug 20`.
Candidate cause: (a) the release string read by DroidGuard's legacy BASIC scan, or (b) a behavioral side-effect of cross-namespace KernelSU hook persistence.

**Definitive test (no rebuild):** `6.8.12-zksu` is still installed as the rollback kernel. One-time `grub-reboot` into `6.8.12-zksu`, run exp ALONE (stop prod; `-zksu` runs a single instance fine), check BASIC. Pass → kernel confirmed (fix = rebuild `-multi` with a benign release string / narrowed patch). Fail → kernel exonerated. NOTE: needs a VPS host reboot (prod down during test) + Oracle serial console + boot-volume backup per the plan's safety rules — requires explicit user OK.

## How to revert (exp only)
- TrickyStore: restore `/data/local/tmp/ts_bak_<timestamp>/` over `/data/adb/tricky_store/`.
- Identity: `rm -rf /data/adb/modules/redroid_pixel5`; `rm /data/adb/modules/playintegrityfix/disable`.
- GApps: MindTheGapps was permanently deleted to save space; LiteGApps is the retained experimental module.
- Restart the exp container to apply.


# NEW TASKS

1. Rebuild kernel without the multi-instance patch - 

2. Use Pixel 7 panther which natively shipped with zygote64 only on Android 14

3. Add ro.hardware=redfin and ro.boot.hardware=redfin directly into your identity module (system.prop):
