#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
ARTIFACT_DIR="$BUILD_ROOT/artifacts"
PACKAGE_DIR="$ARTIFACT_DIR/packages-zksu-build"
LOG_DIR="$ARTIFACT_DIR/logs"
LOG_FILE="$LOG_DIR/build-zksu-v2-$(date -u +%Y%m%dT%H%M%SZ).log"
JOBS=${JOBS:-8}
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}
LOCAL_VER="-zksu-v2"

test "$(id -un)" = builder

cd "$SOURCE_DIR"

echo "=== Cleaning build artifacts and stale vmlinux ==="
rm -rf debian
rm -f vmlinux vmlinux.o .vmlinux* System.map kernel/kheaders_data.tar.xz kernel/kheaders.o

echo "=== Restoring .config from project-inputs ==="
cp -f "$BUILD_ROOT/project-inputs/config.completed" .config

echo "=== Disabling CONFIG_IKHEADERS ==="
./scripts/config --disable CONFIG_IKHEADERS
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

mkdir -p "$PACKAGE_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "started=$(date -Is)"
echo "jobs=$JOBS"
echo "toolchain=$(aarch64-linux-gnu-gcc -dumpfullversion)"

/usr/bin/time -v make -j"$JOBS" \
  ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  KBUILD_DEBARCH=arm64 \
  bindeb-pkg LOCALVERSION="$LOCAL_VER"

PACKAGE_VERSION=$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$SOURCE_DIR/debian/changelog")
test -n "$PACKAGE_VERSION"
echo "package_version=$PACKAGE_VERSION"

find "$PACKAGE_DIR" -maxdepth 1 -type f -delete
find "$BUILD_ROOT" -maxdepth 1 -type f \
  -name "*${LOCAL_VER}_${PACKAGE_VERSION}_arm64.deb" \
  -exec cp -a -t "$PACKAGE_DIR" -- {} +

cd "$PACKAGE_DIR"
mapfile -t images < <(find . -maxdepth 1 -type f \
  -name "linux-image-6.8.12${LOCAL_VER}_${PACKAGE_VERSION}_arm64.deb" | sort)
mapfile -t headers < <(find . -maxdepth 1 -type f \
  -name "linux-headers-6.8.12${LOCAL_VER}_${PACKAGE_VERSION}_arm64.deb" | sort)
test "${#images[@]}" -eq 1
test "${#headers[@]}" -eq 1

for package in "${images[@]}" "${headers[@]}"; do
  test "$(dpkg-deb -f "$package" Architecture)" = arm64
  dpkg-deb -f "$package" Package Version Architecture
done

sha256sum -- *.deb > SHA256SUMS
sha256sum -c SHA256SUMS

REPO_PACKAGES="$REPO_WSL/KernelSU_setup/artifacts/kernel-build/packages-zksu-new"
mkdir -p "$REPO_PACKAGES"
find "$REPO_PACKAGES" -maxdepth 1 -type f -delete

for artifact in "$PACKAGE_DIR"/*; do
  echo "Writing $(basename "$artifact") to $REPO_PACKAGES..."
  cat "$artifact" > "$REPO_PACKAGES/$(basename "$artifact")"
done

echo "completed=$(date -Is)"
du -sh "$SOURCE_DIR" "$PACKAGE_DIR" "$REPO_PACKAGES"
echo ARM64_PACKAGES_VERIFIED
