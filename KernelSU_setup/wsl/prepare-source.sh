#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
INPUTS="$BUILD_ROOT/project-inputs"
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}
KSU_COMMIT=d6a42fd9285c11b8e8e67bfe72a5050528006c00

test "$(id -un)" = builder
test ! -e "$SOURCE_DIR"
mkdir -p "$BUILD_ROOT" "$INPUTS"

git clone --depth 1 --branch v6.8.12 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
  "$SOURCE_DIR"
git clone https://github.com/KernelSU-Next/KernelSU-Next.git \
  "$SOURCE_DIR/KernelSU-Next"
git -C "$SOURCE_DIR/KernelSU-Next" checkout "$KSU_COMMIT"

test "$(make -s -C "$SOURCE_DIR" kernelversion)" = 6.8.12
test "$(git -C "$SOURCE_DIR/KernelSU-Next" rev-parse HEAD)" = "$KSU_COMMIT"

ln -s ../KernelSU-Next/kernel "$SOURCE_DIR/drivers/kernelsu"
printf '%s\n' '' 'obj-$(CONFIG_KSU) += kernelsu/' >> "$SOURCE_DIR/drivers/Makefile"
sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' \
  "$SOURCE_DIR/drivers/Kconfig"

cp -a \
  "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/config/config.completed" \
  "$INPUTS/"
cp -a \
  "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/patches/kernelsu-linux-6.8.patch" \
  "$INPUTS/"
cp -a \
  "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-arm64-cacheflush.patch" \
  "$INPUTS/"
cp -a \
  "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-selinux-unavailable.patch" \
  "$INPUTS/"
cp -a \
  "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-mainline-6.8-security-api.patch" \
  "$INPUTS/"
cp -a \
  "$REPO_WSL/KernelSU_setup/vps/patches/linux-mainline-6.8-binder-modules.patch" \
  "$INPUTS/"
cp -a \
  "$REPO_WSL/KernelSU_setup/vps/patches/linux-mainline-6.8-binder-exports.patch" \
  "$INPUTS/"

# Binder must be built as the loadable composite binder_linux module, exactly as
# the deleted Ubuntu linux-upstream tree did. The module-layout patch converts
# the driver; the exports patch widens the eleven core-kernel symbols that
# binder_linux.ko imports. Apply layout first, then exports.
for patch in \
  "$INPUTS/linux-mainline-6.8-binder-modules.patch" \
  "$INPUTS/linux-mainline-6.8-binder-exports.patch"
do
  git -C "$SOURCE_DIR" apply --check "$patch"
  git -C "$SOURCE_DIR" apply "$patch"
done

git -C "$SOURCE_DIR" diff --check

for patch in \
  "$INPUTS/kernelsu-linux-6.8.patch" \
  "$INPUTS/kernelsu-arm64-cacheflush.patch" \
  "$INPUTS/kernelsu-selinux-unavailable.patch"
do
  git -C "$SOURCE_DIR/KernelSU-Next" apply --check "$patch"
  git -C "$SOURCE_DIR/KernelSU-Next" apply "$patch"
done

# The archived broad patch targeted the Ubuntu linux-upstream tree, whose LSM
# secctx API had a newer backport. The reconstructed vanilla v6.8.12 source uses
# the three-argument API; restore that exact call shape after the broad patch.
git -C "$SOURCE_DIR/KernelSU-Next" apply --check \
  "$INPUTS/kernelsu-mainline-6.8-security-api.patch"
git -C "$SOURCE_DIR/KernelSU-Next" apply \
  "$INPUTS/kernelsu-mainline-6.8-security-api.patch"

git -C "$SOURCE_DIR/KernelSU-Next" diff --check
git -C "$SOURCE_DIR/KernelSU-Next" diff > "$INPUTS/compatibility-baseline.diff"

printf 'linux=%s\nkernelsu=%s\n' \
  "$(make -s -C "$SOURCE_DIR" kernelversion)" \
  "$(git -C "$SOURCE_DIR/KernelSU-Next" rev-parse HEAD)"
du -sh "$SOURCE_DIR"
echo SOURCE_AND_COMPATIBILITY_PATCHES_READY
