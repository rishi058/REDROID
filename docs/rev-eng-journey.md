# PairIPFix journey — KernelSU Redroid 14

Date: 2026-07-28

## Goal

Run the original `com.target-appapp` APK past its Google PairIP licensing flow. On this
Redroid image the Play Store reports the app as incompatible, so the original split
APK set was installed directly while preserving its signature. The PairIP solution
hooks the app at runtime; it does not patch or re-sign the target APK.

## Starting state

- Target: ReDroid 14, arm64-v8a, exposed locally through an SSH tunnel at
  `127.0.0.1:5555`.
- Root stack already present: KernelSU-Next, Zygisk Next, and Zygisk-LSPosed.
- `lspd` was running and its configuration database existed at
  `/data/adb/lspd/config/modules_config.db`.
- The original target-app bundle was available in `exp/target-app_extracted/` as
  `base.apk`, `split_config.arm64_v8a.apk`, `split_config.en.apk`, and
  `split_config.xxhdpi.apk`.

## 1. Install the original split package

```powershell
adb install-multiple -i com.android.vending `
  exp\target-app_extracted\base.apk `
  exp\target-app_extracted\split_config.arm64_v8a.apk `
  exp\target-app_extracted\split_config.en.apk `
  exp\target-app_extracted\split_config.xxhdpi.apk

adb shell pm path com.target-appapp
adb shell pm list packages -i com.target-appapp
```

Verified result:

```text
package:com.target-appapp  installer=com.android.vending
versionName=22.9
primaryCpuAbi=arm64-v8a
```

The installer identity alone does not resolve PairIP when the account lacks a valid
licence; it only preserves the expected install-source metadata.

## 2. Confirm the existing KernelSU / LSPosed foundation

ADB was already root in this Redroid setup, so no Magisk-Delta repair or separate
`su` wrapper was needed.

```sh
adb shell 'id; ps -A | grep -Ei "lspd|zygisk"'
adb shell 'ls -la /data/adb/lspd/config'
```

Expected indicators:

```text
uid=0(root)
lspd
zn-zygisk-companion64 zygisk_lsposed
/data/adb/lspd/config/modules_config.db
```

## 3. Install, enable, and scope PairIPFix

### Provenance and relation to `tools/pairip-fix/`

