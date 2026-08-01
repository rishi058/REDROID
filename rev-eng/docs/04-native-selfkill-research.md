# Problem 8 — Resolved JNI self-kill, plus historical native prior art

The former last unsolved item was a `SIGKILL` after the JS threat reaction was desynced. Host-kernel
tracing has now proved that target-app sends the signal to itself through libc `kill()`, entered from
ART's generic JNI trampoline. The exact path is an eight-second delayed call to native
`androidx.security.FNatives.x(int)`, which executes `kill(getpid(), SIGKILL)`.

The working fix hooks that one native Java method with LSPosed before JNI executes. target-app then
kept the same foreground PID for at least 70 seconds with no kernel-observed `SIGKILL` targeting
it. See [`../../rev-eng-journey.md`](../../rev-eng-journey.md) §8 for commands and proof. The native instrumentation material below
is retained as historical prior art, not as the recommended implementation.

> Research method note: general search engines were bot‑blocked in the research environment;
> findings came from the GitHub/Sourcegraph/Juejin APIs + direct raw‑file fetches. All URLs were
> verified reachable at time of research (2026‑07). Recency skews 2024–2026.

---

## 1. Executive summary

- **Resolved locally:** host `signal:signal_generate` tracing identified a same-process sender and
  target; its user stack was libc `kill` called from `art_quick_generic_jni_trampoline`.
- **Exact boundary:** `C10611o0` schedules `androidx.security.FNatives.x(int)` after eight seconds;
  static analysis of `Java_androidx_security_FNatives_x` confirms `getpid(); kill(pid, 9)`.
- **Narrow fix:** hook only `FNatives.x(int)` and return `null`. Separate native methods
  `FNatives.y()` and `FNatives.z()` remain available for app crypto/integrity operations.
- **No native injector required:** Frida, seccomp, PLT patching, and raw-SVC patching are unnecessary
  for this exact APK. The generic techniques below remain useful only for a different build/path.
- **Talsec AppiCrypt (the `crypt` App‑Integrity cryptogram) and the secret vault: no public break
  exists.** Only vendor docs. Irrelevant to us anyway — we read secrets via the oracle, not by
  breaking the vault.

**Verdict for this build:** solved at a stable Java-to-JNI boundary without modifying the target
APK or native library.

---

## 2. Why the original Java hooks missed it — and why the final hook works

`bionic`'s `kill(getpid(), SIGKILL)` is a thin libc wrapper over the `kill`/`tgkill` syscall — it
never enters the ART/Java layer, so `System.exit`/`Process.killProcess`/`Runtime.halt`/`Os.kill`
hooks are blind to the native call itself. **SIGKILL (9) cannot be caught or handled.** However,
this build reaches the native code through the declared ART method `FNatives.x(int)`. LSPosed can
short-circuit that method before ART enters its JNI implementation, so the signal is never sent.

Generic fallback hierarchy for a build without a hookable JNI boundary:
1. **libc export** (`kill`, `_exit`, `exit`, `abort`, `raise`, `pthread_kill`, `tgkill`, `killpg`)
   — catches almost all real‑world anti‑tamper code (which calls the wrapper, not raw `svc`).
2. **`syscall()` wrapper** filtered by number — catches `syscall(__NR_exit_group, …)` etc.
3. **Inlined `svc #0`** (`mov x8,#94; svc #0`) — *not* interceptable at a function boundary; needs
   instruction patching (Stalker / `Memory.patchCode`) or an out‑of‑process seccomp/ptrace tracer.

arm64 syscall numbers to filter: `__NR_exit`=93, `__NR_exit_group`=94, `__NR_kill`=129,
`__NR_tgkill`=131 (arm32/EABI differ: exit_group=248, kill=37).

---

## 3. Prior art — Talsec/freeRASP‑specific (all Java/JS layer, Community edition)

