# target reverse-engineering: session overview

This is the chronological account of getting `com.targetapp` running in a
Redroid + Magisk environment and capturing its API traffic. Detailed API and
crypto findings live in [03-key-findings.md](03-key-findings.md); failed
approaches are indexed in [02-dead-ends.md](02-dead-ends.md); the native
self-kill investigation is in [04-native-selfkill-research.md](04-native-selfkill-research.md).

## Outcome at a glance

| Layer | Evidence | Result |
|---|---|---|
| Google PairIP | `libpairipcore.so` and `com.pairip.licensecheck.*` | Bypassed with LSPosed + `pairipfix` |
| Talsec freeRASP | `libts.so` and `com.talsecreactnativesecurityplugin.*` | Threat callback suppressed; native self-kill bypassed |
| HTTPS | mitmproxy + system CA + `adb reverse` | Decrypted successfully; no pinning observed |
| App-layer crypto | CryptoJS AES and Talsec vault bridge | Recovered and documented; no external impersonator built |

The final setup kept the app in the foreground for at least 70 seconds and
allowed authenticated requests to be captured through the genuine app.

## 1. Objective and environment

The original goals were:

1. Stop the launch redirect to Google Play.
2. Run the app in Redroid.
3. Observe and understand the endpoints it calls.

The verified environment was:

- Android 11/13, arm64-v8a, in Docker container `a13_1` on an Oracle VPS.
- ADB over TCP: `xxx.xxx.xxx.xxx:5555`.
- SELinux disabled.
- Magisk-Delta 25210 (`io.github.huskydg.magisk`).
- Windows 11, Git Bash/MSYS2, Python 3.14, Frida, mitmproxy 12.2.3, JDK 24,
  Node 24, and Android SDK build-tools 35.

### Environment rules that matter

- Use `/system/xbin/su 0` for root. `/system/bin/su` is MagiskSU and returned
  `Permission denied` on this device.
- Prefix commands containing bare remote paths with
  `MSYS_NO_PATHCONV=1`; otherwise Git Bash can rewrite `/data/...` as a local
  Windows path before `adb.exe` sees it.
- `iptables` cannot be used because the container has no usable `filter`
  table. The working proxy route is `adb reverse` plus the Android global
  proxy setting.
- `adb reboot` is unreliable here. Restart the container with
  `docker restart a13_1`.
- The system CA installation survived container restarts on the tested image.

## 2. Protection layers discovered

Three separate mechanisms appeared in sequence. The first launch failure was
PairIP licensing; only after that was bypassed did the Talsec RASP behaviour
become visible.

### PairIP: the Play Store redirect

PairIP is the APK protection wrapper. In this APK it consists of:

- Java package `com.pairip.*` — `application.Application` (the manifest's
  `android:name`), `SignatureCheck`, `VMRunner`, `StartupLauncher`, and
  `licensecheck.{LicenseClient,LicenseActivity,LicenseResponseHelper,LicenseContentProvider}`;
- native VM `libpairipcore.so` in `split_config.arm64_v8a.apk`; and
- encrypted bytecode in `assets/4UCWUbe2D5uL9vQP`, executed through
  `VMRunner.executeVM(...)`, with method-level virtualization through
  `VMRunner.invoke("…", args)` in roughly 19 classes.

The decompiled PairIP sources were kept under
`target-app-java-src/sources/com/pairip/` during the analysis.

A clean launch showed the actual failure:

```text
I SignatureCheck: Signature check ok
D LicenseClient : Connecting to the main licensing service...
I ActivityManager: Start proc com.android.vending/…LicensingService
START … com.targetapp/com.pairip.licensecheck.LicenseActivity (has extras)
I com.targetapp: System.exit called, status: 0
Process com.targetapp … has died
topResumedActivity= com.android.vending/…finsky…MainActivity
```

Reading `LicenseClient.java` established the path:

- `Application.attachBaseContext` calls `LicenseClient.checkLicense(ctx)`;
- `LicenseContentProvider.onCreate` also constructs a client and calls
  `initializeLicenseCheck()` early in process startup;
