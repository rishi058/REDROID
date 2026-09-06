# `mod_build` — TalsecKill LSPosed module

## What this directory is

This is the complete, hand-built source tree for `TalsecKill`, an LSPosed
module whose installed Android package is `com.recon.talsecbypass`.

It is **not** target-app source, an Android Studio project, a modified target-app
APK, or a decompiled copy of another module. target-app remains installed with
its original APK signature. At process start, LSPosed loads this module into
only `com.target-appapp`; the module observes and replaces selected Java method
calls in that process.

The directory has two roles:

| Location | Role |
| --- | --- |
| `mod_build/` | Source, manifest, build recipe, Xposed API and signing identity. |
| `../modules/talseckill.apk` | Generated, signed Android APK to install on ReDroid. |

The output belongs in `modules/` because that folder is the repository's
installable-artifact area. Do not move it into this folder: `build_module.sh`
deliberately writes it to `../modules/talseckill.apk`, and all install commands
refer to that stable location.

## Why it exists / how it started

PairIP was already bypassed by the separate upstream `pairipfix` module. The
next visible problem was target-app's Talsec/freeRASP protection: it reported an
insecure environment and the app left its foreground activity shortly after
launch. The environment (ReDroid emulator + KernelSU + LSPosed) is inherently
interesting to a RASP SDK, so generic root hiding was not a sufficient fix.

The first custom hooks targeted the preserved React Native bridge class
`com.talsecreactnativesecurityplugin.TalsecReactNativeSecurityPluginModule`.
An early revision stopped listener registration as well as threat delivery,
common Java exit methods, and activity teardown. The current revision leaves
listener registration active so AppiCrypt can initialize normally; it guards
the app's reactions instead.

The decisive finding was a separate eight-second native self-kill path:

```text
C10611o0.a(...) schedules delayed work
    -> androidx.security.FNatives.x(int) (native JNI method)
        -> getpid()
        -> kill(pid, SIGKILL / signal 9)
```

