# Fast Setup Guide: ReDroid 14 + KernelSU-Next + Zygisk Next + LSPosed + GApps

This is the command-first installation guide. The default path uses the
already-built kernel packages and the automation in [`vps/`](vps/). A detailed
WSL2 cross-build fallback is included for cases where those packages are absent.

For the reasoning, failures, fixes, build history, and detailed explanations,
read [`my_setup_journey.md`](my_setup_journey.md).

## What this installs

- Ubuntu ARM64 kernel `6.8.12-zksu` with KernelSU-Next support
- ReDroid 14 container `redroid14-ksu`
- KernelSU Manager
- Zygisk Next
- LSPosed
- Optional systemless Google Play Services and Play Store
- Persistent Binder devices
- Bounded Docker resources and log rotation
- A watchdog, boot validator, and ten-minute stability monitor

Expected fast-path time: about 20–40 minutes plus the optional ten-minute
stability check. If a laptop build is required, allow roughly another 20–90
minutes depending on its CPU, RAM, SSD, cooling, and source-transfer time.

## Assumptions

This guide expects:

- an Ubuntu ARM64 VPS using 4 KiB memory pages;
- SSH access as the `ubuntu` user;
- at least 4 GiB available RAM and 5 GiB free under `/home`;
- at least 300 MiB free in `/boot`;
- this repository on a Windows machine;
- when using the fast path, the packaged files in [`artifacts/`](artifacts/)
  have not been modified.

Commands marked **Windows PowerShell** run locally. Commands in the laptop-build
fallback run inside Ubuntu WSL2 where stated. All remaining commands run on the
VPS.

Replace these placeholders:

```text
C:/path/to/private-key.key
SERVER_IP
```

Do not expose Docker/ADB port `5555` publicly. The container binds ADB only to
`127.0.0.1`; use the SSH tunnel near the end of this guide.

---

## 0. Download fallback Android assets when needed

The repository includes pinned fallback assets for the Android root stack. If
the files under `KernelSU_setup/artifacts/android/` are missing, download them
from the original publisher release URLs with **Windows PowerShell**:

```powershell
$AndroidDir = ".\KernelSU_setup\artifacts\android"
$ProgressPreference = "SilentlyContinue"
New-Item -ItemType Directory -Force $AndroidDir | Out-Null

$Assets = @(
  @{
    Name = "KernelSU_Next_v3.3.0_33214-release.apk"
    Url = "https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.3.0/KernelSU_Next_v3.3.0_33214-release.apk"
    Sha256 = "fd0b12385c98fe9d5f4f1257b5f184e55c74c1376637507df0718305f5d7a924"
  },
  @{
    Name = "ksud-aarch64-linux-android"
    Url = "https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.3.0/ksud-aarch64-linux-android"
    Sha256 = "527fa426c20b312f62adbd1a8baaf47fb8fd170677b1bc6427cbcd8a16ff0ee5"
  },
  @{
    Name = "Zygisk-Next-1.4.3-817-e815170-release.zip"
    Url = "https://github.com/Dr-TSNG/ZygiskNext/releases/download/v1.4.3/Zygisk-Next-1.4.3-817-e815170-release.zip"
    Sha256 = "82fb9176037771a9ed4f6a530581c7826460dbc19ca5a6908b95c60b86903858"
  },
  @{
    Name = "LSPosed-v1.9.2-7024-zygisk-release.zip"
    Url = "https://github.com/LSPosed/LSPosed/releases/download/v1.9.2/LSPosed-v1.9.2-7024-zygisk-release.zip"
    Sha256 = "0ebc6bcb465d1c4b44b7220ab5f0252e6b4eb7fe43da74650476d2798bb29622"
  }
)

foreach ($Asset in $Assets) {
  $Path = Join-Path $AndroidDir $Asset.Name
  if (-not (Test-Path $Path)) {
    Write-Host "Downloading $($Asset.Name)"
    Invoke-WebRequest -Uri $Asset.Url -OutFile $Path
  }

  $Actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Actual -ne $Asset.Sha256) {
    throw "SHA-256 mismatch for $($Asset.Name): expected $($Asset.Sha256), got $Actual"
  }
  Write-Host "Verified $($Asset.Name)"
}
```

These are fallback versions, not replacements for checking newer upstream
releases. If you update one, update its URL and SHA-256 together. The matching
manifest is [`artifacts/android/SHA256SUMS`](artifacts/android/SHA256SUMS).

The two kernel `.deb` files are different: they are produced by the kernel
build steps below or copied from the prepared build output. They are not
downloaded from the Android release pages.

---

## 0. Choose the kernel-package approach

Check for the two ARM64 packages in **Windows PowerShell**:

```powershell
$PackageDir = ".\KernelSU_setup\artifacts\kernel-build\packages"
Get-ChildItem $PackageDir -Filter "linux-*6.8.12-zksu*arm64.deb" `
  -ErrorAction SilentlyContinue

if (Test-Path "$PackageDir\SHA256SUMS") {
  Get-Content "$PackageDir\SHA256SUMS"
} else {
  Write-Host "SHA256SUMS is absent; use the laptop-build fallback."
}
```

Choose one path:

- If both `linux-image` and `linux-headers` packages exist, use them and skip to
  [Step 1](#1-upload-the-prepared-files). This is the recommended fast path.
- If either package is absent, build both on the laptop using the procedure
  below, then return to Step 1.

Do not download `/boot/vmlinuz-*` and try to patch it. That is an already-linked
kernel binary. Kernel patches must be applied to a complete source tree.

### 0.1 Laptop-build requirements

The tested VPS is ARM64, while a typical Windows laptop is x86-64. Build inside
Ubuntu WSL2 using an ARM64 cross-compiler.

Recommended laptop resources:

- 16 GiB RAM or more;
- 30 GiB free inside the WSL2 Linux filesystem;
- 8–10 build jobs on a 12-thread laptop, leaving capacity for Windows;
- an SSD and AC power.

Do not build the kernel under `/mnt/c`, `/mnt/d`, OneDrive, or another Windows
mount. Linux kernel source relies on Linux permissions, symlinks, case behavior,
and many small-file operations. Keep the source under `$HOME` in WSL2; only copy
the final `.deb` files back to Windows.

Install Ubuntu WSL2 from an elevated **Windows PowerShell** if it is not already
installed:

```powershell
wsl --install -d Ubuntu-24.04
```

Restart Windows if requested, open Ubuntu, and install the build tools:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential crossbuild-essential-arm64 \
  bc bison flex libssl-dev libelf-dev libncurses-dev libdw-dev \
  dwarves fakeroot dpkg-dev debhelper rsync cpio kmod git time \
  zstd lz4
```