| Tool | URL | Platform | Technique | Stops native kill? |
|---|---|---|---|---|
| fireshell writeup (origin) | https://fireshellsecurity.team/bhackctf2024-bypass-freerasp-callbacks/ | Android | hook `Intent.getStringExtra`→`""` on action `TALSEC_INFO` so the receiver's `switch` matches nothing | ❌ |
| luca‑regne/android‑freerasp‑bypass | https://codeshare.frida.re/@luca-regne/android-freerasp-bypass/ | Android | same `TALSEC_INFO` trick, packaged as Frida | ❌ |
| **pyrosec/unrasp** | **https://github.com/pyrosec/unrasp** | **Android LSPosed** | `TALSEC_INFO` blank + no‑op `ThreatListener.onReceive` + Java `Process.killProcess`/`System.exit` hooks | ❌ (Java‑only kill block — same limit as ours) |
| muhammadhikmah…/bypass‑talsec‑rasp | https://codeshare.frida.re/@muhammadhikmahhusnuzon/bypass-talsec-rasp-and-root-detection/ | Flutter/Android | neutralise `EventChannel 'talsec.app/freerasp/events'` + root/debug/exit Java hooks | ❌ |
| iOS variants (FYI) | harshitreylon/FalseRASP · ItsFadinG/iOS‑Talsec‑FreeRASP‑Flutter‑Bypass · rodolfomarianocy/… · 0tax00/ios‑freerasp‑bypass | iOS | replace native `talsecStart`/EventChannel callback; hook `ptrace`/`exit` | n/a |

**Pattern:** the community defeats freeRASP by muting the **threat callback**, not the kill. Our
`getThreatChannelData` desync is the same philosophy and already works for the JS layer; the
hardened build's *native* enforcement is the part none of these address.

Talsec AppiCrypt / vault: only vendor material (talsec.app/appicrypt, docs.talsec.app,
deepwiki.com/talsec/Free-RASP-Android — "proprietary binary components"). **No public break.**

---

## 4. Prior art — stopping a NATIVE self‑kill (generic, reusable)

### 4.1 Frida (fastest to try)

- **apkunpacker/FridaScripts — `StopExit.js`** (best reference):
  https://github.com/apkunpacker/FridaScripts/blob/main/StopExit.js
  `Interceptor.replace` on libc `kill/exit/_exit/abort/raise` (return 0); also rewrites
  `system("…kill…")` args; includes backtrace‑on‑call to identify the caller. Sibling `AntiDebug.js`
  = ptrace/port anti‑debug bypass.
- **dodal‑omkar/no‑exit‑please_Frida_Script_Android** (recent, Java+native):
  https://github.com/dodal-omkar/no-exit-please_Frida_Script_Android — Java exit hooks + native
  `Interceptor.replace` on `exit/_exit/abort/kill`. Gaps: no `raise`/`pthread_kill`/`tgkill`/`syscall`.
- Do not use one shared callback ABI for unrelated libc functions, and do not make noreturn
  `exit`/`_exit` paths return; that can fall into a compiler trap. If native instrumentation is ever
  required, block only the proven self‑targeted `SIGKILL` and forward every other call.
- Must be **spawn‑injected** (`frida -U -f com.target-appapp --no-pause`) to beat the ~18 s timer.
- Frida API: https://frida.re/docs/javascript-api/ · https://fridocs.readthedocs.io/en/latest/interceptor.html

### 4.2 Module‑scoped hook (avoid breaking legit teardown / frida itself)

Replacing libc `kill` globally is blunt (ART, the agent, normal shutdown also call it). Scope to
calls **originating from `libts.so`**:

- **ByteHook** (cleanest): `bytehook_hook_single("libts.so","libc.so","kill", my_kill, …)` —
  https://github.com/bytedance/bhook
- **xHook** (PLT/GOT, regex caller): `xhook_register("libts\\.so$","kill",my_kill,NULL)` —
  https://github.com/iqiyi/xHook
- Frida equivalent: `Process.getModuleByName('libts.so').enumerateImports()` → replace only the
  `kill`/`_exit`/`exit` import slots; or global `attach` + `Thread.backtrace()`/`returnAddress`
  range‑check against `libts.so` and only neutralise those.

For this exact `libts.so`, `kill` is also stored through an ABS64 data relocation rather than only
a PLT jump slot, so PLT‑only hookers may miss the relevant call. This is another reason the proven
`FNatives.x` boundary is preferable.

### 4.3 Native inline‑hook engines (when Frida is detected / for a baked‑in patch)

Run inside the target via injection or repackage; also usable via LD_PRELOAD on root.

