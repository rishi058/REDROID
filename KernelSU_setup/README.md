# KernelSU ReDroid Setup Notes

This directory contains the reproducible kernel build records, compatibility
patches, deployment scripts, and operational runbooks for running ReDroid 14
with KernelSU Next, Zygisk Next, and LSPosed.

The production/experimental boundary is strict:

- `redroid14` is the production Android instance serving DW-fast-api users.
- `redroid-experimental` is an isolated Coolify service for application tests.
- They have separate BinderFS devices, `/data` directories, hostnames, network
  identities, and ADB paths.
- Never target production data or recovery actions while operating on the
  experimental instance.

See [coolify/setup-guide-coolify.md](coolify/setup-guide-coolify.md) for the
validated production runbook and [my_setup_journey.md](my_setup_journey.md) for
the original kernel research record.

## Document ownership

This file and [multi-instance-kernel-patch-plan.md](multi-instance-kernel-patch-plan.md)
cover the kernel work together and must not drift. Each fact has exactly one home;
the other document links to it rather than restating it.

| Topic | Canonical location |
|---|---|
| Per-file purpose of everything in `wsl/`, and when to run it | **this file**, [tooling](#kernel-build-tooling-wsl) |
| The nine multi-instance requirements and their met/not-met status | **this file**, [requirements](#requirements-for-a-future-multi-instance-kernel-patch) |
| Requirement 6 analysis, kernel-capability comparison, operational rules | **this file**, [requirement 6](#what-requirement-6-being-out-of-scope-actually-means) |
| Production/experimental operating rules and current runtime state | **this file**, [operational decision](#current-operational-decision) |
| Plain-language summary of what two rooted instances cost the operator | **this file**, [read this first](#read-this-first-running-two-rooted-instances) |
| Build procedure, phase reasoning, execution record, findings, runbook | [multi-instance-kernel-patch-plan.md](multi-instance-kernel-patch-plan.md) |
| Package revisions, SHA256 hashes, per-phase status | [multi-instance-kernel-patch-plan.md](multi-instance-kernel-patch-plan.md) — authoritative, deliberately **not** restated here |

When changing anything, update the canonical location, then check the other
document only for statements that would become false.

## Read this first: running two rooted instances

**Goal.** Keep `redroid14` serving production untouched, and run experiments in
`redroid-experimental` with KernelSU, Zygisk Next, and LSPosed active in **both**
containers at the same time.

**Where it stands.** Not achieved yet. The kernel that does it, `6.8.12-zksu-multi`,
is built and verified on the development machine but **has never been installed or
booted**. Today the second container still gets no Zygisk and no LSPosed. What
remains is Phases 8 to 15: install it on the VPS and test it, which needs a
maintenance window, an Oracle boot-volume backup, and serial-console access first.
The specific fault is fixed in code and the fix is confirmed present in the built
kernel, but it has never run, so treat it as "expected to work, unproven".

**Three things you give up, in plain words.** None of them stops Zygisk or LSPosed
from running, and none makes production worse than it is today.

1. **The KernelSU app only behaves properly in one container at a time.** The
   kernel has a single "admin seat", and both containers keep pushing each other
   out of it, so the app may show wrong status or "not installed" in one of them.
   Zygisk and LSPosed still start on their own at boot. You just install and remove
   modules by typing `ksud` commands over adb instead of tapping in the app.

2. **Do not use the "grant root to this app" feature.** The kernel cannot tell the
   two containers apart for app permissions. Granting root to an app in
   experimental can also grant it to an unrelated app in production, and installing
   or removing an app in experimental can silently wipe permissions you set in
   production. **Leave that list empty.** Zygisk and LSPosed do not need it.

3. **"Safe mode" is shared.** If it ever triggers in one container, modules are
   disabled in both.

**One security point you should know.** Because the two containers share one
kernel, anything that gets root *inside* a container can get root on the **whole
VPS**. That is true of the kernel you are running today, not something the new one
introduces, and there is no fix available for it. In practice: do not run apps you
genuinely do not trust in the experimental container, and never let `adb` be
reachable from the internet. Details and sources in
[upstream research](#upstream-research-is-there-a-fix-or-workaround).

The remaining risk is not in that list. It is that this kernel has never been
booted and the only ARM64 machine available to test it on is the one serving your
users. That is why Phases 8 to 15 require a backup and console access before the
first reboot.

Why these three limits exist, with the code behind them, is in
[what requirement 6 being out of scope actually means](#what-requirement-6-being-out-of-scope-actually-means).
What changes between the old and new kernel is in
[what actually changes between the two kernels](#what-actually-changes-between-the-two-kernels).

## Kernel build tooling: `wsl/`

Everything needed to rebuild the ARM64 kernel on a Windows computer under WSL2
lives in [wsl/](wsl/). The full narrative, including why each patch exists and
what failed on the way, is in
[multi-instance-kernel-patch-plan.md](multi-instance-kernel-patch-plan.md); this
section is the per-file reference.

All scripts assume the WSL user `builder` and honour these environment
overrides: `BUILD_ROOT` (default `/home/builder/kbuild`), `REPO_WSL` (default
`/mnt/d/PROJECT/_TRASH/REDROID`), and `JOBS` (default 6). Run them from Windows
as:

```bash
wsl.exe -d Ubuntu -u builder -- bash /mnt/d/PROJECT/_TRASH/REDROID/KernelSU_setup/wsl/<script>
```

Pass the script as a file path. Do not inline the body with `bash -c` from Git
Bash: MSYS argument marshalling silently blanks `$VAR` references, which
produces confusing errors like `grep: : No such file or directory`.

### Build pipeline, in order

| # | File | When to run | What it does |
|---|---|---|---|
| 1 | [wsl/prepare-source.sh](wsl/prepare-source.sh) | Once, on an empty `BUILD_ROOT` | Clones Linux v6.8.12 and the pinned KernelSU Next commit, wires KernelSU into `drivers/`, copies the retained project inputs, then applies the two Linux Binder patches and the three KernelSU compatibility patches. Refuses to run if `$BUILD_ROOT/linux-6.8.0` already exists. |
| 2 | [wsl/apply-multi-instance.py](wsl/apply-multi-instance.py) | Once, after step 1 | Rewrites `KernelSU-Next/kernel/runtime/ksud_integration.c` into the multi-instance boot-lifecycle candidate: per-open-file init-RC state, namespace-aware init detection, hooks left registered for later Android instances. Not idempotent — it fails loudly if the anchors are already gone. |
| 3 | [wsl/compile-gates.sh](wsl/compile-gates.sh) | After step 2, and after any patch change | Restores `config.completed`, runs ARM64 `olddefconfig`, asserts the eleven required config options and the `6.8.12-zksu-multi` release string, then compile-gates `security/selinux/`, `drivers/kernelsu/`, and `drivers/android/`, and finally calls `verify-binder-edits.sh`. **Starts with `make clean`** — never run it against an object tree you still need. |
| 4 | [wsl/build-packages.sh](wsl/build-packages.sh) | After step 3 passes | Runs `bindeb-pkg` to produce the ARM64 image and headers `.deb`s, asserts exactly one of each and `Architecture: arm64`, writes `SHA256SUMS`, then exports packages, config, log, and the compile-validated multi-instance patch back into this repository. Incremental: safe to re-run without cleaning. |
| 5 | [wsl/verify-packages.sh](wsl/verify-packages.sh) | After step 4 | Acceptance gate. Re-checks `SHA256SUMS`, prints package metadata, then extracts `binder_linux.ko` **out of the finished `.deb`** and confirms it has an `init_module` symbol, distinct `debug_mask`/`alloc_debug_mask` parameters, a `devices` parameter, and vermagic `6.8.12-zksu-multi`. Also asserts the per-namespace record symbols are in the shipped `System.map` and that the upstream one-shot flags are not. A build-tree check is not proof about the shipped artifact. |

### Verification and utility

| File | When to run | What it does |
|---|---|---|
| [wsl/verify-binder-edits.sh](wsl/verify-binder-edits.sh) | Automatically by `compile-gates.sh`; standalone any time | Static assertion that all 20 Binder source changes are present exactly once and that their pre-patch forms are gone. This is the only cheap gate for the `device_initcall`/`module_init` defect, which compiles cleanly and yields a valid `.ko` that never initialises — so no compiler or linker will ever report it. |
| [wsl/syntax-check.sh](wsl/syntax-check.sh) | After editing anything in `wsl/` | `bash -n` on every `.sh` and an AST parse on every `.py` in the directory. Executes none of them. |
| [wsl/check-docs.sh](wsl/check-docs.sh) | After editing this file or the plan | Guards the two documents against drift. Resolves every cross-document and intra-document anchor, confirms every linked file exists, confirms every `wsl/` script is described somewhere, and fails if this file restates a package revision or hash that the plan owns. Prints `DOC_CHECK_PASSED`. |
| [wsl/rebuild-multi-instance.sh](wsl/rebuild-multi-instance.sh) | After editing `apply-multi-instance.py` | `apply-multi-instance.py` is not idempotent, so this reverts `ksud_integration.c` to pinned upstream, re-applies it, regenerates and round-trips `kernelsu-redroid-multi-instance.patch`, asserts the upstream one-shot flags are gone and the per-namespace records plus both `ksu_cred` guards are present, then compile-gates `drivers/kernelsu/` for ARM64. Refuses to revert if a compatibility patch owns that file. Rebuild packages afterwards: KernelSU is `=y`, so it is linked into `vmlinux`. |

### Patch regeneration (not needed for normal reproduction)

Only required if a Binder patch stops applying, which means the Linux baseline
has moved off v6.8.12. Normal reproduction uses the committed patches, which
`prepare-source.sh` applies directly.

| File | When to run | What it does |
|---|---|---|
| [wsl/extract-ubuntu-reference.sh](wsl/extract-ubuntu-reference.sh) | Before regenerating, to re-derive the delta | Selectively extracts the 17 files needed from `linux-source-6.8.0_6.8.0-138.138_all.deb` into a separate reference tree, 1.1 MiB instead of several gigabytes. Never overlay this on the build tree. |
| [wsl/regenerate-binder-patches.sh](wsl/regenerate-binder-patches.sh) | To rebuild both Binder patches | Driver. Applies both edit scripts, verifies every edit, regenerates `linux-mainline-6.8-binder-modules.patch` and `linux-mainline-6.8-binder-exports.patch` with path-scoped `git diff`, validates each by reverse-apply, and publishes them into `vps/patches/`. Compiles nothing, so it needs no object tree, and is safe to re-run on an already-patched tree. |
| [wsl/binder_edit.py](wsl/binder_edit.py) | Library; not run directly | All-or-nothing edit engine. Validates every anchor across the whole edit set before writing a single byte, decides idempotency on the *result* text rather than absence of the anchor, and refuses to touch a partially patched tree. |
| [wsl/apply-binder-module-delta.py](wsl/apply-binder-module-delta.py) | Called by `regenerate-binder-patches.sh` | The eight `drivers/android` edits that make Binder a working loadable module: `module_init`, the `alloc_debug_mask` rename, the `show_init_ipc_ns()` accessor, the tristate Kconfig dependency, the composite Makefile, and the `IS_ENABLED`/`kconfig.h` changes. Its docstring records why each is required. |
| [wsl/apply-binder-exports.py](wsl/apply-binder-exports.py) | Called by `regenerate-binder-patches.sh` | The eleven core-kernel `EXPORT_SYMBOL` additions that `binder_linux.ko` imports, plus the `show_init_ipc_ns()` definition and declaration. Every export mirrors Ubuntu 6.8.0-138's type and placement. Changes visibility only, never behaviour. |

### Patches applied by this tooling

| File | Target tree | Purpose |
|---|---|---|
| [artifacts/kernel-build/patches/kernelsu-linux-6.8.patch](artifacts/kernel-build/patches/kernelsu-linux-6.8.patch) | KernelSU Next | Broad Linux 6.8 compatibility. |
| [vps/patches/kernelsu-arm64-cacheflush.patch](vps/patches/kernelsu-arm64-cacheflush.patch) | KernelSU Next | ARM64 instruction-cache handling. |
| [vps/patches/kernelsu-selinux-unavailable.patch](vps/patches/kernelsu-selinux-unavailable.patch) | KernelSU Next | Null-policy guard when host SELinux policy is unavailable. |
| [vps/patches/kernelsu-mainline-6.8-security-api.patch](vps/patches/kernelsu-mainline-6.8-security-api.patch) | KernelSU Next | Restores the three-argument `security_secid_to_secctx` call shape. The broad patch above assumed Ubuntu's newer `lsmcontext` backport; vanilla v6.8.12 does not have it. |
| [vps/patches/linux-mainline-6.8-binder-modules.patch](vps/patches/linux-mainline-6.8-binder-modules.patch) | Linux | Converts Binder/BinderFS into the loadable composite `binder_linux` module, as the deleted Ubuntu tree did. |
| [vps/patches/linux-mainline-6.8-binder-exports.patch](vps/patches/linux-mainline-6.8-binder-exports.patch) | Linux | Exports the eleven core-kernel symbols `binder_linux.ko` imports. Apply after the module patch. |
| [vps/patches/kernelsu-redroid-multi-instance.patch](vps/patches/kernelsu-redroid-multi-instance.patch) | KernelSU Next | Generated output of `apply-multi-instance.py`, kept for review. Regenerate it from the script; do not hand-edit. |

## Important: KernelSU boot initialization is currently single-instance

The current `6.8.12-zksu` host kernel cannot independently initialize the full
KernelSU boot stack for multiple concurrent ReDroid containers.

> **Status as of 2026-08-20.** This section still describes the kernel that is
> *running in production*. A candidate replacement, `6.8.12-zksu-multi`, has been
> built and addresses it, but it has never been installed or booted. Everything
> below therefore remains the operational reality until Phases 8 through 15 of
> [multi-instance-kernel-patch-plan.md](multi-instance-kernel-patch-plan.md) are
> complete. See
> [requirement status](#status-of-these-requirements-in-6812-zksu-multi) for what
> the candidate does and does not solve.

This was verified on 2026-08-19:

1. Production `redroid14` and `redroid-experimental` were started after the same
   host reboot with separate BinderFS devices and separate persistent data.
2. Production started approximately 17 milliseconds first.
3. Production consumed its pending modules and started Zygisk Next and LSPosed.
4. Experimental Android booted normally, but its module `update` markers
   remained pending and no Zygisk or `lspd` process appeared.

Separate BinderFS devices isolate Android Binder IPC; they do not create
separate KernelSU lifecycle state inside the shared host kernel.

### Why this happens

The custom work in this repository builds KernelSU into Ubuntu Linux 6.8 and
adds compatibility fixes. It did **not** implement the init/zygote lifecycle
hooks themselves. Those hooks come from the pinned upstream KernelSU Next source:

```text
repository: https://github.com/KernelSU-Next/KernelSU-Next
commit:     d6a42fd9285c11b8e8e67bfe72a5050528006c00
source:     kernel/runtime/ksud_integration.c
```

The pinned source uses host-global, one-shot state:

```c
static bool first_zygote = true;
static bool init_second_stage_executed = false;
```

It also:

- disables the KernelSU exec hook after the first zygote;
- processes only the first matching Android `init.rc` read and unregisters the
  read/fstat hooks;
- uses global RC append positions and a global module-RC buffer;
- permits `on_post_fs_data()` only once;
- keeps global boot-completed, manager, allowlist, credential, and SELinux state.

The first Android init/zygote after a host boot therefore consumes the lifecycle
path. A later container can run Android and execute `ksud module list`, but it
does not receive the injected KernelSU RC actions needed to process modules and
start Zygisk/LSPosed.

This is also why a Docker-only ReDroid restart cannot replay the complete root
stack. The host kernel did not reboot, so its one-shot state was not reset.

## Scope of the existing custom patches

The repository currently retains patches for:

- Linux 6.8 KernelSU compatibility;
- Linux 6.8 SELinux ABI adaptation;
- conditional Android-netlink compilation;
- ARM64 instruction-cache handling;
- a required null-policy guard when Android SELinux policy is unavailable.

Relevant files:

```text
artifacts/kernel-build/patches/kernelsu-linux-6.8.patch
vps/patches/kernelsu-arm64-cacheflush.patch
vps/patches/kernelsu-selinux-unavailable.patch
```

These patches must be preserved. They do not provide per-container KernelSU
boot state.

## Requirements for a future multi-instance kernel patch

A future implementation must be treated as a kernel architecture change, not a
Compose or shell-script adjustment.

At minimum, it must:

1. Identify each Android instance using a stable kernel identity, most likely
   its mount namespace together with PID-namespace validation.
2. Replace `first_zygote` and `init_second_stage_executed` with synchronized,
   per-instance lifecycle records.
3. Keep the exec/init-RC hooks available for future Android instances without
   applying them to unrelated host processes.
4. Replace the global `init.rc` proxy, append cursor, and module-RC buffer with
   per-open-file or per-instance state that is safe under concurrent boots.
5. Execute each container's `ksud post-fs-data`, `services`, and
   `boot-completed` commands inside that container's mount namespace and against
   its own `/data/adb` tree.
6. Define whether manager identity, UID allowlists, root grants, safe mode,
   boot-completed state, and module-mounted state are global or namespace-scoped.
   Sharing UID-based policy across containers would violate instance isolation.
7. Bound and garbage-collect namespace records when containers are removed or
   recreated.
8. Retain the Linux 6.8, ARM64, SELinux-unavailable, and BinderFS fixes already
   validated by this project.
9. Add explicit kernel logs containing the namespace identity for every init,
   zygote, post-fs-data, service, and boot-completed transition.

Simply removing the one-shot checks or preventing hook unregistration is not a
safe patch. The current RC proxy and boot-policy state are global and would race
when multiple Android instances boot concurrently.

### Status of these requirements in `6.8.12-zksu-multi`

| Req | Status in the candidate |
|---|---|
| 1 | Met. Instance identity is the Android PID namespace, pinned with `get_pid_ns()`, with PID-1-in-namespace validation. |
| 2 | Met. `first_zygote` and `init_second_stage_executed` are gone, replaced by a mutex-protected record list. |
| 3 | Met. Hooks stay registered; scope is limited by the exec path, `current->comm`, and namespace-init checks. |
| 4 | Met. `struct ksu_rc_file` gives every open `init.rc` its own mutex, cursors, and module-RC buffer. |
| 5 | Met. `ksud` stages fire from the container's own exec context, so its mount namespace and `/data/adb`. |
| 6 | **Not addressed. Deliberate.** See below. |
| 7 | Met. Table bounded at 16, swept on insert; `refcount == 1` marks a removed instance. |
| 8 | Met. All four compatibility patches retained, plus the new Binder module and export patches. |
| 9 | Met. `pidns=` appears in every init, zygote, registration, and reap message. |

Runtime behaviour is still unvalidated. "Met" here means implemented and compiled,
not tested on hardware.

### What actually changes between the two kernels

| Capability | `6.8.12-zksu` (running) | `6.8.12-zksu-multi` (candidate) |
|---|---|---|
| First instance: modules mounted, Zygisk Next, `lspd` | Active | Active |
| Second instance: modules mounted, Zygisk Next, `lspd` | **Dead.** Module `update` markers stay pending, no Zygisk process, no `lspd` | **Active** |
| Third and later instances | Dead | Active, table bounded at 16 |
| Instance boot order | Must boot production first or it loses the lifecycle | Order-independent |
| Docker restart of one instance | Cannot replay the root stack; needs a host reboot | New PID namespace gets its own record |
| KernelSU Manager **GUI** app | Works in the one live instance | Works in one instance at a time, and the instances de-register each other |
| `su` UID allowlist | Single instance, so no conflict | Shared and cross-pruned between instances |

The first three rows are the objective. The last two rows are requirement 6, and
they are the price of not solving it. Nothing in the table gets *worse* for a
single instance, which matters because production is the first instance today.

### What requirement 6 being out of scope actually means

Everything the kernel keys on a **UID** is still host-global: KernelSU manager
identity, the `su` UID allowlist and root grants, safe mode, and the
boot-completed and module-mounted flags. Everything keyed on a **namespace** or
stored in `/data` is per-instance.

This does **not** block the goal of running several ReDroid instances with
KernelSU, Zygisk Next, and LSPosed active on one VPS. That activation path is
init RC → `ksud post-fs-data` → module mount → Zygisk Next injects zygote →
`lspd` starts, and none of it consults the UID allowlist. `ksud` is launched by
each instance's own init in the KernelSU SELinux domain, and each instance has its
own `/data/adb/modules`, its own module list, and its own LSPosed scopes. That
path is exactly what requirements 1 through 5 cover, and it is what the candidate
fixes.

#### Why the activation path is immune

This is not an assumption; it follows from how the pinned source gates its
supercalls. `kernel/supercall/perm.c` defines five gates, and the command table in
`dispatch.c` assigns them:

```c
bool only_root(void)      { return current_uid().val == 0; }
bool manager_or_root(void) { return current_uid().val == 0 || is_manager(); }
bool only_manager(void)   { return is_manager(); }
```

`ksud` is launched by the injected RC as
`exec u:r:<ksu-domain>:s0 root -- /data/adb/ksud post-fs-data`, so it runs as
**uid 0**. Every `only_root` and `manager_or_root` command therefore succeeds
regardless of what the global manager appid currently is. Exactly two of the
roughly twenty-six commands are `only_manager`:

```text
KSU_IOCTL_GET_APP_PROFILE
KSU_IOCTL_SET_APP_PROFILE
```

Those are per-app su profile reads and writes, which is the Manager GUI's
Superuser tab. Module mounting, Zygisk Next injection, and LSPosed startup use
none of them.

#### What it does mean

1. **The two instances actively de-register each other's Manager app.** This is
   stronger than a race. `track_throne()` in `kernel/manager/throne_tracker.c`
   reads the *calling* instance's `/data/system/packages.list`, and if the stored
   manager appid is absent from it, logs `manager is uninstalled, invalidate it!`
   and calls `ksu_invalidate_manager_uid()`. Production's manager appid is not in
   experimental's package list, so any package change in experimental invalidates
   it, and the next scan in production invalidates experimental's in turn. Manage
   modules per instance with the `ksud` CLI from a root adb shell; it needs no
   manager identity.

2. **The `su` allowlist is both shared and cross-pruned.** Android allocates app
   UIDs from 10000 upward independently per instance, so the same number is a
   different app in each: a grant to UID 10123 in experimental also applies to
   whatever is 10123 in production. Worse, `track_throne()` finishes by calling
   `ksu_prune_allowlist()` against the calling instance's package list, so a
   package change in experimental deletes production's grants for UIDs that do not
   exist in experimental. **Keep the allowlist empty.** Zygisk Next and LSPosed
   need no entry, because their daemons are started by init as root rather than by
   an app requesting `su`.

3. **Safe mode is global.** Triggering it in one instance disables modules
   everywhere.

4. **Boot-completed and module-mounted flags are global,** so `ksud` status output
   for a second instance can be misleading. Cosmetic.

Points 1 and 2 are the real content of requirement 6. Neither touches module
loading, so neither blocks the objective, but both are reasons not to depend on
the Manager GUI or on su grants while two instances run.

### Upstream research: is there a fix or workaround?

Searched on 2026-08-20. **No fix exists.** Nobody has implemented per-container or
per-namespace KernelSU policy isolation, and upstream is moving in the opposite
direction: giving containers a way to *drop* KernelSU rather than to have their own
copy of it.

What the search actually found:

| Source | Finding |
|---|---|
| [tiann/KernelSU#1234](https://github.com/tiann/KernelSU/issues/1234), [redroid-doc#700](https://github.com/remote-android/redroid-doc/issues/700) | The only public discussion of KernelSU on ReDroid. Content is "it is feasible, but you need to try yourself." No multi-instance work. The two issues point at each other. |
| [tiann/KernelSU#2909](https://github.com/tiann/KernelSU/pull/2909) (merged) | "Add mount namespace support" — sounds relevant, is not. It adds inherit/global/independent mount-namespace *modes* for `su` sessions on one Android, via App Profile. Nothing per-container. |
| [tiann/KernelSU#3609](https://github.com/tiann/KernelSU/pull/3609) (open) | `KSU_IOCTL_DISABLE_KSU`: a per-process-tree flag to irrevocably drop **all** KernelSU capabilities. Motivated explicitly by "container escape bugs of container software". This is the upstream direction, and it is the opposite of what this project needs. |
| [Droidspaces-OSS#257](https://github.com/ravindu644/Droidspaces-OSS/issues/257) | A container-based Android multi-instance product hit this exact problem and filed it as a **container escape**, with a PoC. See below. |
| [Droidspaces-OSS#262](https://github.com/ravindu644/Droidspaces-OSS/pull/262) (merged) | Their fix: block the container from reaching KernelSU at all, using `KSU_IOCTL_DISABLE_ESCAPE_TO_ROOT` plus a seccomp BPF rule denying the magic `reboot()` that installs the driver fd. Incompatible with wanting root inside the container. |
| [redroid-script#39](https://github.com/ayasa520/redroid-script/issues/39) | The same "only the first container gets root" symptom, but with Magisk. The maintainer's suggested workaround is KitsuneMagisk 27.2, which is a dead end: both KitsuneMagisk repositories are deleted and the referenced build is a 2023 artifact fetched from `web.archive.org`. This project already abandoned Magisk anyway, over a `magiskpolicy` SIGABRT on Oracle ARM64. |

Coverage limits, stated so this is not mistaken for exhaustive: the GitHub and
Stack Exchange APIs were usable, but Reddit, Bing, DuckDuckGo, and public SearXNG
instances all refused automated queries, and GitHub *code* search needs a token.
So this covers GitHub issues and pull requests thoroughly and general web and
Chinese-language blogs not at all.

### Security consequence found during that search, and it is not theoretical

Droidspaces-OSS#257 documents that the global manager appid is not merely a
convenience limitation. It is a **container escape**. The escape chain, and every
element of it is present in the KernelSU Next commit this project pins:

```text
container root (uid 0)
  reboot(KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, .., &fd)  -> obtains [ksu_driver] fd
  KSU_IOCTL_GET_MANAGER_APPID    (perm manager_or_root, uid 0 passes)
  setresuid(manager_appid)       -> is_manager() now true
  KSU_IOCTL_GRANT_ROOT           (perm allowed_for_su, is_manager() branch)
    -> escape_with_root_profile(): uid 0 + full caps + u:r:ksu:s0 + disable_seccomp()
```

Verified against `KernelSU-Next` at the pinned commit:

- `kernel/supercall/supercall.c` installs the `[ksu_driver]` anon-inode fd from a
  **kprobe on `reboot()`**, which runs before that syscall's `CAP_SYS_BOOT` check,
  and the magic-pair branch applies no uid, namespace, or domain test at all;
- `GET_MANAGER_APPID` and `GRANT_ROOT` carry `manager_or_root` and
  `allowed_for_su` respectively, and the `is_manager()` branch of `allowed_for_su`
  consults no SELinux domain, unlike the hardened uid-0 path in
  `__ksu_is_allow_uid_for_current()`, which does call `is_ksu_domain()`;
- `escape_with_root_profile()` calls `disable_seccomp()`;
- the `CHANGE_MANAGER_UID` reboot magic is guarded **only** by
  `current_uid().val != 0`, so any container's root can reassign the global
  manager appid to itself, with no namespace check.

This applies to the **currently running** `6.8.12-zksu` kernel as much as to
`6.8.12-zksu-multi`. The multi-instance work neither introduces nor worsens it;
it is inherited from upstream KernelSU and is the reason requirement 6 exists.

Why it matters specifically here: ReDroid containers run as root sharing this
host's kernel, which is precisely the stated precondition. Anything that achieves
root code execution inside **either** container — a malicious APK under test in
experimental, or an exposed `adb` — can escalate to full root on the VPS. This
host has already had one ADB exposure incident, so that path is not hypothetical.

Practical rules, given that no isolating fix exists:

1. Treat both containers as inside the host's trust boundary. Running genuinely
   untrusted code in experimental is equivalent to running it as root on the VPS.
2. Never expose `adb` beyond the host loopback or a trusted tunnel.
3. Keep the `su` allowlist empty, per the rules above. It removes one of the two
   reachable branches and costs nothing that Zygisk or LSPosed needs.
4. Do not adopt the Droidspaces mitigation. It works by making KernelSU
   unreachable from inside the container, which is exactly the capability this
   project requires.

A genuine fix means namespace-scoping `ksu_manager_appid` and the allowlist, and
adding a namespace check to the `CHANGE_MANAGER_UID` and `GET_MANAGER_APPID`
paths. That is requirement 6, it is not implemented anywhere upstream, and it is a
larger change than the boot-lifecycle work in `6.8.12-zksu-multi`.

So for this project's shape, where both containers are yours rather than mutually
untrusted tenants, requirement 6 is a safety and manager-UX limitation, not a
functional blocker. It would become a genuine blocker if instances ever needed to
be a security boundary against each other, for example if one ran untrusted code
and the other served production users with different privilege.

Phase 12 and Phase 13 item 9 already require proving no cross-instance manager or
allowlist leakage, so this is checked rather than assumed.

## Mandatory test and rollout plan

Do not develop or first-boot a multi-instance KernelSU patch on the production
VPS. A hook bug can panic the host, break both Android instances, or leave
production without Zygisk/LSPosed.

Use a disposable ARM64 host matching production:

```text
Ubuntu ARM64
4 KiB pages
Linux 6.8.12 source baseline
KernelSU Next d6a42fd9285c11b8e8e67bfe72a5050528006c00
separate BinderFS mount and /data tree per ReDroid instance
```

Validate at least these cases:

1. One ReDroid instance, preserving all existing behavior.
2. Two instances started sequentially in both possible orders.
3. Two instances started concurrently.
4. More than two instances to prove the design is namespace-based rather than
   hard-coded for production and experimental.
5. Container recreation with a new PID/mount namespace.
6. Independent module installation and removal.
7. Independent Zygisk and `lspd` processes in every instance.
8. LSPosed injection scoped to different test applications per instance.
9. No cross-instance root grant or UID-allowlist leakage.
10. Host reboot, Docker restart, Coolify restart, OOM, and failed-boot recovery.
11. Binder inode isolation and absence of `ENXIO`, restart storms, kernel BUG,
    panic, or OOM signals.
12. Stock-kernel and previous-`zksu` rollback from the provider console.

Only after the disposable host passes the complete matrix should a new kernel
package be considered for production. Retain the current `6.8.12-zksu` and stock
Ubuntu kernels as bootable rollback entries.

## Current operational decision

A candidate kernel now exists but has not been installed or booted, so nothing
about production behaviour has changed yet. Until `6.8.12-zksu-multi` has passed
the test matrix above on the real host:

- keep `redroid14` as the first production Android instance after host boot;
- do not boot-order `redroid-experimental` ahead of production;
- do not install Magic Mount or systemless GApps in experimental while its
  KernelSU stages remain inactive;
- use experimental as clean Android, or move the full experimental root stack
  to a separate VPS.

Once the candidate is validated, add one standing rule that the kernel does not
enforce: **keep the KernelSU `su` UID allowlist empty**, and install or remove
modules per instance with the `ksud` CLI from a root adb shell rather than the
KernelSU Manager GUI. Root grants are keyed on a bare numeric UID that means
different apps in different containers, so an allowlist entry added in
experimental can silently apply to an unrelated app in production. See
[what requirement 6 being out of scope actually means](#what-requirement-6-being-out-of-scope-actually-means).

The original Linux source/build tree on the VPS was removed during storage
cleanup. That reconstruction is done: the Linux 6.8.12 source, the pinned
KernelSU checkout, all seven patches, and the ARM64 packages are reproducible from
[multi-instance-kernel-patch-plan.md](multi-instance-kernel-patch-plan.md) and the
scripts in [wsl/](wsl/). The older `vps/` build scripts predate that work and
built on the VPS itself; the WSL pipeline supersedes them.
