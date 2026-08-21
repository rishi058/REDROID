#!/usr/bin/env bash
set -Eeuo pipefail

# Two-pass LiteGApps install for the local x86_64 WSL ReDroid, adapted from
# KernelSU_setup/coolify/install-litegapps.sh (which targets ARM64/Coolify).
#
#   bash install-litegapps-x86_64.sh metamodule   # then: wsl --shutdown, restart
#   bash install-litegapps-x86_64.sh litegapps    # then: wsl --shutdown, restart
#
# Downloads are cached in local-setup/artifacts/gapps.

CONTAINER=${CONTAINER:-redroid14}
REPO=${REPO:-/mnt/d/PROJECT/_TRASH/REDROID}
ARTIFACT_DIR="$REPO/local-setup/artifacts/gapps"

META_NAME=meta-magic_mount-v1.0.1-sprout-release.zip
META_URL=https://github.com/KernelSU-Modules-Repo/meta-mm/releases/download/v1.0.1-sprout/$META_NAME
META_SHA256=4e2bfbccd80b0d787223cc8fe36315e8b269514a28f6d7ffb8e6e1f855e6e92b

# x86_64 Android 14 (SDK 34), lite variant.
GAPPS_NAME=LiteGapps-x86_64-14.0-20241029-official.zip
GAPPS_URL=https://downloads.sourceforge.net/project/litegapps/litegapps/x86_64/34/lite/2024-10-29/$GAPPS_NAME

usage() { echo "Usage: $0 {metamodule|litegapps}" >&2; }

command -v curl >/dev/null || { echo "Install curl" >&2; exit 1; }
command -v unzip >/dev/null || { echo "Install unzip" >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker required" >&2; exit 1; }
test "${1:-}" = metamodule -o "${1:-}" = litegapps || { usage; exit 2; }
zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_KSU=y' || { echo "KernelSU kernel not active" >&2; exit 1; }
test "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true || { echo "$CONTAINER not running" >&2; exit 1; }
test -x "$(docker exec "$CONTAINER" sh -c 'command -v /data/adb/ksud')" 2>/dev/null || \
  docker exec "$CONTAINER" test -x /data/adb/ksud || { echo "/data/adb/ksud missing" >&2; exit 1; }

install -d -m 0755 "$ARTIFACT_DIR"

# Download; verify sha256 when provided, otherwise fall back to unzip integrity.
# Diagnostics go to stderr so the caller captures only the file path on stdout.
download() {
  local name=$1 url=$2 expected=${3:-} path="$ARTIFACT_DIR/$1"
  if [ ! -f "$path" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$path.part" "$url" >&2
    mv "$path.part" "$path"
  fi
  if [ -n "$expected" ]; then
    printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >&2
  fi
  unzip -tq "$path" >/dev/null 2>&1
  printf '%s\n' "$path"
}

case "$1" in
  metamodule)
    p=$(download "$META_NAME" "$META_URL" "$META_SHA256")
    docker cp "$p" "$CONTAINER:/data/local/tmp/meta-mm.zip"
    docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/meta-mm.zip
    docker exec "$CONTAINER" sh -c 'grep -Fx metamodule=1 /data/adb/modules_update/meta-mm/module.prop 2>/dev/null || grep -Fx metamodule=1 /data/adb/modules/meta-mm/module.prop'
    docker exec "$CONTAINER" rm -f /data/local/tmp/meta-mm.zip
    echo "META_STAGED: restart WSL (wsl --shutdown) to activate Magic Mount, then run: $0 litegapps"
    ;;
  litegapps)
    docker exec "$CONTAINER" /data/adb/ksud module metamodule 2>&1 | grep -qi installed || {
      echo "Magic Mount not active. Run the metamodule pass + WSL restart first." >&2; exit 1; }
    p=$(download "$GAPPS_NAME" "$GAPPS_URL")
    # KernelSU extracts through /dev/tmp; Docker's /dev defaults to 64 MiB tmpfs
    # while the payload expands past 300 MiB.
    docker exec "$CONTAINER" mount -o remount,size=768M /dev
    docker exec "$CONTAINER" df -k /dev | awk 'NR == 2 { exit !($4 >= 524288) }'
    docker cp "$p" "$CONTAINER:/data/local/tmp/litegapps.zip"
    docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/litegapps.zip
    docker exec "$CONTAINER" rm -f /data/local/tmp/litegapps.zip
    docker exec "$CONTAINER" sh -c 'test -f /data/adb/modules_update/litegapps/module.prop || test -f /data/adb/modules/litegapps/module.prop'
    echo "GAPPS_STAGED: restart WSL (wsl --shutdown) to activate LiteGApps / Play Store."
    ;;
esac
