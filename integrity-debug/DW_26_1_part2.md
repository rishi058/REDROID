# DiskWala 26.1 on x86_64 ReDroid — the three-blocker story

Date: 2026-09-23. This continues [DW_26_1.md](DW_26_1.md).

This was not one integrity problem. DiskWala stopped us at three different walls, and each wall needed a different fix:

1. **Redirected into Play Store** — PairIP / installation-origin protection.
2. **This device isn't supported** — DiskWala's own Keystore + Play Integrity attestation was rejected by its backend.
3. **No Google account is available** — Android rejected Google Play services as a valid Credential Manager system provider.

The final verified result was not a cosmetic bypass:

- real `attest/verify` returned HTTP 200 with `{"ok":true,"tier":"full"}`;
- Google sign-in completed;
- DiskWala reached Home;
- real `token/refresh` returned HTTP 200 with `tier=full` and `integrityStale=false`;
- no mocked response or launch-screen override was active in the final run.

> Part 1 contains useful installation and environment work, but its old theory that Strong Integrity/StrongBox was necessarily the last blocker was superseded by this investigation.

---

## Before the story: verify the exact local target

The tested environment was:

```text
WSL distro: Ubuntu
Docker container: redroid14
Docker data volume: local-setup_redroid14-data
Image: redroid/redroid:14.0.0-latest, linux/amd64
Android: 14 / API 34
Local ADB serial during this test: 127.0.0.1:5555
DiskWala package: com.diskwalaapp
DiskWala version: 26.1 / versionCode 352
DiskWala ABI: arm64-v8a through libndk_translation
```

`5555` is not universally "the local ReDroid" in this repository. It has also been used by SSH tunnels. Verify the current device and container before any write:

```powershell
$d = '127.0.0.1:5555' # Replace with the independently verified local serial.
adb -s $d shell getprop sys.boot_completed
adb -s $d shell getprop ro.product.cpu.abilist
adb -s $d shell getprop ro.dalvik.vm.native.bridge
adb -s $d shell dumpsys package com.diskwalaapp
wsl.exe -d Ubuntu -u root --exec docker inspect redroid14
```

Require `sys.boot_completed=1` before using Package Manager, LSPosed, or integrity scripts.

The exact tested base APK SHA-256 was:

```text
C4D3CA69B82A7AAF79DC8C2510772CCAD1B1CFC4D357613F02FA5A48B0EF359F
```

Check both installed and local copies:

```powershell
adb -s $d shell sha256sum /system/app/DiskWala/base.apk
Get-FileHash -Algorithm SHA256 `
  'rev-eng\apk-extractor\target-apk\DiskWala_26_1_extracted\base.apk'
```

---

# Blocker 1 — "Redirected into Play Store"

## What was happening

DiskWala is protected by PairIP. A normal sideload can be redirected to Play Store before the app reaches its real UI.

## Fast fix: PairIPFix LSPosed APK

The quick path is the existing module:

```text
rev-eng/modules/pairipfix.apk
```

Install it, enable it in LSPosed, and scope it only to `com.diskwalaapp`.

This is useful for experiments, but it is not the cleanest final setup:

- an ordinary sideloaded module APK can restore Play Integrity's `UNKNOWN_INSTALLED` app-access-risk label;
- it adds another moving part to LSPosed/Zygisk;
- reinstalling the module changes its randomized `/data/app/.../base.apk` path, so LSPosed's database path may need repair.

## Recommended fix: use the Part 1 installation/system-preload route

For the final container, follow [DW_26_1.md](DW_26_1.md): install the complete signed split set, configure the system preload/install-source state, and avoid depending on PairIPFix for normal startup.

The complete split set is:

```text
rev-eng/apk-extractor/target-apk/DiskWala_26_1_extracted/base.apk
rev-eng/apk-extractor/target-apk/DiskWala_26_1_extracted/split_config.arm64_v8a.apk
rev-eng/apk-extractor/target-apk/DiskWala_26_1_extracted/split_config.en.apk
rev-eng/apk-extractor/target-apk/DiskWala_26_1_extracted/split_config.xxhdpi.apk
```

Never install only `base.apk`.

**Recommendation:** use the Part 1 route for a repeatable container. Keep PairIPFix only as the fast fallback/debug option.

---

# Blocker 2 — "This device isn't supported"

## First assumption — and why it was incomplete

The independent integrity checker passed BASIC and DEVICE but not STRONG, so it was tempting to conclude that the wall required Strong Integrity or physical StrongBox.

That was not proven. DiskWala performs its own launch-time attestation ceremony, using both:

- a Play Integrity token; and
- DiskWala's own Android Keystore key ID/certificate chain.

The checker app and Google Play services were already in TrickyStore's target list, but **DiskWala itself was not**.

## How the wall actually worked

The verified 26.1 APK is Kotlin/Jetpack Compose, not the old React Native/Hermes build.

The current launch path is:

```text
O5.T.invokeSuspend()              LaunchViewModel device check
  -> B5.f.e(...)
  -> B5.f.q(...)                  attestation ceremony
  -> attest/challenge
  -> attest/verify
  -> E5.f(status, error)
  -> O5.h0.i(...)                 maps rejection codes
  -> O5.K.f = O5.h.UNSUPPORTED
  -> M5.F0.a(...)
  -> M5.D3.a(unsupported title/message)
