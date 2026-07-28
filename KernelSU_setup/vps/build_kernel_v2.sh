#!/usr/bin/env bash
set -Eeuo pipefail

KBUILD_ROOT=/home/ubuntu/kbuild
SOURCE_DIR="$KBUILD_ROOT/linux-6.8.0"
ARTIFACT_DIR="$KBUILD_ROOT/artifacts"
LOG_FILE="$ARTIFACT_DIR/logs/build-$(date -u +%Y%m%dT%H%M%SZ).log"
LOCK_FILE="$KBUILD_ROOT/.kernel-build.lock"
JOBS=${JOBS:-2}

mkdir -p "$ARTIFACT_DIR/logs" "$ARTIFACT_DIR/packages"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another kernel build owns $LOCK_FILE" >&2; exit 40; }
exec > >(tee -a "$LOG_FILE") 2>&1

echo "started=$(date -Is)"
echo "host=$(hostname)"
echo "jobs=$JOBS"
echo "commit=$(git -C "$SOURCE_DIR/KernelSU-Next" rev-parse HEAD)"
echo "kernelrelease=$(make -s -C "$SOURCE_DIR" kernelrelease LOCALVERSION=-zksu)"

test "$(git -C "$SOURCE_DIR/KernelSU-Next" rev-parse HEAD)" = d6a42fd9285c11b8e8e67bfe72a5050528006c00
grep -qx 'CONFIG_DEBUG_INFO_NONE=y' "$SOURCE_DIR/.config"
grep -qx 'CONFIG_KSU=y' "$SOURCE_DIR/.config"
grep -qx 'CONFIG_ANDROID_BINDER_IPC=m' "$SOURCE_DIR/.config"

available_kib=$(df --output=avail / | tail -n 1 | tr -d ' ')
if (( available_kib < 15 * 1024 * 1024 )); then
  echo "At least 15 GiB free on / is required; available KiB: $available_kib" >&2
  exit 41
fi

cd "$SOURCE_DIR"
/usr/bin/time -v ionice -c 2 -n 4 make -j"$JOBS" bindeb-pkg LOCALVERSION=-zksu

find "$ARTIFACT_DIR/packages" -maxdepth 1 -type f -name '*zksu*.deb' -delete
find "$KBUILD_ROOT" -maxdepth 1 -type f -name '*zksu*.deb' -exec cp -a -t "$ARTIFACT_DIR/packages" -- {} +

compgen -G "$ARTIFACT_DIR/packages/linux-image-*zksu*.deb" >/dev/null
compgen -G "$ARTIFACT_DIR/packages/linux-headers-*zksu*.deb" >/dev/null
(cd "$ARTIFACT_DIR/packages" && sha256sum -- *zksu*.deb > SHA256SUMS)
cp -a .config "$ARTIFACT_DIR/config/config.completed"

echo "completed=$(date -Is)"
ls -lh "$ARTIFACT_DIR/packages"
df -hT / /boot