| Lib | Type | URL |
|---|---|---|
| jmpews/Dobby | inline (multi‑arch), dominant in CN RE | https://github.com/jmpews/Dobby |
| bytedance/android‑inline‑hook (ShadowHook) | inline, modern/stable | https://github.com/bytedance/android-inline-hook |
| bytedance/bhook (ByteHook) | PLT, per‑caller scoping | https://github.com/bytedance/bhook |
| iqiyi/xHook | PLT/GOT | https://github.com/iqiyi/xHook |
| Rprop/And64InlineHook | arm64 single‑header | https://github.com/Rprop/And64InlineHook |

Install in an `__attribute__((constructor))` so the hook is live before the RASP timer.
`LD_PRELOAD` stub (root): define your own `kill/_exit/exit/abort/raise` returning early — coarse,
global, misses inlined syscalls.

---

## 5. Anti‑anti‑Frida (historical; only if instrumentation is reintroduced)

Because `libts.so`'s native anti‑Frida runs and *causes* the kill, defeating the kill is pointless
unless detection is also defeated (or you hook natively from process start with a low footprint).

Detections seen in our strings → evasions (from CN blogs + androidmobiles guide):

- **`/proc/self/maps` scan** for `frida-agent`/`memfd`/gadget → hook native `open`/`openat`/`fopen`
  (+ `java.io.FileReader`) to serve a sanitised maps; or use a gadget with masked mappings.
- **`scan_for_frida_server_all_ports` / port 27042** → use a **non‑default port**; better, inject a
  renamed frida‑gadget (no listening server at all) — CN community favours **ZygiskFrida**
  (`lico-n/ZygiskFrida`, connect via `frida -H 127.0.0.1:<port> -n Gadget`).
- **thread/symbol names** (`frida`, `gum-js-loop`, `gmain`) + **`LIBFRIDA`/`strstr`** → rename
  gadget + threads; hook `strstr` filtering `"frida"`.
- **Prologue‑byte hook checks** → prefer **Stalker** (dynamic binary translation, no prologue
  change) or accept that inline hooks (Dobby) are themselves detectable.
- **Root‑triggered exit** → hide root with **Shamiko/Zygisk** so the root threat never fires.

Key CN sources (2026, mainstream):

- CYRUS_STUDIO "Frida 检测与对抗实战…全特征清除": https://juejin.cn/post/7629183326779899931
- 陆业聪 "绕过Frida/Xposed的最后防线：SVC直接系统调用与Native反Hook实战":
  https://juejin.cn/post/7646674707382648847 (defender POV — names every attacker evasion; confirms
  **raw `svc` syscalls defeat libc‑export hooking**, so a robust bypass hooks the callback/Java
  layer or goes kernel‑level)
- ZygiskFrida injection: https://juejin.cn/post/7577691061034156078
- Dobby InlineHook recipe (HURUWO): https://juejin.cn/post/7037008680885157919
- Android anti‑Frida evasion guide (EN): https://androidmobiles.org/detecting-evading-android-anti-frida-anti-tampering-mechanisms-a-practical-guide/
- Talsec's own detection writeups (know thy enemy):
  https://docs.talsec.app/appsec-articles/articles/hook-hack-defend-fridas-impact-on-mobile-security-and-how-to-fight-back

---

## 6. Completed implementation

1. Trace `signal:signal_generate` on the shared host kernel to identify sender and target.
2. Symbolise the sender stack as libc `kill` from ART's generic JNI trampoline.
3. Resolve the delayed caller as `androidx.security.FNatives.x(int)` and confirm its native body is
   `kill(getpid(), 9)`.
4. Hook only that method in `mod_build/src/com/recon/talsecbypass/Hook.java`.
5. Rebuild/reinstall `modules/talseckill.apk`, preserve its target-app-only scope, and reboot the VPS.
6. Verify the same foreground PID for 70 seconds, observe the hook firing, and confirm that the
   host records no signal 9 targeting target-app.

No Frida server, seccomp filter, native memory patch, or tracer remains active after validation.

---

## 7. Link index

