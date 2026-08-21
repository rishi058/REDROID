#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/wsl-kernelsu-redroid}
JOBS=${JOBS:-6}
WSL_BRANCH=${WSL_BRANCH:-linux-msft-wsl-5.15.y}
KSU_SOURCE=${KSU_SOURCE:-}
KSU_APPLY_REPO_PATCHES=${KSU_APPLY_REPO_PATCHES:-auto}
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}
SOURCE_DIR="$BUILD_ROOT/WSL2-Linux-Kernel"
KSU_DIR="$SOURCE_DIR/KernelSU-Next"
CONFIG_FILE="$SOURCE_DIR/Microsoft/config-wsl"
EXPORT_DIR="$REPO_WSL/local-setup/kernels"

mkdir -p "$BUILD_ROOT"

if [ -z "$KSU_SOURCE" ]; then
  cat >&2 <<'EOF'
KSU_SOURCE is required and must point to a local KernelSU-compatible source tree.
This script intentionally does not clone KernelSU from the internet.

The current repo docs describe the multi-instance implementation as a patch
against KernelSU's kernel/ tree, not a complete from-scratch replacement. Vendor
or place the source locally, then rerun, for example:

  KSU_SOURCE=/home/builder/src/KernelSU-Next \
  bash /mnt/d/PROJECT/_TRASH/REDROID/local-setup/build-wsl-kernelsu-redroid-kernel.sh
EOF
  exit 2
fi

if [ ! -d "$SOURCE_DIR/.git" ]; then
  git clone --depth 1 --branch "$WSL_BRANCH" \
    https://github.com/microsoft/WSL2-Linux-Kernel.git \
    "$SOURCE_DIR"
fi

test -d "$KSU_SOURCE/kernel"
test -f "$KSU_SOURCE/kernel/runtime/ksud_integration.c"
rm -rf "$KSU_DIR"
cp -a "$KSU_SOURCE" "$KSU_DIR"

# KernelSU's Kbuild derives its version from `git rev-list --count HEAD`
# (kernel version = 30000 + count). If git refuses the tree ("dubious ownership",
# owned by builder while the build runs as root), the version falls back to 1 and
# modules like Zygisk Next reject the kernel as "too old". Mark the trees safe so
# the real version is detected.
git config --global --add safe.directory "$KSU_DIR" 2>/dev/null || true
git config --global --add safe.directory "$KSU_SOURCE" 2>/dev/null || true
git config --global --add safe.directory '*' 2>/dev/null || true
if ! grep -q '#include <linux/init.h>' "$KSU_DIR/kernel/feature/sulog.h"; then
  sed -i '/#include <linux\/types.h>/a #include <linux/init.h>' \
    "$KSU_DIR/kernel/feature/sulog.h"
fi
python3 - <<'PY' "$KSU_DIR/kernel/manager/pkg_observer.c"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 0, 0)\n\tg = fsnotify_alloc_group(&ksu_ops, 0);\n#else\n\tg = fsnotify_alloc_group(&ksu_ops);\n#endif\n"""
new = "\tg = fsnotify_alloc_group(&ksu_ops, 0);\n"
if old in text:
    path.write_text(text.replace(old, new, 1))
PY

case "$KSU_APPLY_REPO_PATCHES" in
  yes)
    for patch in \
      "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/patches/kernelsu-linux-6.8.patch" \
      "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-selinux-unavailable.patch" \
      "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-mainline-6.8-security-api.patch" \
      "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-redroid-multi-instance.patch"
    do
      git -C "$KSU_DIR" apply --check "$patch"
      git -C "$KSU_DIR" apply "$patch"
    done
    ;;
  auto)
    if ! grep -q 'KSU_MAX_ANDROID_INSTANCES' "$KSU_DIR/kernel/runtime/ksud_integration.c"; then
      git -C "$KSU_DIR" apply --check "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-redroid-multi-instance.patch"
      git -C "$KSU_DIR" apply "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-redroid-multi-instance.patch"
    fi
    ;;
  no)
    ;;
  *)
    echo "KSU_APPLY_REPO_PATCHES must be auto, yes, or no" >&2
    exit 2
    ;;
