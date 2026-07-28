# Running Android (Redroid) on an Oracle Cloud ARM Server — The Complete Guide

### From an empty VPS to a rooted, Play-Store-certified Android instance you can control over the network

> **Last updated:** 2026-07-24
> **Target platform:** Oracle Cloud Infrastructure (OCI) **Ampere A1 Flex** (arm64 / aarch64), Ubuntu 22.04 / 24.04, kernel 6.x
> **Difficulty:** Intermediate. No prior Android-internals knowledge assumed — everything is explained.
> **What you get at the end:** Android 11 or 13 running in a Docker container, reachable over ADB, optionally with root (Magisk), Zygisk, and a certified Google Play Store.

---

**Table of contents**

1. [Part 1 — Understanding what you are building](#part-1--understanding-what-you-are-building)
2. [Part 2 — The two mistakes that waste everyone's weekend](#part-2--the-two-mistakes-that-waste-everyones-weekend)
3. [Part 3 — Prerequisites](#part-3--prerequisites)
4. [Part 4 — Choosing the right image (make-or-break)](#part-4--choosing-the-right-image-make-or-break)
5. [Part 5 — Preparing the host](#part-5--preparing-the-host)
6. [Part 6 — Deploying Redroid](#part-6--deploying-redroid)
7. [Part 7 — Root, Zygisk, and Play Store](#part-7--root-zygisk-and-play-store)
8. [Part 8 — Troubleshooting](#part-8--troubleshooting)
9. [Appendices](#appendix-a--full-command-sequence)

---

# Part 1 — Understanding what you are building

## 1.1 What is Redroid?

**Redroid** ("Remote anDROID") is Android packaged to run inside a Linux container. Instead of emulating a phone (slow, like the Android Studio emulator), it runs the *real* Android operating system directly on your server's Linux kernel, sharing that kernel the same way any Docker container does. That makes it fast and lightweight — but it also means Android is exposed to the host kernel's quirks, which is the source of nearly every problem in this guide.

You interact with it over the network using **ADB** (Android Debug Bridge) and can see the screen using **scrcpy** or any ADB-based screen mirror.

## 1.2 How Android actually boots (the mental model you need)

When the container starts, this chain runs. Knowing it is the difference between guessing and debugging:

| Stage | Process | What it does | If it fails you see… |
|---|---|---|---|
| 1 | **`/init`** | Android's first process (PID 1). Reads boot properties, mounts filesystems, starts every service. | Container exits immediately / boot loop |
| 2 | **`servicemanager`** | The phone-book that every service registers into and looks others up through (Binder IPC). | "No service published for: X" errors |
| 3 | **`surfaceflinger`** | The display compositor. Even headless, Android expects it up. | Stuck at "Waiting for service SurfaceFlinger" |
| 4 | **`lmkd`** | Low-Memory-Killer Daemon. Watches memory pressure to decide what to kill. Marked **critical** — if it dies repeatedly, init aborts the whole boot. | "critical process 'lmkd' exited N times" → boot loop |
| 5 | **`zygote`** | The template process every app forks from. Comes in 64-bit (`app_process64`) and, on some images, 32-bit (`app_process32`). | Framework never starts |
| 6 | **`system_server`** | The heart of Android — hosts ~80 framework services (ActivityManager, WindowManager, **InputManager**, etc.). Forked from zygote. | ADB connects but nothing works; scrcpy shows no `input` service |
| 7 | **`sys.boot_completed=1`** | Set when the home screen is ready. **This is your finish line.** | You never reach it |

**The key insight:** almost every "it connects but doesn't work" symptom means **system_server never finished** (stage 6). Your job when debugging is always to find *why* — and the answer is in the logs, not in a guess.

## 1.3 What the Linux kernel must provide

Android is not a normal container app. It needs kernel features most servers don't expose by default:

- **Binder** — Android's core inter-process communication (IPC) system. Everything talks to everything else through it. Provided by the `binder_linux` kernel module and the `binderfs` filesystem. **Mandatory.**
- **PSI (Pressure Stall Information)** — the modern Linux mechanism (`/proc/pressure/memory`) that reports how starved the system is for memory/CPU/IO. Android 11+ `lmkd` uses it as its primary memory-pressure source. **Effectively mandatory** — without it, `lmkd` dies and takes the boot down with it. (See the myth-buster below for why this — not cgroups — is the real requirement.)
- **A 4 KB memory page size** — Android's binaries assume it. Standard Ubuntu ARM kernels use 4 KB. (Some exotic ARM kernels use 64 KB and will not work.)

That's the real list. Notice what is **not** on it: a specific cgroup version. That surprises people, so it gets its own section.

## 1.4 The cgroup myth (read this — it saves the most time)

You will see this in the logs, and it looks fatal:

```
init: cpuset cgroup controller is not mounted!
init: Failed to mount cgroup v2
libprocessgroup: Failed to add task into cgroup
```

**These messages are harmless on Android 10–13.** Here is the ground truth, straight from the Redroid maintainer and issue tracker:

- Android reads `/system/etc/cgroups.json`, which asks for controllers at `/dev/cpuset`, `/dev/cpuctl`, `/dev/blkio`, `/dev/memcg`. On modern Ubuntu (22.04+), those live under the unified **cgroup v2** hierarchy instead, so Android's attempt to mount them at the old `/dev/*` paths fails. Android's `libprocessgroup` **logs the failure and carries on** — it does not stop the boot.
- The maintainer states plainly: *"All redroid releases should boot on cgroup v2 (although resource limit may not work as expected)."* ([redroid-doc #780](https://github.com/remote-android/redroid-doc/issues/780))
- The Redroid project only ships a code patch for this on **Android 14+** (where one assertion became fatal). For **Android 10–13 there is no cgroup patch at all**, because those versions already tolerate it. ([redroid-patches](https://github.com/remote-android/redroid-patches))
- Confirmed booting despite the warning: [#179](https://github.com/remote-android/redroid-doc/issues/179), [#38](https://github.com/remote-android/redroid-doc/issues/38).

> **Bottom line:** If Android isn't booting, the `cpuset` line is almost never the reason. Do **not** switch kernels, force cgroup v1, or hand-mount `/dev/cpuset` chasing this message. The real cause is in [Part 2](#part-2--the-two-mistakes-that-waste-everyones-weekend). If you want the full explanation of why the "force cgroup v1" fixes floating around the internet are unnecessary, see [Appendix D — The cgroup rabbit hole](#appendix-d--the-cgroup-rabbit-hole-what-not-to-do).

---

# Part 2 — The two mistakes that waste everyone's weekend

On **Oracle Cloud ARM specifically**, 90% of "Android connects over ADB but never boots" cases come down to exactly two things. Fix these and the rest of the guide is routine.

## Mistake #1 — Incompatible 32-bit image or missing host 32-bit COMPAT

Oracle's Ampere A1 (Ampere Altra, ARMv8.2-A Neoverse-N1 cores) hardware **supports 32-bit execution** (AArch32 at EL0), and Ubuntu's default arm64 kernel on Oracle VPS includes 32-bit compatibility (`CONFIG_COMPAT=y`).

However, running certain 32-bit Android images can still fail with `Exec format error` or boot loops under two common scenarios:
1. **Host Kernel missing 32-bit COMPAT:** If using a custom kernel or distro where `CONFIG_COMPAT` is missing/disabled, the host kernel refuses `/system/bin/app_process32`:
   ```
   init: cannot execve('/system/bin/app_process32'): Exec format error
   ```
2. **Android 13 Magisk / Pi5 Incompatibilities:** Images like `fahaddz/redroid:13-arm-pi5` or Android 13 builds with 32-bit Magisk helpers trigger `magiskpolicy` crashes (`SIGABRT`) or 32-bit zygote failures on Oracle ARM64.

**The fix:** 
- If you want a stock clean image guaranteed to boot on *any* kernel (even without 32-bit compat), use an official **64-bit-only** image (tag contains `_64only`, e.g., `redroid/redroid:11.0.0_64only-latest`).
- If you want root, Play Store, and 32-bit app support on Oracle A1 (Ubuntu stock kernel with `CONFIG_COMPAT=y`), use `abing7k/redroid:a11_gapps_magisk_arm`. See [Part 4](#part-4--choosing-the-right-image-make-or-break).

## Mistake #1.5 — The Android 13 Magisk `magiskpolicy` crash
Even if you use a 64-only image of Android 13, the current bootless Magisk implementations (`ayasa520/Magisk` and forks) have an incompatibility on Oracle ARM64 in the `magiskpolicy` binary, causing a fatal `SIGABRT` crash during boot. This breaks the entire Magisk module injection chain, meaning Zygisk and LSPosed will fail to initialize. 
**The fix:** Use a tested Android 11 image (which handles 32-bit natively and doesn't crash Magisk).

## Mistake #2 — `lmkd` dying because PSI isn't active

If the log shows `lmkd` starting and exiting over and over:

```
init: Service 'lmkd' (pid 123) exited with status 0
...
init: critical process 'lmkd' exited 4 times before boot completed
```

…then `lmkd` can't find a memory-pressure source and keeps quitting. Because it's a **critical** service, after 4 deaths init gives up and the boot never completes — and `system_server`'s framework services (including `input`) never register. This produces the exact symptom "scrcpy: No service published for: input" ([#823](https://github.com/remote-android/redroid-doc/issues/823), [#412](https://github.com/remote-android/redroid-doc/issues/412), [#293](https://github.com/remote-android/redroid-doc/issues/293)).

**The fix:** make sure PSI is enabled on the host. Good news for Oracle users: **Ubuntu's arm64 kernels ship with `CONFIG_PSI=y` and PSI enabled by default**, so this usually already works. You just verify it (Part 5, Step 1). If it's somehow off, you add `psi=1` to the kernel command line.

> This is the same wall Waydroid users hit; the [Arch Wiki Waydroid page](https://wiki.archlinux.org/title/Waydroid) gives the identical advice: enable PSI / add `psi=1`.

---

# Part 3 — Prerequisites

Before you start, make sure you have:

- **An Oracle Cloud Ampere A1 instance** running Ubuntu 22.04 or 24.04, with SSH access as a user who can `sudo`. 2+ OCPUs and 6+ GB RAM recommended (Android is hungry, especially during first boot).
- **Your instance's public IP address** (you'll connect ADB to it).
- **Docker** installed. If you use **Coolify**, it manages Docker for you — that's the deployment path this guide uses, with a raw-`docker run` fallback for when Coolify's guardrails get in the way.
- **On your own computer:** `adb` installed (`sudo apt install android-tools-adb`, `brew install android-platform-tools`, or the Android SDK platform-tools). Optionally `scrcpy` to see the screen.

A quick word on the tools:
- **ADB** is the command-line bridge to Android — install apps, read logs, open a shell.
- **Coolify** is a self-hosted deployment platform (a friendlier layer over Docker). Convenient, but it has a safety whitelist that blocks a few Docker flags. Where that matters, this guide shows the workaround.

---

# Part 4 — Choosing the right image (make-or-break)

Depending on your host kernel and whether you need 32-bit app support, **your image choice decides whether Android boots cleanly**.

## 4.1 Image Options vs. Oracle A1 Hardware & Kernel

Oracle Cloud Ampere A1 (Neoverse-N1) hardware supports 32-bit execution (AArch32 EL0), and Ubuntu's default arm64 kernel has 32-bit compatibility (`CONFIG_COMPAT=y`).

* **Official `_64only` Images (`redroid/redroid:11.0.0_64only-latest` / `13.0.0_64only-latest`):** Remove 32-bit zygote (`app_process32`). Guaranteed to boot on *any* host kernel regardless of 32-bit compat.
* **Tested Android 11 Dual 32/64-bit Image (`abing7k/redroid:a11_gapps_magisk_arm`):** Supports 32-bit execution natively on Oracle A1 (Ubuntu stock kernel) and comes pre-configured with Magisk Delta and Play Store.
* **Incompatible Android 13 Community Images (`fahaddz/redroid:13-arm-pi5`):** Built for Pi5 / specific kernels; trigger `magiskpolicy` SIGABRT crashes or 32-bit zygote boot loops on Oracle ARM64.

## 4.2 Option A — Stock Official 64-bit-Only Image (Clean Baseline)

The Redroid project publishes clean, unrooted 64-bit-only images. **Use this to prove your host kernel boots**, before adding root/Play Store complexity:

```
redroid/redroid:11.0.0_64only-latest
# or
redroid/redroid:13.0.0_64only-latest
```

## 4.3 Option B — Rooted Android 11 Image with GApps & 32-Bit Support (Recommended)

If you want a rooted instance with Google Play Store, Magisk Delta, and native 32-bit app support out of the box, you can use the pre-built image:

```
abing7k/redroid:a11_gapps_magisk_arm
```

This image is Android 11, which natively runs both 32-bit and 64-bit binaries on Oracle A1 (Ubuntu arm64) without crashing, and avoids the `magiskpolicy` bug present in Android 13 on Oracle ARM.

> 💡 **Custom Image Building:** If you prefer to build your own custom image from scratch (to include custom GApps, specific Magisk versions, or extra modules), you can use the build script repository: [abing7k/redroid-script](https://github.com/abing7k/redroid-script). Otherwise, simply pull the ready-to-use pre-built Docker image above.

> **Newbie advice:** Start directly with `abing7k/redroid:a11_gapps_magisk_arm`. It is a proven, all-in-one image that works out of the box on Oracle Cloud ARM64.

Throughout the rest of the guide, wherever you see `<YOUR_IMAGE>`, substitute the image you chose here.

---

# Part 5 — Preparing the host

This is host-level work you do once over SSH. It sets up the kernel pieces Android needs and makes them survive reboots.

## Step 0 — Diagnose your starting point

Run these and note the answers. They tell you what (if anything) you need to change:

```bash
# 1. Is PSI active right now? (This is what lmkd needs — see Mistake #2)
cat /proc/pressure/memory
#   Prints "some avg10=... " lines  → PSI is ACTIVE  ✅  (the common case on Ubuntu arm64)
#   "No such file or directory"     → PSI is OFF     ❌  (you'll add psi=1 in Step 1)
#   Alternative check: zgrep PSI /proc/config.gz (looks for CONFIG_PSI=y)

# 2. What kernel are you on?
uname -r

# 3. Is the binder kernel module available?
modinfo binder_linux >/dev/null 2>&1 && echo "binder_linux: available" || echo "binder_linux: MISSING"
#   Alternative check: grep binder /proc/filesystems

# 4. (Informational only — not a blocker) which cgroup mode?
stat -fc %T /sys/fs/cgroup/
#   cgroup2fs = unified v2   |   tmpfs = hybrid v1+v2
#   Either is FINE for Android 13. Do not "fix" this. (See the cgroup myth, 1.4.)
```

## Step 1 — Kernel: guarantee binder + PSI

Android needs the `binder_linux` module and PSI. Here's how to guarantee both.

### 1a. PSI

If Step 0 showed PSI **active**, do nothing. If it showed "No such file", enable it and reboot:

```bash
# Append psi=1 to the kernel command line
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 psi=1"/' /etc/default/grub
sudo update-grub && sudo reboot
# After reboot, re-check: cat /proc/pressure/memory  → must now print stats
```

**Why:** `psi=1` forces the kernel to enable pressure monitoring at boot. It's the switch that keeps `lmkd` alive.

### 1b. Binder module

If Step 0 showed `binder_linux: MISSING`, install the extra modules package for your running kernel:

```bash
sudo apt update
sudo apt install -y linux-modules-extra-$(uname -r)
modinfo binder_linux >/dev/null 2>&1 && echo "now available"
```

**Why:** On the Ubuntu **generic** kernel, `binder_linux` lives in the `linux-modules-extra` package, which isn't installed by default on minimal cloud images.

> **A note on the kernel choice.** Older versions of this guide told you to rip out Oracle's kernel and install the generic Ubuntu kernel "because Oracle strips cpuset." That reasoning was wrong (see the [cgroup myth](#14-the-cgroup-myth-read-this--it-saves-the-most-time)). That said, the **generic Ubuntu kernel is still a good, predictable baseline**: binder is a simple `apt install` away and PSI is on by default. If you're already on `-generic` and binder + PSI check out, you're done — don't change kernels. If you're on Oracle's stock kernel and binder + PSI both work, you can stay there too. Only switch kernels if binder is genuinely unavailable and `linux-modules-extra` can't provide it:
> ```bash
> # Only if you must switch to the generic kernel:
> sudo apt install -y linux-image-generic linux-headers-generic linux-modules-extra-generic
> sudo apt remove -y 'linux-image*oracle*' 'linux-headers*oracle*'
> sudo update-grub && sudo reboot
> # After reboot: uname -r should end in -generic
> ```

## Step 2 — Load the binder module

```bash
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
lsmod | grep binder
# Expected: a line starting with "binder_linux"
```

**Why:** This loads binder into the running kernel and tells it to create three device nodes — `binder` (apps), `hwbinder` (hardware HALs), and `vndbinder` (vendor). Android expects exactly these three.

> **ashmem note:** On kernel 5.x+, the old `ashmem_linux` module is gone; Android uses `memfd` instead. If `modprobe ashmem_linux` fails, ignore it — that's expected and fine.

## Step 3 — Mount binderfs

```bash
sudo mkdir -p /dev/binderfs
sudo mount -t binder binder /dev/binderfs
ls /dev/binderfs
# Expected: binder  hwbinder  vndbinder  binder-control  features
```

**Why:** `binderfs` is a small virtual filesystem that exposes the binder devices as files. Mounting it materializes the device nodes you just asked the module to create.

## Step 4 — Expose binder devices at the standard paths

```bash
sudo touch /dev/binder /dev/hwbinder /dev/vndbinder
sudo mount --bind /dev/binderfs/binder    /dev/binder
sudo mount --bind /dev/binderfs/hwbinder  /dev/hwbinder
sudo mount --bind /dev/binderfs/vndbinder /dev/vndbinder

ls -la /dev/binder /dev/hwbinder /dev/vndbinder
# Expected: each shows "crw-------" (a character device)
```

**Why:** Android looks for binder at `/dev/binder`, not `/dev/binderfs/binder`. A **bind mount** makes the real device node appear at the path Android expects. (We'll pass these into the container in Part 6.)

## Step 5 — Make it all survive reboots

Right now everything you did evaporates on reboot. These systemd units and config files make it permanent.

### 5.1 Auto-load the binder module

```bash
echo "binder_linux" | sudo tee /etc/modules-load.d/binder.conf
echo "options binder_linux devices=binder,hwbinder,vndbinder" | sudo tee /etc/modprobe.d/binder.conf
```

**Why:** The first line tells systemd to load the module at every boot; the second passes it the right device list.

### 5.2 Systemd mount unit for binderfs

```bash
sudo tee /etc/systemd/system/dev-binderfs.mount << 'EOF'
[Unit]
Description=binderfs filesystem
After=systemd-modules-load.service
Requires=systemd-modules-load.service

[Mount]
What=binder
Where=/dev/binderfs
Type=binder

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p /dev/binderfs
sudo systemctl daemon-reload
sudo systemctl enable --now dev-binderfs.mount
systemctl status dev-binderfs.mount
# Expected: Active: active (mounted)
```

### 5.3 Systemd service for the bind mounts

```bash
sudo tee /etc/systemd/system/binder-bindmounts.service << 'EOF'
[Unit]
Description=Bind mount binderfs devices to /dev
After=dev-binderfs.mount
Requires=dev-binderfs.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/touch /dev/binder /dev/hwbinder /dev/vndbinder
ExecStart=/usr/bin/mount --bind /dev/binderfs/binder /dev/binder
ExecStart=/usr/bin/mount --bind /dev/binderfs/hwbinder /dev/hwbinder
ExecStart=/usr/bin/mount --bind /dev/binderfs/vndbinder /dev/vndbinder

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now binder-bindmounts.service
systemctl status binder-bindmounts.service
# Expected: Active: active (exited)
```

**Why the two-unit split:** the `.mount` unit mounts binderfs; the `.service` unit depends on it and creates the bind mounts afterward. The `Requires`/`After` ordering guarantees they run in the right sequence at every boot.

## Step 6 — Reboot and verify the host

```bash
sudo reboot
```

Wait ~60 seconds, SSH back in, and confirm **everything survived**:

```bash
lsmod | grep binder                                   # binder_linux present
systemctl status dev-binderfs.mount binder-bindmounts.service   # both active
ls -la /dev/binder /dev/hwbinder /dev/vndbinder        # three char devices
cat /proc/pressure/memory                              # PSI prints stats
```

**All four must pass before you deploy.** If any fail, fix it now — a broken host means a broken Android, and you'll waste time blaming the container.

---

# Part 6 — Deploying Redroid

## Step 7 — Deploy via Coolify

1. In Coolify: **New Resource → Docker Compose (Empty)**.
2. Paste this compose file, replacing `<YOUR_IMAGE>` with the image from [Part 4](#part-4--choosing-the-right-image-make-or-break):

```yaml
services:
  a13_1:
    image: <YOUR_IMAGE>          # e.g. redroid/redroid:13.0.0_64only-latest
    container_name: a13_1
    restart: 'no'              # enable a boot-ordered service only after a clean canary
    privileged: true             # Android needs broad kernel access (mounts, binder, cgroups)
    tty: true
    stdin_open: true
    cpus: 1.0                    # preserve one CPU for SSH/host services on a 2-vCPU VPS
    pids_limit: 1536             # hard backstop against process/thread storms
    mem_limit: 6g
    memswap_limit: 8g
    security_opt:
      - 'apparmor:unconfined'    # remove host AppArmor profile — it blocks Android's mounts
      - 'seccomp:unconfined'     # allow the syscalls Android init makes
    volumes:
      - ./data:/data                              # Android's persistent storage (survives restarts)
      - /dev/binderfs/binder:/dev/binder          # the binder devices from Part 5
      - /dev/binderfs/hwbinder:/dev/hwbinder
      - /dev/binderfs/vndbinder:/dev/vndbinder
      - /dev/null:/dev/kmsg                       # do not forward Android log storms to host kmsg
    ports:
      - '127.0.0.1:5555:5555'                     # ADB through an SSH tunnel only
    command:
      - androidboot.redroid_gpu_mode=guest        # software rendering (headless server has no GPU)
      - androidboot.use_memfd=1                   # Fixes binder crashes on modern kernels missing ashmem
      - androidboot.redroid_width=1080
      - androidboot.redroid_height=1920
      - androidboot.redroid_fps=30
      # The two props below are ONLY needed for rooted images (Magisk).
      - ro.secure=0
      - ro.debuggable=1
      - androidboot.selinux=permissive
```

3. Click **Deploy** and watch the logs. On a fresh `./data`, first boot can take **2–5 minutes** on ARM software rendering — be patient. Boot is done when the logs show `sys.boot_completed=1`.

### Step 7.1 — Bind the container's ADB port to VPS loopback

Redroid listens for ADB on TCP port `5555` inside the container. This Compose
entry publishes it only on the VPS loopback interface:

```yaml
ports:
  - '127.0.0.1:5555:5555'
```

Read the mapping from left to right:

```text
127.0.0.1 : 5555       : 5555
VPS address   VPS port   container port
```

The first `127.0.0.1` is the important security boundary. It means:

- ADB is reachable from the VPS itself at `127.0.0.1:5555`.
- It is not listening on the VPS public address.
- An Oracle VCN ingress rule for `5555` is neither needed nor useful.
- A local computer reaches it through the SSH tunnel in Step 8.

Docker creates this binding when it creates the container. It cannot be added
to an already-created container with `docker start`. For an existing Coolify
deployment that lacks the mapping:

1. Add the `ports:` block to the Compose resource.
2. Save the Compose file.
3. Redeploy so Coolify recreates the container.

The persistent `./data:/data` volume survives a normal Compose recreation. Do
not select an option that deletes volumes or manually remove `./data`.

For a raw Docker deployment, the equivalent option is:

```bash
-p 127.0.0.1:5555:5555
```

After deployment, verify the actual Docker mapping on the VPS:

```bash
sudo docker port a13_1 5555/tcp

sudo docker inspect a13_1 \
  --format '{{(index (index .HostConfig.PortBindings "5555/tcp") 0).HostIp}}:{{(index (index .HostConfig.PortBindings "5555/tcp") 0).HostPort}}'
```

Both commands should report:

```text
127.0.0.1:5555
```

Confirm that Android and its ADB daemon have finished starting:

```bash
sudo docker exec a13_1 getprop sys.boot_completed
sudo docker exec a13_1 getprop init.svc.adbd
```

Expected output:

```text
1
running
```

If `docker port` prints nothing, the container was created without the port
mapping; update Compose and redeploy. If the mapping exists but ADB is refused,
check that the container is running and wait for `init.svc.adbd=running`:

```bash
sudo docker ps --filter name=a13_1
sudo docker logs --tail 100 a13_1
```

Do not replace the loopback address with `0.0.0.0`, omit the address, or use
Docker host networking. Each of those can expose an unauthenticated Android
debugging endpoint beyond the VPS.

### Why each important setting is there

- **`privileged: true`** — Android's `init` mounts filesystems and pokes at kernel interfaces a normal container can't. Without this it can't even start.
- **`androidboot.redroid_gpu_mode=guest`** — a headless server has no GPU. `guest` mode uses software rendering (SwiftShader). If you leave this on `host`/`auto`, SurfaceFlinger hangs waiting for a GPU that isn't there ([#687](https://github.com/remote-android/redroid-doc/issues/687)).
- **Resource limits** — Docker containers are unlimited by default. The CPU, memory, swap, and PID ceilings preserve enough host capacity for SSH and Docker recovery. Do not set `oom_score_adj: -1000`; an extreme negative value can make the kernel kill critical host services instead of Redroid.
- **`security_opt: ...unconfined`** — AppArmorV and seccomp are host security layers that block some of the mounts and syscalls Android init performs. Unconfining them clears those blocks.
- **The binder volumes** — hand the host's binder devices (set up in Part 5) into the container at the paths Android expects.
- **`/dev/null:/dev/kmsg`** — Redroid redirects init output to `/dev/kmsg`. Masking it prevents an Android restart storm from flooding the host journal and serial console; collect Android diagnostics through `adb logcat` and `/data` instead.
- **`ro.secure=0` + `ro.debuggable=1`** — make the build behave like an engineering build so `adb root` and Magisk's bootless install work. **Only needed for rooted images**; skip them on the plain 64only image.
- **`androidboot.selinux=permissive`** — logs SELinux denials instead of enforcing them. Needed for Magisk/Zygisk module injection; harmless otherwise.

### Two settings NOT in this file, on purpose

- **No `init: true`.** Android's own `/init` is designed to run as **PID 1** (it reaps zombies and runs the property service itself). Docker's `init: true` inserts a `tini` shim as PID 1 and demotes Android init to PID 2, which can cause subtle issues. The official Redroid examples omit it, so we do too.
- **No cgroup flags** (`cgroup: host`, `cgroupns_mode: host`). You don't need them (see the [cgroup myth](#14-the-cgroup-myth-read-this--it-saves-the-most-time)), and Coolify's schema rejects them anyway (see [Appendix D](#appendix-d--the-cgroup-rabbit-hole-what-not-to-do)).

## Step 8 — Create a local SSH tunnel

Do not open ADB in either the Oracle VCN or `ufw`. Keep the container port bound to loopback and run this from your own computer:

```bash
ssh -N -L 5555:127.0.0.1:5555 ubuntu@YOUR_VPS_PUBLIC_IP
```

ADB then connects to `127.0.0.1:5555` on your computer. A public ADB endpoint is effectively a remote shell and is unnecessary here.

## Step 9 — Connect with ADB

From **your own computer** (not the VPS):

```bash
adb connect 127.0.0.1:5555
adb devices
# Expected: your VPS listed as "device" (not "offline" or "unauthorized")

# Confirm Android actually finished booting:
adb shell getprop sys.boot_completed
# Expected: 1
```

If `sys.boot_completed` is `1`, **congratulations — Android is up.** If it's blank or ADB shows `offline`, go to [Part 8 — Troubleshooting](#part-8--troubleshooting); do not proceed to root setup on a half-booted system.

---

# Part 7 — Root, Zygisk, and Play Store

*(This part applies only if you deployed a **rooted 64-only image** with Magisk + GApps, per [Part 4, Option B](#43-option-b--rooted-image-with-magisk--play-store-what-most-people-actually-want).)*

## Step 10 — Wait for first-boot Magisk setup

Rooted community images run their Magisk setup on the first boot (often triggered from `bootanim.rc`). Give it **2–3 minutes after `sys.boot_completed=1`** before testing.

## Step 11 — Verify / install the Magisk app

```bash
adb connect 127.0.0.1:5555
adb shell pm list packages | grep magisk
# If nothing prints, install it manually (path varies by image):
adb shell pm install /system/etc/init/magisk/magisk.apk
```

## Step 12 — Fix "Magisk shows N/A"

If the Magisk app opens but shows **N/A** instead of a version, the bootless injection didn't complete. Run it by hand:

```bash
adb root
adb shell /system/etc/init/magisk/magisk --auto-selinux --setup-sbin /system/etc/init/magisk /sbin
adb shell /sbin/magisk --auto-selinux --post-fs-data
adb reboot
# wait ~60s
adb connect 127.0.0.1:5555
adb shell magisk --version    # should now print a version
```

**Why it happens:** the bootless method relies on `ro.secure=0` / `ro.debuggable=1` (Step 7) and a permissive SELinux to inject itself. If any of those isn't in effect, injection silently no-ops and you get N/A. Re-check those props first.

### Step 12.5 — Fix "Abnormal State: su binary not from Magisk"
Community images often ship with Redroid's native root enabled by default, conflicting with Magisk Delta. If you see this popup in the Magisk app, remove the native binary:

```bash
docker exec a11_1 su -c 'mount -o remount,rw / && rm /system/xbin/su'
docker restart a11_1
```

## Step 13 — Enable Zygisk

1. Open the Magisk app on the Android instance (via scrcpy or an ADB screen mirror).
2. **Settings → Zygisk → enable.**
   *If the Magisk GUI fails to save the setting, force it via SQLite from your host:*
   ```bash
   cat > /tmp/zygisk.sql << 'EOF'
   INSERT OR REPLACE INTO settings (key, value) VALUES ('zygisk', 1);
   EOF
   # Run against your mounted data volume
   sudo sqlite3 ./data/adb/magisk.db < /tmp/zygisk.sql
   ```
3. Restart the container using Docker:
   ```bash
   docker restart a11_1
   # wait ~60s
   adb connect 127.0.0.1:5555
   ```
4. Reopen Magisk → Settings → confirm **Zygisk: Enabled**.

> **If tapping "Reboot" inside the Magisk app boot-loops the container**, restart the container instead (`docker restart a11_1`). This is a known Redroid + Zygisk quirk; different instances react differently, so try both.

## Step 13.5 — Installing LSPosed
> [!WARNING]
> **Do not try to install modules manually by extracting them into `/data/adb/modules/`.** In a bootless environment, placing a module folder manually will often result in a **false positive**: the Magisk app will say the module is "Installed and Active", but the LSPosed Manager app will say "Not Installed" because the hooks failed to inject during boot. `magisk --install-module` via CLI also reliably fails here.

You must install it via the Magisk App GUI to trigger the correct internal Magisk scripts:

1. Place the LSPosed release zip in the container's Download folder:
   ```bash
   wget -q https://github.com/LSPosed/LSPosed/releases/download/v1.9.2/LSPosed-v1.9.2-7024-zygisk-release.zip -O lsposed.zip
   docker exec a11_1 mkdir -p /sdcard/Download
   docker cp lsposed.zip a11_1:/sdcard/Download/LSPosed.zip
   ```
2. Open the Magisk app via scrcpy.
3. Go to the **Modules tab** (puzzle piece icon) → **Install from storage**.
4. Select `LSPosed.zip` from the Downloads folder.
5. Restart the container (`docker restart a11_1`).

## Step 14 — Certify the device for Play Store

The image ships GApps, so Play Store is present. Google may flag the device "uncertified" on first run. Register it:

```bash
adb root
adb shell sqlite3 /data/data/com.google.android.gsf/databases/gservices.db \
  "select * from main where name = 'android_id';"
```

Copy the numeric **Android ID**, register it at **https://www.google.com/android/uncertified/**, wait ~15 minutes, then restart:

```bash
docker restart a13_1
```

Sign into your Google account in the Play Store afterward.

---

# Part 8 — Troubleshooting

## The #1 rule: read the log, don't guess

Almost every problem here is diagnosable in seconds by looking at the **Android log**, not the Docker log. Learn this one command:

```bash
adb connect 127.0.0.1:5555
adb logcat -b all -d > boot.log 2>&1     # dump everything to a file

# Then find the real failure:
adb logcat -b all -d | grep -iE 'exec format|lmkd|lowmemorykiller|pressure|SurfaceFlinger|process group|boot_progress|FATAL|E ActivityManager|dalvik-cache'
```

If ADB won't connect at all, use the Docker/host log and host kernel buffer (`dmesg`) instead:

```bash
docker logs a13_1 2>&1 | tail -120
docker exec a13_1 logcat -d 2>&1 | tail -120     # if the container is up but ADB isn't

# View host/kernel logs (binder, cgroup, memory pressure, driver crashes):
sudo dmesg | tail -250
```

**The single most useful discriminator** — run this and let the output tell you which of the big three you're hitting:

```bash
docker exec a13_1 logcat -d 2>&1 | grep -iE "exec format|lmkd|SurfaceFlinger"
```
- `exec format` → **incompatible 32-bit image or missing kernel COMPAT** → [see below](#symptom-adb-connects-but-nothing-works--scrcpy-no-service-published-for-input)
- repeated `lmkd ... exited` → **PSI** → [see below](#symptom-lmkd-critical-process-exited-4-times--boot-loop)
- `Waiting for service SurfaceFlinger` → **GPU mode** → [see below](#symptom-stuck-at-waiting-for-service-surfaceflinger)

## Symptom → cause → fix (quick table)

| What you see | Real cause | Fix |
|---|---|---|
| ADB connects, `sys.boot_completed` empty, scrcpy "No service published for: input" | `system_server` never finished — usually 32-bit image crash **or** lmkd/PSI | Below ↓ |
| `cannot execve('/system/bin/app_process32'): Exec format error` | Kernel lacks 32-bit COMPAT or incompatible image | Use `abing7k/redroid:a11_gapps_magisk_arm` or a `_64only` image ([Part 4](#part-4--choosing-the-right-image-make-or-break)) |
| `critical process 'lmkd' exited 4 times before boot completed` | PSI not active → lmkd dies | Enable PSI / `psi=1` ([Step 1a](#1a-psi)) |
| Stuck at `Waiting for service SurfaceFlinger` | GPU mode wrong for headless | `androidboot.redroid_gpu_mode=guest` |
| `init: cpuset cgroup controller is not mounted!` | **Harmless warning** | **Ignore it** ([cgroup myth](#14-the-cgroup-myth-read-this--it-saves-the-most-time)) |
| `Error creating cache dir /data/dalvik-cache` | Bad/stale `./data` volume | Wipe `./data`, reboot clean (below) |
| `modprobe: FATAL: Module binder_linux not found` | Binder module missing | `apt install linux-modules-extra-$(uname -r)` ([Step 1b](#1b-binder-module)) |
| `mount: /dev/binderfs: unknown filesystem type 'binder'` | Module not loaded yet | Re-run `modprobe binder_linux ...`, wait 5s, retry |
| ADB `offline` / `unauthorized` | Half-boot, or image crash | Fix the boot first; use a verified image |
| Works, then breaks after reboot | A host mount/module didn't persist | Re-check Part 5 units are `enabled` |

## Symptom: ADB connects but nothing works / scrcpy "No service published for: input"

This is the headline symptom of "**`system_server` never finished**." It is **not** a scrcpy bug and **not** the cpuset warning. Find which of the two big causes it is:

```bash
docker exec a13_1 logcat -d 2>&1 | grep -iE "exec format|app_process32|lmkd"
```

- See `Exec format error` / `app_process32` → **Incompatible 32-bit image or missing kernel COMPAT.** Switch to `abing7k/redroid:a11_gapps_magisk_arm` or a `_64only` image (Part 4). (Refs: [#26](https://github.com/remote-android/redroid-doc/issues/26), [#308](https://github.com/remote-android/redroid-doc/issues/308), [#412](https://github.com/remote-android/redroid-doc/issues/412).)
- See repeated `lmkd ... exited` → **PSI.** See next section. (Refs: [#823](https://github.com/remote-android/redroid-doc/issues/823), [#412](https://github.com/remote-android/redroid-doc/issues/412).)

## Symptom: `lmkd` "critical process exited 4 times" / boot loop

`lmkd` can't find a memory-pressure source and keeps dying until init aborts the boot.

1. On the **host**, confirm PSI: `cat /proc/pressure/memory`. If it errors, add `psi=1` ([Step 1a](#1a-psi)) and reboot.
2. If PSI is active on the host but lmkd still dies, the image's `lmkd` may be misconfigured for your kernel — try the official `_64only` image to isolate whether it's the image or the host.

(Refs: [#293](https://github.com/remote-android/redroid-doc/issues/293), [#823](https://github.com/remote-android/redroid-doc/issues/823); Waydroid's identical fix on the [Arch Wiki](https://wiki.archlinux.org/title/Waydroid).)

## Symptom: stuck at "Waiting for service SurfaceFlinger"

The display compositor can't initialize. On a headless server this is almost always GPU mode:

- Ensure `androidboot.redroid_gpu_mode=guest` is in your `command:` list.
- Make sure nothing set it to `host` or `auto` (those need a real GPU / DRI device).

(Ref: [#687](https://github.com/remote-android/redroid-doc/issues/687).)

## Symptom: boots ~90%, then stalls (dalvik-cache / `/data` problems)

A stale or wrongly-owned `./data` volume from a previous failed boot is a top cause of "gets most of the way, then hangs." Wipe it and boot clean:

```bash
docker compose down            # or stop/remove via Coolify
sudo rm -rf ./data/*           # ⚠️ erases the Android instance's state — you start fresh
docker compose up -d           # or redeploy in Coolify
```

Then watch `adb logcat` for `dalvik-cache` errors disappearing and `boot_progress_*` advancing.

## Symptom: Magisk shows "N/A"

Three causes, in order of likelihood. Check the log first:

```bash
docker logs a13_1 2>&1 | grep -iE 'lmkd|Zygote|Magisk|zygisk|selinux'
```

| Log pattern | Cause | Fix |
|---|---|---|
| `lmkd ... exited` / boot loop | Boot never completed | Fix the boot first (PSI / image) |
| `Zygote: ZygoteInitFailedErr` | SELinux blocking Zygote | `androidboot.selinux=permissive` |
| Clean boot, still N/A | Magisk props missing | Verify `ro.secure=0` + `ro.debuggable=1`, then [Step 12](#step-12--fix-magisk-shows-na) |

Healthy boot logs contain `Zygote: Zygote started` and `zygisk: Zygisk loaded`.

## Symptom: Play Store "device not certified"

Register your Android ID at google.com/android/uncertified — see [Step 14](#step-14--certify-the-device-for-play-store).

## When Coolify gets in the way — the raw `docker run` escape hatch

Coolify enforces a whitelist of allowed Docker options. Its **Custom Docker Options** field accepts only:

```
--ip  --ip6  --shm-size  --cap-add  --cap-drop  --security-opt  --sysctl
--device  --ulimit  --init  --privileged  --gpus  --entrypoint
```

Anything else (notably `--cgroupns` and `--cgroup-parent`) is rejected by design. **You don't need those for Android 13** — but if you ever want to run outside Coolify's constraints entirely, drop to raw Docker. This also gives you a clean, reproducible way to test:

```bash
docker rm -f a13_1 2>/dev/null || true

docker run -d \
  --name a13_1 \
  --restart=no \
  --privileged \
  --tty --interactive \
  --cpus=1 \
  --pids-limit=1536 \
  --memory=6g \
  --memory-swap=8g \
  --security-opt apparmor=unconfined \
  --security-opt seccomp=unconfined \
  -v "$(pwd)/data:/data" \
  -v /dev/binderfs/binder:/dev/binder \
  -v /dev/binderfs/hwbinder:/dev/hwbinder \
  -v /dev/binderfs/vndbinder:/dev/vndbinder \
  -v /dev/null:/dev/kmsg \
  -p 127.0.0.1:5555:5555 \
  abing7k/redroid:a11_gapps_magisk_arm \
  androidboot.redroid_gpu_mode=guest \
  androidboot.use_memfd=1 \
  androidboot.redroid_width=1080 \
  androidboot.redroid_height=1920 \
  androidboot.redroid_fps=30 \
  androidboot.selinux=permissive \
  ro.secure=0 \
  ro.debuggable=1

docker logs -f a11_1     # watch it boot
```

**Trade-off:** a container started this way is **not managed by Coolify** — you'll start/stop/monitor it with `docker` directly.

---

# Appendix A — Full command sequence

For readers who've done this before. `<YOUR_IMAGE>` = your chosen `_64only` image.

```bash
# ===== HOST: diagnose =====
cat /proc/pressure/memory              # PSI must print stats (else add psi=1)
modinfo binder_linux >/dev/null 2>&1 && echo binder-ok || echo binder-MISSING
uname -r

# ===== HOST: binder module (install extra modules if missing) =====
sudo apt update && sudo apt install -y linux-modules-extra-$(uname -r)
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
lsmod | grep binder

# ===== HOST: binderfs + device bind mounts =====
sudo mkdir -p /dev/binderfs
sudo mount -t binder binder /dev/binderfs
sudo touch /dev/binder /dev/hwbinder /dev/vndbinder
sudo mount --bind /dev/binderfs/binder    /dev/binder
sudo mount --bind /dev/binderfs/hwbinder  /dev/hwbinder
sudo mount --bind /dev/binderfs/vndbinder /dev/vndbinder
ls -la /dev/binder /dev/hwbinder /dev/vndbinder

# ===== HOST: persist across reboots =====
echo "binder_linux" | sudo tee /etc/modules-load.d/binder.conf
echo "options binder_linux devices=binder,hwbinder,vndbinder" | sudo tee /etc/modprobe.d/binder.conf

sudo tee /etc/systemd/system/dev-binderfs.mount << 'EOF'
[Unit]
Description=binderfs filesystem
After=systemd-modules-load.service
Requires=systemd-modules-load.service
[Mount]
What=binder
Where=/dev/binderfs
Type=binder
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/binder-bindmounts.service << 'EOF'
[Unit]
Description=Bind mount binderfs devices to /dev
After=dev-binderfs.mount
Requires=dev-binderfs.mount
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/touch /dev/binder /dev/hwbinder /dev/vndbinder
ExecStart=/usr/bin/mount --bind /dev/binderfs/binder /dev/binder
ExecStart=/usr/bin/mount --bind /dev/binderfs/hwbinder /dev/hwbinder
ExecStart=/usr/bin/mount --bind /dev/binderfs/vndbinder /dev/vndbinder
[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p /dev/binderfs
sudo systemctl daemon-reload
sudo systemctl enable --now dev-binderfs.mount binder-bindmounts.service

# ===== HOST: reboot & verify =====
sudo reboot
# (after ~60s)
lsmod | grep binder
systemctl status dev-binderfs.mount binder-bindmounts.service
ls -la /dev/binder /dev/hwbinder /dev/vndbinder
cat /proc/pressure/memory

# ===== CLIENT: SSH tunnel, then connect =====
ssh -N -L 5555:127.0.0.1:5555 ubuntu@YOUR_VPS_PUBLIC_IP
adb connect 127.0.0.1:5555
adb devices
adb shell getprop sys.boot_completed     # must be 1
```

---

# Appendix B — Final compose file

```yaml
services:
  a13_1:
    image: <YOUR_IMAGE>          # a _64only image (see Part 4)
    container_name: a13_1
    restart: 'no'
    privileged: true
    tty: true
    stdin_open: true
    cpus: 1.0
    pids_limit: 1536
    mem_limit: 6g
    memswap_limit: 8g
    security_opt:
      - 'apparmor:unconfined'
      - 'seccomp:unconfined'
    volumes:
      - ./data:/data
      - /dev/binderfs/binder:/dev/binder
      - /dev/binderfs/hwbinder:/dev/hwbinder
      - /dev/binderfs/vndbinder:/dev/vndbinder
      - /dev/null:/dev/kmsg
    ports:
      - '127.0.0.1:5555:5555'
    command:
      - androidboot.redroid_gpu_mode=guest
      - androidboot.redroid_width=1080
      - androidboot.redroid_height=1920
      - androidboot.redroid_fps=30
      # rooted-image-only props below (omit for plain 64only):
      - ro.secure=0
      - ro.debuggable=1
      - androidboot.selinux=permissive
```

---

# Appendix C — Pre-flight checklist

Before you say "it's broken," confirm every one of these:

- [ ] Image is compatible with host kernel (e.g., `abing7k/redroid:a11_gapps_magisk_arm` for Ubuntu with COMPAT, or `_64only` for pure 64-bit kernels)
- [ ] `cat /proc/pressure/memory` prints stats (PSI active)
- [ ] `lsmod | grep binder` shows `binder_linux`
- [ ] `ls -la /dev/binder /dev/hwbinder /dev/vndbinder` shows three char devices
- [ ] Both systemd units are `active` after a reboot
- [ ] Compose uses `privileged: true`, `androidboot.redroid_gpu_mode=guest`, and the binder volumes
- [ ] Port 5555 is bound only to `127.0.0.1`; remote ADB uses an SSH tunnel
- [ ] `./data` is fresh (wiped) if you're recovering from a failed boot
- [ ] You have read `adb logcat -b all -d` before concluding anything

---

# Appendix D — The cgroup rabbit hole (what NOT to do)

This section exists because the internet is full of "fixes" for the `cpuset cgroup controller is not mounted!` message, and **almost all of them are unnecessary for Android 13**. Earlier drafts of this very guide chased them. Here's the record so you don't repeat the mistake.

**Why the message is harmless (recap):** Android's `libprocessgroup` logs a warning when a cgroup controller isn't at the expected `/dev/*` path and then continues. Android 10–13 boot fine on cgroup v2. The Redroid project only patches this on Android **14+**, and even then it's a one-line change from a fatal assertion to a log line. (Refs: [#780](https://github.com/remote-android/redroid-doc/issues/780), [#179](https://github.com/remote-android/redroid-doc/issues/179), [#38](https://github.com/remote-android/redroid-doc/issues/38), [redroid-patches](https://github.com/remote-android/redroid-patches).)

**Things people try that you should skip** (all confirmed unnecessary and/or non-working for this problem):

| "Fix" | Verdict |
|---|---|
| Forcing the host to cgroup v1 (`systemd.unified_cgroup_hierarchy=0`) + ripping out the Oracle kernel "because it strips cpuset" | Unnecessary. Android 13 boots on v2. This was the original misdiagnosis. |
| `cgroupns_mode: host` in compose | Not a real compose key — correctly rejected. |
| `cgroup: host` in compose | Real key, but Coolify's schema rejects it. Also not needed. |
| `"default-cgroupns-mode": "host"` in `daemon.json` | On a cgroup-v1/hybrid host Docker *already* defaults cgroupns to `host`, so this changes nothing. (And it only affects freshly *created* containers, never a `restart`.) |
| `mount --bind /sys/fs/cgroup/cpuset /dev/cpuset` inside the running container | Fails (read-only namespace) and pointless. |
| Volume `- /sys/fs/cgroup/cpuset:/dev/cpuset` | No effect on the actual boot problem. |
| Patching `/system/etc/cgroups.json` paths | Wrong layer — libprocessgroup already treats the miss as non-fatal, so repointing gains nothing. |

**The one legitimately useful nugget from all of that:** if you genuinely need cgroup **resource-limit enforcement** to work inside Android (most people don't — it only affects Android's internal scheduling niceties, not whether it boots), the maintainer's advice is simply to run the host in cgroup v1/hybrid mode via GRUB (`systemd.unified_cgroup_hierarchy=0`) and reboot. That's it — no per-container gymnastics.

---

# Appendix E — Sources & further reading

Primary sources behind this guide (all from the official Redroid tracker unless noted):

- **cgroup v2 is fine / not a blocker:** [#780](https://github.com/remote-android/redroid-doc/issues/780), [#179](https://github.com/remote-android/redroid-doc/issues/179), [#38](https://github.com/remote-android/redroid-doc/issues/38)
- **The real "input service" cause is lmkd/PSI:** [#823](https://github.com/remote-android/redroid-doc/issues/823), [#412](https://github.com/remote-android/redroid-doc/issues/412), [#293](https://github.com/remote-android/redroid-doc/issues/293)
- **64-bit-only CPUs need a `_64only` image:** [#26](https://github.com/remote-android/redroid-doc/issues/26), [#308](https://github.com/remote-android/redroid-doc/issues/308)
- **GPU mode / SurfaceFlinger:** [#687](https://github.com/remote-android/redroid-doc/issues/687)
- **Oracle ARM + redroid working (crashes were GPU, not cgroup):** [#776](https://github.com/remote-android/redroid-doc/issues/776)
- **Android 14 cgroup assertion patch:** [redroid-patches](https://github.com/remote-android/redroid-patches) → `android-14.0.0_r*/frameworks/base/0001-ignore-cgroup-error.patch`
- **Deployment prerequisites:** [redroid-doc `deploy/ubuntu.md`](https://github.com/remote-android/redroid-doc/blob/master/deploy/ubuntu.md)
- **Rooted-image toolchain & build script:** [abing7k/redroid-script](https://github.com/abing7k/redroid-script) (Build custom Redroid images with GApps and Magisk)
- **Same PSI wall in Waydroid:** [Arch Wiki — Waydroid](https://wiki.archlinux.org/title/Waydroid)
- **Coolify custom Docker options whitelist:** [Coolify docs — custom commands](https://coolify.io/docs)
- **A related project (later migrated off Redroid to Cuttlefish on OCI ARM):** [lehelkovach/redroid-cloud-phone](https://github.com/lehelkovach/redroid-cloud-phone)

---

# Appendix F — Glossary

- **ADB (Android Debug Bridge):** command-line tool to talk to Android — install apps, shell in, read logs, reboot.
- **Binder:** Android's kernel-level IPC. Every service-to-service call rides on it.
- **binderfs:** a virtual filesystem exposing binder devices as files.
- **cgroup (control group):** Linux mechanism for grouping processes to limit/account CPU, memory, IO. "v1" and "v2" are two generations; v2 is unified.
- **lmkd (Low Memory Killer Daemon):** Android service that frees memory by killing apps under pressure. Critical to boot.
- **PSI (Pressure Stall Information):** kernel feature (`/proc/pressure/*`) reporting resource-starvation; lmkd's modern data source.
- **system_server:** the process hosting Android's ~80 framework services. If it doesn't finish, "nothing works."
- **SurfaceFlinger:** Android's display compositor.
- **Zygote:** the warm template process apps fork from.
- **Magisk / Zygisk:** root solution / its in-process module framework.
- **scrcpy:** a tool to mirror and control the Android screen over ADB.
- **AArch32 / AArch64:** 32-bit vs 64-bit ARM execution states. Ampere Altra (Neoverse-N1) hardware supports both AArch64 and AArch32 at EL0 (userspace) when host kernel has `CONFIG_COMPAT=y`.