```

The app maps these server/local errors to the same wall:

```text
device_not_trusted
attestation_failed
device_id_missing
attest_key_id_mismatch
```

Before the real fix, the backend response was:

```text
attest/challenge -> HTTP 200
attest/verify    -> HTTP 400
{"error":"attestation_failed"}
```

Android ID was present, so the local `device_id_missing` path was not the cause in this run.

## Real fix: valid keybox + DiskWala target in TrickyStore

Start with the container's working `keybox.xml` and TrickyStore installation. Do not commit or publish the keybox.

Inspect the existing targets:

```powershell
adb -s $d shell su -c 'cat /data/adb/tricky_store/target.txt'
```

The pre-fix list included Google packages/checker but omitted DiskWala:

```text
com.android.vending
com.google.android.gms!
gr.nikolasspyr.integritycheck
```

Add the **correct package name**:

```text
com.diskwalaapp!
```

The message typo `com.diskwalaaap` is wrong.

The reusable script is:

```text
integrity-debug/DW_26_1/scripts/01-add-tricky-target.sh
```

Run from WSL after verifying `CONTAINER`:

```bash
CONTAINER=redroid14 \
  bash /mnt/d/PROJECT/_TRASH/REDROID/integrity-debug/DW_26_1/scripts/01-add-tricky-target.sh
```

It preserves the existing target list and creates a timestamped backup before adding DiskWala.

The first real request after the fix returned:

```text
attest/verify -> HTTP 200
{"ok":true,"tier":"full"}
```

The wall disappeared with the custom probe in `observe` mode — no UI bypass and no response mock.

## Optional launch-screen bypass

A separate LSPosed module was built during diagnosis:

```text
APK: rev-eng/modules/dw26gate.apk
Package: com.recon.dw26gate
Version: 0.4 / versionCode 4
SHA-256: D500FD9E1B6E276B8776B7505EC95ED0107DFB1F0818B4FDC85DC3982FD62308
Source: rev-eng/mod_build/gate/
Build: rev-eng/mod_build/build_gate.sh
```

Its `local` mode replaces only the unsupported-screen renderer with DiskWala's existing signed-out UI. That exposed **Continue with Google** even while the real backend still returned `attestation_failed`.

That proved an important distinction:

- **launch screen bypassed** does not mean **attestation fixed**;
- Google sign-in retried attestation and still failed until the TrickyStore target was corrected.

The module modes are:

| Mode | Behavior |
|---|---|
| `off` | No hooks. |
| `observe` | Version-pinned diagnostics and privacy-safe response capture. Recommended final mode if keeping the module. |
| `local` | Presentation-only wall bypass; underlying `UNSUPPORTED` state/server response remains unchanged. |
| `mock` | Opt-in client-only endpoint fixtures. Not used for the successful setup. |

Change mode and restart the target process:

```powershell
adb -s $d shell 'printf observe > /data/local/tmp/dw26gate.mode'
adb -s $d shell am force-stop com.diskwalaapp
adb -s $d shell am start -n com.diskwalaapp/.app.MainActivity
```

**Recommendation:** keep both the real keybox/TrickyStore fix and the probe source/artifact. Leave the probe in `observe` or `off`. Use `local` only as a fallback diagnostic, because bypassing the wall alone cannot authenticate.

The helper that persists the probe as a system app is:

```text
integrity-debug/DW_26_1/scripts/install-probe-system.sh
```

---

# Blocker 3 — Google sign-in said no account was available

## Symptom

After attestation succeeded, pressing Continue with Google displayed:

```text
No Google account is available on this device.
```

But Android Account Manager already had one Google account.

## Proven cause

Credential Manager logged:

```text
CredentialProviderInfoFactory:
Provider is not a valid system provider:
com.google.android.gms.auth.api.credentials.credman.service.GoogleIdService
```

Google's `RemoteService` was rejected in the same way.

DiskWala uses Android 14's framework Credential Manager and requires a system provider. Its request did not restrict to previously authorized accounts and did not auto-select. The generic "no account" message was therefore misleading: Android rejected the provider before account selection.

Required permission:

```text
android.permission.PROVIDE_DEFAULT_ENABLED_CREDENTIAL_SERVICE
protectionLevel=signature|privileged
```

The permission was already allowlisted but `granted=false`.

## Why the permission was denied

The active GMS update requested the permission, but its older factory APK did not:

| GMS copy | Tested version | Requested permission? |
|---|---:|---|
| Factory `/system/product/priv-app/GmsCore/GmsCore.apk` | 22.21.16 / 222116056 | No |
| Active `/data/app/.../com.google.android.gms.../base.apk` | 26.32.34 / 263234032 | Yes |

Android's updated-system-app privileged-permission rule checks whether the original factory package requested that exact permission. An allowlist entry alone was not sufficient.

## Repair: promote the complete, same-signed active GMS set to factory

Do this only when the same mismatch is independently confirmed.

The reusable scripts are:

```text
integrity-debug/DW_26_1/scripts/02-stage-gms-factory.sh
integrity-debug/DW_26_1/scripts/03-swap-gms-factory.sh
integrity-debug/DW_26_1/scripts/04-validate-gms-factory.sh
```

### Step 1 — verify signatures and manifests

Compare the current factory APK and active update with `aapt2` and `apksigner`. They must have the same valid Google signer. On the tested instance, both public certificate SHA-256 values were:

```text
7ce83c1b71f3d572fed04c8d40c5cb10ff75e6d87d9df6fbd53f0468c2905053
```

Do not rebuild or resign Google Play services.

### Step 2 — stage every active split

```bash
CONTAINER=redroid14 \
  bash /mnt/d/PROJECT/_TRASH/REDROID/integrity-debug/DW_26_1/scripts/02-stage-gms-factory.sh
