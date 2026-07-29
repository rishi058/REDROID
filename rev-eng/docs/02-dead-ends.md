# Dead ends and environment traps

This is a quick diagnostic index. It records approaches that were tested and
the reason each one failed. The working path is in
[01-starting-point.md](01-starting-point.md).

## Frida and PairIP

| ID | Attempt | Observation | Conclusion |
|---|---|---|---|
| D1 | Frida attach | TCP-ADB attach took about three seconds; the app died in about two seconds. | Attach cannot win the startup race. |
| D2 | Frida spawn with Java hooks | Spawn held the process, but the Java hooks did not install under Frida 17. | Spawn was viable, but the runtime setup was incomplete. |
| D3 | Frida 17 Java bridge | `ReferenceError: 'Java' is not defined`; Frida 17 no longer bundled the Java bridge. | Adding `frida-java-bridge` would still leave PairIP’s instrumentation check. |
| D4 | Frida 16 | Restored `Java`, then PairIP detected ART/JVMTI instrumentation and raised an in-process `SIGSEGV`. | Java-level Frida hooks are detected by this APK. |
| D5 | Frida 17 + `frida-compile` | The agent still triggered the same PairIP integrity response. | Packaging the bridge does not avoid the native check. |
| D6 | Leaving `frida-server` installed | Talsec detected Frida artifacts. | Frida is unsuitable for the final setup. |

The practical replacement is LSPosed: it hooks at the Zygote/ART level without
loading a Frida/JVMTI agent into the target process. PairIPFix then handles the
license verdict without modifying the APK.

## Redroid and Magisk

| ID | Trap | Symptom | Working response |
|---|---|---|---|
| D7 | `iptables` | `filter` table does not exist. | Use `adb reverse` and the global proxy setting. |
| D8 | `magisk --install-module` | Exit 127: “Incomplete Magisk install”. | Restore Magisk files, then place LSPosed manually. |
| D9 | MSYS path conversion | `adb push` appears successful but a leading `/remote/path` is rewritten locally. | Prefix the command with `MSYS_NO_PATHCONV=1`. |
| D10 | `adb reboot` | Reboot is unreliable in this Redroid setup. | Run `docker restart a13_1`. |
| D11 | LSPosed configuration cache | Direct database changes do not take effect immediately. | Enable/scope modules in the database, then restart the container. |

The root command that worked consistently was:

```bash
adb shell "/system/xbin/su 0 sh -c '<command>'"
```

`/system/bin/su` used MagiskSU’s default-deny path and was not equivalent.

## PairIP and Talsec approaches that were insufficient

### D12 — Repackaging the APK

The original signature check passed. Replacing PairIP’s application wrapper or
re-signing the APK would risk native integrity checks and was unnecessary.

### D13 — Redirecting or disabling `LicenseActivity`

This did not address the license state machine. The fix must neutralise the
`NOT_LICENSED` response handling, which is what PairIPFix does.

### D14 — Blocking only Java exits

Blocking `System.exit`, `Process.killProcess`, `Runtime.halt`, and activity
teardown extended the lifetime but did not stop the final `SIGKILL`. The sender
was native code reached through `androidx.security.FNatives.x(int)`. The exact
investigation and fix are documented in
[04-native-selfkill-research.md](04-native-selfkill-research.md).

### D15 — Generic freeRASP bypasses

`pyrosec/unrasp` and similar public bypasses target canonical Java/JS threat
callbacks. This build obfuscates that path and also has a native enforcement
path. The custom module therefore hooks the preserved React Native bridge
methods and the confirmed JNI boundary instead of relying on class names such
as `ThreatListener`.

## Small operational traps

- The PairIPFix APK’s package name is malformed. Resolve it with
  `pm list packages | grep -i pairip` before editing the LSPosed database.
- `api-82.jar` was obtained from the Aliyun Maven mirror because it was not
  available from Maven Central.
- `openssl -subj "/CN=..."` is also affected by MSYS path conversion; use
  `MSYS_NO_PATHCONV=1`.
- Android system CA files must be named with the old subject hash and contain
  the PEM certificate in the expected format. A wrong order produces
  `DirectoryCertificateSrc: Failed to read certificate`.