Create the Linux-side workspace:

```bash
export BUILD_ROOT="$HOME/kbuild"
mkdir -p "$BUILD_ROOT"/{vps,artifacts/{config,logs,packages}}
mkdir -p "$HOME/.ssh"
```

Copy the private key into WSL's Linux filesystem. Replace the example key path:

```bash
install -m 0600 \
  "/mnt/c/Users/YOUR_WINDOWS_USER/.ssh/YOUR_PRIVATE_KEY.key" \
  "$HOME/.ssh/vps-build.key"
```

### 0.2 Copy the prepared source tree from the VPS

The source is expected at:

```text
/home/ubuntu/kbuild/linux-6.8.0
```

Copy the directory with `rsync`. The trailing slashes are intentional:

```bash
export SERVER_IP="SERVER_IP"

rsync -aH --info=progress2 \
  -e "ssh -i $HOME/.ssh/vps-build.key -o StrictHostKeyChecking=accept-new" \
  "ubuntu@$SERVER_IP:/home/ubuntu/kbuild/linux-6.8.0/" \
  "$BUILD_ROOT/linux-6.8.0/"
```

This may transfer several gigabytes because it preserves the exact prepared
source, nested KernelSU checkout, Debian metadata, and any existing build state.
The copied build objects will be cleaned locally before cross-compilation.

Copy the project inputs from the Windows checkout. Replace the repository path:

```bash
export REPO_WSL="/mnt/d/path/to/new-terabox"

cp -a "$REPO_WSL/KernelSU_setup/vps/." "$BUILD_ROOT/vps/"
cp -a \
  "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/config/." \
  "$BUILD_ROOT/artifacts/config/"
```

Verify the source identity and pinned KernelSU commit:

```bash
export SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
export KSU_COMMIT="d6a42fd9285c11b8e8e67bfe72a5050528006c00"

test -x "$SOURCE_DIR/scripts/config"
test -f "$SOURCE_DIR/debian/changelog"
test -d "$SOURCE_DIR/KernelSU-Next/.git"
test "$(git -C "$SOURCE_DIR/KernelSU-Next" rev-parse HEAD)" = "$KSU_COMMIT"

head -n 1 "$SOURCE_DIR/debian/changelog"
git -C "$SOURCE_DIR/KernelSU-Next" status --short
```

The expected source line is:

```text
linux-upstream (6.8.12-11) noble; urgency=low
```

The `status --short` output may show the already-applied KernelSU compatibility
changes. Do not reset or discard them.

If the source directory no longer exists on the VPS, reconstruct the exact
source and KernelSU checkout using Part 6 of
[`my_setup_journey.md`](my_setup_journey.md). Do not substitute a random
`latest` kernel or KernelSU branch.

### Why this guide does not use the upstream one-line setup command

The older general rooting analysis documents this alternative:

```bash
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s next
```

That command is intended for integrating KernelSU-Next into a fresh kernel
source checkout. It clones or updates the live `next` branch and edits the
kernel `Makefile` and `Kconfig` automatically. This guide does not use it
because this workflow already has a pinned KernelSU-Next commit, archived
Linux 6.8 compatibility patches, and a known-good configuration. Running the
one-line command here could replace the prepared checkout, pull unpinned
changes, or bypass the required patches. Use it only for a deliberately
separate fresh-source build after pinning and reviewing the exact revision.

### 0.3 Apply the archived compatibility patches only when needed

The copied VPS tree should normally already contain both fixes. The following
function applies each patch only if it is not already present:

```bash
cd "$SOURCE_DIR/KernelSU-Next"

apply_if_missing() {
  local patch_file="$1"

  if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "Already applied: $patch_file"
  elif git apply --check "$patch_file"; then
    git apply "$patch_file"
    echo "Applied: $patch_file"
  else
    echo "Patch is neither cleanly applicable nor already applied: $patch_file" >&2
    return 1
  fi
}

apply_if_missing "$BUILD_ROOT/vps/patches/kernelsu-arm64-cacheflush.patch"
apply_if_missing "$BUILD_ROOT/vps/patches/kernelsu-selinux-unavailable.patch"

git diff --check
```

Do not run `git apply` unconditionally. Applying the same fix twice can corrupt
the source or produce a misleading partial patch.

### 0.4 Restore and validate the known-good configuration

Clean only the laptop copy, then restore the archived final config:

```bash
cd "$SOURCE_DIR"

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean
rm -f KernelSU-Next/kernel/built-in.a

cp "$BUILD_ROOT/artifacts/config/config.completed" .config

make ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  olddefconfig
```

Validate the essential contract:

```bash
required=(
  CONFIG_DEBUG_INFO_NONE=y
  CONFIG_KPROBES=y
  CONFIG_EXT4_FS=y
  CONFIG_OVERLAY_FS=y
  CONFIG_KSU=y
  CONFIG_ANDROID_BINDER_IPC=m
  CONFIG_ANDROID_BINDERFS=m
  CONFIG_NAMESPACES=y
  CONFIG_PID_NS=y
  CONFIG_NET_NS=y
  CONFIG_CGROUPS=y
  CONFIG_SECCOMP=y
  CONFIG_PSI=y
  CONFIG_MEMCG=y
  CONFIG_CGROUP_PIDS=y
  CONFIG_ARM64_4K_PAGES=y
)

for option in "${required[@]}"; do
  grep -qx "$option" .config || {
    echo "Required option missing: $option" >&2
    exit 1
  }
done

test "$(git -C KernelSU-Next rev-parse HEAD)" = "$KSU_COMMIT"

release=$(make -s \
  ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  kernelrelease LOCALVERSION=-zksu)

test "$release" = 6.8.12-zksu
echo "$release"
```