`FNatives.x(int)` is intentionally hooked before JNI runs. This is narrow: the
neighbouring `FNatives.y()` and `FNatives.z()` methods are left alone because
they are used by the app's crypto/integrity flow. Host-kernel tracing then
showed target-app remaining in its foreground `MainActivity` with the same PID
for 70 seconds, with no generated `SIGKILL` directed at that PID. The full
evidence trail is in [`../../exp-journey.md`](../../exp-journey.md#8-stable-ui-resolution--attribute-and-hook-the-exact-jni-self-kill).

## Files and trust boundaries

```text
mod_build/
├─ src/com/recon/talsecbypass/Hook.java  # all runtime behaviour
├─ AndroidManifest.xml                    # declares the LSPosed module
├─ assets/xposed_init                     # says which class LSPosed loads
├─ build_module.sh                        # no-Gradle build and signing recipe
├─ scope_talseckill.sh                   # on-device: enable + scope in LSPosed DB
├─ fix_lspd_scope.sh                      # on-device: scope + repair stale apk_path
├─ patch_lspd.py                          # host-side: same repair when device sqlite3 is broken
├─ xposed-api.jar                         # compile-only API 82 dependency
├─ key.pk8                                # private APK signing key -- confidential
└─ cert.der                               # corresponding public certificate
```

`classes/`, `dexout/`, `classes.dex`, `base.apk`, `mod.apk`, and
`talseckill-aligned.apk` are temporary build products. The build script removes
them on exit. Only the signed output in `../modules/` is retained.

`key.pk8` is the update identity for the installed package. Keep it private and
back it up securely. Replacing it with a new key makes Android reject
`adb install -r` updates to the existing `com.recon.talsecbypass` installation;
uninstalling the old package would then be required before installing a
newly-signed APK.

## LSPosed entry and scope

`AndroidManifest.xml` lines 2–11 declares Android package metadata and the
LSPosed metadata:

- `xposedmodule=true` marks the APK as an Xposed/LSPosed module.
- `xposedminversion=82` requires the API level used at compilation.
- `xposedscope=com.target-appapp` documents the intended target.

`assets/xposed_init` contains one line:

```text
com.recon.talsecbypass.Hook
```

That causes LSPosed to instantiate `Hook`, which implements
`IXposedHookLoadPackage` (`Hook.java` lines 14–18). The first executable guard
at lines **19–20** returns for every package except `com.target-appapp`. This
runtime guard is important even when LSPosed scope configuration is wrong.

`scope_talseckill.sh` uses LSPosed's `modules_config.db`:

- lines **2–3** select the database and module package;
- line **4** enables the registered module;
- line **5** adds a scope row for `com.target-appapp`, Android user `0`;
- lines **6–7** print the resulting enabled/scope state.

The scope is deliberately not global. Do not broaden it without a reason: many
hooks below target Android framework classes and would affect another process
if this module were loaded there.

### Scoping helpers — which one to use

Three scripts write the same LSPosed `modules_config.db`. Pick by situation:

| Script | Runs on | Enables | Fixes `apk_path` | Use when |
| --- | --- | --- | --- | --- |
| `scope_talseckill.sh` | device (root) | yes | no | First scope after a fresh install, path still valid. |
| `fix_lspd_scope.sh` | device (root) | yes | **yes** | After `adb install -r` — the randomized `/data/app/...` path went stale and the module stopped loading. |
| `patch_lspd.py` | **host** (off-device) | yes | **yes** | On-device `sqlite3` core-dumps (ABI-broken ReDroid image) or the `adb shell` user has no access to `/data/adb`. |

Why `apk_path` repair exists: LSPosed caches an **absolute** path to the module
APK, and every `adb install -r` randomizes that path. LSPosed then sees the row
enabled and scoped but the file missing, and **silently** fails to load the
module — no hook, no log line. `fix_lspd_scope.sh` / `patch_lspd.py` re-resolve
the live path (`pm path com.recon.talsecbypass`) and write it back. This is the
usual reason a freshly-rebuilt module "installs fine" yet never injects.

`patch_lspd.py` operates on a **copy** of the DB pulled off the device, because
the ReDroid container's `/system/bin/sqlite3` can core-dump and the `adb shell`
user cannot read `/data/adb`. Typical host workflow:

```bash
sudo docker cp <ctr>:/data/adb/lspd/config/modules_config.db /tmp/db
sudo python3 patch_lspd.py /tmp/db com.recon.talsecbypass com.target-appapp "$(adb shell pm path com.recon.talsecbypass | sed 's/package://')"
sudo docker cp /tmp/db <ctr>:/data/adb/lspd/config/modules_config.db
# remove the container's stale modules_config.db-wal / -shm, then reboot the host
```

All three leave the target as the `com.target-appapp` placeholder (substituted at
deploy time) and all require a **Zygote restart (host reboot)** afterwards — a
`docker restart` alone does not re-arm the KernelSU trigger, so Zygisk never
re-injects and LSPosed never reloads.

## Runtime behaviour: current hooks

All runtime logic is in
[`Hook.java`](src/com/recon/talsecbypass/Hook.java). The three compile-time test
switches are deliberately visible at the top of the class:

- `PASSIVE_INTEGRITY_TEST=false`: normal stability guards are active;
- `BYPASS_RASP_START=false`: `registerListeners()` executes normally and starts
  the native Talsec runtime;
- `LOG_NATIVE_THREATS=false`: no diagnostic threat telemetry hooks are active.

The normal configuration applies only these reaction/stability guards:

1. `onInvalidCallback()` cannot kill the process.
2. `System.exit()` and the `Process.*` signal methods block only a self-targeted
   `SIGKILL`; calls targeting other processes and non-`SIGKILL` signals pass.
3. Exactly `androidx.security.FNatives.x(int)` is stopped. `FNatives.y()` and
   `FNatives.z()`, used by cryptography/integrity paths, remain untouched.
4. `TALSEC_INFO` broadcast extras are blanked only for that action.
5. Activity/task finish and background operations triggered by the reaction
   path are stopped.
6. JavaScript receives dead threat-event channel names so the insecure-device
   screen does not take over the task.
7. AppLovin MAX interstitial and rewarded-ad reloads are limited per ad unit to
   one permitted load every 10 minutes. The initial load, MAX initialization,
   readiness/event APIs, ad-endpoint reachability checks, and Diskwala network
   requests remain real.
8. Banner and MREC auto-refresh requests are rewritten from enabled to disabled;
   their initial mount load remains enabled.
9. An experimental BidMachine GAM guard can make a positively attributed loader
   executor's idle core workers expire after 30 seconds. Production v1.3 has not
   produced a configured-pool log, so this timeout must currently be treated as
   inactive.

Expected normal log lines include:

```text
[TalsecKill] registerListeners left active (native RASP starts normally)
[TalsecKill] FNatives.x native self-kill guard installed
[TalsecKill] AppLovin loadInterstitial limiter installed
[TalsecKill] AppLovin loadRewardedAd limiter installed
[TalsecKill] AppLovin auto-refresh guard installed
[TalsecKill] BidMachine GAM executor guard installed
[TalsecKill] reaction guards installed (native RASP active, threat channel desynced)
```

### AppLovin resource containment

Production profiling showed that repeated full-screen ad reloads fan out into
the installed MAX mediation adapters and leave hundreds of long-lived executor
threads in the Diskwala process. The limiter is installed at the narrow React
Native bridge (`AppLovinMAXModuleImpl`) rather than hooking adapter internals,
generic executors, `Thread.start`, or networking.

The first `loadInterstitial`/`loadRewardedAd` call for each ad unit is allowed.
Further calls inside the 10-minute monotonic cooldown return from the bridge's
void method without fabricating loaded/failed events. Suppression logs contain
only a hash fingerprint of the ad unit and are sampled at the first and every
25th suppressed call. This does not interfere with the app's independent
ad-block reachability checks or the `/android/np_lelo` and
`/android/playlist_items` capture requests.

After installing this module update, repair LSPosed's cached APK path, reboot
the complete host, and validate both capture types before production traffic.
Compare fresh-process thread count and RSS against an unmodified run. If a
future AppLovin bridge class changes, the hook logs a failure and leaves the
original SDK behavior intact.

ART thread-dump analysis identified BidMachine's `GAMLoader$GAMTaskLoader` as a
strong source match for the dominant anonymous scheduled pools. Each loader
creates a 2–4 core scheduled executor, submits only immediate work, and has no
shutdown path. The module is designed to keep the executor and submitted work
intact while enabling a 30-second idle-core timeout only after exact owner
attribution. In the production v1.3 A/B, the direct owner hook did not fire and
generic constructor telemetry saw only `LSPHooker_#constructor`; no timeout was
observed applying. Do not claim this guard is active without a
`BidMachine GAM idle-core timeout configured` log.

The earlier promise wrapper that logged vault values and cryptograms, including
its secret-priming helper, has been removed from source. The module must never
write authorization values, nonces, cryptograms, or vault values to logcat.

### Passive integrity A/B mode

Setting `PASSIVE_INTEGRITY_TEST=true` makes `handleLoadPackage()` return before
installing any hook. This was tested on 2026-07-29: target-app still sent
`all_ghusja/v2`, received HTTP 403, and then performed its normal self-kill.
The same 403 also occurred after removing the TalsecKill scope and after removing
both target-app LSPosed scopes, with no LSPosed bridge loaded in the target. The
module is therefore required for foreground stability but is not the source of
the HTTP 403.

## Build process

`build_module.sh` is a minimal reproducible build; it does not need Gradle or
Android Studio. Its current stages are:

| Script lines | Stage | Result |
| --- | --- | --- |
| 3–5 | Select SDK platform/build-tools paths | `android.jar`, `d8`, `aapt2`, `zipalign`, `apksigner`. |
| 7–11 | Clean setup and exit trap | Removes all temporary products even after a failed build. |
| 15–16 | `javac --release 11` | Compiles `Hook.java` against `xposed-api.jar`. |
| 19–20 | `d8` | Converts class files to Android `classes.dex`. |
| 23–24 | `aapt2 link` | Produces a manifest-only base APK. |
| 27–28 | Python `zipfile` | Adds `classes.dex` and `assets/xposed_init`. |
| 31–32 | `zipalign` | Aligns the unsigned APK. |
| 35–36 | `apksigner` | Signs output as `../modules/talseckill.apk`. |

The script currently expects the SDK at
`D:/SOFTWARES/01_ANDROID_SDK_HOME`, Android Platform `35`, and Build Tools
`35.0.1`. Change only the `SDK=` variable when using another SDK location.

Build from the repository root in PowerShell:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' rev-eng/mod_build/build_module.sh
```

Do not run `scope_talseckill.sh` through an unprivileged ADB shell. The deployed
Android `sqlite3` is ABI-broken, and LSPosed's live WAL must not be edited in
place. Use the vetted host-side workflow documented in
`DW-fast-api/TALSEC_v1.3.md`:

1. Back up the installed module APK and complete LSPosed config directory.
2. Install the signed APK through the ReDroid container's root `pm`.
3. Resolve the new randomized `pm path`.
4. `SIGSTOP` `lspd`, copy the complete config directory to the VPS host, and set
   an EXIT/error trap that always sends `SIGCONT`.
5. Run `patch_lspd.py` against the copied DB, checkpoint its WAL, require
   `PRAGMA integrity_check = ok`, and verify the module path/scope.
6. Copy the verified main DB back, remove stale device-side WAL/SHM, and restore
   root ownership/mode.
7. On any failed copy/patch/check, resume `lspd` before aborting. Leave it stopped
   only after all verification succeeds and the full VPS reboot is the immediate
   next command.
8. Reboot the full host so LSPosed/Zygote loads the new module into a fresh app
   process.

## Verification checklist

After the host and Android boot finish:

1. Check the module package is installed: `adb shell pm path com.recon.talsecbypass`.
2. Verify a read-only host copy of the LSPosed DB shows the module enabled, its
   current randomized APK path, and scope `com.diskwalaapp,user_id=0`.
3. Launch target-app and inspect LSPosed logs for the `FNatives.x` guard-install
   and block messages above.
4. Confirm the same target-app PID remains in the foreground beyond the former
   eight-to-twenty-second failure window.
5. Do not run Frida, seccomp experiments, native memory patchers, or old
   `unrasp` as part of the final configuration; they are not needed for this
   module's working path.

## Maintenance rules

- Keep the package guard at `Hook.java` line 24 and LSPosed scope narrow.
- Keep the `FNatives.x` hook narrow. Do not broadly no-op the whole
  `androidx.security.FNatives` class; `y()` and `z()` are intentionally not
  hooked.
- Preserve `key.pk8`/`cert.der` for upgrade continuity.
- Rebuild after any source, manifest, or entry-point change; do not hand-edit
  the signed APK.
- The SHA-256 of `talseckill.apk` may change after rebuilding because APK ZIP
  metadata can vary. The signing identity and reviewed source are the relevant
  upgrade invariants.
