#!/usr/bin/env bash
set -Eeuo pipefail

KBUILD_ROOT=/home/ubuntu/kbuild
SOURCE_DIR="$KBUILD_ROOT/linux-6.8.0"
ARTIFACT_DIR="$KBUILD_ROOT/artifacts"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

test "$(id -un)" = ubuntu
test -d "$SOURCE_DIR"
test -x "$SOURCE_DIR/scripts/config"
test -d "$SOURCE_DIR/KernelSU-Next/.git"

mkdir -p "$ARTIFACT_DIR/config" "$ARTIFACT_DIR/patches" "$ARTIFACT_DIR/logs" "$ARTIFACT_DIR/packages"
cd "$SOURCE_DIR"

cp -a .config "$ARTIFACT_DIR/config/config.before-clean.$STAMP"
git -C KernelSU-Next rev-parse HEAD | tee "$ARTIFACT_DIR/config/kernelsu-commit.txt"
git -C KernelSU-Next diff -- kernel/hook/lsm_hook.c kernel/selinux/selinux.c kernel/selinux/sepolicy.c \
  > "$ARTIFACT_DIR/patches/kernelsu-linux-6.8.patch"
head -n 1 debian/changelog > "$ARTIFACT_DIR/config/kernel-source-version.txt"

# The prior crash storm filled these two rsyslog files. The final diagnostic tail
# was captured before cleanup, and the offending container has been removed.
sudo truncate -s 0 /var/log/syslog /var/log/syslog.1

# Config changes were made after the old build, so an incremental resume would
# retain multi-gigabyte stale objects. Preserve .config above, then clean.
make clean
rm -f KernelSU-Next/kernel/built-in.a

./scripts/config --disable DEBUG_INFO
./scripts/config --enable DEBUG_INFO_NONE
./scripts/config --disable DEBUG_INFO_DWARF5
./scripts/config --disable DEBUG_INFO_BTF
./scripts/config --disable GDB_SCRIPTS
./scripts/config --disable DRM_AMDGPU
./scripts/config --disable DRM_NOUVEAU
./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
./scripts/config --enable KPROBES
./scripts/config --enable EXT4_FS
./scripts/config --enable OVERLAY_FS
./scripts/config --enable KSU
./scripts/config --module ANDROID_BINDER_IPC
./scripts/config --module ANDROID_BINDERFS
make olddefconfig

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
)
for option in "${required[@]}"; do
  grep -qx "$option" .config || { echo "Required option missing: $option" >&2; exit 30; }
done

for disabled in CONFIG_DEBUG_INFO CONFIG_DEBUG_INFO_BTF CONFIG_GDB_SCRIPTS CONFIG_DRM_AMDGPU CONFIG_DRM_NOUVEAU; do
  state=$(./scripts/config --state "${disabled#CONFIG_}")
  case "$state" in
    n|undef) ;;
    *) echo "Option is not disabled: $disabled ($state)" >&2; exit 31 ;;
  esac
done

cp -a .config "$ARTIFACT_DIR/config/config.build.$STAMP"

# Restore the configured swap target already declared in /etc/fstab.
if ! swapon --noheadings --show=NAME | grep -qx /swapfile; then
  if ! sudo test -f /swapfile; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
  fi
  sudo swapon /swapfile
fi

# Compile KernelSU first so compatibility failures occur before the full build.
nice -n 10 ionice -c 3 make -j1 prepare
nice -n 10 ionice -c 3 make -j1 security/selinux/
nice -n 10 ionice -c 3 make -j1 drivers/kernelsu/

echo "kernelrelease=$(make -s kernelrelease LOCALVERSION=-zksu)"
df -hT / /boot
free -h
swapon --show