The VPS-oriented [`prepare_kernel_v2.sh`](vps/prepare_kernel_v2.sh) documents
the same configuration contract and early subtree gates, but do not execute it
unchanged on the laptop. It has VPS-specific paths, user checks, swap handling,
and incident-log cleanup.

### 0.5 Run a small compatibility build first

Catch patch or compiler problems before starting the full package build:

```bash
cd "$SOURCE_DIR"

make -j1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- prepare
make -j1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- security/selinux/
make -j1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/kernelsu/
```

Do not continue if any command fails.

### 0.6 Build ARM64 Debian packages on the laptop

Use ten jobs initially on a 12-thread laptop. Reduce `JOBS` if Windows becomes
unresponsive or the laptop thermally throttles:

```bash
cd "$SOURCE_DIR"
export JOBS=10
export BUILD_LOG="$BUILD_ROOT/artifacts/logs/laptop-cross-build-$(date -u +%Y%m%dT%H%M%SZ).log"
set -o pipefail

/usr/bin/time -v make -j"$JOBS" \
  ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_DEBARCH=arm64 \
  bindeb-pkg LOCALVERSION=-zksu \
  2>&1 | tee "$BUILD_LOG"
```

[`build_kernel_v2.sh`](vps/build_kernel_v2.sh) is the native two-core VPS
equivalent. The laptop command retains its pinned commit, config, package, and
hash expectations while adding the cross-compilation variables explicitly.

### 0.7 Collect and verify the generated packages

`bindeb-pkg` writes packages into the parent of the source directory:

```bash
find "$BUILD_ROOT" -maxdepth 1 -type f \
  -name '*6.8.12-zksu*arm64.deb' -print

mapfile -t image_packages < <(
  find "$BUILD_ROOT" -maxdepth 1 -type f \
    -name 'linux-image-6.8.12-zksu_*_arm64.deb' | sort
)
mapfile -t header_packages < <(
  find "$BUILD_ROOT" -maxdepth 1 -type f \
    -name 'linux-headers-6.8.12-zksu_*_arm64.deb' | sort
)

test "${#image_packages[@]}" -eq 1
test "${#header_packages[@]}" -eq 1

rm -f "$BUILD_ROOT/artifacts/packages/"*.deb \
      "$BUILD_ROOT/artifacts/packages/SHA256SUMS"
cp -a "${image_packages[0]}" "${header_packages[0]}" \
  "$BUILD_ROOT/artifacts/packages/"

cd "$BUILD_ROOT/artifacts/packages"

for package in *.deb; do
  test "$(dpkg-deb -f "$package" Architecture)" = arm64
  dpkg-deb -f "$package" Package Version Architecture
done

sha256sum -- *.deb > SHA256SUMS
sha256sum -c SHA256SUMS
```

Exactly one image package and one headers package must be present, both with
`Architecture: arm64`.

### 0.8 Copy the packages back to the Windows project

Still inside WSL2:

```bash
export WINDOWS_PACKAGES="$REPO_WSL/KernelSU_setup/artifacts/kernel-build/packages"
mkdir -p "$WINDOWS_PACKAGES"

cp -a "$BUILD_ROOT/artifacts/packages/." "$WINDOWS_PACKAGES/"
```

Verify them again in **Windows PowerShell**:

```powershell
$PackageDir = ".\KernelSU_setup\artifacts\kernel-build\packages"
Get-ChildItem "$PackageDir\*.deb" | Get-FileHash -Algorithm SHA256
Get-Content "$PackageDir\SHA256SUMS"
```

The hashes printed by PowerShell must match `SHA256SUMS`. The files are now in
the location expected by Step 1 and
[`install_kernel_v2.sh`](vps/install_kernel_v2.sh).

---

## 1. Upload the prepared files

Run from the repository root in **Windows PowerShell**:

```powershell
$Key = "C:/path/to/private-key.key"
$Target = "ubuntu@SERVER_IP"

ssh -i $Key $Target "mkdir -p /home/ubuntu/kbuild/artifacts/config /home/ubuntu/kbuild/artifacts/logs"
scp -i $Key -r ".\KernelSU_setup\vps" "${Target}:/home/ubuntu/kbuild/"
scp -i $Key -r ".\KernelSU_setup\artifacts\android" "${Target}:/home/ubuntu/kbuild/artifacts/"
scp -i $Key -r ".\KernelSU_setup\artifacts\kernel-build\config" "${Target}:/home/ubuntu/kbuild/artifacts/"
scp -i $Key -r ".\KernelSU_setup\artifacts\kernel-build\packages" "${Target}:/home/ubuntu/kbuild/artifacts/"
```

Connect:

```powershell
ssh -i $Key $Target
```

The remote layout must now be:

```text
/home/ubuntu/kbuild/
|-- vps/
`-- artifacts/
    |-- android/
    |-- config/
    |-- logs/
    `-- packages/
```

## 2. Run the host preflight

```bash
set -e

test "$(id -un)" = ubuntu
test "$(dpkg --print-architecture)" = arm64
test "$(getconf PAGESIZE)" -eq 4096
test -r /proc/pressure/memory

free -h
df -h / /boot /home/ubuntu
nproc
```

Stop here if any `test` fails. These scripts and packages target the tested
ARM64/4-KiB-page environment, not an x86 VPS or a 16-KiB-page ARM host.

Install the runtime tools:

```bash
sudo apt-get update
command -v docker >/dev/null || sudo apt-get install -y docker.io
command -v adb >/dev/null || sudo apt-get install -y adb
sudo systemctl enable --now docker
sudo docker info >/dev/null
```

Add a 2 GiB emergency swap file only if the host has no active swap:

```bash
if ! swapon --show --noheadings | grep -q .; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || \
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

swapon --show
```

Keep kernel console noise bounded. The deployment script deliberately refuses
an excessively noisy console because it previously contributed to host stress:

```bash
echo 'kernel.printk = 4 4 1 7' | sudo tee /etc/sysctl.d/90-redroid-console.conf
sudo sysctl --system >/dev/null
cat /proc/sys/kernel/printk
```

Verify the uploaded assets before installing anything:

```bash
cd /home/ubuntu/kbuild
chmod 0755 vps/*.sh

cd artifacts/packages
sha256sum -c SHA256SUMS

cd ../android
sha256sum -c SHA256SUMS

cd /home/ubuntu/kbuild
```

Every hash must report `OK`.

## 3. Install the prebuilt KernelSU kernel

Run the guarded installer
[`install_kernel_v2.sh`](vps/install_kernel_v2.sh):

```bash
cd /home/ubuntu/kbuild
./vps/install_kernel_v2.sh
```

The script verifies the package hashes and architecture, checks `/boot` space,
installs the image and headers, creates initramfs, and updates GRUB. It does not
change the default kernel and does not reboot.

Confirm the files exist:

```bash
ls -lh /boot/vmlinuz-6.8.12-zksu \
       /boot/initrd.img-6.8.12-zksu \
       /boot/config-6.8.12-zksu
```

Find the **exact** GRUB menu path generated on this VPS:

```bash
sudo grep -E "^submenu |^menuentry " /boot/grub/grub.cfg
```

Copy the complete entry path for `6.8.12-zksu`. It will normally look like:

```text
Advanced options for Ubuntu>Ubuntu, with Linux 6.8.12-zksu
```

Use the string copied from your VPS, not the example:

```bash
CUSTOM_ENTRY='PASTE THE EXACT CUSTOM KERNEL ENTRY HERE'
sudo grub-reboot "$CUSTOM_ENTRY"
sudo grub-editenv list
```

The output must show `next_entry` pointing to the custom kernel. Reboot:

```bash
sudo reboot
```

Your SSH connection will close. Wait for the VPS to return, reconnect, then
verify the running kernel before doing anything else:

```bash
uname -r
test "$(uname -r)" = 6.8.12-zksu
```

Do not continue unless the test passes.

## 4. Make Binder devices persistent

The kernel deliberately has no default Binder device list. Persist both the
module and its required device names:

```bash
echo 'binder_linux' | sudo tee /etc/modules-load.d/redroid-binder.conf
echo 'options binder_linux devices=binder,hwbinder,vndbinder' | \
  sudo tee /etc/modprobe.d/redroid-binder.conf

sudo modprobe binder_linux devices=binder,hwbinder,vndbinder
sudo install -d -m 0755 /dev/binderfs
```

Install the supplied Binder units:

```bash
cd /home/ubuntu/kbuild

sudo install -m 0644 vps/dev-binderfs.mount \
  /etc/systemd/system/dev-binderfs.mount
sudo install -m 0644 vps/binder-bindmounts.service \
  /etc/systemd/system/binder-bindmounts.service
sudo install -m 0644 vps/redroid-binder-permissions.service \
  /etc/systemd/system/redroid-binder-permissions.service

sudo systemctl daemon-reload
sudo systemctl enable --now dev-binderfs.mount
sudo systemctl enable --now binder-bindmounts.service
sudo systemctl enable --now redroid-binder-permissions.service
```

Verify all three units and all three devices:

```bash
systemctl is-active dev-binderfs.mount \
  binder-bindmounts.service \
  redroid-binder-permissions.service

ls -l /dev/binder /dev/hwbinder /dev/vndbinder
stat -Lc '%n inode=%i mode=%a owner=%U:%G' \
  /dev/binderfs/binder /dev/binder \
  /dev/binderfs/hwbinder /dev/hwbinder \
  /dev/binderfs/vndbinder /dev/vndbinder
```

Each `/dev/binderfs/...` node and its `/dev/...` partner must have the same
inode number.

## 5. Deploy ReDroid and stage root modules

Install the watchdog command first because the deploy script starts it:

```bash
cd /home/ubuntu/kbuild
sudo install -m 0755 vps/redroid14_watchdog_v2.sh \
  /usr/local/sbin/redroid14-watchdog
```

Run [`deploy_redroid14_v2.sh`](vps/deploy_redroid14_v2.sh):

```bash
./vps/deploy_redroid14_v2.sh
```

The script performs its own safety checks, pulls the pinned ReDroid image,
creates the bounded container, installs KernelSU Manager, stages `ksud`, and
stages Zygisk Next and LSPosed.

Its important Docker limits are already encoded in the script:

```text
CPU:                1.5 cores
Memory:             8 GiB
Memory + swap:      10 GiB
PIDs:               8192
Restart policy:     no
Docker log:         50 MiB x 2 files
ADB host binding:   127.0.0.1:5555
/dev/kmsg:          mapped to /dev/null
```

The 8,192-task hard cap and the watchdog's lower 7,000-task limit leave ample
headroom for Google Play Services and modding workloads while still containing
a genuine thread or process storm. The earlier 1,536/1,400 limits are sufficient
for bare ReDroid but kill a healthy GApps boot. The 7,000-task guard also remains
below the previously observed runaway workload of about 8,230 tasks.

If the script refuses an existing `redroid14-ksu` container or a nonempty
`/home/ubuntu/redroid14-data`, stop and inspect them. Do not blindly delete an
older installation.

Check the transient deployment:

```bash
sudo docker ps --filter name=redroid14-ksu
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 shell getprop sys.boot_completed
```

The last command must print `1`.

## 6. Install the permanent service units

```bash
cd /home/ubuntu/kbuild

sudo install -m 0755 vps/validate_redroid14.sh \
  /usr/local/sbin/validate-redroid14
sudo install -m 0755 vps/monitor_redroid14_10m.sh \
  /usr/local/sbin/monitor-redroid14-10m

sudo install -m 0644 vps/redroid14.service \
  /etc/systemd/system/redroid14.service
sudo install -m 0644 vps/redroid14-watchdog.service \
  /etc/systemd/system/redroid14-watchdog.service
sudo install -m 0644 vps/redroid14-validate.service \
  /etc/systemd/system/redroid14-validate.service

sudo systemctl daemon-reload
sudo systemd-analyze verify \
  /etc/systemd/system/dev-binderfs.mount \
  /etc/systemd/system/binder-bindmounts.service \
  /etc/systemd/system/redroid-binder-permissions.service \
  /etc/systemd/system/redroid14.service \
  /etc/systemd/system/redroid14-watchdog.service \
  /etc/systemd/system/redroid14-validate.service

sudo systemctl enable redroid14.service \
  redroid14-watchdog.service \
  redroid14-validate.service
```

