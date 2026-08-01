# Follow-up fixes: Redroid Play compatibility, integrity, and Target-App acceptance

Date range: 2026-07-29 through 2026-08-02  
Target: Android 14 ARM64 Redroid with KernelSU  
Container: `redroid14-ksu`  
Target application alias: **Target-App**  
Target package placeholder: `<TARGET_PACKAGE>`

This document records the work performed after the original PairIP/Talsec
investigation in docs 01–04. It covers the complete progression from a generic
Redroid device that Play Store considered incompatible to:

- a coherent Pixel 5-style Android identity;
- access to Play Store listings that were previously restricted;
- a genuine Google Play installation of Target-App;
- Basic, Device, and Strong Play Integrity labels in a Play-installed checker;
- a stable Target-App process despite PairIP and Talsec reactions; and
- an accepted protected Target-App initialization request with HTTP 200.

The final Target-App fix was **not** Strong Integrity by itself. The decisive gate
was the set of per-check `OK`/`NOK` values embedded in the AppiCrypt cryptogram.
Every local `NOK` had to be converted to `OK` before the genuine native signer
created the cryptogram.

No SSH key, Google credential, Play bearer token, Play Integrity token,
AppiCrypt cryptogram, authorization value, keybox private key, session token, or
native vault secret is reproduced here.

## 1. Outcome summary

| Milestone | Before | Final result |
| --- | --- | --- |
| Device identity | Generic Redroid/userdebug/test-keys | Coherent Pixel 5 Android 14 global profile |
| Play Store catalog | Restricted apps unavailable or shown only on other devices | Previously restricted listings became installable |
| Target-App installation | Sideloaded; shell remained initiating package | Installed directly by Google Play; installer and initiator both Play Store |
| Play Integrity checker | Initially unevaluated, then Basic/Device only | Basic, Device, and Strong all passed under TEESimulator-RS |
| PairIP | Redirect/license exit | PairIPFix loaded and scoped through LSPosed |
| Talsec process reaction | Security alert and delayed native SIGKILL | Threat channels desynchronised and all self-kill paths guarded |
| AppiCrypt checks | `privilegedAccess`, `hooks`, and `adbEnabled` remained `NOK` | Every `NOK` changed to `OK` before native signing |
| Protected Target-App request | Persistent `403 Forbidden` | HTTP 200 with the expected encrypted success envelope, reproduced twice |

App-specific captures remain in the private capture store. They are intentionally
not named here so this guide remains reusable and does not expose target-specific
API naming or evidence paths.

## 2. Final component stack

| Component | Version/state | Repository |
| --- | --- | --- |
| KernelSU | Existing Redroid image; version code 33223 during TEESimulator installation | Image-specific |
| LiteGApps | v4.9, Android 14 ARM64 | https://github.com/litegapps/litegapps |
| Zygisk Next | 1.4.3 (`817-e815170-release`) | https://github.com/Dr-TSNG/ZygiskNext |
| LSPosed | Runtime reported v1.9.2 (7024) | https://github.com/JingMatrix/LSPosed |
| Play Integrity Fix | Customized KOWX712 v4.7-1 `inject_s` package | https://github.com/KOWX712/PlayIntegrityFix |
| Tricky Store | v1.4.1 during the Play compatibility and first keybox tests | https://github.com/5ec1cff/TrickyStore |
| TEESimulator-RS | v6.0.1-282; replaced Tricky Store for the final integrity test | https://github.com/Enginex0/TEESimulator-RS |
| PairIPFix | v1.2 LSPosed APK | https://github.com/ahmedmani/pairipfix |
| TalsecKill | Locally built LSPosed APK | `rev-eng/mod_build/` |
| Zygisk Assistant | Installed but disabled | https://github.com/snake-4/Zygisk-Assistant |

Important: TEESimulator-RS and Tricky Store both use module ID `tricky_store`.
They replace one another and must not be treated as simultaneously active.

## 3. Establish the base connection and module stack

Use placeholders for the private SSH key and VPS address:

```powershell
$SshKey = "<SSH_KEY>"
$VpsHost = "<VPS_HOST>"
$Remote = "ubuntu@$VpsHost"
$AdbSerial = "127.0.0.1:5555"
$Container = "redroid14-ksu"
$TargetPackage = "<TARGET_PACKAGE>"
$TargetActivity = "<TARGET_PACKAGE>/.MainActivity"
```

Keep the ADB tunnel running in one PowerShell window:

```powershell
ssh -i $SshKey `
  -o StrictHostKeyChecking=no `
  -o ExitOnForwardFailure=yes `
  -o ServerAliveInterval=30 `
  -N `
  -L 127.0.0.1:5555:127.0.0.1:5555 `
  $Remote
```

Connect from another window:

```powershell
adb disconnect $AdbSerial
adb connect $AdbSerial
adb -s $AdbSerial wait-for-device
adb -s $AdbSerial shell getprop sys.boot_completed
```

The base order was:

1. KernelSU-enabled Redroid image.
2. LiteGApps for Android 14 ARM64.
3. Zygisk Next.
4. LSPosed.
5. Full VPS reboot.
6. Verify Play Store and Google Play Services.

Install KernelSU modules by pushing the ZIP and invoking `ksud` inside the
container:

```powershell
adb -s $AdbSerial push ".\module.zip" /data/local/tmp/module.zip

ssh -i $SshKey -o StrictHostKeyChecking=no $Remote `
  "sudo docker exec $Container /data/adb/ksud module install /data/local/tmp/module.zip"
```

After KernelSU/Zygisk/module changes, reboot the **complete VPS**:

```powershell
ssh -i $SshKey -o StrictHostKeyChecking=no $Remote "sudo reboot"
```

A Docker-only restart was not sufficient. It restarted Android userspace but
did not reliably re-arm the KernelSU kernel trigger, so `zygiskd`, LSPosed, and
the scoped hooks could remain absent.

## 4. Make Redroid present a coherent Pixel profile

### 4.1 Why simple per-app spoofing failed

The original Play Store symptoms included:

```text
This app won't work for your device
Available only for your other devices
This app was not installed from Google Play
Device is not certified
```

Injecting fake `Build` values into only the Play Store process did not change
catalog eligibility. Play's device catalog is tied to the profile registered by
Google Services Framework, not only values visible to the current Play Store
UI process.

The final solution therefore used both:

- a scoped Play Integrity/DroidGuard profile; and
- a coherent global Pixel 5 identity applied before GSF startup.

### 4.2 Final Play Integrity Fix repository

The retained PIF base was the `inject_s` branch of:

```text
https://github.com/KOWX712/PlayIntegrityFix
```

Clone command used during development:

```powershell
git clone --branch inject_s --single-branch --recursive `
  https://github.com/KOWX712/PlayIntegrityFix.git `
  rev-eng/PlayIntegrityFix-KOWX712
```

An earlier `jyotidwi/PlayIntegrityFix` 15.9.9 experiment changed some properties
but did not make Target-App installable. `osm0sis/PlayIntegrityFork` was also
reviewed but was not the final deployed module.

### 4.3 Fix absent-property handling

Upstream `resetprop_if_diff()` skipped properties that did not already exist.
Redroid omits several verified-boot properties entirely, so the module never
created them.

The helper was changed from:

```sh
[ -z "$CURRENT" ] || [ "$CURRENT" = "$EXPECTED" ] || resetprop -n "$NAME" "$EXPECTED"
```

to:

```sh
[ "$CURRENT" = "$EXPECTED" ] || resetprop -n "$NAME" "$EXPECTED"
```

This allowed the module to create missing identity and boot-state properties.

### 4.4 Scoped PIF profile

The final `pif.prop` used a current Google profile for the scoped integrity
path:

```properties
FINGERPRINT=google/oriole_beta/oriole:CANARY/ZP11.260618.005/15760424:user/release-keys
MANUFACTURER=Google
MODEL=Pixel 6
SECURITY_PATCH=2026-07-05
spoofBuild=true
spoofProps=false
spoofProvider=false
spoofSignature=true
spoofVendingBuild=true
spoofVendingSdk=false
DEBUG=false
```

`spoofVendingSdk=false` was intentional. Forcing an older SDK can make Play
Store deliver the wrong APK variant or break updates.

### 4.5 Global Pixel 5 profile

The global profile was added to PIF's `post-fs-data.sh` so GSF registered a
coherent Android 14 Pixel identity:

```sh
FINGERPRINT="google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys"
DESCRIPTION="redfin-user 14 UP1A.231105.001.B2 11260668 release-keys"