- the client binds `com.android.vending`'s `ILicensingService` and sends
  `TRANSACTION_CHECK_LICENSE_V2`; and
- the asynchronous result reaches `processResponse(responseCode, payload)`.

The response handling is:

| Code | Meaning | Action |
|---:|---|---|
| `0` | Licensed | Set `licenseCheckState = FULL_CHECK_OK` and continue. |
| `2` | Not licensed | Start `LicenseActivity`, fire the Play Store `PendingIntent`, then `System.exit(0)`. |
| `3`/other | Error | Show the error path and exit. |

The conclusion was that this was not signature tampering and not initially a
Frida-detection failure. It was a genuine Play `NOT_LICENSED` verdict: the
Redroid Google account had not purchased/owned the app. The fix therefore had
to neutralise license-verdict handling. Repackaging was deliberately avoided:
the unmodified signature passed, re-signing would risk PairIP integrity checks,
and the native VM has its own integrity-sensitive code.

### Why Frida was abandoned for PairIP

The failed Frida path is indexed in [02-dead-ends.md](02-dead-ends.md), but
the timing and detection evidence is important:

- TCP-ADB `frida.attach()` took roughly three seconds while the app died in
  roughly two seconds.
- Spawn held the process and native anti-detection work let it reach the real
  activity, but Frida 17 produced `ReferenceError: 'Java' is not defined`
  because its bundled Java bridge had been removed.
- Frida 16 restored `Java`, but PairIP then detected ART/JVMTI
  instrumentation and raised an in-process `SIGSEGV` in `libpairipcore.so`
  around offset `0xf28000`.
- FKIE-CAD's friTap observations corroborated a periodic in-process `.text`
  integrity check that reacts to Java/ART instrumentation.

Therefore any Frida Java-level license hook was a dead end for this APK.

### Working PairIP solution: LSPosed + PairIPFix

LSPosed hooks at the Zygote/ART level through inline LSPlant hooks without
loading a JVMTI agent into the target. PairIPFix forces the relevant signature
and license checks to pass while leaving `libpairipcore.so` and its
virtualized methods untouched.

The verified prerequisites were Magisk-Delta, a working `/system/xbin/su 0`,
and disabled SELinux. The complete install procedure is in §3 below.

### Talsec freeRASP: the security reaction

Once PairIP was bypassed, the app showed a “Security Alert — Device is
Insecure” card and exited after roughly eight seconds. The relevant components
were:

- React Native module
  `com.talsecreactnativesecurityplugin.TalsecReactNativeSecurityPluginModule`;
- obfuscated helpers under `Nd/`, `p278ra/`, and `V4/`;
- native detector `libts.so` under `jni/arm64-v8a/`; and
- the custom LSPosed module in `mod_build/`.

Strings in `libts.so` showed emulator, root, Xposed/LSPosed, and Frida checks,
including `LIBFRIDA`, `/memfd:frida-agent`,
`scan_for_frida_server_all_ports`, and `/proc/self/maps`. Redroid plus Magisk
plus LSPosed therefore triggers multiple detectors by design.

The confirmed reaction model is:

```text
native detector
  → TALSEC_INFO LocalBroadcast
  → obfuscated ThreatListener.onReceive
  → decoded threat extra
  → NativeEventEmitter channel with per-session-randomised names
  → app JavaScript renders “Device is Insecure” and exits/backgrounds
```

There is also an SDK-side `onInvalidCallback → Process.killProcess` path.

### Why the generic freeRASP bypass was insufficient

`pyrosec/unrasp` was tested as a generic LSPosed experiment. It implemented
canonical hooks such as blanking `Intent.getStringExtra` on `TALSEC_INFO`,
no-oping `ThreatListener.onReceive`, and blocking Java
`System.exit`/`Process.killProcess`. Its log showed:

```text
UnRASP: Intercepted TALSEC_INFO getStringExtra, returning empty
UnRASP: ThreatListener class not found (may be obfuscated): …security.api.ThreatListener
UnRASP: Blocked System.exit(0) / Blocked Process.killProcess(self)
```

