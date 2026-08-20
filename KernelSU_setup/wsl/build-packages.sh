#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
ARTIFACT_DIR="$BUILD_ROOT/artifacts"
PACKAGE_DIR="$ARTIFACT_DIR/packages-zksu-multi"
LOG_DIR="$ARTIFACT_DIR/logs"
LOG_FILE="$LOG_DIR/build-zksu-multi-$(date -u +%Y%m%dT%H%M%SZ).log"
JOBS=${JOBS:-8}
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}

test "$(id -un)" = builder
test -f "$SOURCE_DIR/.config"
test "$(make -s -C "$SOURCE_DIR" ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  kernelrelease LOCALVERSION=-zksu-multi)" = 6.8.12-zksu-multi

mkdir -p "$PACKAGE_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "started=$(date -Is)"
echo "jobs=$JOBS"
echo "toolchain=$(aarch64-linux-gnu-gcc -dumpfullversion)"
echo "kernelsu=$(git -C "$SOURCE_DIR/KernelSU-Next" rev-parse HEAD)"

cd "$SOURCE_DIR"
/usr/bin/time -v make -j"$JOBS" \
  ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_DEBARCH=arm64 \
  bindeb-pkg LOCALVERSION=-zksu-multi

# Collect only the revision this run produced. `bindeb-pkg` leaves every previous
# revision in BUILD_ROOT, so a glob on the release string alone matches all of
# them and the "exactly one" assertion below fails on the second build. Take the
# version from debian/changelog, which is the value dpkg-deb itself used.
PACKAGE_VERSION=$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$SOURCE_DIR/debian/changelog")
test -n "$PACKAGE_VERSION"
echo "package_version=$PACKAGE_VERSION"

find "$PACKAGE_DIR" -maxdepth 1 -type f -delete
find "$BUILD_ROOT" -maxdepth 1 -type f \
  -name "*6.8.12-zksu-multi_${PACKAGE_VERSION}_arm64.deb" \
  -exec cp -a -t "$PACKAGE_DIR" -- {} +

cd "$PACKAGE_DIR"
mapfile -t images < <(find . -maxdepth 1 -type f \
  -name "linux-image-6.8.12-zksu-multi_${PACKAGE_VERSION}_arm64.deb" | sort)
mapfile -t headers < <(find . -maxdepth 1 -type f \
  -name "linux-headers-6.8.12-zksu-multi_${PACKAGE_VERSION}_arm64.deb" | sort)
test "${#images[@]}" -eq 1
test "${#headers[@]}" -eq 1

for package in "${images[@]}" "${headers[@]}"; do
  test "$(dpkg-deb -f "$package" Architecture)" = arm64
  dpkg-deb -f "$package" Package Version Architecture
done

sha256sum -- *.deb > SHA256SUMS
sha256sum -c SHA256SUMS

test -d "$REPO_WSL/KernelSU_setup/artifacts/kernel-build"
mkdir -p \
  "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/packages-zksu-multi" \
  "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/logs"
# The repository is an NTFS drvfs mount that rejects utimensat, chmod, and chown,
# so archive-mode copies and `install -m` both fail there even though the data
# transfers fine. Write contents only and let the mount supply all metadata.
REPO_PACKAGES="$REPO_WSL/KernelSU_setup/artifacts/kernel-build/packages-zksu-multi"
find "$REPO_PACKAGES" -maxdepth 1 -type f -delete
for artifact in "$PACKAGE_DIR"/*; do
  cat "$artifact" > "$REPO_PACKAGES/$(basename "$artifact")"
done
cat "$BUILD_ROOT/kernelsu-redroid-multi-instance.patch" \
  > "$REPO_WSL/KernelSU_setup/vps/patches/kernelsu-redroid-multi-instance.patch"
cat "$SOURCE_DIR/.config" \
  > "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/config/config.zksu-multi"
cat "$LOG_FILE" \
  > "$REPO_WSL/KernelSU_setup/artifacts/kernel-build/logs/$(basename "$LOG_FILE")"

echo "completed=$(date -Is)"
du -sh "$SOURCE_DIR" "$PACKAGE_DIR"
echo ARM64_PACKAGES_VERIFIED
