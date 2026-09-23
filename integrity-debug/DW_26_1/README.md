# DiskWala 26.1 helper files and 26.2 follow-up

These are the reusable scripts produced during the DiskWala 26.1 investigation.
The narrative and verified order are in [`../../DW_26_1_part2.md`](../../DW_26_1_part2.md).
The [2026-09-23 follow-up](#2026-09-23-wsl-lsposed-repair-and-diskwala-262-retarget)
below documents the WSL LSPosed repair and the current 26.2 probe. The original
26.1 attestation/sign-in findings remain historical; they were not repeated as
part of this infrastructure repair.

Run these only against a verified local ReDroid container. Script defaults match
the tested container (`redroid14`) but can be overridden with environment variables.
The follow-up's PowerShell examples explicitly select `Ubuntu` and `redroid14`.

## What the `DW26Gate` module does

`DW26Gate` is a separate, narrowly scoped LSPosed module, originally created for
DiskWala 26.1 and now pinned to 26.2. It is not a renamed TalsecKill build and does
not modify Google Play services, Android Keystore, TrickyStore, or system-server
permission checks.

```text
APK: rev-eng/modules/dw26gate.apk
Package: com.recon.dw26gate
Version: 0.6 / versionCode 6
Target APK: DiskWala 26.2 / versionCode 353
Target process: com.diskwalaapp only
Pinned DiskWala base SHA-256:
C2BABB8419C69E1F8334425764F1DAFD1EAC9A687EA30E1C53FD98086B9CE735
Module APK SHA-256:
AC2D763BFA2355E2468C0FD9F557A1B12808FA833B62BDA6FED96B132858DE30
```

The module verifies the DiskWala base APK hash before installing any hook. An unknown
or updated APK is left untouched. Its hooks target exact 26.2 methods rather than broad
class-loading, native-library, or network-framework hooks.
The earlier v0.4/v0.5 probe targeted 26.1; do not remove the digest guard to make a
mismatched app/module pair load.

### Observed decision points

The gate/API tracing records the following without logging request credentials:

- DiskWala API transaction start/end, relative endpoint, elapsed time and HTTP status;
- the backend's allowlisted error code, such as `attestation_failed`;
- construction and classification of DiskWala's typed API exceptions;
- creation of the local unsupported-device and unusable-Android-ID exceptions;
- whether Android ID was present, recording only type/length rather than its value;
- sign-in and launch-gate state classes;
- bounded, redacted response JSON after DiskWala has already decrypted and parsed it.

During the original 26.1 investigation, the in-process response capture proved
the real transition:

```text
attest/verify -> HTTP 400 / attestation_failed  # before TrickyStore target fix
attest/verify -> HTTP 200 / ok=true, tier=full # after adding com.diskwalaapp!
```

Response records are stored in DiskWala's private cache:

```text
/data/user/0/com.diskwalaapp/cache/dw26gate-responses.jsonl
```

The gate/API response recorder, from version 0.4 onward, stores metadata only for
`login` and `token/refresh`; access tokens, refresh tokens, ID tokens, authorization
headers, challenges, certificate chains, identifiers, e-mail addresses, JWTs and
opaque values are omitted/redacted. Captures are size/depth/count bounded.
This redaction guarantee does not cover the separate
response-key oracle described next.

### Response-key oracle: sensitive output

Version 0.5 added read-only hooks on `C5.c.a(String, String)` (decrypt) and
`C5.c.b(String, String)` (encrypt). Version 0.6 retains these hooks for the verified
26.2 APK. They observe the password argument and result without changing either.
Their separate output intentionally contains raw content keys and plaintext:

```text
/data/user/0/com.diskwalaapp/cache/dw26gate-keys.jsonl
[DW26Gate][key] records in LSPosed logs
```

This oracle also runs in `observe` mode. Treat these files and log lines as sensitive
local research data, not privacy-safe response summaries; do not commit or share
them unredacted. Use `off` when no instrumentation is wanted. The repair below
verified hook installation, not an actual encrypted file-response/key capture.

### Module modes

Mode is read once when the DiskWala process starts from:

```text
/data/local/tmp/dw26gate.mode
```

| Mode | Behavior |
|---|---|
| `off` | Installs no hooks. |
| `observe` | Records the exact gate/API path and redacted response summaries, plus the separate sensitive key-oracle output described above. Used for the final diagnostic verification. |
| `local` | Replaces only the unsupported launch-screen Composable with DiskWala's existing signed-out UI. It does not change the underlying `UNSUPPORTED` state or create a session. |
| `mock` | Enables explicitly configured client-only fixtures for the exact `attest/verify` and `appuser/version` endpoints. It is disabled by default and was not used for the successful setup. |

Example:

```powershell
adb -s <verified-local-serial> shell 'printf observe > /data/local/tmp/dw26gate.mode'
adb -s <verified-local-serial> shell am force-stop com.diskwalaapp
adb -s <verified-local-serial> shell am start -n com.diskwalaapp/.app.MainActivity
```

`local` mode is a diagnostic/presentation bypass only. It can reveal **Continue with
Google**, but authentication still fails if the real server rejects attestation. The
working fix was the TrickyStore target change, not the local renderer hook.

`mock` mode requires both the mode file and an explicitly enabled
`/data/local/tmp/dw26gate-mocks.json`. It sends the real request and captures the real
response before returning any allowlisted fixture to the client. It cannot mint server
tokens or establish trust and should be used only on a disposable snapshot.

### Source, build and installation

```text
Source: rev-eng/mod_build/gate/
Build script: rev-eng/mod_build/build_gate.sh
Built artifact: rev-eng/modules/dw26gate.apk
```

Build from PowerShell at the repository root:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' 'rev-eng/mod_build/build_gate.sh'
```

The build runs 49 host-side checks (10 mode, 20 policy, 19 privacy), compiles
Java/DEX, signs the APK with the existing local module key, checks ZIP alignment
and verifies APK v2/v3 signatures. It does not overwrite `talseckill.apk`.

For the clean tested setup, the module was persisted as a KernelSU system app:

```text
/data/adb/modules/dw26_gate_probe/
  module.prop
  system/app/DW26Gate/base.apk
```

The `scripts/install-probe-system.sh` helper deploys the current APK and metadata
but leaves the container stopped; start it before enabling/scoping the probe to
only `com.diskwalaapp`, user 0, through LSPosed. If the manager is unavailable, Part 2
documents the offline, backup-first `patch_lspd.py` procedure. Keep the module in
`observe` or `off` after setup; mocks must remain disabled.

## 2026-09-23: WSL LSPosed repair and DiskWala 26.2 retarget

### Verified local environment and symptoms

This repair was performed only in WSL distro `Ubuntu`, container `redroid14`:

| Component | Verified value |
|---|---|
| Android | ReDroid 14, `zygote64_32`, x86_64 primary plus x86 secondary |
| WSL kernel | `5.15.167.4-microsoft-standard-WSL2-redroid-ksu` |
| KernelSU root version | 33223, as reported by Zygisk Next |
| LSPosed | 1.9.2 (7024); matching manager already preloaded |
| Zygisk Next | Upgraded from 1.4.3 (817-e815170) to 1.5.0 (843-5217106) |
| Android `/data` | Docker volume `local-setup_redroid14-data` |
| Observed host volume path | `/var/lib/docker/volumes/local-setup_redroid14-data/_data` |

LSPosed was reporting `System server injection fails, trying a restart`,
`system server died`, and `no response from bridge`. There were two separate issues:

1. **Zygisk Next was disabled.** `/data/adb/modules/zygisksu/disable` and
   `/data/adb/zygisksu/.abort_msg` dated from 10:55:57 UTC, before the later LSPosed
   attempts. KernelSU logged `/data/adb/modules/zygisksu is disabled, skip` and no
   Zygisk daemon was running. A system-owned `lspd` process alone did not mean
   injection was working.
2. **Experimental Zygisk hooks crashed during startup once re-enabled.** Both the
   old 1.4.3 copy and freshly downloaded 1.5.0 reproduced early `app_process32` /
   `app_process64` failures. The injector first reported `PIPE(13)`,
   `remote_post_call failed`, and `WriteProc failed` on the `exp_hook` path, followed
   by timeout/SIGSEGV and zygote retries. Upgrading alone did not fix this.

The supported `exp_hook disable` setting eliminated these startup failures. A
separate `linker system` compatibility test did **not** fix them, so the original
built-in linker was restored. Do not present the linker switch as the solution.

### Local-only recovery and official x86 installation

Before any change, verify the distro, container and `/data` mount; do not assume
these paths identify another machine's instance:

```powershell
wsl --list --verbose
wsl -d Ubuntu -u root --exec uname -r
wsl -d Ubuntu -u root --exec docker ps
wsl -d Ubuntu -u root --exec docker inspect redroid14 --format '{{json .Mounts}}'
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/ksud module list
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/modules/zygisksu/bin/zygiskd status
```

Back up the affected module directories, `/data/adb/zygisksu`, and LSPosed config/logs
before changing module state. The actual rollback archives are listed below.
The first recovery action was:

```powershell
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/ksud module enable zygisksu
if ($LASTEXITCODE -ne 0) { throw 'Failed to enable Zygisk Next' }
wsl -d Ubuntu -u root --exec docker restart redroid14
```

That restored injection, but exposed the startup crashes described above. The
subsequent download came from the official
[LSPosed/ZygiskNext 1.5.0 release](https://github.com/LSPosed/ZygiskNext/releases/tag/1.5.0),
not the historical `Dr-TSNG/ZygiskNext` URL. The
[GitHub release API](https://api.github.com/repos/LSPosed/ZygiskNext/releases/tags/1.5.0)
published the following asset and SHA-256:

```text
Zygisk-Next-1.5.0-843-5217106-release.zip
474d58abc208c0779e7f8f1d8449db755a874d475c13b9cf8decf74bc171933b
```

Download and verify from PowerShell; the temporary directory must already exist:

```powershell
$work = Join-Path $env:LOCALAPPDATA 'Temp\kilo'
if (-not (Test-Path -LiteralPath $work)) { throw 'Create a local temporary/backup directory first' }
$zip = Join-Path $work 'Zygisk-Next-1.5.0-843-5217106-release.zip'
curl.exe --fail --location --proto '=https' --tlsv1.2 --retry 2 --output $zip 'https://github.com/LSPosed/ZygiskNext/releases/download/1.5.0/Zygisk-Next-1.5.0-843-5217106-release.zip'
if ($LASTEXITCODE -ne 0) { throw 'Zygisk download failed' }
$expected = '474d58abc208c0779e7f8f1d8449db755a874d475c13b9cf8decf74bc171933b'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Release SHA-256 mismatch; do not install'
}
tar -tf $zip
```

This is a multi-architecture ZIP: it contains `bin/x86/zygiskd`,
`bin/x86_64/zygiskd`, and corresponding `lib/x86/` and `lib/x86_64/` payloads.
ELF inspection confirmed 32-bit Intel 80386 and 64-bit x86-64 binaries. KernelSU's
installer detected `Device platform: x64`, extracted **both** architecture sets,
and verified the payload hashes. There was no ARM-only ZIP substitution or manual
replacement of individual `.so` files.

```powershell
$zipWsl = (wsl -d Ubuntu -u root --exec wslpath -u $zip).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve archive path in WSL' }
wsl -d Ubuntu -u root --exec docker cp $zipWsl redroid14:/data/local/tmp/Zygisk-Next-1.5.0-843-5217106-release.zip
if ($LASTEXITCODE -ne 0) { throw 'Archive copy failed' }
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/ksud module install /data/local/tmp/Zygisk-Next-1.5.0-843-5217106-release.zip
if ($LASTEXITCODE -ne 0) { throw 'KernelSU module installation failed' }
wsl -d Ubuntu -u root --exec docker restart redroid14
```

Wait for Android boot completion, then apply the verified compatibility setting
using the installed controller, not by patching vendor binaries or boot scripts:

```powershell
wsl -d Ubuntu -u root --exec docker exec redroid14 getprop sys.boot_completed
# Continue once the value is 1.
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/modules/zygisksu/bin/zygiskd exp_hook disable
if ($LASTEXITCODE -ne 0) { throw 'Failed to disable experimental hooks' }
# Restore the original linker if the unsuccessful system-linker test was performed.
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/modules/zygisksu/bin/zygiskd linker builtin
if ($LASTEXITCODE -ne 0) { throw 'Failed to restore built-in linker' }
wsl -d Ubuntu -u root --exec docker restart redroid14
```

The setting persists as `/data/adb/zygisksu/experimental_hook` containing `0`.
Final status was `hook_mode:0`, `linker:1`, `memory_type:0`; normal Zygisk/LSPosed
injection remains enabled. Container restarts were sufficient with the correct KSU
kernel already running. No full WSL shutdown, container recreation, LSPosed upgrade,
scope-database patch, account/data wipe, or VPS change was needed.

Use `wsl ... --exec docker exec ...` for these commands. Localhost ADB forwarding
had been unreliable after earlier WSL termination, and `--exec` avoids an extra
Linux-shell parsing layer for quoted arguments, `$` variables and regex pipes.

### Retargeting and deploying the probe

After injection recovered, the old v0.5 probe correctly refused the installed 26.2
APK with `SKIP: APK digest does not match tested 26.1; no hooks installed`. This was
the probe's version guard, not another LSPosed failure.

The 26.2 base APK in `rev-eng/apk-extractor/target-apk/DiskWala_26_2_extracted/`
and the installed `/system/app/DiskWala/base.apk` had the same hash shown in the
current module metadata above. The actual 26.2 DEX was inspected, including the raw
`E5`, `B5`, `O5` gate signatures and `C5.c.a/b(String, String)` methods; JADX's
case-insensitive aliases were not substituted for runtime class names.

Changes were limited to the probe's target constants/hash, version metadata,
target-specific logs/comments and policy tests. The manifest and KernelSU
`module.prop` were bumped to v0.6 / code 6. The exact-APK guard, package/process
scope, existing signing key and `observe` behavior were retained; no Google tokens,
Keystore state, real server responses or app APK signatures were changed.

After building with `rev-eng/mod_build/build_gate.sh`, deployment used a temporary
KernelSU ZIP containing exactly:

```text
module.prop                         # rev-eng/mod_build/gate/module.prop
system/app/DW26Gate/base.apk         # rev-eng/modules/dw26gate.apk
```

The package was saved as `%LOCALAPPDATA%\Temp\kilo\dw26gate-0.6-diskwala26.2-system.zip`,
copied to `/data/local/tmp/`, and installed through the same supported module API:

```powershell
# Run from the repository root, using the existing $work directory above.
$probeZip = Join-Path $work 'dw26gate-0.6-diskwala26.2-system.zip'
python.exe -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED); z.write(sys.argv[2],"module.prop"); z.write(sys.argv[3],"system/app/DW26Gate/base.apk"); z.close()' $probeZip 'rev-eng/mod_build/gate/module.prop' 'rev-eng/modules/dw26gate.apk'
if ($LASTEXITCODE -ne 0) { throw 'Probe packaging failed' }
$probeZipWsl = (wsl -d Ubuntu -u root --exec wslpath -u $probeZip).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve probe archive path in WSL' }
wsl -d Ubuntu -u root --exec docker cp $probeZipWsl redroid14:/data/local/tmp/dw26gate-0.6-diskwala26.2-system.zip
if ($LASTEXITCODE -ne 0) { throw 'Probe archive copy failed' }
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/ksud module install /data/local/tmp/dw26gate-0.6-diskwala26.2-system.zip
if ($LASTEXITCODE -ne 0) { throw 'Probe module installation failed' }
wsl -d Ubuntu -u root --exec docker restart redroid14
# After sys.boot_completed returns 1:
wsl -d Ubuntu -u root --exec docker exec redroid14 am start -W -n com.diskwalaapp/.app.MainActivity
```

The existing LSPosed scope was preserved: `com.recon.dw26gate` enabled only for
`com.diskwalaapp`, user 0. The mounted module APK hash matched the rebuilt artifact,
and Package Manager reported version 0.6 / code 6.

### Acceptance checks and results (14:28–14:37 UTC)

The results below were recorded during the repair on 2026-09-23, ending with the
14:37 UTC verification boot. On any later check, wait for boot completion and
inspect the **current boot**, not `log.old` or an older successful process:

A check before the daemon starts can report `failed to connect to server` together
with a cached `Last injection failed!`. The old `.abort_msg` retained its 10:55 UTC
timestamp even after successful recovery. Do not treat that file alone as a new
failure: check module enablement, boot completion, live status and fresh logs.

```powershell
wsl -d Ubuntu -u root --exec docker exec redroid14 getprop sys.boot_completed
wsl -d Ubuntu -u root --exec docker exec redroid14 /data/adb/modules/zygisksu/bin/zygiskd status
wsl -d Ubuntu -u root --exec docker exec redroid14 ps -A -o USER,PID,PPID,NAME
wsl -d Ubuntu -u root --exec docker exec redroid14 /system/bin/sh -c '/data/adb/ksu/bin/busybox grep -E "binder received|System server injection fails|system server died|Fatal signal 11" /data/adb/lspd/log/verbose_*.log'
wsl -d Ubuntu -u root --exec docker exec redroid14 /system/bin/sh -c '/data/adb/ksu/bin/busybox grep -E "target=|key oracle.*installed|ACTIVE hooks=|SKIP:|PROBE_ERROR" /data/adb/lspd/log/modules_*.log'
```

Verified results:

- Zygisk Next `1.5.0-843-5217106-release`, `inject_state:1`, both x86 zygotes
  successful, `modules64:1,zygisk_lsposed`, `modules32:1,zygisk_lsposed`, and
  `modules_with_issue:0`.
- `lspd` owned by Android `system` / UID 1000 **and** a current-boot
  `LSPosed Bridge ... binder received` record. In this 1.9.2 build the daemon's
  bridge receipt is in `verbose_*.log`; module loads use `LSPosed-Bridge` in
  `modules_*.log`. Do not require the bridge receipt to appear in the module log.
- LSPosed Manager displayed **Activated — 1.9.2 (7024) - Zygisk**.
- Repeated container boots had no Zygisk `SIGSEGV`, system-server injection failure
  or LSPosed restart loop. Both post-deployment DiskWala cold launches returned
  `Status: ok`, with the process remaining alive.
- All 49 host-side checks passed; APK v2/v3 signatures and ZIP alignment verified.
- Current-boot probe records confirmed:

  ```text
  mode=OBSERVE target=26.2/353
  C5.c key oracle installed (26.2 content keys -> cache/dw26gate-keys.jsonl)
  ACTIVE hooks=12 digest=verified tokens=untouched bodyCapture=redacted
  ```

Actual encrypted file-response/key capture and a new end-to-end sign-in/attestation
test were **not** performed. The existing **Dex Optimizer Wrapper: Unsupported
(SELinux is permissive)** notice is separate from activation; SELinux was not
changed. LSPosed 1.9.2 has no `--system-server-max-retry` option, so the older
1.11-specific `3 -> 60` retry patch is not applicable.

### Rollback material

The following archives were saved under `%LOCALAPPDATA%\Temp\kilo` before changes:

- `wsl-lsposed-before-20260923T141700.tar.gz`: the old `zygisksu` and
  `zygisk_lsposed` modules, Zygisk state, and LSPosed config/logs.
- `dw26gate-before-26.2-20260923.tar.gz`: the previous v0.5 probe overlay and metadata.

These are local, potentially sensitive rollback artifacts, not repository files.
If rollback is required, stop the verified local container before restoring the
selected paths into its verified `/data` volume, then restart and revalidate.
The first archive includes the original disabled Zygisk state: restoring it is a
rollback, not a repaired configuration. The v0.5 probe remains pinned to 26.1.

## Complete setup elsewhere — historical 26.1 short version

The following is the original 26.1 workflow. Match the app and probe versions;
the current v0.6 artifact above is pinned to 26.2 and will not hook a 26.1 APK.

On another x86_64 ReDroid 14 container, first reproduce Part 1: verify
`libndk_translation`, install/preload the complete signed DiskWala 26.1 split set, and
configure a working TrickyStore/keybox without committing the keybox. Then run
`01-add-tricky-target.sh` so DiskWala's own Keystore chain is covered, and confirm the
real `attest/verify` becomes HTTP 200 with mocks/UI override disabled. Install the
version-pinned probe only if diagnostics are needed. If Google sign-in still says no
account while Account Manager has one, confirm the exact denied Credential Manager
permission/factory-versus-update GMS mismatch, then run the stage/swap/validate scripts
to promote the complete same-signed active GMS set to the factory directory without
clearing GMS, GSF, accounts or Keystore data. Complete normal user account consent and
run `05-final-verify.sh`; success means Home plus a genuine HTTP 200 token refresh, not
merely disappearance of the launch wall.

## Recommended order (original 26.1 investigation)

1. `scripts/01-add-tricky-target.sh` — add `com.diskwalaapp!` to the existing
   TrickyStore target list, with rollback.
2. Confirm real `attest/verify` succeeds. The optional probe source is at
   [`../../rev-eng/mod_build/gate`](../../rev-eng/mod_build/gate), built by
   [`../../rev-eng/mod_build/build_gate.sh`](../../rev-eng/mod_build/build_gate.sh).
3. Only if Google Credential Manager rejects GMS as an invalid system provider:
   - `scripts/02-stage-gms-factory.sh`
   - `scripts/03-swap-gms-factory.sh`
   - restart the local WSL/container boundary
   - `scripts/04-validate-gms-factory.sh`
4. `scripts/05-final-verify.sh` — confirm a real successful refresh with privacy-safe logs.

## Additional utilities

- `scripts/inspect-google-chooser.py` — inspect or open the Google account chooser
  without selecting an account.
- `scripts/install-probe-system.sh` — persist the built probe as a KernelSU system app.
- `scripts/redact-old-diagnostics.py` — one-time cleanup for affected old probe logs.
- `config/tricky-target.example.txt` — example only; merge with an existing target list,
  never replace it blindly.
- `config/diskwala-system-module.prop` — metadata used by Part 1's optional
  DiskWala system-preload KernelSU overlay.

## Intentionally not copied from scratch storage

The following are transient, instance-specific, sensitive, or large and must not be
committed as journey artifacts:

- keyboxes or private keys;
- Google Play services APK backups;
- LSPosed SQLite databases;
- decoded `packages.xml` state;
- manager APK backups;
- Android logs, packet captures, account/session data, access or refresh tokens;
- key-oracle JSONL/log output, recovered content keys and unredacted plaintext;
- the generated full JADX tree (recreate it from the verified APK hash when needed).

All scripts fail on unexpected paths or incomplete state. Keep the generated rollback
directories until the repaired container has been validated.