resetprop_if_diff ro.build.fingerprint "$FINGERPRINT"
resetprop_if_diff ro.system.build.fingerprint "$FINGERPRINT"
resetprop_if_diff ro.system_ext.build.fingerprint "$FINGERPRINT"
resetprop_if_diff ro.product.build.fingerprint "$FINGERPRINT"
resetprop_if_diff ro.vendor.build.fingerprint "$FINGERPRINT"
resetprop_if_diff ro.odm.build.fingerprint "$FINGERPRINT"
resetprop_if_diff ro.build.description "$DESCRIPTION"
resetprop_if_diff ro.build.id UP1A.231105.001.B2
resetprop_if_diff ro.build.product redfin
resetprop_if_diff ro.product.brand google
resetprop_if_diff ro.product.manufacturer Google
resetprop_if_diff ro.product.model "Pixel 5"
resetprop_if_diff ro.product.name redfin
resetprop_if_diff ro.product.device redfin
resetprop_if_diff ro.product.first_api_level 30
resetprop_if_diff ro.board.first_api_level 30
```

The resulting visible values included:

```text
model=Pixel 5
device=redfin
build.type=user
build.tags=release-keys
verifiedbootstate=green
flash.locked=1
```

The module also enforced hardened-facing values such as `ro.secure=1` and
`ro.debuggable=0`. This removed root ADB and required later privileged commands
to use `sudo docker exec` from the VPS.

`ro.hardware` was deliberately **not** changed. Spoofing that property can make
Android load HALs that do not exist in Redroid. The actual container SELinux
state also remained `Disabled`; an `enforcing` property is not a real kernel
policy.

### 4.6 Repackage with Linux line endings

The first customized PIF install failed because Windows CRLF reached shell
scripts consumed by KernelSU. The official release binaries were retained while
the reviewed scripts/property file were replaced, all scripts were normalized
to LF/UTF-8 without BOM, and the ZIP was rebuilt.

Verified archives:

```text
PlayIntegrityFix_v4.7-1-inject-s.zip
SHA-256 10eec591735cafee437332871443a2fadf6632b1a58abb16fe2461d9df100ab1

PlayIntegrityFix_v4.7-1-redroid.zip
SHA-256 e46b76c010875920532658b29ed378a7fe84645fe02d1af55225580ae4b8f6de
```

Install the customized archive with `ksud`, then fully reboot.

## 5. Tricky Store and the first keybox test

### 5.1 Install Tricky Store

The first attestation layer was:

```text
https://github.com/5ec1cff/TrickyStore
Tricky Store v1.4.1
SHA-256 2f5e73fcba0e4e43b6e96b38f333cbe394873e3a81cf8fe1b831c2fbd6c46ea9
```

Initial configuration:

```text
/data/adb/tricky_store/target.txt
  com.android.vending
  com.google.android.gms!

/data/adb/tricky_store/security_patch.txt
  system=202607
  boot=2026-07-05
  vendor=2026-07-05
```

The `!` suffix used Tricky Store's generated-certificate handling for GMS in the
TEE-less Redroid environment.

### 5.2 Disable Zygisk Assistant

Zygisk Assistant was tested as an additional hiding layer:

```text
https://github.com/snake-4/Zygisk-Assistant
```

On this image it caused `com.google.process.gservices` to crash repeatedly,
probably because it unmounted systemless LiteGApps resources from GSF. It was
left installed but disabled:

```powershell
ssh -i $SshKey -o StrictHostKeyChecking=no $Remote `
  "sudo docker exec $Container /data/adb/ksud module disable zygisk-assistant"

ssh -i $SshKey -o StrictHostKeyChecking=no $Remote "sudo reboot"
```