```

The script discovers `pm path com.google.android.gms`, copies every base/split APK into a timestamped `/data/adb/gms-factory-fix-*` rollback directory, and verifies each copy byte-for-byte.

It prints a path such as:

```text
GMS_BACKUP=/data/adb/gms-factory-fix-YYYYMMDDTHHMMSSZ
```

### Step 3 — replace the factory directory offline

```bash
CONTAINER=redroid14 \
GMS_BACKUP=/data/adb/gms-factory-fix-YYYYMMDDTHHMMSSZ \
  bash /mnt/d/PROJECT/_TRASH/REDROID/integrity-debug/DW_26_1/scripts/03-swap-gms-factory.sh
```

This stops ReDroid, moves the original factory directory to `factory-original`, installs the exact staged APK set, verifies every file, and leaves the container stopped.

It does **not** clear GMS, GSF, account data, app data, Keystore data, or Package Manager state.

### Step 4 — refresh local overlays and validate

Restart the verified local WSL/container boundary using the normal local procedure, preserving the same Docker container and data volume. Wait for `sys.boot_completed=1`.

Then run:

```bash
CONTAINER=redroid14 \
  bash /mnt/d/PROJECT/_TRASH/REDROID/integrity-debug/DW_26_1/scripts/04-validate-gms-factory.sh
```

Expected:

```text
factory GMS versionName = active GMS versionName
android.permission.PROVIDE_DEFAULT_ENABLED_CREDENTIAL_SERVICE: granted=true
existing account count preserved
```

On the tested container, factory and update both became 26.32.34, the permission became granted, and the account count remained 1.

After normal user account selection/consent, DiskWala reached Home.

---

# The final proof

The privacy-fixed probe 0.4 observed this real startup/session result:

```text
mode=OBSERVE
attest/challenge -> HTTP 200
token/refresh    -> HTTP 200
{
  "tier": "full",
  "integrityStale": false,
  "has_access": true,
  "has_refresh": true,
  "auth_values_omitted": true
}
subsequent API calls -> HTTP 200
```

Home was visible. No launch-screen override or response mock was active.

Run the privacy-safe final verifier:

```bash
CONTAINER=redroid14 \
  bash /mnt/d/PROJECT/_TRASH/REDROID/integrity-debug/DW_26_1/scripts/05-final-verify.sh
