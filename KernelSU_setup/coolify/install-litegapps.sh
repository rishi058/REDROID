#!/usr/bin/env bash
set -Eeuo pipefail

# Install in two passes:
#   sudo ./install-litegapps.sh metamodule
#   reboot, redeploy in Coolify, then sudo ./install-litegapps.sh litegapps

CONTAINER=${CONTAINER:-}
ARTIFACT_DIR=/home/ubuntu/kbuild/artifacts/gapps
META_NAME=meta-magic_mount-v1.0.1-sprout-release.zip
META_URL=https://github.com/KernelSU-Modules-Repo/meta-mm/releases/download/v1.0.1-sprout/$META_NAME
META_SHA256=4e2bfbccd80b0d787223cc8fe36315e8b269514a28f6d7ffb8e6e1f855e6e92b
GAPPS_NAME=LiteGapps-arm64-14.0-20260118-official.zip
GAPPS_URL=https://downloads.sourceforge.net/project/litegapps/litegapps/arm64/34/lite/2026-01-18/$GAPPS_NAME
GAPPS_SHA256=6308d96e359dd61f40ff32c9828108a0b2695cc21701204600b4513b7379876a

resolve_container() {
  if [ -n "$CONTAINER" ]; then
    return
  fi

  mapfile -t containers < <(docker ps -q --filter 'label=coolify.serviceName=redroid14')
  if [ "${#containers[@]}" -eq 0 ]; then
    mapfile -t containers < <(docker ps -aq --filter 'label=coolify.serviceName=redroid14')
  fi
  if [ "${#containers[@]}" -ne 1 ]; then
    echo "Expected exactly one Coolify ReDroid container; found ${#containers[@]}." >&2
    exit 1
  fi
  CONTAINER=${containers[0]}
}

usage() {
  echo "Usage: sudo $0 {metamodule|litegapps}" >&2
}

test "$(id -u)" -eq 0 || { echo "Run this script with sudo." >&2; exit 1; }
command -v curl >/dev/null || { echo "Install curl first: apt-get install -y curl" >&2; exit 1; }
command -v unzip >/dev/null || { echo "Install unzip first: apt-get install -y unzip" >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is required on the Coolify host." >&2; exit 1; }
resolve_container
test "$(uname -r)" = 6.8.12-zksu || { echo "The KernelSU host kernel is not active." >&2; exit 1; }
test "${1:-}" = metamodule -o "${1:-}" = litegapps || { usage; exit 2; }
test "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true || {
  echo "Deploy the Compose service in Coolify first." >&2; exit 1;
}

install -d -m 0755 "$ARTIFACT_DIR"
download_verified() {
  local name=$1 url=$2 expected=$3 path="$ARTIFACT_DIR/$1"
  if [ ! -f "$path" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$path.part" "$url"
    mv "$path.part" "$path"
  fi
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c -
  unzip -tq "$path"
}

case "$1" in
  metamodule)
    download_verified "$META_NAME" "$META_URL" "$META_SHA256"
    docker cp "$ARTIFACT_DIR/$META_NAME" "$CONTAINER:/data/local/tmp/meta-mm.zip"
    docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/meta-mm.zip
    docker exec "$CONTAINER" sh -c 'grep -Fx metamodule=1 /data/adb/modules_update/meta-mm/module.prop'
    docker exec "$CONTAINER" rm -f /data/local/tmp/meta-mm.zip
    echo "Magic Mount is staged. Reboot the VPS, then redeploy the Coolify service before installing LiteGapps."
    ;;
  litegapps)
    docker exec "$CONTAINER" /data/adb/ksud module metamodule | grep -qi installed || {
      echo "Magic Mount is not active. Complete the metamodule pass and host reboot first." >&2
      exit 1
    }
    download_verified "$GAPPS_NAME" "$GAPPS_URL" "$GAPPS_SHA256"
    # KernelSU extracts this module through /dev/tmp. Docker defaults /dev to
    # a 64 MiB tmpfs, while the verified LiteGapps payload expands past 300 MiB.
    docker exec "$CONTAINER" mount -o remount,size=768M /dev
    docker exec "$CONTAINER" df -k /dev | awk 'NR == 2 { exit !($4 >= 524288) }'
    docker cp "$ARTIFACT_DIR/$GAPPS_NAME" "$CONTAINER:/data/local/tmp/litegapps.zip"
    docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/litegapps.zip
    docker exec "$CONTAINER" rm -f /data/local/tmp/litegapps.zip
    docker exec "$CONTAINER" sh -c '
      test -f /data/adb/modules_update/litegapps/module.prop ||
      test -f /data/adb/modules/litegapps/module.prop
    '
    echo "LiteGapps is staged. Reboot the VPS, then redeploy the Coolify service to activate it."
    ;;
esac
