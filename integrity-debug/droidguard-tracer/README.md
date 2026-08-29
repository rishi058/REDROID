# DroidGuard Signal Tracer / Harmonizer (Phase M)

A KernelSU/Magisk module in two parts:

## Part 1 — Diagnostic tracer (included, `v0.1-diagnostic`)
Logs the environment signals DroidGuard / legacy CTS-profile inspect, to
`/data/adb/droidguard_tracer/trace.log`, at post-fs-data and after boot. Use it to
capture a device's signal state and diff a **failing** device against a **passing** one:

```
adb -s <fail> shell su -c 'cat /data/adb/droidguard_tracer/trace.log'
# and compare with ../scripts/env_diff.py using ../scripts/d4_env_snapshot.sh output
```

## Part 2 — Harmonizer (design; needs a Zygisk native component)
PIF already spoofs `android.os.Build` fields to the DroidGuard process. This module targets
the **deeper signals** that PIF does not, which are the suspected residual differentiators on
the VPS (ARM64 / Oracle-KVM) vs the passing WSL (x86) instance:

| Signal (exp, failing) | Real Pixel 5 | Fixable by props? | Mechanism |
|---|---|---|---|
| `ro.board.platform` empty, `ro.soc.*` empty | `lito` / Qualcomm SM7250 | **Yes** (opt-in, Part 1) | `resetprop` |
| 0 sensors | many | No | Zygisk: fake `SensorManager`/HAL for GMS |
| SELinux `Disabled` | `Enforcing` | No (kernel) | Zygisk: hook `getenforce`/`/sys/fs/selinux/enforce` reads in GMS |
| `uname -r` = `6.8.12-zksu-multi` | redfin kernel string | No (kernel) | Zygisk: hook `uname`/`/proc/version` reads in GMS |
| `ro.hardware` = `redroid` | `redfin` | Risky globally | Zygisk: per-process prop spoof for GMS only |
| CPU implementer `0x41` (Ampere) | Qualcomm | No | Zygisk: hook `/proc/cpuinfo` reads in GMS |

### Why Zygisk (not global props)
These signals must be spoofed **only inside the GMS/DroidGuard process** (like PIF does), because
changing them globally (`ro.hardware`, SELinux, kernel) breaks redroid or other apps. The Zygisk
companion would, on load into `com.google.android.gms*`:
- hook libc `open`/`openat`/`__system_property_get`/`uname` to rewrite `/proc/cpuinfo`,
  `/proc/version`, `/sys/fs/selinux/enforce`, and select props to redfin-coherent values;
- optionally synthesize a plausible sensor list.

### Important honesty
On **Android 13+ Play Integrity**, `MEETS_BASIC_INTEGRITY` hinges on the **key-attestation root of
trust being Google's** (handled by the keybox + TrickyStore/TEESimulator), *not* primarily on these
CTS-profile signals. So harmonizing these signals is most relevant to the **legacy/DEVICE** path and
to reducing emulator tells. Prove the failure mode first with `../decode-harness` before investing in
the Zygisk build — if the decode shows a keybox/root-of-trust rejection, the fix is a private keybox,
not signal harmonization.

## Build the Zygisk component
Model it on PIF's `zygisk/` (see `../../rev-eng/PlayIntegrityFix-KOWX712/zygisk/`): a `companion` +
`libzygisk` `.so` built with the NDK, packaged under `zygisk/arm64-v8a.so`. Not included here to keep
the diagnostic module buildless.