### 5.3 Reset and register GSF under the Pixel profile

After the Pixel 5 global profile was active:

```powershell
adb -s $AdbSerial shell am force-stop $TargetPackage
adb -s $AdbSerial shell pm clear com.google.android.gsf
adb -s $AdbSerial shell pm clear com.android.vending
ssh -i $SshKey -o StrictHostKeyChecking=no $Remote "sudo reboot"
```

Clearing GSF creates a new decimal GSF Android ID. The local Android `sqlite3`
binary crashed in this hardened environment, so `gservices.db` was copied to
the VPS/Windows host and queried with host `sqlite3`:

```sql
SELECT value FROM main WHERE name='android_id';
```

That newly generated decimal ID was registered at:

```text
https://www.google.com/android/uncertified/
```

The old ID must not be reused after another GSF clear.

### 5.4 Play Store compatibility result

After the customized KOWX712 PIF, Tricky Store, global Pixel 5 profile, GSF
reset/registration, and full reboot, Play Store changed from an incompatible
listing to an enabled **Install** button. This also made other previously
restricted catalog entries available on the Redroid device.

The capture proxy had to be cleared before opening Play Store because stale
global proxy keys caused Cronet `ERR_PROXY_CONNECTION_FAILED`:

```powershell
adb -s $AdbSerial shell settings put global http_proxy :0
adb -s $AdbSerial shell settings delete global global_http_proxy_host
adb -s $AdbSerial shell settings delete global global_http_proxy_port
adb -s $AdbSerial shell settings delete global global_http_proxy_exclusion_list
adb -s $AdbSerial shell settings delete global global_proxy_pac_url
adb -s $AdbSerial reverse --remove tcp:8080
```

Target-App was then installed through the Play Store UI, not sideloaded and not
with `pm install -i`.

Verified package state:

```text
versionCode=<PLAY_VERSION_CODE>
versionName=<PLAY_VERSION_NAME>
installerPackageName=com.android.vending
initiatingPackageName=com.android.vending
```

This distinction matters: `pm install -i com.android.vending` changed only the
installer label while `InstallSourceInfo` still exposed `com.android.shell` as
the initiator.

### 5.5 Internet/Telegram keybox

A third-party `keybox.xml` obtained from a public Internet/Telegram source was
tested next. It contained private attestation keys and was treated as sensitive,
untrusted, and potentially revocable. The document records the procedure, not
the private key contents.

Tested SHA-256:

```text
5c9ba17bc4f6ef2b746c82875c53481cb1217cd0bfd5901543af31ad593da3f8
```

Install with restrictive permissions:

```powershell
scp -i $SshKey -o StrictHostKeyChecking=no `
  ".\keybox.xml" `
  "${Remote}:/tmp/redroid-keybox.xml"

ssh -i $SshKey -o StrictHostKeyChecking=no $Remote `
  "chmod 600 /tmp/redroid-keybox.xml; sudo docker cp /tmp/redroid-keybox.xml ${Container}:/data/adb/tricky_store/keybox.xml; sudo docker exec $Container sh -c 'chown 0:0 /data/adb/tricky_store/keybox.xml; chmod 600 /data/adb/tricky_store/keybox.xml'; rm -f /tmp/redroid-keybox.xml; sudo reboot"