```

---

# Why we did not set `signed_in=true`

The current 26.1 APK does not have an authoritative login boolean.

Authentication storage is AndroidX EncryptedSharedPreferences:

```text
Logical file: com.diskwalaapp.auth.xml
refresh_token
attest_key_alias
dw.profile.uid / name / email / photo
```

The short-lived access token is held in memory. `diskwala.db` stores recent files, recent creators, and downloads — not authentication.

A fake/non-empty refresh-token preference might change the initial local navigation branch, but `token/refresh` still requires:

- a real server-issued refresh token;
- a valid attestation key alias;
- a fresh challenge;
- a Keystore assertion;
- backend acceptance.

A 401 causes refresh/retry and eventual session clearing. We did not edit authentication preferences, account databases, or tokens.

The older `hermes-dec-output` and partial `jadx-java-src` exports are historical React Native material. The verified 26.1 app is Compose; recreate the targeted decompile from the hash-verified current APK when debugging a new release.

---

# Response capture and middleware idea

The repository already has MITM + ADB reverse tooling under `rev-eng/network-tools`, but the local host MITM CA was not trusted by this image. Installing a CA and globally proxying a signed-in device would also capture unrelated Google/account traffic.

The custom probe therefore captured DiskWala's already-decrypted parsed response in-process. Probe 0.4:

- captures bounded JSON only;
- redacts identifiers, challenges, chains, tokens, credentials, e-mail addresses, JWTs, and opaque strings;
- stores metadata-only auth response summaries;
- does not consume the response stream.

An early 0.3 build missed fields named `access` and `refresh`. Those affected diagnostic captures/log entries were cleaned, the redactor was fixed, and tests were added. Use 0.4 or later. Rotate the app session through normal sign-out/sign-in if old diagnostics were retained or shared.

The `mock` mode supports explicitly enabled, exact client-only fixtures for `attest/verify` and `appuser/version`. It was not used for the successful setup. A fake HTTP 200 can only change client behavior; it cannot mint backend credentials or prove that the device is trusted.

---

# Reusable files moved from scratch storage

All safe authored journey scripts are now under:

```text
integrity-debug/DW_26_1/
```

Index:

```text
integrity-debug/DW_26_1/README.md
integrity-debug/DW_26_1/config/tricky-target.example.txt
integrity-debug/DW_26_1/scripts/01-add-tricky-target.sh
integrity-debug/DW_26_1/scripts/02-stage-gms-factory.sh
integrity-debug/DW_26_1/scripts/03-swap-gms-factory.sh
integrity-debug/DW_26_1/scripts/04-validate-gms-factory.sh
integrity-debug/DW_26_1/scripts/05-final-verify.sh
integrity-debug/DW_26_1/scripts/inspect-google-chooser.py
integrity-debug/DW_26_1/scripts/install-probe-system.sh
integrity-debug/DW_26_1/scripts/redact-old-diagnostics.py
```

The custom module source was already stored in the repo and is referenced rather than duplicated:

```text
rev-eng/mod_build/build_gate.sh
rev-eng/mod_build/gate/
rev-eng/modules/dw26gate.apk
```

Sensitive/transient artifacts were deliberately not moved: keyboxes, private keys, Google Play services APK copies, LSPosed DBs, manager APK backups, decoded Package Manager state, raw Android logs/captures, account/session data, and the generated full JADX tree.

---

# Rollback

## TrickyStore target

Restore the timestamped `target.txt.before-diskwala-*` backup, preserving owner/mode. Force-stop/restart DiskWala. Do not delete or publish the keybox.

## Gate probe

Disable behavior immediately:

```powershell
adb -s $d shell 'printf off > /data/local/tmp/dw26gate.mode'
adb -s $d shell am force-stop com.diskwalaapp
```

To remove it fully, disable/remove the `dw26_gate_probe` KernelSU module, restore the LSPosed configuration backup if needed, and refresh local overlays.

## GMS factory repair

Stop ReDroid, move the repaired factory directory aside, and restore:

```text
/data/adb/gms-factory-fix-*/factory-original
```

at the original GApps module path. Preserve permissions, reboot, and verify. Do not clear GMS/GSF/account data as rollback.

---

# Short repeat checklist

1. Verify the local target, Android boot state, DiskWala version/hash, and ARM translation.
2. Solve PairIP redirect: recommended Part 1 system-preload route; PairIPFix only as fallback.
3. Ensure the existing keybox/TrickyStore stack works.
4. Add `com.diskwalaapp!` to TrickyStore with backup.
5. Confirm real `attest/verify` returns HTTP 200 / `tier=full`, with probe in `observe` or `off` and mocks disabled.
6. If Google sign-in says no account, inspect Credential Manager provider errors and the GMS privileged permission.
7. If the confirmed factory/update manifest mismatch exists, run the GMS stage/swap/validate scripts.
8. Complete normal Google account selection/consent.
9. Confirm Home and real `token/refresh` HTTP 200.
10. Leave the probe in `observe` or `off`; retain rollback directories.