- unrasp (Android LSPosed): https://github.com/pyrosec/unrasp
- StopExit.js: https://github.com/apkunpacker/FridaScripts/blob/main/StopExit.js
- no‑exit‑please: https://github.com/dodal-omkar/no-exit-please_Frida_Script_Android
- fireshell freeRASP writeup: https://fireshellsecurity.team/bhackctf2024-bypass-freerasp-callbacks/
- luca‑regne Frida bypass: https://codeshare.frida.re/@luca-regne/android-freerasp-bypass/
- Dobby: https://github.com/jmpews/Dobby · ShadowHook: https://github.com/bytedance/android-inline-hook
- ByteHook: https://github.com/bytedance/bhook · xHook: https://github.com/iqiyi/xHook · And64InlineHook: https://github.com/Rprop/And64InlineHook
- CN Frida countermeasures: https://juejin.cn/post/7629183326779899931 · https://juejin.cn/post/7646674707382648847
- ZygiskFrida: https://juejin.cn/post/7577691061034156078 · Dobby recipe: https://juejin.cn/post/7037008680885157919
- Frida API: https://frida.re/docs/javascript-api/

### The key research verdict:

  No public tool defeats a hardened Talsec build's native self-kill. Every existing freeRASP/Talsec bypass (fireshell, luca-regne, pyrosec/unrasp, the Flutter/iOS ones) is Java/JS-layer targeting the Community edition's threat callback — which is exactly what our module already does. None stop a native kill(). Your symptoms (libts.so, native anti-Frida strings, native SIGKILL) = the commercial/hardened build they don't address.

  The general technique does exist and is reusable: hook libc kill/_exit/abort/raise/pthread_kill + the syscall path via Frida Interceptor.replace (best refs: apkunpacker/FridaScripts/StopExit.js, dodal-omkar/no-exit-please), or a native inline/PLT hooker (Dobby / ShadowHook / ByteHook / xHook) scoped to libts.so. But it only works if paired with anti-anti-Frida (masked /proc/self/maps, renamed gadget/ZygiskFrida, non-default port, Shamiko) — otherwise the detection just re-fires the kill. The hard edge is an inlined svc #0 syscall, which needs Stalker/instruction-patching or a ptrace/seccomp tracer.

  Talsec AppiCrypt cryptogram + secret vault: no public break exists — vendor docs only. (Irrelevant to us; the oracle reads the secrets anyway.)

  The doc has the full link index, arm64 syscall numbers, a copy-paste Frida starter, the module-scoping approach, and a 5-step diagnose→neutralize→scope→escalate plan — everything you need to implement later without re-researching.

> Net: it's achievable but a genuine cat-and-mouse effort

---

## 8. Follow-up — the practical bypass was achieved

The sentence above records the uncertainty at the end of the research phase. It
is no longer the final project verdict. The remaining native self-kill was later
attributed to one exact Java-to-JNI boundary and neutralised reliably without a
general native anti-anti-Frida framework.

The complete chronological evidence is in
[`../../rev-eng-journey.md`](../../rev-eng-journey.md), especially §8. This
section preserves the successful path so the document reads as a journey from
generic prior art to a proven target-specific fix.

### 8.1 What the earlier experiments established

Before the exact sender was known, the project had already removed the visible
Java/React Native reactions:

- PairIPFix allowed Target-App to reach its real activity;
- the custom LSPosed module desynchronised Talsec's threat channel;
- Java `System.exit`, process-kill wrappers, activity teardown, and task
  backgrounding were guarded; and
- Target-App remained foreground longer than before but still died with signal
  9 after the delayed native reaction.

Android's exit history reported a foreground `SIGKILL`, but did not identify the
sender. A temporary Frida libc probe did not log the final call because the
process could die before its last diagnostic message was delivered. The broad
seccomp experiment was also rejected: denying `exit`/`exit_group` broke normal
process semantics and produced a startup `SIGILL`/ANR.

Those failures narrowed the problem but did not prove that the kill was an
unhookable inline syscall.

### 8.2 Attribute the sender from the shared host kernel

Redroid shares the VPS kernel. A bounded host-side
`signal:signal_generate` tracepoint captured both sender and target while
Target-App was launched:

```text
sender=<TARGET_PACKAGE> pid=<PID> tid=<PID> uid=<APP_UID>
target=<TARGET_PACKAGE> target_pid=<PID> code=0 group=1 result=0
```

The sender and target were the same process. This ruled out:

- ActivityManager;
- `lmkd`/OOM;
- the Redroid watchdog;
- an external anti-tamper helper; and
- a remote process issuing the signal.

The captured user stack resolved to:

```text
libc.so: kill
libart.so: art_quick_generic_jni_trampoline
```