```

At test time, its distinct certificate serials were not listed in Google's
published Android attestation status list. Absence from that list was not proof
of acceptance.

With Tricky Store and this keybox, the Play-installed checker reported:

```text
PLAY_RECOGNIZED
LICENSED
MEETS_BASIC_INTEGRITY
MEETS_DEVICE_INTEGRITY
MEETS_STRONG_INTEGRITY: fail
Play Protect: NO_ISSUES
recentDeviceActivity: UNEVALUATED
```

Target-App still returned HTTP 403. Device Integrity alone was therefore not the
remaining protected-request gate.

## 6. Replace Tricky Store with TEESimulator-RS

### 6.1 Why this module was selected

Repository:

```text
https://github.com/Enginex0/TEESimulator-RS
```

Release used:

```text
TEESimulator-RS-v6.0.1-282-Release.zip
SHA-256 4cde854bdc6add7a3f587dae24d3cefff519206716b2d0dea7ff4c2772bb86ef
```

TEESimulator-RS was reviewable and explicitly supports Android 10+, ARM64, and
KernelSU. It intercepts Keystore2 Binder traffic and generates attestation
certificate chains from the configured keybox.

`sarhan00/Strong-Integrity-Fix` v1.2 was reviewed but not installed. It would
overwrite the existing `playintegrityfix` module, delete/rebuild Tricky Store
state, install a public shared keybox, broadly target packages, clear Play Store
data, and run additional privileged scripts without reproducible source.

`PerformanC/ReZygisk` was also reviewed but not installed. Replacing the stable
Zygisk Next provider provided no direct attestation benefit and risked the
working LSPosed injection chain. ReZygisk and Zygisk Next must never run at the
same time.

### 6.2 Back up Tricky Store before replacement

The module directory and `/data/adb/tricky_store` were archived on the VPS with
mode 600 because the archive includes private key material:

```text
/home/ubuntu/redroid-backups/teesim-test-20260801T115805Z/tricky-state.tgz
SHA-256 4eea3951b14c544996f63a5b984412caebf9914d80391b44c5fd49587eb5a3dc
```

### 6.3 Install TEESimulator-RS

TEESimulator-RS intentionally uses module ID `tricky_store`, so it replaced
Tricky Store in place:

```powershell
$TeeZip = "$env:LOCALAPPDATA\Temp\kilo\TEESimulator-RS-v6.0.1-282-Release.zip"

Invoke-WebRequest `
  -Uri "https://github.com/Enginex0/TEESimulator-RS/releases/download/v6.0.1-282/TEESimulator-RS-v6.0.1-282-Release.zip" `
  -OutFile $TeeZip

Get-FileHash -Algorithm SHA256 $TeeZip
adb -s $AdbSerial push $TeeZip /data/local/tmp/TEESimulator-RS-v6.0.1-282-Release.zip

ssh -i $SshKey -o StrictHostKeyChecking=no $Remote `
  "sudo docker exec $Container /data/adb/ksud module install /data/local/tmp/TEESimulator-RS-v6.0.1-282-Release.zip"
```

The existing keybox and patch file were retained. TEESimulator also generated a
device-local 32-byte `hbk` seed.

### 6.4 Correct TEESimulator target semantics

In TEESimulator, `!` means force **software** key generation. The previous
Tricky Store `com.google.android.gms!` entry was therefore not reused.

Final targets:

```text
com.android.vending
com.google.android.gms
gr.nikolasspyr.integritycheck
<TARGET_PACKAGE>
```

After writing `target.txt`, the complete VPS was rebooted.

Successful startup evidence included:

```text
Successfully loaded 4 package configurations
Binder interception initialized successfully
Found TEE SecurityLevel
Interceptors initialized successfully
TEE functionality check successful
NativeCertGen loaded libcertgen.so
Finished parsing, found 2 valid keys
```

The device still logged `No StrongBox Keymint available`,
`HARDWARE_TYPE_UNAVAILABLE`, and failure to intercept a real StrongBox security
level. TEESimulator produced a server-accepted simulated attestation chain; it
did **not** turn Redroid into real certified hardware.

### 6.5 All three integrity labels passed

One controlled request in the Play-installed Play Integrity API Checker v2.2/22
returned:

```text
PLAY_RECOGNIZED
LICENSED
MEETS_BASIC_INTEGRITY
MEETS_DEVICE_INTEGRITY
MEETS_STRONG_INTEGRITY
Play Protect: NO_ISSUES
deviceAttributes.sdkVersion: 34
recentDeviceActivity: UNEVALUATED
appsDetected: KNOWN_INSTALLED, UNKNOWN_INSTALLED
```

This proved that the checker's backend accepted the generated attestation at
that time. It did not prove that every app/project would receive identical
labels or that the public keybox would remain valid.

TEESimulator also touched ordinary Keystore2 operations and produced one Google
Pay `Signature/MAC verification failed` boot error. The configuration remains
experimental for Wallet, banking, work-profile, and lock-screen use.