`exp/modules/pairipfix.apk` is the ready-made v1.2 module from the upstream
[ahmedmani/pairipfix](https://github.com/ahmedmani/pairipfix) project. It was
not built from `exp/tools/pairip-fix/`, and this repository does not contain a
local source checkout or build recipe for that APK.

The former local `exp/tools/pairip-fix/` folder was removed. It contained
one-off LSPosed setup/scoping helpers and failed Frida experiments; it did not
alter or compile `pairipfix.apk`. The active setup now uses the direct
database commands below.

### Rebuild `pairipfix.apk` from upstream source

To reproduce the preserved v1.2 APK, use the upstream source tag rather than
anything in this repository. The project is a normal Gradle Android project
(`app/`, `gradlew`, and Gradle Kotlin build files), not a hand-built module
like `mod_build`.

```powershell
git clone --branch v1.2 --depth 1 https://github.com/ahmedmani/pairipfix.git pairipfix-src
Set-Location pairipfix-src
.\gradlew.bat assembleRelease
Copy-Item .\app\build\outputs\apk\release\app-release.apk ..\exp\modules\pairipfix.apk
```

Requirements are a JDK compatible with the repository's Gradle wrapper and
an Android SDK available to Gradle. The upstream build uses Android Gradle
Plugin and declares Xposed API 82 as a compile-only dependency; Gradle obtains
these dependencies during the first build. A locally rebuilt APK will have
the same module behaviour but will normally have a different signing key and
may not have byte-identical archive metadata. If an old copy is installed,
uninstall it before installing a locally rebuilt copy:

```powershell
adb uninstall io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
```

The unusual installed package name is produced by the upstream v1.2 Gradle
settings (`rootProject.name` is duplicated), not by the local setup.

Install the preserved module APK twice. The reinstall re-emits package-added state
so LSPosed registers it.

```powershell
adb install exp\modules\pairipfix.apk
adb install -r exp\modules\pairipfix.apk
adb shell 'pm list packages | grep -i pairip'
```

This build registers under the malformed-but-real package ID below; do not replace it
with an assumed package name:

```text
io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
```

Enable and scope it only to target-app from a root ADB shell:

```powershell
adb shell
```

Then run these commands inside that device shell:

```sh
DB=/data/adb/lspd/config/modules_config.db
PKG=io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
sqlite3 "$DB" "UPDATE modules SET enabled=1 WHERE module_pkg_name='$PKG';"
sqlite3 "$DB" "INSERT OR IGNORE INTO scope(mid,app_pkg_name,user_id) SELECT mid,'com.target-appapp',0 FROM modules WHERE module_pkg_name='$PKG';"
```

The script updates `modules_config.db` to set `enabled=1` and adds the scope row for
`com.target-appapp`, user `0`. Confirmed database state:

```text
2|1|io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
2|io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix|com.target-appapp|0
```

## 4. KernelSU-specific activation: reboot the VPS, not only Android

This is the important difference from the old Magisk-Delta/Redroid procedure.
KernelSU-Next's init and Zygisk hooks are replayed only during a full host boot.
Neither `adb reboot` nor `docker restart redroid14-ksu` activates newly staged root
modules reliably.

```powershell
ssh oracle_ubuntu_xpipe 'sudo systemctl reboot'
```

After the host returns, verify the expected kernel and ordered Redroid services,
then recreate the local SSH ADB tunnel if needed:

```powershell
ssh oracle_ubuntu_xpipe 'uname -r; systemctl is-active redroid14.service redroid14-watchdog.service redroid14-validate.service'
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:5555:127.0.0.1:5555 oracle_ubuntu_xpipe
adb connect 127.0.0.1:5555
adb wait-for-device
adb shell getprop sys.boot_completed
```

Verified after reboot:

```text
kernel=6.8.12-zksu
redroid14.service=active
redroid14-watchdog.service=active
redroid14-validate.service=active
sys.boot_completed=1
```

## 5. Verify the PairIP bypass

```powershell
adb logcat -c
adb shell am force-stop com.target-appapp
adb shell am start -n com.target-appapp/.MainActivity
Start-Sleep -Seconds 8
adb shell 'dumpsys window | grep -E "mCurrentFocus|mFocusedApp"'
adb logcat -d -v brief | Select-String -Pattern '\[PairIPFix\]|LicenseActivity|LicenseClient|SignatureCheck'
```

Observed proof:

```text
mCurrentFocus=Window{... u0 com.target-appapp/com.target-appapp.MainActivity}
[PairIPFix] Module loaded for package: com.target-appapp
[PairIPFix] SignatureBypass applied successfully
[PairIPFix] LicenseClientBypass applied successfully
[PairIPFix] LicenseActivityBypass applied successfully
[PairIPFix] LicenseResponseBypass applied successfully
[PairIPFix] 4/4 hooks applied
```

There was no PairIP `LicenseActivity` or Play Store redirect. target-app reached its real
`MainActivity`, so PairIP is resolved. A later `System.exit` is the separate Talsec/freeRASP
reaction and must be handled independently before stable UI use or traffic capture.

## 6. Talsec/freeRASP mitigation — KernelSU Redroid 14

### Objective and boundary

After PairIP is neutralised, target-app detects the rooted/emulated/LSPosed environment through
Talsec freeRASP. The documented custom LSPosed module suppresses the Java and React-Native
threat-delivery paths. It is a **mitigation**, not a full native bypass: `libts.so` can still
terminate the process with an uncatchable native `SIGKILL`.


### 6.1 Use the baseline custom module

The selected build was [`exp/modules/talseckill.apk`](exp/modules/talseckill.apk), package
`com.recon.talsecbypass`. Its targeted hooks:

- no-op `registerListeners(Promise)` and `onInvalidCallback()` on
  `TalsecReactNativeSecurityPluginModule`;
- block Java `System.exit`, `Process.killProcess`, activity teardown, and task backgrounding;
- return inert names from `getThreatChannelData(Promise)`, so JavaScript subscribes to channels
  on which the native Talsec emitter never sends a threat.

`talseckill_stable.apk` was not used. Its extra Java termination hooks were already shown not to
stop a native `kill(getpid(), SIGKILL)` from `libts.so`.

### 6.2 Install, register, enable, and scope it

```powershell
adb install exp\modules\talseckill.apk
adb install -r exp\modules\talseckill.apk
adb shell 'pm list packages | grep -i talsec'

adb push exp\mod_build\scope_talseckill.sh /data/local/tmp/scope_talseckill.sh
adb shell 'chmod 700 /data/local/tmp/scope_talseckill.sh && sh /data/local/tmp/scope_talseckill.sh'
```

The second installation makes LSPosed register the package. The scope script updates
`/data/adb/lspd/config/modules_config.db` to enable `com.recon.talsecbypass` and apply it only
to `com.target-appapp`, user `0`.

Verified state before reboot:

```text
2|1|io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
6|1|com.recon.talsecbypass

io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
com.recon.talsecbypass
```

### 6.3 Apply the scope through a full KernelSU host reboot

This environment does not reliably apply a new LSPosed scope after Android-only or Docker-only
restarts. Use the same full VPS reboot required for PairIPFix:

```powershell
ssh oracle_ubuntu_xpipe 'sudo systemctl reboot'
```

When the host is available again, wait for `sys.boot_completed=1`, recreate the SSH ADB tunnel if
necessary, and verify the root stack before testing:

```powershell
ssh oracle_ubuntu_xpipe 'systemctl is-active redroid14.service redroid14-watchdog.service redroid14-validate.service'
adb connect 127.0.0.1:5555
adb wait-for-device
adb shell 'getprop sys.boot_completed; ps -A | grep -E "lspd|zygisk"'
```

### 6.4 Test the live window

`talseckill.apk` includes optional logging hooks for the Talsec vault. Those values are not needed
to prove the RASP mitigation and not be copied into journals or command output. Filter them
out during verification.

```powershell
adb logcat -c
adb shell am force-stop com.target-appapp
adb shell am start -n com.target-appapp/.MainActivity

Start-Sleep -Seconds 10
adb shell 'dumpsys activity activities | grep -E "mResumedActivity|topResumedActivity"'

Start-Sleep -Seconds 12
adb shell 'dumpsys activity activities | grep -E "mResumedActivity|topResumedActivity"'

adb logcat -d -v brief |
  Select-String -Pattern '\[TalsecKill\]' |
  Where-Object { $_.Line -notmatch 'ORACLE' }
```

Baseline result before the final fix in section 8:

```text
# At 10 seconds
topResumedActivity=... com.target-appapp/.MainActivity

[TalsecKill] loaded in com.target-appapp
[TalsecKill] all hooks installed (threat-channel desynced)
[TalsecKill] getThreatChannelData -> DESYNCED (JS on dead channels)
[TalsecKill] registerListeners -> NO-OP (freeRASP not started)
[TalsecKill] AppTask.finishAndRemoveTask blocked
[TalsecKill] System.exit blocked
[TalsecKill] killProcess blocked

# At roughly 22 seconds
Process com.target-appapp ... exited due to signal 9 (Killed)
Process com.target-appapp ... has died: fg TOP
```

### 6.5 Interim outcome

The baseline module stopped the Java/React-Native threat reaction and kept target-app in its real
foreground activity for at least ten seconds. At this point the residual foreground `SIGKILL` was
known only to originate below the already-hooked Java wrappers. It was not yet proof that LSPosed
could not intercept the responsible Java-to-native boundary. Section 8 identifies that boundary
and records the stable fix.

## 7. Initial SIGKILL investigation — what was tried before host attribution

This section documents the attempt to keep target-app alive beyond the TalsecKill window. It is
important to separate the confirmed facts from the initial hypothesis: Android confirms that the
process receives `SIGKILL`, but this initial session did **not** identify the sender or a safe
native instruction to patch. Its stopping point was later superseded by section 8.

### 7.1 Temporary diagnostic setup

The existing arm64 `exp/frida-server` and matching host Frida 17.16.4 were used only as a
native-only diagnostic probe. The Java bridge was never loaded, so this was not the PairIP-breaking
Frida/JVMTI approach described in the old environment.

- The server used a temporary local Android listener on port `27099`, forwarded through ADB.
- The process was spawned with the probe loaded before target-app resumed.
- The following temporary probe scripts were used during diagnosis and then removed:
  - `native_kill_probe.js` and `run_native_kill_probe.py` record native termination calls.
  - `runtime_svc_census.js` finds raw ARM64 `svc` instructions in relevant executable mappings.
  - `native_svc_patch.js` is a runtime-only candidate patcher; it never found a live target to
    modify in this run.
  - `native_seccomp_guard.js` is the rejected process-wide syscall-filter experiment below.
- The temporary server was stopped and the `adb forward tcp:27099` rule removed after testing.
  No Frida agent remains attached to target-app.

### 7.2 What Android itself reports

`dumpsys activity exit-info com.target-appapp` consistently recorded:

```text
reason=2 (SIGNALED)
subreason=0 (UNKNOWN)
status=9
importance=100
```

The app was foreground when it died. System-server logs show `ActivityManager` observing the
death and then removing the activity; they do not show an `am_kill` or another ActivityManager
kill reason before the signal. Therefore Android confirms a `SIGKILL` but does not attribute it to
target-app, Talsec, ActivityManager, or the kernel OOM killer.

### 7.3 Native libc probe result

The probe attached to these libc exports before app resume:

```text
kill, tkill, tgkill, pthread_kill, raise, abort, exit, _exit, syscall
```

It saw only normal Zygote startup `SIGSTOP` activity and helper-process `_exit(-1)` calls. It did
**not** report a call carrying the final `SIGKILL`, nor a termination syscall through libc's
`syscall()` wrapper. Section 8 later proved that libc `kill()` was called. The log-only probe was a
false negative: it allowed the fatal call to continue, so process destruction could discard the
last Frida message before the host received it.

### 7.4 Raw `svc` instruction census

The original census result was invalid. Both SVC scripts compared a signed JavaScript bitwise
result with the positive number `0xD4000001`, so high-bit ARM64 words could never match. Static ELF
inspection then located the sole candidate word, `0xD4005F01`, inside `.gcc_except_table`. That
exception metadata happens to live in an executable PT_LOAD mapping, but it is data rather than an
executed syscall instruction. NOP-patching it could corrupt unwinding and must not be attempted.

The zero-count observation therefore did not rule out raw syscalls. The safe conclusion came from
executed kernel trace evidence in section 8, not from scanning executable mappings for byte words.

### 7.5 Rejected seccomp workaround

As a last bounded experiment, `native_seccomp_guard.js` successfully installed a TSYNC seccomp
filter in the spawned app process (`noNewPrivs=0`, filter install result `0`). It denied
`exit`/`exit_group` as well as kill/tkill/tgkill, signal-queue variants, and pidfd-send-signal.

This was not viable. target-app failed its startup lifecycle, crashed with `SIGILL`, then was removed
by Android as a background-startup ANR. Denying noreturn `exit` calls can make execution fall into a
compiler trap, which is the likely source of that `SIGILL`; the result did not invalidate a narrow
self-`SIGKILL` guard. The filter was per-process and disappeared with the test process.

### 7.6 Old stopping point and reason

The initial run stopped here by design:

- PairIP is fully bypassed and the Java/React-Native Talsec reaction is mitigated.
- The remaining `SIGKILL` is confirmed, but its sender and call site are not identified.
- The direct libc, raw-`svc`, and broad syscall-filter workarounds either did not observe a target
  or prevented Android from starting the app.
- Continuing would require a more invasive host/kernel-level trace of signal senders, or a
  purpose-built native injector with a known call site. Attempting a blind permanent native patch
  would risk corrupting the target process or destabilising the Redroid container without evidence
  that it addresses the kill.

That was a safe stopping point with the available evidence, but it is no longer the final state.
Section 8 records the host attribution, exact Java-to-native call path, and working LSPosed fix.
No temporary Frida server or seccomp filter was left active.

## 8. Stable UI resolution — attribute and hook the exact JNI self-kill

### 8.1 Attribute the sender at the shared host kernel

ReDroid shares the VPS kernel, so the host `signal:signal_generate` tracepoint can observe signal
delivery without attaching to or modifying the Android process. A bounded `bpftrace` run while
launching target-app produced:

```text
sender=com.target-appapp pid=74100 tid=74100 uid=10092
target=com.target-appapp target_pid=74100 code=0 group=1 result=0
```

The sender and target were the same process. This eliminated ActivityManager, the watchdog, lmkd,
OOM, and an external anti-tamper helper. The sender user stack resolved to:

```text
libc.so: kill
libart.so: art_quick_generic_jni_trampoline
```

This was the missing clue: the kill used libc, but it was entered through an ART native-method
trampoline and could still be stopped at the Java native-method boundary.

### 8.2 Resolve the exact delayed call path

The decompiled app and the exact `libts.so` build agree on this path:

```text
Z.x(...)
  -> C10611o0.a(int)
    -> main-looper Handler delay (8000 ms)
      -> androidx.security.FNatives.x(int)
        -> getpid()
        -> kill(pid, SIGKILL)
```

Relevant sources:

- `exp/target-app-java-src/sources/defpackage/C10611o0.java` schedules the eight-second call.
- `exp/target-app-java-src/sources/androidx/security/FNatives.java` declares native `Void x(int)`.
- `FNatives.y(...)` and `FNatives.z(...)` are separate crypto/integrity methods and must remain
  operational.

Static ARM64 analysis confirmed that `Java_androidx_security_FNatives_x` resolves `getpid`, loads
signal `9`, and calls `kill`. There was no need for an inline native patch, Frida, or seccomp.

### 8.3 Add the narrow LSPosed hook

`exp/mod_build/src/com/recon/talsecbypass/Hook.java` now hooks only
`androidx.security.FNatives.x(int)` and returns `null` before JNI executes. It also guards the
framework `killProcess*` and `sendSignal*` self-`SIGKILL` paths while leaving other signals and
other target PIDs alone.

Build, reinstall, retain the existing scope, and apply through a full KernelSU host reboot:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' exp/mod_build/build_module.sh
adb install -r exp\modules\talseckill.apk
ssh oracle_ubuntu_xpipe 'sudo systemctl reboot'
```

Installed artifact:

```text
exp/modules/talseckill.apk
SHA256 D64416D38CB0F4251347F29F57DE944818BA95F8B0751E382F2E65ACAF32256B
```

### 8.3.1 Recreate `mod_build` from an empty folder

`mod_build` is not an Android Studio project or a decompiled APK. It is a
small, hand-built LSPosed module. The target application (`com.target-appapp`)
is never repackaged or modified: LSPosed loads this separate module into it.

The canonical inputs are:

```text
exp/mod_build/
  AndroidManifest.xml                         # module metadata
  assets/xposed_init                          # Hook entry-point class name
  src/com/recon/talsecbypass/Hook.java        # custom hook implementation
  build_module.sh                             # javac/d8/aapt2/sign build recipe
  scope_talseckill.sh                         # LSPosed SQLite scope helper
  xposed-api.jar                              # compile-only Xposed API 82 dependency
  key.pk8 + cert.der                          # APK signing identity
```

Only those inputs need to be retained. `classes/`, `dexout/`, `classes.dex`,
`base.apk`, `mod.apk`, and `talseckill-aligned.apk` are build intermediates;
the build script removes them automatically. The only output worth keeping is
`exp/modules/talseckill.apk`.

#### Prerequisites

On the Windows build machine, provide a JDK 11 or newer, Python 3, Git Bash,
Android SDK Platform `android-35`, Build Tools `35.0.1`, and a compatible
Xposed API 82 JAR saved as `xposed-api.jar`. The current script expects the
SDK at `D:/SOFTWARES/01_ANDROID_SDK_HOME`; change only its `SDK=` line if the
SDK lives elsewhere.

#### Create the source inputs

Create this directory structure and restore `Hook.java` from this repository;
it is the custom source of truth, not code copied from an APK:

```text
mod_build/
  assets/xposed_init
  src/com/recon/talsecbypass/Hook.java
```

`assets/xposed_init` contains exactly:

```text
com.recon.talsecbypass.Hook
```

`Hook.java` prevents the relevant Java-side RASP actions and narrowly changes
the observed `androidx.security.FNatives.x(int)` native self-`SIGKILL` call to
a no-op. It must remain scoped only to `com.target-appapp`.

Create `AndroidManifest.xml` with:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.recon.talsecbypass"
    android:versionCode="1" android:versionName="1.0">
    <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="35"/>
    <application android:label="TalsecKill" android:hasCode="true">
        <meta-data android:name="xposedmodule" android:value="true"/>
        <meta-data android:name="xposeddescription" android:value="No-op target-app Talsec registerListeners"/>
        <meta-data android:name="xposedminversion" android:value="82"/>
        <meta-data android:name="xposedscope" android:value="com.target-appapp"/>
    </application>
</manifest>
```

Restore `build_module.sh` and `scope_talseckill.sh` from this repository too.
The build script compiles Java with `javac`, converts it with `d8`, makes the
minimal APK with `aapt2`, adds `classes.dex` plus `xposed_init`, aligns it, and
signs it. The scope script enables the module and adds only `com.target-appapp`
to the LSPosed scope database.

#### Signing identity: preserve it for an update

To update the installed `com.recon.talsecbypass`, retain the existing
`key.pk8` and `cert.der` exactly. Android accepts an update only when it is
signed by the same key. Back them up privately; do not commit or share the
private key.

For a genuinely new installation where replacing/removing the old module is
acceptable, generate a new pair in Git Bash:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -subj "/CN=recon"
openssl pkcs8 -topk8 -nocrypt -in key.pem -outform DER -out key.pk8
openssl x509 -in cert.pem -outform DER -out cert.der
rm key.pem cert.pem
```

A newly generated key cannot update the old module. First remove it with
`adb uninstall com.recon.talsecbypass`, then install and scope the replacement.

#### Build, install, and scope

From the repository root in PowerShell:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' exp/mod_build/build_module.sh
adb install -r exp/modules/talseckill.apk
adb push exp/mod_build/scope_talseckill.sh /data/local/tmp/scope_talseckill.sh
adb shell 'chmod 700 /data/local/tmp/scope_talseckill.sh && sh /data/local/tmp/scope_talseckill.sh'
ssh oracle_ubuntu_xpipe 'sudo systemctl reboot'
```

After the ReDroid host is back, reconnect ADB and verify the module is enabled
and scoped before launching target-app. A full container reboot matters because
LSPosed hooks load when the target app process starts.

The SHA-256 above is a snapshot, not a reproducibility invariant: rebuilding
can alter APK zip metadata. For an update, the important invariant is the
signing identity and retained `Hook.java` source, not an identical archive hash.

### 8.4 Sustained verification

After the reboot, target-app was launched normally while the host traced every generated
`SIGKILL`. The app kept PID `2420` and remained focused in `com.target-appapp/.MainActivity` at
10, 20, 30, 40, 50, 60, and 70 seconds.

The safe LSPosed log stream showed:

```text
[TalsecKill] FNatives.x native self-kill guard installed
[TalsecKill] FNatives.x native self-kill blocked
[TalsecKill] FNatives.x native self-kill blocked
[TalsecKill] FNatives.x native self-kill blocked
```

The host trace recorded no `SIGKILL` targeting target-app. A final log scan found no fatal exception,
ANR, process-death message, or signal-9 exit, and the same process was still the focused app after
the trace ended.

### 8.5 Final outcome

target-app now survives beyond the former eight-to-twenty-second window and remains usable in its
real foreground activity. PairIPFix and the updated TalsecKill module remain enabled and scoped only
to `com.target-appapp`; no Frida agent, seccomp filter, native memory patch, or host tracer remains
attached. The application is left running.
