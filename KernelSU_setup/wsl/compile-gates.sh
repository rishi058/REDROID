#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
INPUTS="$BUILD_ROOT/project-inputs"
LOG_DIR="$BUILD_ROOT/artifacts/logs"
LOG_FILE="$LOG_DIR/compile-gates-$(date -u +%Y%m%dT%H%M%SZ).log"
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}
SCRIPTS="$REPO_WSL/KernelSU_setup/wsl"

# This script starts with `make clean`. Never run it against an object tree you
# still need; use it before a build, not to re-check one in progress.
test "$(id -un)" = builder
test -x "$SOURCE_DIR/scripts/config"
test "$(git -C "$SOURCE_DIR/KernelSU-Next" rev-parse HEAD)" = \
  d6a42fd9285c11b8e8e67bfe72a5050528006c00

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

cd "$SOURCE_DIR"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean
rm -f KernelSU-Next/kernel/built-in.a
cp "$INPUTS/config.completed" .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

required=(
  CONFIG_KSU=y
  CONFIG_KPROBES=y
  CONFIG_EXT4_FS=y
  CONFIG_OVERLAY_FS=y
  CONFIG_ANDROID_BINDER_IPC=m
  CONFIG_ANDROID_BINDERFS=m
  CONFIG_NAMESPACES=y
  CONFIG_PID_NS=y
  CONFIG_NET_NS=y
  CONFIG_CGROUPS=y
  CONFIG_SECCOMP=y
)
for option in "${required[@]}"; do
  grep -qx "$option" .config || {
    echo "Missing required option: $option" >&2
    exit 1
  }
done

release=$(make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  kernelrelease LOCALVERSION=-zksu-multi)
test "$release" = 6.8.12-zksu-multi
echo "release=$release"

make -j1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- prepare
make -j1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- security/selinux/
make -j1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/kernelsu/

# Binder is the other patched subsystem. The original gates skipped it, so a
# plain compile error inside drivers/android/ was only found after 11:28 of
# full-build compiling. One minute here replaces that.
make -j1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/android/
test -f drivers/android/binder_linux.o

# Compiling binder_linux proves nothing about the two defects that matter for a
# module: unresolved imports and a missing init function. Unresolved imports need
# modpost, which needs a linked vmlinux.o, so that gate belongs to the full build
# in build-packages.sh. A missing init function, on the other hand, is a pure
# source property, and device_initcall produces a valid .ko with no diagnostic at
# all. Check it statically here, for free, instead of after a reboot.
bash "$SCRIPTS/verify-binder-edits.sh"

git -C KernelSU-Next diff --check
cp .config "$BUILD_ROOT/artifacts/config.zksu-multi"
echo COMPILE_GATES_PASSED