## 7. Strong Integrity still did not fix Target-App

Target-App was captured again while the separate checker passed all three labels.
The result was still:

```text
POST /fdfe/integrity                          HTTP 200
Target-App protected initialization request  HTTP 403 Forbidden
integrityToken                               present
integrityTs                                  present
crypt header                                 present
ck header                                    absent
token response to backend request            approximately 0.618 seconds
```

This ruled out the broad theory that missing Strong Integrity was the sole
protected-request problem. The remaining independent proof was AppiCrypt's
signed local check set.

## 8. Keep PairIPFix and TalsecKill loaded

After every fresh Target-App install, reinstall/re-scope both LSPosed modules
before launching the app.

PairIPFix package:

```text
io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
```

TalsecKill package:

```text
com.recon.talsecbypass
```

Build and install:

```powershell
adb -s $AdbSerial install -r "rev-eng\modules\pairipfix.apk"
adb -s $AdbSerial install -r "rev-eng\modules\pairipfix.apk"

& "C:\Program Files\Git\bin\bash.exe" rev-eng/mod_build/build_module.sh
adb -s $AdbSerial install -r "rev-eng\modules\talseckill.apk"
```

LSPosed must show both modules enabled and scoped to `<TARGET_PACKAGE>` user 0.
Every APK reinstall can produce a new randomized `/data/app/.../base.apk` path;
the `modules.apk_path` field must match `pm path`.

The container's Android `sqlite3` binary could core-dump after hardening. The
safe repair path was:

1. Stop or freeze LSPosed's database writer.
2. Copy `modules_config.db` to the VPS/Windows host.
3. Update `enabled`, `apk_path`, and `scope` with host Python/SQLite.
4. Copy it back as root with mode 600.
5. Remove stale WAL/SHM only while the writer is stopped.
6. Fully reboot the VPS.

Expected evidence:

```text
[PairIPFix] 4/4 hooks applied
[TalsecKill] loaded in <TARGET_PACKAGE>
[TalsecKill] AppiCrypt pre-signing JSON schema hook installed
[TalsecKill] FNatives.z metadata probe installed
[TalsecKill] FNatives.x native self-kill guard installed
```

## 9. Resolve the Talsec/freeRASP process reactions

The custom module had to solve several independent reactions:

### 9.1 Threat-channel desynchronization

The native SDK used randomized React Native event channels. Returning dead
channel names from both `getThreatChannelData` and
`getRaspExecutionStateChannelData` prevented the JS layer from receiving and
re-rendering the detected threats.

### 9.2 Java/UI reaction guards

The module guarded only self-targeted teardown paths, including:

- `System.exit`;
- `Process.killProcess` and `killProcessQuiet`;
- `Process.sendSignal` and `sendSignalQuiet`;
- activity finish/move-to-back methods; and
- `AppTask.finishAndRemoveTask`.

### 9.3 Native self-kill

Host-kernel tracing proved the final delayed death was:

```text
Handler delay (~8 seconds)
  -> androidx.security.FNatives.x(int)
  -> getpid()
  -> kill(pid, SIGKILL)
```

Hooking `FNatives.x(int)` before JNI prevented that self-kill. `FNatives.y()` and
`FNatives.z()` were deliberately left active because they participate in native
initialization and AppiCrypt signing.

## 10. The final AppiCrypt gate

### 10.1 Why the earlier two-field fix was insufficient

An earlier application generation changed only:

```text
unofficialStore: NOK -> OK
privilegedAccess: NOK -> OK
```

That was sufficient to move the older integrity gate from 403 to a downstream
404/session lookup.

The later genuine Play-installed protected flow was different:

- `unofficialStore` was already `OK`;
- the selective hook changed `privilegedAccess` to `OK`;
- `hooks` remained `NOK` because LSPosed/Xposed was visible; and
- `adbEnabled` remained `NOK` because ADB was enabled.

The native `FNatives.z()` signer then embedded those remaining `NOK` states in
the AppiCrypt cryptogram. The server independently verified the cryptogram and
returned 403 even while Play Integrity displayed Basic, Device, and Strong.