The app's SDK is obfuscated, so the named listener was not found, and this
build reads the threat through a different path. The process still became
cached and was reaped.

### Custom `talseckill` module

React Native preserves the bridge class and `@ReactMethod` names. That made
these methods stable hook points even though the SDK internals were obfuscated:

1. `registerListeners(Promise)` — no-op and resolve the promise, skipping
   `c.l()/c.k()` so freeRASP listeners do not start.
2. `onInvalidCallback()` — no-op the body that calls
   `Process.killProcess(myPid())`.
3. `getThreatChannelData(Promise)` — return dead channel names instead of the
   per-session native names, so JavaScript subscribes to channels native code
   never emits on.

The module also blocks the defensive Java/UI paths:

- `System.exit(int)`;
- `android.os.Process.killProcess(int)`;
- `Intent.getStringExtra` and `getSerializableExtra` when the action is
  `TALSEC_INFO`;
- `Activity.finish`, `finishAndRemoveTask`, and `finishAffinity`;
- `ActivityManager$AppTask.finishAndRemoveTask`; and
- `Activity.moveTaskToBack`.

The final native boundary is documented separately in
[04-native-selfkill-research.md](04-native-selfkill-research.md):
`androidx.security.FNatives.x(int)` schedules the actual self-`SIGKILL` path.

## 3. Reproducible setup

The following is the shortest verified path. Run it from the `rev-eng/`
directory; script and generated-module paths below are relative to that
directory.

```text
1. adb connect xxx.xxx.xxx.xxx:5555
2. Enable Zygisk and repair the Magisk binaries if required.
3. Install LSPosed manually and restart the container.
4. Install pairipfix, enable it, scope it to com.targetapp, and restart.
5. Build/install talseckill, enable it, scope it to com.targetapp, and restart.
6. Install the mitmproxy system CA and configure adb reverse.
7. Trigger requests with a target deep link.
```

### Enable Zygisk

```bash
adb shell "/system/xbin/su 0 sh -c 'magisk --sqlite \"REPLACE INTO settings (key,value) VALUES(\\\"zygisk\\\",1)\"'"
# Verify with:
adb shell "/system/xbin/su 0 magisk --sqlite 'SELECT * FROM settings'"
```

On this image `/data/adb/magisk/` was initially empty, so
`magisk --install-module` failed with exit 127 and reported “Incomplete Magisk
install”. The binaries were present under `/system/etc/init/magisk/`, while
`util_functions.sh` was inside `magisk.apk`. Run the repository’s
`setup_magiskbin.sh` to restore the expected Magisk layout:

```bash
MSYS_NO_PATHCONV=1 adb push setup_magiskbin.sh /data/local/tmp/
MSYS_NO_PATHCONV=1 adb shell "/system/xbin/su 0 sh /data/local/tmp/setup_magiskbin.sh"
```

Even after this repair, `magisk --install-module` still exited 127 because the
Delta build could not find busybox in its expected tmpfs. LSPosed was therefore
placed manually. `build_lsposed.py` prepares `modules/ lsposed/` and
`place_lsposed.sh` installs it. The build extracts the arm64/arm32 Zygisk
libraries, `dex2oat`, and `liboat_hook`, then applies the DEV_PATH binary patch
by replacing the placeholder
`5291374ceda0aef7c5d86cd2a4f6a3ac` with a random 32-hex value in
`daemon.apk` and `dex2oat32/64`.

```bash
python build_lsposed.py
MSYS_NO_PATHCONV=1 adb push modules/zygisk_lsposed /data/local/tmp/
MSYS_NO_PATHCONV=1 adb push place_lsposed.sh /data/local/tmp/
MSYS_NO_PATHCONV=1 adb shell "/system/xbin/su 0 sh /data/local/tmp/place_lsposed.sh"
docker restart a13_1
```

