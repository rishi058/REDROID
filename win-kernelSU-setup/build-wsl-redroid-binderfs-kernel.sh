#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/wsl-redroid-binderfs}
JOBS=${JOBS:-6}
WSL_BRANCH=${WSL_BRANCH:-linux-msft-wsl-5.15.y}
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}
SOURCE_DIR="$BUILD_ROOT/WSL2-Linux-Kernel"
CONFIG_FILE="$SOURCE_DIR/Microsoft/config-wsl"
EXPORT_DIR="$REPO_WSL/local-setup/kernels"

mkdir -p "$BUILD_ROOT"

if [ ! -d "$SOURCE_DIR/.git" ]; then
  git clone --depth 1 --branch "$WSL_BRANCH" \
    https://github.com/microsoft/WSL2-Linux-Kernel.git \
    "$SOURCE_DIR"
fi

cd "$SOURCE_DIR"
git reset --hard HEAD
rm -rf KernelSU-Next drivers/kernelsu

test -f "$CONFIG_FILE"
scripts/config --file "$CONFIG_FILE" \
  --enable ANDROID \
  --enable ANDROID_BINDER_IPC \
  --enable ANDROID_BINDERFS \
  --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder" \
  --enable OVERLAY_FS \
  --enable PSI \
  --enable MEMCG \
  --enable CGROUPS

if grep -q '^config ASHMEM' drivers/staging/android/Kconfig 2>/dev/null; then
  scripts/config --file "$CONFIG_FILE" --enable ASHMEM
fi

make KCONFIG_CONFIG=Microsoft/config-wsl olddefconfig
grep -E 'CONFIG_ANDROID_BINDER|CONFIG_ANDROID_BINDERFS|CONFIG_ANDROID_BINDER_DEVICES|CONFIG_OVERLAY_FS|CONFIG_PSI' "$CONFIG_FILE"

make -j"$JOBS" KCONFIG_CONFIG=Microsoft/config-wsl LOCALVERSION=-redroid-binderfs

kernel_release=$(make -s KCONFIG_CONFIG=Microsoft/config-wsl kernelrelease LOCALVERSION=-redroid-binderfs)
mkdir -p "$EXPORT_DIR"
cp -f arch/x86/boot/bzImage "$EXPORT_DIR/bzImage-$kernel_release"
cat > "$EXPORT_DIR/latest-wsl-kernel.env" <<EOF
kernel_release=$kernel_release
wsl_kernel_linux_path=$EXPORT_DIR/bzImage-$kernel_release
wsl_kernel_windows_path=D:\\PROJECT\\_TRASH\\REDROID\\local-setup\\kernels\\bzImage-$kernel_release
EOF

echo "WSL_KERNEL_READY=$EXPORT_DIR/bzImage-$kernel_release"