# Magisk and KernelSU reverse-engineering journeys compared

## Purpose

This note explains why the repository has two apparently similar
reverse-engineering records:

- [`rev-eng/docs/`](rev-eng/docs/) is the earlier, Magisk-Delta-based research
  record for the `a13_1` ReDroid environment.
- [`rev-eng-journey.md`](rev-eng-journey.md) is the later, validated
  KernelSU-Next/ReDroid 14 record for the same target investigation.

They share the app-level objective—run the original target APK past PairIP,
observe its traffic, and prevent the later freeRASP/Talsec termination—but they
do **not** have interchangeable root setup or reboot commands.

## Short answer

The Magisk material documents a bootless root path inside Android.  The
KernelSU material documents root hooks built into the shared VPS kernel.  The
stable UI fix is an LSPosed hook at a Java-to-JNI boundary, so it is not tied to
KernelSU and could run under Magisk **if** Magisk's Zygisk and LSPosed are
actually active.  It cannot help an Android 13 Magisk installation whose
bootless injection chain has already failed.

## The two environments

| Concern | Earlier Magisk research environment | Validated KernelSU environment |
|---|---|---|
| Android / container | Android 11/13 history; container named `a13_1` | ReDroid 14, `redroid14-ksu` |
| Root provider | Magisk-Delta, bootless/userspace | KernelSU-Next, integrated into the VPS kernel |
| Zygisk provider | Magisk's built-in Zygisk | Zygisk Next |
| Hook framework | LSPosed Zygisk module | Zygisk-LSPosed |
| Host access | ADB over the earlier direct/TCP setup | Loopback ADB through an SSH tunnel |
| Root shell behaviour | The working command was `/system/xbin/su 0`; Magisk's other `su` path was not equivalent | ADB shell was already root |
| Applying module changes | Container restart after a verified working Magisk setup | Stage modules, then reboot the **host** so KernelSU's one-shot init state is reset |
| Validated runtime target | Earlier research/capture setup | target foreground stayed alive for at least 70 seconds after the final hook |

The older environment is recorded in
[`rev-eng/docs/01-starting-point.md`](rev-eng/docs/01-starting-point.md), while
the KernelSU starting state is recorded in
[`rev-eng-journey.md`](rev-eng-journey.md).

## What "Magisk on ReDroid 13" means in this repository

The Magisk setup guide covers ReDroid 13, but that does not mean it claims a
fully reliable rooted Android 13 + Zygisk + LSPosed deployment on this Oracle
ARM64 host.

It separates three cases:

1. **Clean Android 13 baseline.** An official `_64only` ReDroid 13 image is
   suitable for proving that the host, Binder, PSI, and container boot path
   work.  It is deliberately a clean/unrooted baseline.
2. **A13 bootless-Magisk limitation.** The guide records the observed
   `magiskpolicy` crash on Oracle ARM64.  When it occurs, Magisk may expose
   some `su` functionality, but the module-injection path does not complete;
   consequently Zygisk and LSPosed cannot be treated as working.
3. **Recommended rooted Magisk route.** For Magisk plus Play Store, Zygisk,
   LSPosed, and 32-bit app support, the guide recommends the tested Android 11
   image `abing7k/redroid:a11_gapps_magisk_arm` rather than claiming that A13
   has been repaired.

The distinction matters because `a13_1` is a container name used by the old
research record; it is not proof that every Android 13 Magisk image has a
reliable Zygisk/LSPosed chain.

## How the old Magisk work handled its limitations

The older research environment reached a usable hook state through targeted
workarounds.  These were practical steps for that image, not a general A13
bootless-Magisk fix:

1. It used `/system/xbin/su 0` because the other documented Magisk `su` path
   returned `Permission denied`.
2. The expected `/data/adb/magisk/` layout was incomplete.  The local
   `setup_magiskbin.sh` restored the required Magisk files.
3. `magisk --install-module` still failed with exit `127` because of the
   image's BusyBox/tmpfs expectation.  LSPosed was then assembled and placed
   manually for that specific research environment.
4. PairIPFix and the custom LSPosed module were enabled and scoped by editing
   LSPosed's SQLite configuration database.
5. A `docker restart a13_1` was used to make the direct database changes take
   effect, because LSPosed caches its configuration.

This is why the old documentation contains manual placement commands that the
general Magisk guide warns against.  The general guide describes the safer
normal path—install the LSPosed ZIP through the Magisk Manager UI—because
merely placing a module directory can create a false "installed" indication
without a real Zygisk injection.

## Why KernelSU changes the operational workflow

ReDroid is Android userspace in a container and shares the host Linux kernel;
there is no separate Android `boot.img` to patch.  The two root paths therefore
attach at different layers:

```text
Magisk path
host kernel -> ReDroid Android init -> bootless Magisk -> Magisk Zygisk -> LSPosed

KernelSU path
host kernel + KernelSU hooks -> ReDroid Android init -> Zygisk Next -> LSPosed
```

For KernelSU-Next, the documented integration has one-time state in the host
kernel.  Restarting Docker creates a new Android init but does not reload the
host kernel or reset that state.  Newly staged root modules therefore need a
full VPS reboot, followed by confirmation of the custom kernel, service order,
Android boot completion, Zygisk, and LSPosed.