### 10.2 Blanket pre-signing mutation

The decisive implementation is in:

```text
rev-eng/mod_build/src/com/recon/talsecbypass/Hook.java
```

Final toggle:

```java
private static final boolean SPOOF_ALL_NOK_CHECKS = true;
```

Immediately before `JSONObject.toString()` supplies the checks object to the
native signer, the hook:

1. finds the `checks` sub-object;
2. iterates every check key;
3. reads each nested `status`;
4. converts every `NOK` to `OK`; and
5. leaves the genuine `FNatives.z()` call active.

Equivalent logic:

```java
Iterator<?> keys = checks.keys();
while (keys.hasNext()) {
    String name = String.valueOf(keys.next());
    JSONObject check = checks.optJSONObject(name);
    if (check != null && "NOK".equals(check.optString("status"))) {
        check.put("status", "OK");
    }
}
```

Observed mutations on the successful Target-App launch included:

```text
privilegedAccess NOK -> OK
hooks NOK -> OK
adbEnabled NOK -> OK
```

Other relevant checks were already clean:

```text
simulator=OK
appIntegrity=OK
accessibility=OK
```

The signer evidence then showed no remaining threat names at signing/return,
and the genuine native signer produced the cryptogram normally.

### 10.3 Proven result

With the blanket mutation, threat-channel desync, reaction guards, and working
LSPosed scope:

```text
Target-App protected initialization request -> HTTP 200
response shape -> expected encrypted success envelope
```

Two consecutive cold launches produced HTTP 200. The device tuple still
contained an empty MediaDrm identifier, and `recentDeviceActivity` remained
`UNEVALUATED`; neither hard-gated the protected request once the AppiCrypt check
set was clean.

## 11. Capture and verify the final HTTP 200

Clear stale proxy state, then run:

```powershell
python -u ".\rev-eng\network-tools\capture-live-networks.py" `
  --serial $AdbSerial `
  --name target-app-follow-up
```

In another window:

```powershell
adb -s $AdbSerial shell am force-stop $TargetPackage
adb -s $AdbSerial shell am start -W -n $TargetActivity
```

Verify only safe metadata. Do not print request headers/bodies or successful
response bodies because they can contain tokens or encrypted session material.

Expected safe result:

```text
/fdfe/integrity                         HTTP 200
Target-App protected initialization    HTTP 200
response                               expected encrypted success envelope
```

The accepted capture remains in the private capture store.

## 12. Obstacles and their solutions

| Obstacle | Symptom/root cause | Working solution |
| --- | --- | --- |
| Sideloaded app was not a genuine Play transaction | Installer label could be spoofed, but initiating package remained shell | Fix Play catalog eligibility and install directly from Play Store |
| Restricted Play Store apps unavailable | Generic Redroid/GSF catalog identity | Apply coherent global Pixel 5 profile, reset GSF, register new GSF ID |
| Per-app Build spoof ineffective | Catalog profile is tied to GSF registration | Apply identity before GSF startup, not only inside Play Store |
| First PIF fork insufficient | Old profile/module behavior did not unlock listing | Use customized KOWX712 `inject_s` v4.7-1 |
| Missing boot properties stayed empty | Upstream helper skipped absent values | Patch `resetprop_if_diff()` to create absent properties |
| PIF install syntax error | Windows CRLF in module scripts | Normalize scripts/properties to LF and UTF-8 without BOM |
| Zygisk Assistant broke GSF | It unmounted LiteGApps resources from GSF | Disable Zygisk Assistant and fully reboot |
| Play Store proxy failure | Interrupted capture left separate global proxy keys | Delete every proxy key and remove ADB reverse |
| ADB stopped being root | Hardened `ro.secure=1`, `ro.debuggable=0` | Use `sudo docker exec` for root operations |
| Local `sqlite3` crashed | Hardened/spoofed Android userspace incompatibility | Copy databases out and use host SQLite/Python |
| Fresh TalsecKill APK did not load | LSPosed retained the old randomized APK path | Update `modules.apk_path`, preserve scope, reboot |
| Docker restart did not load hooks | KernelSU/Zygisk kernel boot stages were not re-armed | Reboot the complete VPS |
| App died after Java exit hooks | Native `FNatives.x()` called `kill(getpid(), 9)` | Hook the stable Java-to-JNI boundary before native execution |
| Generic freeRASP bypass failed | SDK classes were obfuscated and native enforcement remained | Hook preserved React Native bridge methods plus the proven JNI boundary |
| Play Integrity HTTP 429 | Repeated checker/app launches exhausted project quota | Stop retries and wait for the quota reset window |
| Tricky Store keybox gave Device but not Strong | Generated chain/profile insufficient for checker policy | Replace Tricky Store with TEESimulator-RS and correct target semantics |
| All three Play Integrity labels passed but Target-App still returned 403 | AppiCrypt contained independent local `NOK` states | Inspect and mutate the full check set before native signing |
| Two-field AppiCrypt mutation still failed on the later protected flow | `hooks` and `adbEnabled` remained `NOK` | Enable `SPOOF_ALL_NOK_CHECKS` and convert every `NOK` to `OK` |