esac

grep -q 'KSU_MAX_ANDROID_INSTANCES' "$KSU_DIR/kernel/runtime/ksud_integration.c"

if [ ! -e "$SOURCE_DIR/drivers/kernelsu" ]; then
  ln -s ../KernelSU-Next/kernel "$SOURCE_DIR/drivers/kernelsu"
fi
if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$SOURCE_DIR/drivers/Makefile"; then
  printf '%s\n' '' 'obj-$(CONFIG_KSU) += kernelsu/' >> "$SOURCE_DIR/drivers/Makefile"
fi
if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$SOURCE_DIR/drivers/Kconfig"; then
  sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$SOURCE_DIR/drivers/Kconfig"
fi

test -f "$CONFIG_FILE"
cd "$SOURCE_DIR"

scripts/config --file "$CONFIG_FILE" \
  --enable ANDROID \
  --enable ANDROID_BINDER_IPC \
  --enable ANDROID_BINDERFS \
  --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder" \
  --enable KSU \
  --enable OVERLAY_FS \
  --enable PSI \
  --enable MEMCG \
  --enable CGROUPS \
  --enable SECURITY_NETWORK \
  --enable SECURITY_SELINUX \
  --enable SECURITY_SELINUX_DEVELOP \
  --set-val SECURITY_SELINUX_SIDTAB_HASH_BITS 9 \
  --set-val SECURITY_SELINUX_SID2STR_CACHE_SIZE 256 \
  --enable KSU_X86_PATCH_SYSCALL_DISPATCHER \
  --enable KALLSYMS \
  --enable KALLSYMS_ALL

if grep -q '^config ASHMEM' drivers/staging/android/Kconfig 2>/dev/null; then
  scripts/config --file "$CONFIG_FILE" --enable ASHMEM
fi

# Optional verbose KernelSU boot logging for diagnosing hook activation.
if [ "${KSU_DEBUG:-0}" = "1" ]; then
  scripts/config --file "$CONFIG_FILE" --enable KSU_DEBUG
fi

make KCONFIG_CONFIG=Microsoft/config-wsl olddefconfig
gcc \
  -Iinclude/uapi -Iinclude -Isecurity/selinux/include \
  scripts/selinux/genheaders/genheaders.c \
  -o scripts/selinux/genheaders/genheaders
scripts/selinux/genheaders/genheaders \
  security/selinux/flask.h \
  security/selinux/av_permissions.h
grep -E 'CONFIG_ANDROID_BINDER|CONFIG_ANDROID_BINDERFS|CONFIG_ANDROID_BINDER_DEVICES|CONFIG_KSU|CONFIG_SECURITY_SELINUX|CONFIG_OVERLAY_FS|CONFIG_PSI' "$CONFIG_FILE"

make -j"$JOBS" KCONFIG_CONFIG=Microsoft/config-wsl LOCALVERSION=-redroid-ksu

kernel_release=$(make -s KCONFIG_CONFIG=Microsoft/config-wsl kernelrelease LOCALVERSION=-redroid-ksu)
mkdir -p "$EXPORT_DIR"
cp -f arch/x86/boot/bzImage "$EXPORT_DIR/bzImage-$kernel_release"
cat > "$EXPORT_DIR/latest-wsl-kernel.env" <<EOF
kernel_release=$kernel_release
wsl_kernel_linux_path=$EXPORT_DIR/bzImage-$kernel_release
wsl_kernel_windows_path=D:\\PROJECT\\_TRASH\\REDROID\\local-setup\\kernels\\bzImage-$kernel_release
EOF

echo "WSL_KERNEL_READY=$EXPORT_DIR/bzImage-$kernel_release"