For a working Magisk container, the relevant module lifecycle is inside the
Android/container side, so a Docker restart was the documented activation
mechanism.  Do not use the KernelSU host-reboot rule as evidence that every
Magisk change needs a host reboot, and do not use the Magisk Docker-restart
rule to activate newly staged KernelSU modules.

## PairIP and freeRASP work that is shared

Both journeys use runtime instrumentation rather than repackaging or resigning
the target APK:

- The original split APK is installed while retaining its signature.
- PairIPFix is installed as an LSPosed module, enabled, and scoped only to the
  target app.
- The custom `talseckill` LSPosed module suppresses the Java/React-Native
  freeRASP threat-delivery and termination paths.
- Scope is intentionally narrow: `com.targetapp`, user `0`.

The implementation mechanism—an LSPosed hook loaded into the app process—is
independent of whether the underlying Zygisk provider came from Magisk or
Zygisk Next.  What differs is the reliability and activation procedure of that
provider in each environment.

## The stable UI fix

### What the earlier hooks missed

The initial custom module blocked Java-level paths such as `System.exit`,
`Process.killProcess`, activity teardown, and the React-Native threat callback
flow.  That stopped the visible Java/JS reaction but did not stop the later
foreground `SIGKILL`.

The reason is that the final kill did not pass through those Java wrappers.  A
native function in `libts.so` reached libc's `kill()` path, and signal 9 cannot
be caught after it is sent.

### How it was identified

The later KernelSU investigation used the shared host kernel's
`signal:signal_generate` tracepoint.  It proved that target was sending the
signal to itself, rather than being killed by Android's ActivityManager, the
watchdog, low-memory killing, or another process.

Static/decompiled analysis then resolved the exact delayed path:

```text
Z.x(...)
  -> C10611o0.a(int)
    -> main-looper delay of about 8 seconds
      -> androidx.security.FNatives.x(int)
        -> getpid()
        -> kill(pid, SIGKILL)
```

The final custom module hooks only `androidx.security.FNatives.x(int)` and
returns before ART enters the JNI implementation.  It does not disable the
separate `FNatives.y(...)` or `FNatives.z(...)` crypto/integrity functions.
This is a precise app-build-specific fix, not a blanket native-kill or generic
freeRASP bypass.

### Could the same fix have been found and used with Magisk?

**Yes, conditionally.** Nothing about the final enforcement point requires
KernelSU:

- Host-kernel signal tracing works for either provider because both ReDroid
  containers share the VPS kernel.
- The final action is a standard LSPosed method hook before JNI execution.
- Therefore a healthy Magisk + Zygisk + LSPosed instance could compile, install,
  scope, and run the same `talseckill` module.  Its activation would follow the
  working Magisk container lifecycle rather than the KernelSU host reboot.

**No, on a broken A13 Magisk injection chain.** If the Android 13
`magiskpolicy` problem has stopped Zygisk/LSPosed from loading, the module
cannot enter the target process.  The correct `FNatives.x` hook then exists on
disk but has no opportunity to run.  In that case, first move to a verified
Magisk-compatible image/environment or use the KernelSU route.

KernelSU was useful here because it created a stable, repeatable ReDroid 14
test bed in which the full root, Zygisk, and LSPosed stack could be verified
after each change.  It was not a technical prerequisite for discovering the
JNI boundary or implementing the hook.

## Decision guide

| Situation | Appropriate path |
|---|---|
| Need to validate host/container boot on Android 13 | Use the clean A13 `_64only` baseline; do not infer that Magisk modules work from this alone. |
| Need a Magisk, Play Store, Zygisk, and LSPosed deployment on this Oracle ARM64 setup | Prefer the documented tested Android 11 Magisk image and confirm a live LSPosed hook before app work. |
| Need the repository's validated target/ReDroid 14 workflow | Use KernelSU-Next + Zygisk Next + LSPosed and its host-reboot/service validation steps. |
| Want to port the stable target fix to Magisk | First prove Magisk Zygisk and LSPosed are injecting into target, then use the same narrowly scoped `FNatives.x(int)` hook and test sustained foreground survival. |
| App update changes `libts.so`, Java names, or timing | Re-attribute and reanalyse; do not assume this hook covers a different APK build. |

## Validation requirements

For either root provider, do not call the fix successful merely because the
module appears enabled in a manager UI.  Verify all of the following:

1. The relevant Zygisk provider and `lspd` process are alive.
2. The module is enabled and scoped only to target in the LSPosed database.
3. target reaches `MainActivity` without a PairIP redirect.
4. The `FNatives.x` guard logs that it loaded and blocked the call.
5. The same foreground PID remains focused across a sustained observation
   window; the validated KernelSU run checked 10 through 70 seconds.
6. Logs contain no signal-9 process death, fatal exception, or ANR for the
   target.

## Primary repository references

- [Magisk ReDroid setup guide](Magisk_setup/oracle-vps-redroid-magisk-setup.md)
- [Android 13 vs Android 11 rooting analysis](Magisk_setup/Redroid-A13-vs-A11-Rooting-Analysis.md)
- [Earlier reverse-engineering starting point](rev-eng/docs/01-starting-point.md)
- [Earlier Magisk/Redroid dead ends](rev-eng/docs/02-dead-ends.md)
- [JNI self-kill research and rationale](rev-eng/docs/04-native-selfkill-research.md)
- [Final KernelSU/target journey and proof](rev-eng-journey.md)
- [KernelSU host build and operational journey](KernelSU_setup/my_setup_journey.md)