## 13. Final verification checklist

1. Pixel 5/redfin global profile is active.
2. Build type/tags are `user` and `release-keys`.
3. Verified boot properties report `green` and locked.
4. Real SELinux state is recorded honestly; property spoofing is not treated as
   a real policy.
5. KOWX712 PIF is enabled with the reviewed configuration.
6. TEESimulator-RS is the active `tricky_store` module when reproducing all
   three integrity labels.
7. Keybox and generated attestation state remain mode 600 and outside Git.
8. Zygisk Next and LSPosed are active; Zygisk Assistant is disabled.
9. PairIPFix and TalsecKill paths match current `pm path` values.
10. Both modules are scoped to `<TARGET_PACKAGE>` user 0.
11. `SPOOF_ALL_NOK_CHECKS=true` in the built TalsecKill source.
12. Logs show each observed `NOK -> OK` mutation before `FNatives.z()`.
13. Target-App remains alive beyond the previous native self-kill window.
14. `/fdfe/integrity` returns 200 without quota errors.
15. The protected Target-App initialization request returns 200 with its expected encrypted envelope.

## 14. Security and maintenance notes

- The public Internet/Telegram keybox is shared private key material. It can be
  revoked, correlated, or abused and is not equivalent to an owned hardware
  identity.
- TEESimulator-RS simulates hardware-style attestation. It does not add a real
  TEE or StrongBox chip to Redroid.
- A passing integrity checker does not guarantee Wallet, banking, RCS,
  work-profile, or app-specific acceptance.
- Keep the exact PIF, Tricky Store rollback, TEESimulator, PairIPFix, and
  TalsecKill artifacts with hashes outside public Git.
- Revalidate fingerprints and patch levels before any upgrade; Google policy
  and keybox revocation state can change.
- Do not repeatedly run Play Integrity checks. Quota throttling previously
  produced HTTP 429 and obscured the real application result.
- After every fresh Target-App or LSPosed-module install, re-check module paths,
  scopes, and full-host reboot state.
- Capture JSON files can contain authorization and integrity tokens. Keep them
  ignored and summarize only status codes, field presence, timing, and lengths.

## 15. Final technical conclusion

The work solved three different classes of problems that initially looked like
one integrity failure:

1. **Play compatibility:** customized KOWX712 PIF, global Pixel 5 identity, GSF
   re-registration, and Tricky Store made Play Store treat Redroid as an
   eligible device and enabled genuine Play installation.
2. **Platform attestation:** the public keybox plus TEESimulator-RS produced
   Basic, Device, and Strong labels in the independent checker.
3. **Target-App's application gate:** PairIPFix/TalsecKill preserved the app,
   while blanket `NOK -> OK` mutation cleaned AppiCrypt's signed local check set.

The decisive Target-App result came from item 3. Strong Integrity was useful as a
control, but the backend continued returning 403 until the AppiCrypt cryptogram
contained an all-clean check-state set. Once that state was signed by the
genuine `FNatives.z()` implementation, the protected request returned HTTP 200.