`place_lsposed.sh` installs the tree under
`/data/adb/modules/zygisk_lsposed/` with root-owned 0755/0644 permissions,
`bin/` owned by `root:shell` with 0755 permissions and the `xposed_file`
context, and the daemon set to 0744. Verify the LSPosed daemon,
`/data/adb/lspd/config/modules_config.db`, and the presence of `sqlite3` with
`check_lspd_db.sh`.

### Install and scope PairIPFix

`modules/pairipfix.apk` is the `ahmedmani/pairipfix` v1.2 Xposed module. It
must be installed as an app, enabled, and scoped in LSPosed. Its installed
package name is malformed in this build, so resolve it instead of hardcoding
it:

```bash
adb shell pm list packages | grep -i pairip
MSYS_NO_PATHCONV=1 adb install modules/pairipfix.apk
MSYS_NO_PATHCONV=1 adb install -r modules/pairipfix.apk  # re-fire PACKAGE_ADDED
MSYS_NO_PATHCONV=1 adb push scope_pairipfix.sh /data/local/tmp/
MSYS_NO_PATHCONV=1 adb shell "/system/xbin/su 0 sh /data/local/tmp/scope_pairipfix.sh"
docker restart a13_1
```

The scope script edits LSPosed’s SQLite database because LSPosed has no CLI
for headless module configuration. The essential operations are:

```sql
UPDATE modules SET enabled=1 WHERE module_pkg_name='<pairipfix pkg>';
INSERT OR IGNORE INTO scope(mid,app_pkg_name,user_id)
  SELECT mid,'com.targetapp',0
  FROM modules WHERE module_pkg_name='<pairipfix pkg>';
```

The direct database change is cached by LSPosed and takes effect after the
container restart. The PairIPFix package name in this build is literally
`io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix`,
which is why the `pm list packages` lookup is required.

PairIPFix v1.2 hooks `SignatureCheck.verifyIntegrity` to a no-op,
`verifySignatureMatches` to `true`, and the PairIP license paths including
`LicenseClient.initializeLicenseCheck`, `performLocalInstallerCheck`, the
license state, `LicenseClientV3.processResponse`, `LicenseActivity` exit paths,
and `LicenseResponseHelper`.

Successful startup includes log lines equivalent to:

```text
LSPosed-Bridge: [PairIPFix] Module loaded for package: com.targetapp
[PairIPFix] SignatureBypass applied successfully
[PairIPFix] LicenseClientBypass applied successfully
[PairIPFix] LicenseActivityBypass applied successfully
[PairIPFix] LicenseResponseBypass applied successfully
[PairIPFix] 4/4 hooks applied
```

### Build and scope `talseckill`

The module is built without Gradle. `mod_build/build_module.sh` performs the
following reproducible stages:

1. Compile `src/com/recon/talsecbypass/Hook.java` with
   `javac --release 11 -cp xposed-api.jar`.
2. Convert the class files to `classes.dex` with `d8`.
3. Link `AndroidManifest.xml` with `aapt2`, including the
   `xposedmodule`, `xposedminversion`, and `xposedscope` metadata.
4. Add `classes.dex` and `assets/xposed_init` using Python `zipfile`.
5. Align with `zipalign` and sign with `apksigner` using `key.pk8` and
   `cert.der`.

The tested toolchain was Android SDK build-tools 35.0.1,
`platforms/android-35/android.jar`, JDK 24, and Xposed API `api-82.jar` from
the Aliyun Maven mirror because it was not available on Maven Central.

The build, install, scope, and reboot sequence is:

```bash
cd mod_build
bash build_module.sh
cd ..
MSYS_NO_PATHCONV=1 adb install -r modules/talseckill.apk
MSYS_NO_PATHCONV=1 adb push mod_build/scope_talseckill.sh /data/local/tmp/
MSYS_NO_PATHCONV=1 adb shell "/system/xbin/su 0 sh /data/local/tmp/scope_talseckill.sh"
docker restart a13_1
```

The hook is scoped only to `com.targetapp`. It covers the preserved React
Native methods, Java teardown methods, and the native boundary described in
`04-native-selfkill-research.md`.

