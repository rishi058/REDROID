# Local WSL ReDroid 14 + KernelSU Setup (Windows machine)

This document is the full, step-by-step record of how KernelSU + ReDroid 14 is
being set up on **this Windows machine** using WSL2. It explains every script in
this folder, every Windows-side prerequisite, and **why** each piece is needed.

Target: a custom **x86_64 WSL2 kernel** that exposes BinderFS *and* KernelSU,
running `redroid/redroid:14.0.0-latest` in Docker inside WSL, with the KernelSU
root stack (KernelSU Manager, Zygisk Next, LSPosed, LiteGApps) active.

Architecture note: the Oracle VPS work in `KernelSU_setup/` is **ARM64**. This
machine is **x86_64**. Kernel C source is portable, but every prebuilt Android
binary (`ksud`, `zygiskd`, `liblspd.so`, LiteGApps) must be the x86_64 variant.

---

## 0. From-scratch setup order

Follow these top to bottom on a clean Windows machine. ReDroid is installed
**last**, only after BinderFS (and, for root, the KernelSU kernel) is in place —
ReDroid cannot boot without a Binder-capable kernel.

### 0.1 Install WSL

```powershell
# Windows PowerShell (Administrator)
wsl --install --no-distribution
```

This installs the WSL2 engine only. Reboot Windows if prompted.

### 0.2 Install the Ubuntu distro

```powershell
wsl --install -d Ubuntu
wsl --set-default Ubuntu
wsl -l -v                 # confirm: Ubuntu, VERSION 2
```

On first launch Ubuntu asks for a UNIX username/password. After that, from
Windows you enter it with `wsl` or `wsl -d Ubuntu`.

### 0.3 Enable systemd + install Docker and build tools

```bash
# inside Ubuntu WSL
printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
```

```powershell
wsl --shutdown            # apply systemd
```

```bash
# inside Ubuntu WSL
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin \
  build-essential flex bison bc libssl-dev libelf-dev dwarves \
  git android-tools-adb unzip
sudo systemctl enable --now docker
```

### 0.4 Set up BinderFS (build + boot a Binder-capable kernel)

ReDroid needs Linux Binder/BinderFS, which the stock WSL kernel does not expose.
Build and boot the BinderFS kernel:

```bash
# inside Ubuntu WSL — build the BinderFS-only kernel
BUILD_ROOT=/home/wsl-redroid-binderfs JOBS=6 \
bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/build-wsl-redroid-binderfs-kernel.sh
```

```powershell
# Windows PowerShell — boot WSL on the built kernel
D:\PROJECT\_TRASH\REDROID\local-setup\install-wsl-custom-kernel.ps1
```

```bash
# inside Ubuntu WSL — confirm BinderFS is present and auto-mounts before Docker
grep binder /proc/filesystems
sudo install -m 0644 \
  /mnt/d/PROJECT/_TRASH/REDROID/local-setup/redroid-binderfs.service \
  /etc/systemd/system/redroid-binderfs.service
sudo systemctl daemon-reload
sudo systemctl enable --now redroid-binderfs.service
mount | grep binder      # expect: binder on /dev/binderfs ... max=1048576
```

For **root** (KernelSU), instead build and boot the KernelSU kernel — see
sections 4–7. That kernel supersedes the BinderFS-only one.

### 0.5 Install ReDroid 14 (x86_64) — LAST

Only after BinderFS is confirmed present, start ReDroid — see section 8.

```bash
# inside Ubuntu WSL
bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/start-redroid14-wsl.sh
```

---

### Where this machine currently stands

- Custom BinderFS kernel installed and booting by default via
  `C:\Users\Rishi\.wslconfig`:
  `5.15.167.4-microsoft-standard-WSL2-redroid-binderfs`.
- `redroid14` runs from `redroid/redroid:14.0.0-latest`, ADB on `127.0.0.1:5555`,
  `sys.boot_completed=1`.
- KernelSU-enabled kernel is **built** but not yet installed:
  `local-setup/kernels/bzImage-5.15.167.4-microsoft-standard-WSL2-redroid-ksu`.
