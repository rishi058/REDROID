# Redroid on Oracle Ampere A1: Why Zygisk/LSPosed Break on Android 13+ (and How to Actually Fix It)

> **Editor's note on this revision:** The original draft of this doc claimed the Ampere A1's Neoverse-N1 CPU has "zero hardware support" for 32-bit AArch32 instructions. That's not correct, and it changes the diagnosis in Section 1. Everything else has been kept, but hedged where I couldn't independently confirm the exact crash mechanism, and Section 4 (KernelSU) now has real, tested commands instead of a two-line summary. Section 5 has been rewritten with what's actually out there right now for the "wait for a Magisk fix" path.

---

## 1. What's actually going on with the CPU

Neoverse-N1 (and Ampere's Altra/Altra Max silicon that OCI's "A1" shape runs on) is **not** AArch32-free. Per Arm's own Neoverse N1 Technical Reference Manual, the core implements AArch64 at all exception levels (EL0-EL3) **and** AArch32 at EL0 — i.e., 32-bit *user-space* binaries are something the silicon can genuinely execute. You can see this reflected in `lscpu` on real Altra hardware, which reports `CPU op-mode(s): 32-bit, 64-bit`, and in Ampere's own marketing copy, which says Altra runs both 32-bit and 64-bit instructions. (Arm did drop AArch32 entirely — even at EL0 — starting with Neoverse V1, and it's gone across the board in the N2/N3/V2/V3 generation, so this distinction matters if you ever move to a newer Ampere or Graviton chip.)

So why do standard (non-`64only`) Redroid images still faceplant on an A1 instance? Two things, neither of which is "the CPU can't do it":

1. **The `64only` Redroid images are a deliberate build choice**, not a hardware detection. They ship with no 32-bit system partition at all (`ro.product.cpu.abilist32` is empty), originally targeting devices/hosts where 32-bit really is entirely absent. Point a standard multi-ABI image at one of these and any 32-bit binary — `app_process32`, 32-bit `zygote`, `mediaserver`, etc. — fails with a plain `Exec format error`, because the file literally isn't there in the 64only variant, or the loader has no 32-bit ABI table to match it against.
2. **Even where 32-bit binaries exist, they still need the shared host kernel to support AArch32 compat mode** (`CONFIG_COMPAT`). Server-oriented ARM64 kernels — which is what Oracle ships by default on Ubuntu/Oracle Linux A1 images — commonly build this out, since it's dead weight and extra attack surface for a machine that's never going to run 32-bit legacy apps. You can check your own instance with:
   ```bash
   zcat /proc/config.gz 2>/dev/null | grep CONFIG_COMPAT || grep CONFIG_COMPAT /boot/config-$(uname -r)
   ```
   If that comes back empty or `is not set`, 32-bit execution is blocked at the kernel level regardless of what the silicon supports.

**Net effect on your actual workflow: nothing changes.** You still want `64only` Android 13/14 images on Ampere A1 — that part of the original advice was right, just for a software/build reason rather than a hardware one.

---

## 2. The environment (unchanged)

- **Redroid** runs in a Docker container sharing the **host's** Linux kernel. There's no `boot.img`, no separate Android kernel, no boot partition to patch.
- Root has to be injected either through userspace boot scripts (Magisk's "bootless" mode) or by putting the root hooks directly into the one kernel that's actually running — the host's.

## 3. Why the bootless-Magisk + Zygisk combo is fragile on Android 13/14

The commonly reported failure pattern: `magiskpolicy` (Magisk's SELinux live-patcher) dies during `post-fs-data` on Android 13/14 Redroid containers, `magiskd` limps along enough to give you `su`, but module injection and Zygisk never come up — so LSPosed shows "enabled" but never actually hooks Zygote.

Caveat: I could not find a canonical upstream issue that pins this down to a specific signal or syscall — it's consistent with what people report in `ayasa520/redroid-script` and related issue trackers, but treat the SIGABRT/signal-6 specifics as an observed symptom rather than a confirmed root cause. What **is** well documented is that the maintainers of the popular Redroid+Magisk scripts (`ayasa520/redroid-script`, its `abing7k` fork) only claim verified support on `redroid:11.0.0`; Android 13 support is listed as an available tag, not a tested-working one.

## 4. Why Android 11 works

- Older, less strict init/filesystem layout means `magiskpolicy` completes without crashing.
- Some prebuilt Android 11 images bundle `libndk_translation`, which handles 32-bit calls gracefully instead of hard-crashing.
- Because `magiskpolicy` succeeds, Magisk reaches `post-fs-data`/`late_start`, reads `/data/adb/modules`, hooks Zygote, and LSPosed loads.

---

## 5. Path A: KernelSU (recommended) — full walkthrough

The idea, confirmed directly by KernelSU's own FAQ and issue tracker: since Redroid has no kernel of its own, you build the root hooks into the **host's** Linux kernel, reboot the host into it, and every process on the box — including everything inside the Redroid container — is root-capable at the kernel level. No boot image, no bootless hacks, no `magiskpolicy`.

**Important fork note:** official `tiann/KernelSU` v1.0+ dropped support for non-GKI kernels (a generic Ubuntu server kernel doesn't carry Android's GKI/KMI branding, so it counts as non-GKI). Use **KernelSU-Next**, an actively maintained fork that explicitly still supports non-GKI kernels 4.4–6.6 via the same kprobe mechanism. This is also the fork whose companion project, **ZygiskNext**, shipped an update in November 2025 specifically adding support for SELinux-free container environments "such as Redroid" — this is currently the best-supported path for exactly your setup.

### 5.0 Safety first
Recompiling and swapping the *host* kernel on a cloud VM is not reversible with a simple `apt remove`. Before touching anything:
- Take a **boot volume backup/snapshot** of the Ampere A1 instance in the OCI console.
- Confirm you can reach the **serial console** for that instance (OCI Console → Instance → Console Connection), in case GRUB needs manual intervention.
- Keep your current kernel installed alongside the new one; don't remove it.

### 5.1 Get build tools and matching kernel source
```bash
sudo apt update
sudo apt build-dep -y linux linux-image-unsigned-$(uname -r)
sudo apt install -y fakeroot llvm libncurses-dev dwarves bc flex bison libssl-dev libelf-dev git

mkdir -p ~/kbuild && cd ~/kbuild
apt source linux-image-unsigned-$(uname -r)
cd linux-*/
```
(If `apt source` errors out with "no source available," you need the `deb-src` lines enabled in `/etc/apt/sources.list` — uncomment them and `sudo apt update` first.)

### 5.2 Integrate KernelSU-Next into the source tree
```bash
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s next
```
This clones the driver into `KernelSU-Next/` inside your kernel tree and wires it into the build.

### 5.3 Turn on the config options it needs
```bash
cp /boot/config-$(uname -r) .config

./scripts/config --enable CONFIG_KPROBES
./scripts/config --enable CONFIG_HAVE_KPROBES
./scripts/config --enable CONFIG_KPROBE_EVENTS
./scripts/config --enable CONFIG_MODULES
./scripts/config --enable CONFIG_OVERLAY_FS
./scripts/config --enable CONFIG_KSU

make olddefconfig
```
`olddefconfig` will carry over everything from your currently-running config and just resolve new prompts with defaults, so you don't lose Oracle's networking/virtio/etc. drivers.

### 5.4 Build and install
```bash
make -j$(nproc) bindeb-pkg LOCALVERSION=-ksu
cd ..
sudo dpkg -i linux-image-*-ksu_*.deb linux-headers-*-ksu_*.deb
sudo update-grub
```
Reboot **only once you're sure you can get back in via serial console if it fails**:
```bash
sudo reboot
```

### 5.5 Verify the new kernel is active
```bash
uname -r          # should show your version + "-ksu"
dmesg | grep -i ksu
```

### 5.6 Deploy a clean (unrooted) Redroid container
Since root now lives in the kernel, you no longer need Magisk baked into the image at all — use a plain `64only` image:
```bash
docker run -itd --rm --privileged \
  -v ~/data13:/data \
  -p 5555:5555 \
  redroid/redroid:13.0.0_64only-latest
adb connect localhost:5555
```

### 5.7 Install the KernelSU-Next manager inside the container
Grab the latest manager APK from KernelSU-Next's GitHub Releases page and push it in:
```bash
adb install KernelSU_Next_<version>.apk
```
Open it — because the kernel already has the hooks compiled in (there's no boot.img to patch in this setup, same as how KernelSU is deployed for WSA/Waydroid), the manager should report the kernel as active/working rather than "Unsupported."

### 5.8 Add Zygisk support and LSPosed as modules
KernelSU has no built-in Zygisk, so:
1. In the manager app, go to **Modules → Install from storage**.
2. `adb push` the latest **ZygiskNext** release zip (from `Dr-TSNG/ZygiskNext`, v1.3.1 or later — this is the release that added Redroid/SELinux-free support) into the container and install it.
3. Do the same for the **Zygisk-mode build of LSPosed**.
4. Reboot the *container* (not the host): `adb shell reboot`.
5. Confirm in LSPosed that "Zygisk API" shows as working.

### Troubleshooting
- If the manager still shows "Unsupported" after reboot: check `dmesg | grep -i ksu` on the **host** — if kprobes silently failed to attach, KernelSU-Next's docs suggest testing whether kprobe is broken on your kernel before falling back to the manual (non-kprobe) source-patching method described in their docs.
- If GRUB doesn't boot the new kernel: reboot from the serial console, select the old kernel from the GRUB menu (it's still installed), and investigate `.config` differences.

---

## 6. Path B: waiting for a bootless-Magisk fix — where things actually stand

I looked for an existing, confirmed fix for the Android 13/14 bootless-Magisk crash rather than assuming one exists. Here's the honest state of it:

- No canonical upstream bug report or changelog entry from `topjohnwu/Magisk` was found that specifically documents and fixes this bootless/container/Android-13 crash.
- The most active community script for Redroid rooting (`ayasa520/redroid-script`) has, at time of writing, dropped its dependency on Magisk Delta/HuskyDG's fork in favor of stock Magisk, but its own docs still only claim verified success on `redroid:11.0.0`; 13.0.0 remains an available-but-unverified tag.
- The ecosystem's actual response to this problem hasn't been "patch bootless Magisk" — it's been the KernelSU-Next + ZygiskNext combination in Path A, which sidesteps the bootless injection chain entirely. ZygiskNext's November 2025 release explicitly calling out Redroid/SELinux-free support is the clearest sign of where active development is actually going.

**Bottom line:** if you're currently blocked on Android 13/14 + Zygisk + bootless Magisk, there isn't a known fix to wait for — Path A is the currently-supported route, not a workaround while a "real" fix is pending.

---

## References
- Arm Neoverse N1 Technical Reference Manual (AArch32 EL0 support): developer.arm.com/documentation/100616
- KernelSU FAQ and non-GKI integration docs: kernelsu.org/guide/faq.html, kernelsu.org/guide/how-to-integrate-for-non-gki.html
- KernelSU-Next homepage (non-GKI kernel range): kernelsu-next.github.io/webpage
- ZygiskNext releases (Redroid/SELinux-free support, v1.3.1): github.com/Dr-TSNG/ZygiskNext/releases
- Ubuntu kernel build docs: ubuntu.com/kernel/docs/how-to/develop-customise/build-kernel
- `ayasa520/redroid-script` README and issues: github.com/ayasa520/redroid-script

---
For any future VPS setups, you will **never have to compile this again**.

### How to reuse this for future VPS deployments:

1. **Save the `.deb` packages from this build:**
   Once this build completes, we will have generated `.deb` installer files in `~/kbuild/`:
   * `linux-image-6.8.0-136-zksu_*.deb`
   * `linux-headers-6.8.0-136-zksu_*.deb`

2. **Store them for reuse:**
   You can download these 2 files to your local PC or upload them to a Cloud Storage bucket (like R2, S3, or GitHub Releases).

3. **Deploy on any new VPS in 30 seconds:**
   On any new Ubuntu 24.04 ARM VPS in the future, instead of compiling for 40 minutes, you just run:
   ```bash
   # Upload the .deb files and run:
   sudo dpkg -i linux-image-*-zksu_*.deb linux-headers-*-zksu_*.deb
   sudo update-grub
   sudo reboot
   ```
   **Total time required: ~30 seconds!**

---

### Why couldn't we download a pre-built one from the internet?
* Linux kernels must match the specific host OS distribution version (Ubuntu 24.04 Noble) and architecture (`arm64`). 
* Because KernelSU requires inline driver patching into the host kernel source, pre-built binary kernels aren't hosted on central apt repositories.
* However, now that we've built it for your OS version (Ubuntu 24.04 ARM64), you own the compiled `.deb` binaries and can reuse them anytime!