Before the exact native self-kill was identified, these hooks removed the hard
crash and extended the app lifetime from roughly eight seconds to 15–22
seconds. Logcat showed:

```text
[TalsecKill] registerListeners -> NO-OP
[TalsecKill] System.exit blocked
[TalsecKill] killProcess blocked
[TalsecKill] Activity.* / AppTask.finishAndRemoveTask blocked
```

That was enough to trigger and capture API calls, but not enough for indefinite
UI navigation. The native `libts.so` detector starts before
`registerListeners`; its threat still reached JavaScript through a randomised
React Native channel. The app rendered the insecure state, moved to the
background, and Redroid’s low-memory killer reaped the cached process after
roughly 15 seconds.

The `getThreatChannelData(Promise)` hook then returned dead channel names
(`dead_ch_a`, `dead_ch_b`, `dead_ch_c`) instead of the real per-session values.
This suppressed the JavaScript insecure screen without hardcoding a random
channel. The observed state changed as follows:

| | Before channel desync | After channel desync |
|---|---|---|
| Logcat death line | `... has died: cch+15 CEM` | `... has died: fg TOP` |
| Meaning | Backgrounded, cached, then LMK-reaped | Stayed foreground/top, then killed |
| Insecure screen | Rendered | Suppressed |

The desync proved that the JS-side reaction was removed, but the foreground
process still died without an `AndroidRuntime` fatal or LMK reap. A
`mod_build_stable/` experiment added `Runtime.halt/exit`,
`Process.sendSignal`, `Process.killProcessQuiet`, and `android.system.Os.kill`
hooks, but none fired at the actual boundary:

```text
[TalsecKillS] AppTask.finishAndRemoveTask blocked
Process com.targetapp (pid 2638) has died: fg TOP
Zygote: Process 2638 exited due to signal 9 (Killed)
```

Host-kernel tracing then attributed the delayed path to:

```text
C10611o0.a(int) -> Handler(8000 ms)
                  -> androidx.security.FNatives.x(int)
                  -> getpid() -> kill(pid, 9)
```

Hooking `FNatives.x(int)` before JNI executes is the final stable fix. The
neighbouring `FNatives.y()` and `FNatives.z()` methods remain untouched because
they are used by the app’s crypto/integrity flow.

## 4. Capture traffic

Install the mitmproxy CA into the Android **system** trust store; a user CA is
not sufficient for the tested React Native/OkHttp path. On Android 14, the
active store is `/apex/com.android.conscrypt/cacerts`, so the repository helper
installs the certificate there as well as the legacy `/system` path. The helper
is `network-tools/install_cert.sh`.

```bash
mitmdump -p 8080 --set block_global=false -w network-tools/captures/flows.mitm
MSYS_NO_PATHCONV=1 adb push network-tools/install_cert.sh /data/local/tmp/
MSYS_NO_PATHCONV=1 adb shell "/system/xbin/su 0 sh /data/local/tmp/install_cert.sh"
adb reverse tcp:8080 tcp:8080
adb shell settings put global http_proxy 127.0.0.1:8080
```

Trigger the app with a deep link:

```bash
adb shell am start -a android.intent.action.VIEW \
  -d "https://www.target.com/app/<id>" com.targetapp
```

The app performs the authenticated request itself, even when the UI is not
usable. Use `network-tools/parse_flows.py`, `dump_flows.py`, or
`deeplink_capture.py` to inspect the result. The endpoint map, request
envelopes, and decryption rules are in [03-key-findings.md](03-key-findings.md).

## 5. Final status

Solved:

- PairIP no longer redirects the app to Play Store.
- HTTPS traffic can be captured and decrypted at the TLS layer.
- Deep links trigger authenticated endpoint calls without UI navigation.
- The Talsec Java/JS reaction and the confirmed native self-kill are bypassed.
- The app-layer protocol and content decryption path are documented.

Not attempted:

- Building an off-device API client that forges Talsec cryptograms or replaces
  the genuine app’s request flow.