- Remaining blocker: an **x86_64 Android `ksud`** binary must be built and staged
  at `/data/adb/ksud` before the KernelSU kernel can activate the root stack.

---

## 1. Why each Windows-side prerequisite is needed

| Prerequisite | Why it is required |
|---|---|
| **WSL2** | Provides a real Linux kernel VM. ReDroid needs Linux Binder/BinderFS; Windows cannot run it natively. WSL2 lets us replace the kernel image. |
| **WSL install on a large drive** | The kernel source + object tree is ~6 GiB and must live on the WSL ext4 disk (here on `D:`), never on `/mnt/c` or `/mnt/d` NTFS (NTFS breaks `chmod`/`utimensat` during builds). |
| **Docker Engine inside Ubuntu WSL** (not Docker Desktop's own distro) | ReDroid is a Docker container. It must run in the WSL distro whose kernel we control, so Binder devices are visible to the container. |
| **systemd in WSL** | Lets `dockerd` and the BinderFS mount unit start automatically at WSL boot. Enabled via `/etc/wsl.conf` `[boot] systemd=true`. |
| **Kernel build toolchain in WSL** (`build-essential flex bison bc libssl-dev libelf-dev dwarves`) | Compiles the WSL2 Linux kernel + KernelSU driver from source. |
| **`git` in WSL** | Clones Microsoft's `WSL2-Linux-Kernel` source. KernelSU is supplied locally (never cloned). |
| **A local KernelSU source tree** (`KSU_SOURCE`) | The repo vendors only *patches*, not KernelSU's `kernel/` source. We build against a local copy so nothing is pulled from the internet. |
| **`.wslconfig` on Windows** | The only supported way to tell WSL2 to boot a custom `bzImage` kernel. |
| **`adb.exe` + `scrcpy.exe` on Windows** | Windows reaches the WSL-published `127.0.0.1:5555` directly (no SSH tunnel). Used to install APKs and view the ReDroid GUI. |
| **Android NDK r26d (`x86_64` toolchain)** | `ksud` is a Rust program cross-compiled for Android. The NDK provides the `x86_64-linux-android` clang/linker/`llvm-ar`. |
| **Rust + `x86_64-linux-android` target** | `ksud` is written in Rust. `rustup target add x86_64-linux-android` provides the Android std library. |
| **libclang (MSYS2 `mingw-w64-ucrt-x86_64-clang`)** | `ksud`'s build script uses `bindgen`, which needs `libclang.dll` to parse `ksu_uapi.h`. The NDK ships no Windows `libclang.dll`. |

---

## 2. Files in this folder and what each does

| File | Purpose |
|---|---|
| [build-wsl-redroid-binderfs-kernel.sh](build-wsl-redroid-binderfs-kernel.sh) | Builds a WSL2 x86_64 kernel with **BinderFS only** (no KernelSU). This is what boots today and makes ReDroid runnable. |
| [build-wsl-kernelsu-redroid-kernel.sh](build-wsl-kernelsu-redroid-kernel.sh) | Builds a WSL2 x86_64 kernel with **BinderFS + KernelSU** from a local `KSU_SOURCE`. Applies WSL/x86 compatibility fixes and the multi-instance patch. |
| [install-wsl-custom-kernel.ps1](install-wsl-custom-kernel.ps1) | Windows script that writes `.wslconfig` to boot the built `bzImage`, restarts WSL, and prints the running kernel + BinderFS status. |
| [redroid-binderfs.service](redroid-binderfs.service) | systemd unit that mounts BinderFS (`max=1048576`) **before** `docker.service`, so ReDroid always finds `/dev/binderfs/{binder,hwbinder,vndbinder}`. |
| [docker-compose.redroid14.yml](docker-compose.redroid14.yml) | Defines the `redroid14` container: image, privileged mode, port `5555`, `/data` volume, BinderFS bind. |
| [start-redroid14-wsl.sh](start-redroid14-wsl.sh) | Preflight + launcher. Refuses to start ReDroid unless Docker is up and the running kernel exposes BinderFS, then mounts BinderFS and `docker compose up -d`. |
| [build-ksud-x86_64.ps1](build-ksud-x86_64.ps1) | Builds the **x86_64 Android `ksud`** from the local KernelSU source, under `local-setup/build/`, and stores the binary in `local-setup/artifacts/`. |
| [install-litegapps-x86_64.sh](install-litegapps-x86_64.sh) | Two-pass LiteGApps (Play Store) installer for this x86_64 ReDroid: `metamodule` (Magic Mount) pass, then `litegapps` pass. Downloads cache in `artifacts/gapps/`. **Superseded by MindTheGapps** (its `customize.sh` rejects x86_64 — see 11.2). |
| [install-mindthegapps-x86_64.sh](install-mindthegapps-x86_64.sh) | **Working GApps path.** Downloads MindTheGapps x86_64 (A14), repackages its plain `system/` tree as a Magic Mount module, and installs it. No arch-gating installer. |
| [install-integrity-stack.sh](install-integrity-stack.sh) | Play-Integrity / genuine-device stack: `fetch` (download+verify+arch-probe), `identity-trickystore` (Pixel 5 identity module + TrickyStore + keybox), `teesimulator` (refuses on x86_64 — see 11.4). |
| [verify-redroid-stack.sh](verify-redroid-stack.sh) | Post-restart check: waits for `sys.boot_completed`, then reports Zygisk/LSPosed/TrickyStore persistence, the Pixel 5 identity props, the `mindthegapps` mount, and GApps packages. |
| [GUIDE.md](GUIDE.md) | Short operator cheat-sheet for connecting ADB/scrcpy and current root-stack status. |
| `kernels/` | Exported `bzImage-*` kernel artifacts and `latest-wsl-kernel.env` metadata. |
| `artifacts/` | Built Android binaries (e.g. `ksud-x86_64-linux-android` + `.sha256`). |
| `build/` | Working copies for in-repo builds (e.g. `build/ksud-x86_64/`). |

---

## 3. Prepare the Windows/WSL base (one-time)

```powershell
# Windows PowerShell
wsl --install Ubuntu           # if not already installed
wsl --set-default Ubuntu
```

```bash
# inside Ubuntu WSL, enable systemd so dockerd + BinderFS unit autostart
printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
```

```powershell
wsl --shutdown                 # apply systemd
```

```bash
# inside Ubuntu WSL, install Docker + kernel build deps + adb
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin \
  build-essential flex bison bc libssl-dev libelf-dev dwarves \
  git android-tools-adb unzip
sudo systemctl enable --now docker
```

---

## 4. `build-wsl-kernelsu-redroid-kernel.sh`, step by step

Run inside Ubuntu WSL:

```bash
BUILD_ROOT=/home/wsl-kernelsu-redroid \
KSU_SOURCE=/home/builder/kbuild/linux-6.8.0/KernelSU-Next \
KSU_APPLY_REPO_PATCHES=auto \
JOBS=6 \
bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/build-wsl-kernelsu-redroid-kernel.sh
```

What it does:

1. **Refuse internet KernelSU pulls.** Exits if `KSU_SOURCE` is empty. KernelSU is
   never cloned; it must be a local tree.
2. **Clone the WSL kernel base** `microsoft/WSL2-Linux-Kernel` branch
   `linux-msft-wsl-5.15.y` (matches the WSL kernel line in use).
3. **Copy the local KernelSU tree** into `drivers/` and apply x86/WSL compatibility
   fixes the ARM64 VPS build never needed:
   - add `#include <linux/init.h>` to `feature/sulog.h` (WSL 5.15 needs it for
     `__init`/`__exit`);
   - collapse KernelSU's `fsnotify_alloc_group` version check to the 2-arg form
     (WSL 5.15 backported the newer signature);
   - `KSU_APPLY_REPO_PATCHES=auto` applies `kernelsu-redroid-multi-instance.patch`
     only if the multi-instance markers are absent.
4. **Wire KernelSU into the build** (`drivers/Makefile`, `drivers/Kconfig`).
5. **Configure the kernel** (`scripts/config` on `Microsoft/config-wsl`):
   - `ANDROID`, `ANDROID_BINDER_IPC`, `ANDROID_BINDERFS`, devices
     `binder,hwbinder,vndbinder` — ReDroid IPC;
   - `KSU` — the KernelSU driver;
   - `OVERLAY_FS`, `PSI`, `MEMCG`, `CGROUPS` — module mounts + container limits;
   - `SECURITY_NETWORK`, `SECURITY_SELINUX`, `SECURITY_SELINUX_DEVELOP`,
     `SIDTAB_HASH_BITS=9`, `SID2STR_CACHE_SIZE=256` — **SELinux is compiled in.**
     KernelSU includes SELinux internal headers and does not build without them.
     `kernelsu-selinux-unavailable.patch` is a **runtime null-policy guard**, not a
     compile-time disable — WSL has no loaded policy, so that guard prevents a
     null-deref at boot.
   - `KSU_X86_PATCH_SYSCALL_DISPATCHER` — **critical x86 fix.** On x86_64 KernelSU
     refuses to build (and would panic) unless it uses its own syscall dispatcher
     hook mode, or a kernel hardening patch that defines `X86_FEATURE_INDIRECT_SAFE`.
     This selects the dispatcher mode. This guard is exactly why an ARM-oriented
     tree does not silently produce a broken x86 kernel.
6. **`make olddefconfig`**, then **generate SELinux headers** (`flask.h`,
   `av_permissions.h`) explicitly.
7. **Build** `make -j6 ... LOCALVERSION=-redroid-ksu` → `arch/x86/boot/bzImage`.
8. **Export** to `local-setup/kernels/bzImage-<release>` + `latest-wsl-kernel.env`.

Result: `bzImage-5.15.167.4-microsoft-standard-WSL2-redroid-ksu`.

For reference, the BinderFS-only kernel already installed was built with:

```bash
BUILD_ROOT=/home/wsl-redroid-binderfs JOBS=6 \
bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/build-wsl-redroid-binderfs-kernel.sh
```

---

## 5. Install the kernel (Windows) — `install-wsl-custom-kernel.ps1`

```powershell
D:\PROJECT\_TRASH\REDROID\local-setup\install-wsl-custom-kernel.ps1
```

It backs up any existing `.wslconfig`, writes `[wsl2] kernel=<escaped path>`, runs
`wsl --shutdown`, then prints `uname -a` and whether `binder` is in
`/proc/filesystems`. The path is written with escaped backslashes because WSL
rejects `\P`-style single backslashes in `.wslconfig`.

To boot the KernelSU kernel instead of the BinderFS-only one, ensure
`kernels/latest-wsl-kernel.env` references the `-redroid-ksu` image (the KSU build
writes this automatically) before running it.

---

## 6. Build the x86_64 Android `ksud` (Windows) — current step

`ksud` is the KernelSU userspace daemon/CLI. The repo only ships
`ksud-aarch64-linux-android` (ARM64), which **cannot run** on this x86_64 ReDroid.
We build the x86_64 one from the local KernelSU `userspace/ksud` Rust project.

Prerequisites and why:

- **Rust (Windows)** at `C:\Users\Rishi\.cargo` — the compiler.
- **`rustup target add x86_64-linux-android`** — Android std library.
- **Android NDK r26d** at `D:\SOFTWARES\01_ANDROID_SDK_HOME\ndk\26.3.11579264` —
  provides `x86_64-linux-android26-clang(.cmd)` and `llvm-ar` (for native C deps
  like `zstd-sys`/`lz4-sys`).
- **MSYS2 `mingw-w64-ucrt-x86_64-clang`** — provides `libclang.dll` for `bindgen`
  (parses `src/ksu_uapi.h`). Install with:
  `C:\msys64\usr\bin\pacman.exe -S --needed --noconfirm mingw-w64-ucrt-x86_64-clang`.

Build (reproducible, output stored in this repo):

```powershell
D:\PROJECT\_TRASH\REDROID\local-setup\build-ksud-x86_64.ps1
```

This copies the KernelSU `userspace/` sources + `uapi/` headers into
`local-setup/build/ksud-x86_64/`, patches the throwaway copy's `build.rs` to point
bindgen at the NDK Android target/sysroot, builds, and copies the result to
`local-setup/artifacts/ksud-x86_64-linux-android` (+ `.sha256`).

**Status: DONE.** `file` reports
`ELF 64-bit LSB pie executable, x86-64 ... interpreter /system/bin/linker64`.

Blockers hit and how they were solved:

1. **MinGW linker cannot write to `\\wsl.localhost\...` UNC paths** — build must
   run from a normal Windows path. The script builds under `local-setup/build/`.
2. **`bindgen` needs `libclang.dll`** — the NDK ships none on Windows. Install
   MSYS2 `mingw-w64-ucrt-x86_64-clang` and set `LIBCLANG_PATH=C:\msys64\ucrt64\bin`.
3. **`x86_64-linux-android-ar` not found** — set `AR_x86_64_linux_android` to the
   NDK `llvm-ar.exe` (needed by native C deps `zstd-sys`/`lz4-sys`).
4. **`uapi/ksu.h` / nested `uapi/*.h` not found** — copy the KernelSU `uapi/`
   dir next to the build and add the build root to the include path.
5. **`linux/ioctl.h` not found** — build.rs hardcodes `-I/usr/include` (a Linux
   path). Patch the copy's `build.rs` to pass `--target=x86_64-linux-android26`
   and `--sysroot=<NDK>/sysroot` so Android system headers resolve. The real
   KernelSU source and repo scripts are never modified — only the throwaway copy.

---

## 7. Activation sequence (per `KernelSU_setup/` docs)

Order matters. `ksud module list` showing `enabled=true` is **staging**, not
activation. Activation needs the KernelSU kernel boot hooks to fire, which on this
setup means a **WSL restart** (the WSL equivalent of a host reboot).

1. Boot the KernelSU kernel (`install-wsl-custom-kernel.ps1` → `-redroid-ksu`,
   then `wsl --shutdown`).
2. Stage `ksud` at `/data/adb/ksud`, mode `0755` (exec bit mandatory).
3. Install KernelSU Manager APK (`com.rifsxd.ksunext`) — already installed.
4. `ksud module install` the **x86_64** Zygisk Next and LSPosed payloads (the ZIPs
   in `KernelSU_setup/artifacts/android/` contain `lib/x86_64/` and `bin/x86_64/`).
5. Restart WSL again so the boot hooks consume the `update` markers.
6. Validate real activation: `pidof lspd`, `ksud -V`, module payload moved from
   `/data/adb/modules_update/` into `/data/adb/modules/`.
7. LiteGApps (optional): two-pass — Magic Mount metamodule, restart, then the
   **x86_64** LiteGApps zip; remount `/dev` to `size=768M` first (default 64 MiB
   tmpfs is too small for the ~300 MiB payload). See section 11.

---

## 8. Run ReDroid and view the GUI

```bash
# inside Ubuntu WSL
bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/start-redroid14-wsl.sh
```

```powershell
# Windows host — no SSH tunnel needed
adb connect 127.0.0.1:5555
scrcpy -s 127.0.0.1:5555 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio
```

`start-redroid14-wsl.sh` preflights Docker + BinderFS, mounts BinderFS, then
`docker compose up -d`. It refuses to start if the running kernel has no BinderFS.

---

## 9. Binder / BinderFS requirements (both kernels)

- Kernel must expose the `binder` filesystem (`grep binder /proc/filesystems`).
- BinderFS is mounted with `-o max=1048576`. `max=3` is a known failure that makes
  `service list` empty inside Android.
- `redroid-binderfs.service` mounts it before Docker so the container always sees
  `/dev/binderfs/{binder,hwbinder,vndbinder}`.

---

## 10. Current status

**FULLY WORKING on this x86_64 machine — KernelSU + Zygisk Next + LSPosed active.**

Verified after booting the KernelSU kernel:

- `su` returns `uid=0(root) gid=0(root)` \u2014 **root works**.
- KernelSU manager crowned: `com.rifsxd.ksunext`.
- Zygisk Next daemons running: `zn-nsdaemon-zygote`, `zn-nsdaemon-zygote_secondary`,
  `zn-zygisk-companion64/32`.
- **LSPosed daemon `lspd` running** and injecting (verbose logs under
  `/data/adb/lspd/log/`).
- `ksud module list`: `zygisksu` and `zygisk_lsposed` both `enabled=true`; payloads
  migrated into `/data/adb/modules/*/bin` (markers consumed).
- Kernel: `CONFIG_KSU=y`, version 33223, `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y`,
  `CONFIG_KALLSYMS_ALL=y`, BinderFS + SELinux.
- **Google Play Store working** via MindTheGapps over Magic Mount (`com.android.vending`,
  `com.google.android.gms`, `com.google.android.gsf`) — see section 11.3.
- Activation is **reboot-persistent** with zero manual steps — see section 11.1.

**Blockers solved (full chain):**

1. x86 build guard (`X86_FEATURE_INDIRECT_SAFE`) \u2192 `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER`.
2. WSL 5.15 compat: `sulog.h` `<linux/init.h>`; `fsnotify_alloc_group` arity;
   SELinux compiled in + generated headers.
3. `ksud` x86_64 build: libclang, NDK `llvm-ar`, uapi headers, sysroot includes.
4. Module "KernelSU too old": kernel version `1` from git "dubious ownership"
   \u2192 `git safe.directory` in the build script \u2192 version 33223.
5. **Hooks never fired (the real activation fix):** KernelSU's x86 dispatcher
   resolves `sys_call_table` via kallsyms at `kernelsu_init`. The WSL kernel had
   `CONFIG_KALLSYMS` but not `CONFIG_KALLSYMS_ALL`, so the non-exported data symbol
   `sys_call_table` was absent from kallsyms \u2192 dispatcher never installed \u2192 no
   execve hook \u2192 modules never activated. **Fix: `--enable KALLSYMS_ALL`.** After
   this, `dmesg` shows `Crowning manager`, `init second_stage`, and
   `attached independent KernelSU rc stream`, and Zygisk/LSPosed start at boot.

Debug builds: pass `KSU_DEBUG=1` to `build-wsl-kernelsu-redroid-kernel.sh` to get
verbose KernelSU boot logs (`sys_call_table=0x...`, `dispatcher installed`).

---

## 11. Reboot persistence & LiteGApps

### 11.1 Persistence — VERIFIED

The Zygisk Next + LSPosed activation is **reboot-persistent** with no manual steps.
Everything the activation depends on survives a `wsl --shutdown`:

- **Kernel** — pinned in `C:\Users\Rishi\.wslconfig` (`-redroid-ksu`, with
  `CONFIG_KALLSYMS_ALL` so the x86 dispatcher re-resolves `sys_call_table` every
  boot and the execve hooks fire).
- **`ksud` + modules** — live in the `redroid14-data` Docker volume mounted at
  `/data` (`/data/adb/ksud`, `/data/adb/modules/*`), so they persist across
  container recreation.
- **BinderFS** — `redroid-binderfs.service` mounts it (`max=1048576`) **before**
  `docker.service`, so the container always finds Binder at boot.
- **Container autostart** — `redroid14` runs `restart: unless-stopped`.

Verified: after `wsl --shutdown` + restart, with zero manual intervention,
`sys.boot_completed=1` and the daemons are already running:

```text
lspd
zn-nsdaemon-zygote  /  zn-nsdaemon-zygote_secondary
zn-zygisk-companion64 zygisk_lsposed  /  zn-zygisk-companion32 zygisk_lsposed
```

Re-check any time from Windows:

```powershell
wsl -d Ubuntu -- bash -lc 'docker exec redroid14 sh -c "ps -A | grep -iE zygisk\|lspd"'
wsl -d Ubuntu -- bash -lc 'docker exec redroid14 su -c id'   # expect uid=0(root)
```

### 11.2 LiteGApps (Play Store) — metamodule active, payload BLOCKED

Run the two passes from Windows (each `_STAGED` message is followed by a WSL
restart to activate):

```powershell
wsl -d Ubuntu -- bash -lc 'bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/install-litegapps-x86_64.sh metamodule'
wsl --shutdown   # then restart docker + redroid14
wsl -d Ubuntu -- bash -lc 'bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/install-litegapps-x86_64.sh litegapps'
```

- **Pass 1 (metamodule) — DONE.** `meta-mm` Magic Mount installs with the x86_64
  binary (`mm_amd64`), `metamodule=1`, and after a WSL restart
  `ksud module metamodule` reports `Installed`. This is the mount backend
  LiteGApps needs (ReDroid's `/system` is read-only; Magic Mount overlays it).

- **Pass 2 (LiteGApps zip) — BLOCKED.** The x86_64 SDK-34 lite zip
  (`LiteGapps-x86_64-14.0-20241029-official.zip`) downloads and passes `unzip -t`,
  but its `customize.sh` aborts inside `ksud module install` with:

  ```text
  known error •> <x64> Your Architecture Not Support
  can't create /sdcard/Android/litegapps/log/litegapps.log: nonexistent directory
  ```

  Two independent causes:
  1. **Arch gate** — the installer's `ARCH` probe (`getprop ro.product.cpu.abi` /
     `uname -m`) does not classify ReDroid's `x86_64` as supported and hard-exits
     with `<x64> Your Architecture Not Support`.
  2. **No `/sdcard`** — during `ksud module install` the emulated storage / FUSE
     `/sdcard` is not mounted, so the installer's logging path does not exist.

  Net: LiteGApps' installer script is not ReDroid-x86_64-friendly. **Resolved by
  switching to MindTheGapps (11.3), which ships a plain `system/` tree with no
  installer script.**

### 11.3 MindTheGapps (Play Store) via Magic Mount — WORKING

The simple, container-friendly path. MindTheGapps' zip payload is a plain
top-level `system/` tree (no arch-detecting `customize.sh`), so it drops straight
onto Magic Mount. `install-mindthegapps-x86_64.sh` downloads the x86_64 A14 build
(`MindTheGapps-14.0.0-x86_64-20240226.zip`, md5 `a827a84ccb0cf5914756e8561257ed13`,
from `s1204IT/MindTheGappsBuilder`), repackages `system/` + a `module.prop` into a
KernelSU module, and installs it. Requires the Magic Mount metamodule from 11.2
to be active first.

```powershell
wsl -d Ubuntu -- bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/install-mindthegapps-x86_64.sh
wsl --shutdown   # then restart docker + redroid14
wsl -d Ubuntu -- bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/verify-redroid-stack.sh
```

Verified after the restart — Magic Mount overlays the GApps
(`KSU on /system/system_ext/priv-app type tmpfs`, `.../etc/permissions`) and the
packages are present:

```text
package:com.android.vending                 # Play Store
package:com.google.android.gms              # Play Services
package:com.google.android.gsf              # Services Framework
package:com.google.android.googlequicksearchbox
```

Notes:
- Payload includes `Phonesky` (Play Store), `GmsCore`, `GoogleServicesFramework`,
  `Velvet`, `SetupWizard`, permission XMLs — lands under `/system/product` and
  `/system/system_ext`.
- Play Protect certification: sign in, then register the device's `android_id` at
  <https://www.google.com/android/uncertified/> if apps flag “not certified”.
This README is updated after each step and each blocker+solution.

### 11.4 Genuine device identity + Play Integrity (Pixel 5 + TrickyStore)

Goal: present a coherent Pixel 5 (redfin) Android 14 device and pass Play
Integrity so apps install/run normally. Driven by
[install-integrity-stack.sh](install-integrity-stack.sh); mirrors
`rev-eng/docs/05-Follow-Up-Fixes.md` (ARM64) but adapted for x86_64.

First extract the GSF ID to register the device for Play certification:

```powershell
wsl -d Ubuntu -- bash -lc 'docker cp redroid14:/data/data/com.google.android.gsf/databases/gservices.db /tmp/g.db; python3 -c "import sqlite3;print(next(v for n,v in sqlite3.connect(\"/tmp/g.db\").execute(\"select name,value from main where name=\x27android_id\x27\")))"'
```

Register the printed decimal at <https://www.google.com/android/uncertified/>
(clearing GSF data generates a NEW id that must be re-registered).

Install the Pixel 5 identity module + TrickyStore + keybox, then restart:

```powershell
wsl -d Ubuntu -- bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/install-integrity-stack.sh identity-trickystore
wsl --shutdown   # restart docker + redroid14
wsl -d Ubuntu -- bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/verify-redroid-stack.sh
```

- **Pixel 5 identity — DONE.** A generated KernelSU module `redroid_pixel5`
  (`system.prop`) resetprops the redfin profile on every boot. Verified:
  `ro.product.model=Pixel 5`, `manufacturer=Google`, `device=redfin`,
  `brand=google`, `ro.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/...:user/release-keys`,
  `verifiedbootstate=green`, `flash.locked=1`. Top-level **and** per-partition
  (`ro.product.<system|vendor|product|odm|system_ext>.*`) keys are set so every
  getter agrees.
  - **ADB side effect:** the module also sets `ro.secure=1` + `ro.debuggable=0`
    (genuine-device values), which switches adbd to **authenticated** mode, so
    `adb connect` starts returning `failed to authenticate`. Fix (keeps the
    genuine props): trust the host key once — the script does this automatically
    (`authorize_adb`), or run it standalone:
    `install-integrity-stack.sh authorize-adb`. It writes
    `~/.android/adbkey.pub` into the container's `/data/misc/adb/adb_keys`
    (persists in the `/data` volume) and restarts adbd. Set `ADBKEY_PUB=` to
    override the key path.
- **TrickyStore — DONE (x86_64).** Tricky Store v1.4.1 ships `lib/x64/libtricky_store.so`
  + `machikado.x64`; its daemon runs. Config in `/data/adb/tricky_store/`:
  `keybox.xml` (0600, sha256 `5c9ba17b…` — the same keybox as the docs),
  `target.txt` (`com.android.vending`, `com.google.android.gms!`,
  `gr.nikolasspyr.integritycheck`), `security_patch.txt`.
- **TEESimulator-RS — BLOCKED on x86_64.** v6.0.1-282 ships `lib/x86_64/` for
  `libTEESimulator/libinject/libsupervisor` but **`libcertgen.so` only for
  `arm64-v8a`** — the native keybox→attestation forger has no x86_64 build, so its
  forge path cannot run here. The docs used it for STRONG on ARM64; on x86_64 the
  script's `teesimulator` step refuses. TrickyStore is the x86_64-viable attestor.
- **PlayIntegrityFix (KOWX712) — not used.** Its Zygisk `.so` is arm64/armeabi
  only (no x86_64), so the Java-layer spoof can't inject; the Pixel 5 identity is
  instead handled by the arch-independent `redroid_pixel5` `system.prop` module.

Verify integrity from inside ReDroid (needs a signed-in Google account):
install **Play Integrity API Checker** (`gr.nikolasspyr.integritycheck`) from
Play Store and run it. Expected on this x86_64 stack: **BASIC** and **DEVICE**
likely pass; **STRONG** depends on the keybox being valid/unrevoked — the public
`5c9ba17b…` keybox is almost certainly on Google's CRL, and without an x86_64
TEESimulator there is no forge fallback, so STRONG is not expected to pass here.

This README is updated after each step and each blocker+solution.