That stack was the decisive clue. The final signal did use native libc
`kill()`, but execution entered through an ART native-method trampoline. The
call could therefore be stopped before JNI rather than patched inside libc or
`libts.so`.

### 8.3 Resolve the exact delayed path

The decompiled Java and matching ARM64 native library established this sequence:

```text
obfuscated scheduler
  -> main-looper Handler delay (~8000 ms)
    -> androidx.security.FNatives.x(int)
      -> getpid()
      -> kill(pid, SIGKILL)
```

Static analysis of `Java_androidx_security_FNatives_x` confirmed that it obtains
the current PID, loads signal 9, and invokes `kill`.

The neighbouring native methods were distinct:

- `FNatives.x(int)` — delayed self-kill;
- `FNatives.y(...)` — protected native operation; and
- `FNatives.z(...)` — AppiCrypt/integrity signing path.

Only `x(int)` could be disabled. Replacing the complete native class or blocking
all calls into `libts.so` would also break the genuine cryptographic flow needed
by Target-App.

### 8.4 Add the narrow LSPosed boundary hook

The final implementation in
`rev-eng/mod_build/src/com/recon/talsecbypass/Hook.java` hooks the declared
native Java method and returns before ART enters JNI:

```java
XposedHelpers.findAndHookMethod(
    "androidx.security.FNatives",
    classLoader,
    "x",
    int.class,
    new XC_MethodHook() {
        @Override
        protected void beforeHookedMethod(MethodHookParam param) {
            param.setResult(null);
        }
    }
);
```

The implementation also retained narrow framework guards for self-targeted
`SIGKILL` paths while forwarding other signals and other target PIDs. It did not
replace `FNatives.y()` or `FNatives.z()`.

Build and reinstall the separate LSPosed module; Target-App itself remains
unmodified and Play-signed:

```powershell
& "C:\Program Files\Git\bin\bash.exe" rev-eng/mod_build/build_module.sh
adb -s 127.0.0.1:5555 install -r "rev-eng\modules\talseckill.apk"
```

The module must remain enabled and scoped only to `<TARGET_PACKAGE>` user 0.
After an APK reinstall, compare the current `pm path` with LSPosed's stored
`modules.apk_path`; Android may assign a new randomized APK path.

### 8.5 Apply it with a full KernelSU host reboot

An Android-only or Docker-only restart did not reliably replay KernelSU's boot
stages. In failed restart attempts, Zygisk was absent from Zygote maps and
LSPosed never injected the module.

Apply the update with a complete VPS reboot:

```powershell
ssh -i "<SSH_KEY>" -o StrictHostKeyChecking=no `
  ubuntu@<VPS_HOST> "sudo reboot"
```

After the host returns, recreate the ADB tunnel, wait for
`sys.boot_completed=1`, and verify:

```text
Zygisk mappings present in Zygote
lspd daemon running
LSPosed module enabled
scope contains <TARGET_PACKAGE>, user 0
Loading class com.recon.talsecbypass.Hook
```

### 8.6 Sustained runtime proof

After the full reboot, Target-App was launched normally while the host traced
all generated `SIGKILL` events.

The same foreground PID remained alive and focused at:

```text
10, 20, 30, 40, 50, 60, and 70 seconds
```

Safe LSPosed evidence showed:

```text
[TalsecKill] FNatives.x native self-kill guard installed
[TalsecKill] FNatives.x native self-kill blocked
```

The host trace recorded no signal 9 targeting Target-App after the guard was
installed. A final scan found no fatal exception, ANR, process-death message, or
signal-9 exit, and the original PID remained the focused application.

No Frida agent, seccomp filter, native memory patch, or host tracer remained
attached after validation.

### 8.7 Updated verdict

The generic anti-tamper landscape is still a cat-and-mouse problem, but this
specific hardened build is **resolved reproducibly**:

1. suppress the Java/React Native threat-delivery and teardown reactions;
2. identify the actual signal sender at the shared host kernel;
3. resolve the exact ART-to-JNI method responsible for the native self-kill;
4. hook only `FNatives.x(int)` before JNI;
5. preserve `FNatives.y()` and `FNatives.z()`; and
6. apply the scoped module through a complete KernelSU host reboot.

The final result is a stable Target-App process beyond the former
eight-to-twenty-second kill window, achieved without repackaging the target APK
or deploying a permanent native injector.