Do not start a second watchdog manually. The deploy script already has a
transient watchdog running; systemd takes ownership after the next reboot.

## 7. Reboot once more to activate the root modules

The first `grub-reboot` was one-shot and has already been consumed. Set another
one-shot custom-kernel boot before this reboot, or the VPS may return to its
stock kernel.

Find and copy the entry again if this is a new SSH session:

```bash
sudo grep -E "^submenu |^menuentry " /boot/grub/grub.cfg
CUSTOM_ENTRY='PASTE THE EXACT CUSTOM KERNEL ENTRY HERE'

sudo grub-reboot "$CUSTOM_ENTRY"
sudo grub-editenv list
sudo reboot
```

Reconnect and run the final validator:

```bash
test "$(uname -r)" = 6.8.12-zksu

systemctl is-active \
  dev-binderfs.mount \
  binder-bindmounts.service \
  redroid-binder-permissions.service \
  redroid14.service \
  redroid14-watchdog.service

sudo /usr/local/sbin/validate-redroid14
```

The validator checks the kernel, Binder topology, boot state, Docker policy,
watchdog, root assets, Manager package, Zygisk Next, LSPosed, and recent OOM or
kernel-failure signals.

Useful status commands:

```bash
sudo systemctl status redroid14.service redroid14-watchdog.service --no-pager
sudo journalctl -u redroid14.service -u redroid14-watchdog.service -b --no-pager
sudo docker stats --no-stream redroid14-ksu
sudo docker logs --tail 100 redroid14-ksu
```

## 8. Make the custom kernel the saved default

Do this only after the final validator passes. Keep the stock kernel installed
as the recovery path.

```bash
sudo grep -E "^submenu |^menuentry " /boot/grub/grub.cfg
CUSTOM_ENTRY='PASTE THE EXACT CUSTOM KERNEL ENTRY HERE'

sudo cp -a /etc/default/grub \
  "/etc/default/grub.before-zksu.$(date +%s)"

if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
  sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
else
  echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub
fi

sudo update-grub
sudo grub-set-default "$CUSTOM_ENTRY"
sudo grub-editenv list
```

The output must show `saved_entry` set to the custom kernel.

## 9. Run the ten-minute stability gate

The setup is operational after the validator passes. This final monitor is
strongly recommended before considering it stable:

```bash
sudo systemd-run \
  --unit=redroid14-stability-check \
  --collect \
  --property=Type=exec \
  /usr/local/sbin/monitor-redroid14-10m

sudo journalctl -fu redroid14-stability-check
```

The monitor takes eleven samples about one minute apart and fails if the
container stops, Android loses boot completion, the watchdog disappears, or a
critical kernel event appears.

After it finishes:

```bash
systemctl show redroid14-stability-check \
  -p Result -p ExecMainStatus -p ActiveState -p SubState
```

Success is `Result=success` and `ExecMainStatus=0`.

## 10. Connect ADB from Windows

Keep this SSH tunnel open in one **Windows PowerShell** window:

```powershell
ssh -i "C:/path/to/private-key.key" `
  -N -L 5555:127.0.0.1:5555 `
  ubuntu@SERVER_IP
```

In a second PowerShell window:

```powershell
adb kill-server
adb start-server
adb connect 127.0.0.1:5555
adb devices -l
```

Connect to `127.0.0.1:5555`, not `SERVER_IP:5555`. A public Oracle VCN rule for
port 5555 is unnecessary and should be removed.

## 11. Confirm KernelSU, Zygisk, and LSPosed

```bash
adb connect 127.0.0.1:5555

adb -s 127.0.0.1:5555 shell su -c id
adb -s 127.0.0.1:5555 shell su -c 'ls -la /data/adb/modules'
adb -s 127.0.0.1:5555 shell su -c 'ps -A | grep -i zygisk'
adb -s 127.0.0.1:5555 shell su -c 'logcat -d | grep -i -E "zygisk|lsposed" | tail -100'
```

KernelSU Manager and the LSPosed UI can then be opened inside Android. If
Android asks for root authorization, approve only the apps you trust.

## 12. Optional: add GApps and Google Play Store

This section adds Google Play Services, Google Services Framework, and Play
Store to the existing pinned ReDroid 14 image without rebuilding that image.
Skip it if you want a Google-free Android instance.

### 12.1 Understand the support boundary

ReDroid documents that GMS can be added with GApps and describes building GApps
directly into a custom image. For this already-deployed KernelSU instance, the
shorter route is a systemless LiteGapps module:

- [ReDroid GMS support](https://github.com/remote-android/redroid-doc#gms-support)
- [ReDroid image-build method](https://github.com/remote-android/redroid-doc/blob/master/android-builder-docker/README.md#build-with-gapps)
- [LiteGapps KernelSU Next installation](https://litegapps.github.io/doc/installation.html)
- [KernelSU Next Magic Mount](https://kernelsu-next.github.io/webpage/#dynamic-module-mount)

This method is optional and experimental in ReDroid. LiteGapps itself warns
that its systemless mode is not fully functional and may have limitations such
as contact synchronization. ReDroid also does not guarantee that every app,
location API, payment flow, Play Integrity level, DRM feature, or hardware API
will work merely because Play Store opens.

For a production image where GMS must be part of `/system`, build and pin a
custom ReDroid image using ReDroid's image-build method instead. Do not silently
replace the image digest in
[`deploy_redroid14_v2.sh`](vps/deploy_redroid14_v2.sh); a custom image requires
its own digest, validation run, and rollback test.

### 12.2 Confirm the Android target and absence of existing GApps

Run on the VPS:

```bash
export ADB_SERIAL=127.0.0.1:5555
export CONTAINER=redroid14-ksu

adb connect "$ADB_SERIAL"
adb -s "$ADB_SERIAL" wait-for-device

test "$(adb -s "$ADB_SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')" = 34
test "$(adb -s "$ADB_SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')" = arm64-v8a
test "$(adb -s "$ADB_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" = 1

adb -s "$ADB_SERIAL" shell pm list packages | \
  grep -E 'com\.google\.android\.gms|com\.google\.android\.gsf|com\.android\.vending' || true
```

The final command should print nothing. Do not install LiteGapps over a ROM that
already contains GApps; the upstream installer warns that the two copies can
conflict.

Confirm KernelSU and its existing modules are healthy:

```bash
sudo docker exec "$CONTAINER" /data/adb/ksud -V
sudo docker exec "$CONTAINER" /data/adb/ksud module list
```

### 12.3 Install the Magic Mount metamodule

LiteGapps changes the system directory, while a fresh KernelSU Next installation
does not mount ordinary modules by itself. It needs one active
[metamodule](https://kernelsu.org/guide/metamodule.html). The pinned `ksud 3.3.0`
used by this project has no `ksud module mount` command and no Manager setting
that substitutes for this prerequisite. Install a real metamodule instead.

This procedure uses the
[Magic Mount metamodule](https://modules.kernelsu.org/module/meta-mm/), which is
compatible with the Magisk-style mount layout expected by LiteGapps:

```bash
export META_NAME=meta-magic_mount-v1.0.1-sprout-release.zip
export META_DIR=/home/ubuntu/kbuild/artifacts/gapps
export META_ZIP="$META_DIR/$META_NAME"
export META_URL="https://github.com/KernelSU-Modules-Repo/meta-mm/releases/download/v1.0.1-sprout/$META_NAME"
export META_SHA256=4e2bfbccd80b0d787223cc8fe36315e8b269514a28f6d7ffb8e6e1f855e6e92b

mkdir -p "$META_DIR"
curl -fL --retry 3 --retry-delay 2 \
  -o "$META_ZIP.part" "$META_URL"
mv "$META_ZIP.part" "$META_ZIP"

printf '%s  %s\n' "$META_SHA256" "$META_ZIP" | sha256sum -c -
unzip -tq "$META_ZIP"
unzip -p "$META_ZIP" module.prop
```

The release ZIP deliberately contains `metamodule=0`; its verified installer
changes that property to `metamodule=1` while installing. Copy it into ReDroid,
install it, and confirm the staged property:

```bash
sudo docker cp "$META_ZIP" "$CONTAINER":/data/local/tmp/meta-mm.zip
sudo docker exec "$CONTAINER" \
  /data/adb/ksud module install /data/local/tmp/meta-mm.zip

sudo docker exec "$CONTAINER" sh -c '
  cat /data/adb/modules_update/meta-mm/module.prop |
    grep -Fx metamodule=1
'
sudo docker exec "$CONTAINER" rm -f /data/local/tmp/meta-mm.zip
```

KernelSU init hooks run at host boot in this deployment. Confirm the custom
kernel is the saved GRUB entry and perform the first host reboot:

```bash
test "$(uname -r)" = 6.8.12-zksu
sudo grub-editenv list
sudo reboot
```

After reconnecting, wait for Android and verify the metamodule. `Installed` is
the expected result:

```bash
test "$(uname -r)" = 6.8.12-zksu
adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 wait-for-device
test "$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed | tr -d '\r')" = 1

sudo docker exec "$CONTAINER" /data/adb/ksud module metamodule
sudo docker exec "$CONTAINER" sh -c \
  'grep -F "Magic Mount Completed Successfully" /data/adb/magic_mount/mm.log'
```

### 12.4 Download and verify the pinned Android 14 ARM64 package

The Lite variant is used because it contains the minimum useful Google stack:
common permissions, Google Services Framework, Google Play Services, Play
Store, and Google Contacts Sync Adapter. The larger Core/Nano/Pixel variants
add setup and application packages that are unnecessary on this headless VPS.
See the [official variant comparison](https://litegapps.github.io/doc/litegapps_variant.html).

Install only the host-side download/inspection tools:

```bash
sudo apt-get update
sudo apt-get install -y curl unzip
```

Download the pinned package from the project's official SourceForge release:

```bash
export GAPPS_NAME=LiteGapps-arm64-14.0-20260118-official.zip
export GAPPS_DIR=/home/ubuntu/kbuild/artifacts/gapps
export GAPPS_ZIP="$GAPPS_DIR/$GAPPS_NAME"
export GAPPS_URL="https://downloads.sourceforge.net/project/litegapps/litegapps/arm64/34/lite/2026-01-18/$GAPPS_NAME"
export GAPPS_SHA256=6308d96e359dd61f40ff32c9828108a0b2695cc21701204600b4513b7379876a

mkdir -p "$GAPPS_DIR"
curl -fL --retry 3 --retry-delay 2 \
  -o "$GAPPS_ZIP.part" "$GAPPS_URL"
mv "$GAPPS_ZIP.part" "$GAPPS_ZIP"

printf '%s  %s\n' "$GAPPS_SHA256" "$GAPPS_ZIP" | sha256sum -c -
unzip -p "$GAPPS_ZIP" module.prop
```

The metadata must include:

```text
id=litegapps
name=litegapps arm64 14.0 official
version=v4.9
date=18-01-2026
```

The exact upstream file is
[LiteGapps ARM64 Android 14 Lite, 2026-01-18](https://sourceforge.net/projects/litegapps/files/litegapps/arm64/34/lite/2026-01-18/LiteGapps-arm64-14.0-20260118-official.zip/download).
The SHA-256 above was independently calculated from that file on 2026-07-28.
If you choose a newer release, do not reuse this digest: verify its architecture,
Android API, module metadata, and new checksum separately.

Google applications are proprietary. This project deliberately does not bundle
or redistribute the ZIP; each operator downloads it from its publisher and is
responsible for the applicable licence and Google terms.

### 12.5 Install LiteGapps as a KernelSU module

KernelSU extracts module payloads under `/dev/tmp`. Docker creates ReDroid's
`/dev` as a 64 MiB tmpfs by default, but this LiteGapps package expands to about
316 MB. Without raising the limit, its installer misleadingly finishes after
GNU tar reports `No space left on device`, leaving truncated GMS and Play Store
APKs. Temporarily enlarge the tmpfs; memory is consumed only by files actually
written, and the normal 64 MiB setting returns at the next container start:

```bash
sudo docker exec "$CONTAINER" mount -o remount,size=768M /dev
sudo docker exec "$CONTAINER" df -h /dev
```

Copy the verified ZIP into Android and install it with the same pinned `ksud`
used for the other modules:

```bash
sudo docker cp "$GAPPS_ZIP" "$CONTAINER":/data/local/tmp/litegapps.zip
sudo docker exec "$CONTAINER" sha256sum /data/local/tmp/litegapps.zip

sudo docker exec "$CONTAINER" \
  /data/adb/ksud module install /data/local/tmp/litegapps.zip

sudo docker exec "$CONTAINER" rm -f /data/local/tmp/litegapps.zip
sudo docker exec "$CONTAINER" /data/adb/ksud module list

sudo docker exec "$CONTAINER" sh -c '
  test -f /data/adb/modules_update/litegapps/module.prop ||
  test -f /data/adb/modules/litegapps/module.prop
'
```

The module list must contain `litegapps`. Its staged directory should be about
305 MB, and the two largest APKs must not be empty or truncated:

```bash
sudo docker exec "$CONTAINER" du -sh \
  /data/adb/modules_update/litegapps
sudo docker exec "$CONTAINER" stat -c '%n %s bytes' \
  /data/adb/modules_update/litegapps/system/product/priv-app/GmsCore/GmsCore.apk \
  /data/adb/modules_update/litegapps/system/product/priv-app/Phonesky/Phonesky.apk
```

For the pinned release, the expected sizes are `225469269` and `76478510`
bytes. Stop and remove only `/data/adb/modules_update/litegapps` if installation
reports an architecture, SDK, space, mount, extraction, or permission error. Do
not reboot an incomplete staged module.

### 12.6 Reboot the host—not only Android

This environment requires a host reboot to replay KernelSU's init hooks and
activate newly installed modules. `adb reboot`, `docker restart`, and restarting
only `redroid14-ksu` are insufficient.

Step 8 should already have made `6.8.12-zksu` the saved GRUB default. Verify it:

```bash
test "$(uname -r)" = 6.8.12-zksu
sudo grub-editenv list
```

Confirm `saved_entry` names `6.8.12-zksu`, then reboot:

```bash
sudo reboot
```

Reconnect after the VPS returns:

```bash
test "$(uname -r)" = 6.8.12-zksu
systemctl is-active redroid14.service redroid14-watchdog.service

adb connect 127.0.0.1:5555
adb -s 127.0.0.1:5555 wait-for-device
test "$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed | tr -d '\r')" = 1
```

### 12.7 Verify Play Services and Play Store

```bash
for package in \
  com.google.android.gsf \
  com.google.android.gms \
  com.android.vending
do
  echo "Checking $package"
  adb -s 127.0.0.1:5555 shell pm path "$package" | grep -q '^package:'
done

adb -s 127.0.0.1:5555 shell dumpsys package com.android.vending | \
  grep -m1 versionName

sudo docker exec redroid14-ksu /data/adb/ksud module list | \
  grep -i litegapps

sudo /usr/local/sbin/validate-redroid14
```

Launch Play Store:

```bash
adb -s 127.0.0.1:5555 shell monkey \
  -p com.android.vending \
  -c android.intent.category.LAUNCHER 1
```

Use `scrcpy` to complete Google sign-in inside the Android UI. Never paste a
Google password into an ADB command, shell history, setup script, or log file.

After Google Play Services has settled, check for repeated crashes:

```bash
adb -s 127.0.0.1:5555 shell logcat -d | \
  grep -iE 'FATAL EXCEPTION|com\.google\.android\.gms|com\.android\.vending' | \
  tail -200

sudo docker stats --no-stream redroid14-ksu
```

A few startup messages are normal. Repeated process deaths, `FATAL EXCEPTION`,
or a rapidly rising PID count are not; disable the module rather than allowing
a restart storm.

Run another ten-minute stability gate because GMS adds background services:

```bash
sudo systemd-run \
  --unit=redroid14-gapps-stability-check \
  --collect \
  --property=Type=exec \
  /usr/local/sbin/monitor-redroid14-10m

sudo journalctl -fu redroid14-gapps-stability-check
```

### 12.8 Play Protect certification is separate

In Play Store, open **Profile → Settings → About → Play Protect certification**.
Google explains that rooted or modified Android systems may remain uncertified,
and that uncertified devices or apps may not function correctly. Installing
GApps does not certify ReDroid and does not guarantee Play Integrity.

References:

- [Google: check and fix Play Protect certification](https://support.google.com/android/answer/7165974)
- [Google: uncertified/custom-ROM device registration](https://www.google.com/android/uncertified/)

If registration is offered, submit the **Google Services Framework ID** shown
by a trusted device-ID tool—not the ordinary Android Settings ID. The ID can be
read directly from GSF's `gservices.db`; no third-party Android application is
needed.

The Android-side `/bin/sqlite3` included in this ReDroid image can abort while
opening this database. Copy the database to Ubuntu and use the host SQLite
implementation instead:

```bash
sudo apt-get update
sudo apt-get install -y sqlite3

GSF_TMP_DIR=$(mktemp -d)
trap 'sudo rm -rf "$GSF_TMP_DIR"' EXIT

sudo docker cp \
  redroid14-ksu:/data/data/com.google.android.gsf/databases/gservices.db \
  "$GSF_TMP_DIR/gservices.db"

GSF_DECIMAL=$(sudo sqlite3 -readonly "$GSF_TMP_DIR/gservices.db" \
  "SELECT value FROM main WHERE name='android_id';")

case "$GSF_DECIMAL" in
  ''|*[!0-9]*)
    echo "GSF Android ID was not generated or is invalid" >&2
    exit 1
    ;;
esac

GSF_HEX=$(printf '%016x' "$GSF_DECIMAL")
printf 'GSF Android ID (decimal): %s\n' "$GSF_DECIMAL"
printf 'GSF Android ID (hex):     %s\n' "$GSF_HEX"

sudo rm -rf "$GSF_TMP_DIR"
trap - EXIT
```

Submit the 16-character hexadecimal value printed as `GSF_HEX` at
[Google's uncertified-device registration portal](https://www.google.com/android/uncertified/).
Do not submit `Settings.Secure.ANDROID_ID`; that is a different identifier.
After registration, wait several minutes and perform a host reboot:

```bash
sudo reboot
```

Do not clear Google Services Framework storage, replace the persistent
`/home/ubuntu/redroid14-data` directory, or regenerate Android data after
registering. Those operations can create a different GSF ID, making the
registered value stale. Registration can take time and is not a promise that a
rooted cloud instance will become certified or pass Play Integrity.

### 12.9 Disable LiteGapps if Android becomes unstable

Because this installation is systemless, the recovery path does not modify the
base Docker image. If Android boot-loops while the VPS remains reachable:

```bash
sudo systemctl stop redroid14-watchdog.service redroid14.service

for module_dir in \
  /home/ubuntu/redroid14-data/adb/modules/litegapps \
  /home/ubuntu/redroid14-data/adb/modules_update/litegapps
do
  if sudo test -d "$module_dir"; then
    sudo touch "$module_dir/disable"
  fi
done

sudo reboot
```

After recovery, inspect LiteGapps and Android logs before deleting module data.
The [LiteGapps removal instructions](https://litegapps.github.io/doc/uninstall.html)
also warn that Google application updates should be removed before uninstalling
the systemless module, otherwise Google apps can force-close or boot-loop.

---

## Script reference

| File | Use in this guide |
|---|---|
| [`install_kernel_v2.sh`](vps/install_kernel_v2.sh) | Validates and installs the prebuilt kernel packages. |
| [`deploy_redroid14_v2.sh`](vps/deploy_redroid14_v2.sh) | Creates the bounded ReDroid container and stages root assets. |
| [`redroid14_watchdog_v2.sh`](vps/redroid14_watchdog_v2.sh) | Stops the container when host safety thresholds are crossed. |
| [`validate_redroid14.sh`](vps/validate_redroid14.sh) | Performs the final end-to-end validation. |
| [`monitor_redroid14_10m.sh`](vps/monitor_redroid14_10m.sh) | Runs the ten-minute stability gate. |
| [`dev-binderfs.mount`](vps/dev-binderfs.mount) | Mounts BinderFS on every boot. |
| [`binder-bindmounts.service`](vps/binder-bindmounts.service) | Exposes the Binder nodes at the paths ReDroid expects. |
| [`redroid-binder-permissions.service`](vps/redroid-binder-permissions.service) | Applies Binder permissions before Docker starts. |
| [`redroid14.service`](vps/redroid14.service) | Starts the existing ReDroid container safely after boot. |
| [`redroid14-watchdog.service`](vps/redroid14-watchdog.service) | Runs the watchdog under systemd. |
| [`redroid14-validate.service`](vps/redroid14-validate.service) | Runs the validator after ReDroid boots. |

The following are rebuild-only tools and are intentionally excluded from the
fast path:

| File | Purpose |
|---|---|
| [`prepare_kernel_v2.sh`](vps/prepare_kernel_v2.sh) | Prepares an already-populated kernel source tree for a controlled rebuild. |
| [`build_kernel_v2.sh`](vps/build_kernel_v2.sh) | Builds and packages the pinned custom kernel. |
| [`kernelsu-arm64-cacheflush.patch`](vps/patches/kernelsu-arm64-cacheflush.patch) | Fixes the Linux 6.8 ARM64 cache-flush invocation. |
| [`kernelsu-selinux-unavailable.patch`](vps/patches/kernelsu-selinux-unavailable.patch) | Guards KernelSU when the host SELinux policy is unavailable. |

Those rebuild scripts are not a fresh-server bootstrap: they expect the kernel
source, `.config`, pinned KernelSU-Next checkout, and patches to already exist
under `/home/ubuntu/kbuild`. Use the rebuild chapters in
[`my_setup_journey.md`](my_setup_journey.md) instead of running them blindly.

## Recovery commands

### ReDroid fails but SSH still works

```bash
sudo systemctl disable --now \
  redroid14-validate.service \
  redroid14-watchdog.service \
  redroid14.service

sudo docker stop -t 20 redroid14-ksu || true
sudo journalctl -b -p warning --no-pager
```

This does not delete the container or Android data.

### Boot the stock kernel once

List the exact GRUB entries, select the stock Ubuntu kernel entry, and schedule
only the next boot:

```bash
sudo grep -E "^submenu |^menuentry " /boot/grub/grub.cfg
STOCK_ENTRY='PASTE THE EXACT STOCK KERNEL ENTRY HERE'
sudo grub-reboot "$STOCK_ENTRY"
sudo grub-editenv list
sudo reboot
```

Do not uninstall the custom or stock kernel during troubleshooting. Confirm a
known-good boot first.

## Do not

- Do not rebuild the kernel when the verified prebuilt packages meet the target.
- Do not run `prepare_kernel_v2.sh` on a fresh host; it is a rebuild-stage tool.
- Do not use all host CPU/RAM for an unbounded kernel build or container.
- Do not set the custom kernel as the permanent GRUB default before validation.
- Do not forget the second one-shot `grub-reboot` before module activation.
- Do not expose ADB `5555` to the internet; tunnel it through SSH.
- Do not create another ad-hoc privileged container. The supplied deployment
  already uses `--privileged` together with strict CPU, memory, PID, restart,
  logging, Binder, ADB, and `/dev/kmsg` controls.
- Do not enable Docker's `always` restart policy; systemd and the watchdog own recovery.
- Do not map the host's real `/dev/kmsg` into ReDroid.
- Do not delete an existing container or data directory merely because deployment refuses it.
- Do not remove the stock Ubuntu kernel; it is the rollback path.
- Do not republish bundled third-party binaries without checking their licenses.
- Do not install LiteGapps over an image that already contains GApps.
- Do not use an ARM, x86, or non-Android-14 GApps package on this ARM64/API-34 image.
- Do not install a system-changing KernelSU module without an active metamodule.
- Do not ignore `No space left on device` from LiteGapps merely because its
  installer later prints success; enlarge ReDroid's `/dev` tmpfs and reinstall.
- Do not assume Play Store presence means Play Protect certification or Play Integrity.
- Do not use `adb reboot` or `docker restart` to activate a new KernelSU module here.
