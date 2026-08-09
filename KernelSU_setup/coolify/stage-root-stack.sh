#!/usr/bin/env bash
set -Eeuo pipefail

# Stages the Android-side KernelSU daemon, Manager, Zygisk Next, and LSPosed.
# A host reboot is deliberately required after this script finishes.

CONTAINER=${CONTAINER:-}
ADB_SERIAL=127.0.0.1:5555
DATA_DIR=/home/ubuntu/redroid14-data
ARTIFACT_DIR=/home/ubuntu/kbuild/artifacts/android

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

test "$(id -u)" -eq 0 || {
  echo "Run this script with sudo." >&2
  exit 1
}
command -v adb >/dev/null || {
  echo "Install the host ADB client first: apt-get install -y adb" >&2
  exit 1
}
command -v docker >/dev/null || {
  echo "Docker is required on the Coolify host." >&2
  exit 1
}
resolve_container
test "$(uname -r)" = 6.8.12-zksu || {
  echo "Expected the KernelSU host kernel 6.8.12-zksu; found $(uname -r)." >&2
  exit 1
}
test -d "$ARTIFACT_DIR"
(
  cd "$ARTIFACT_DIR"
  sha256sum -c SHA256SUMS
)

test "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true || {
  echo "Deploy the Compose service in Coolify and wait for it to run first." >&2
  exit 1
}

for _ in $(seq 1 42); do
  if [ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; then
    break
  fi
  sleep 5
done
test "$(docker exec "$CONTAINER" getprop sys.boot_completed)" = 1

install -d -m 0755 -o root -g root "$DATA_DIR/adb"
install -m 0755 -o root -g root \
  "$ARTIFACT_DIR/ksud-aarch64-linux-android" "$DATA_DIR/adb/ksud"

adb start-server
adb connect "$ADB_SERIAL" >/dev/null
adb -s "$ADB_SERIAL" wait-for-device
adb -s "$ADB_SERIAL" install -r \
  "$ARTIFACT_DIR/KernelSU_Next_v3.3.0_33214-release.apk"
adb -s "$ADB_SERIAL" shell pm list packages | grep -Fx 'package:com.rifsxd.ksunext'

docker cp "$ARTIFACT_DIR/Zygisk-Next-1.4.3-817-e815170-release.zip" \
  "$CONTAINER:/data/local/tmp/zygisk-next.zip"
docker cp "$ARTIFACT_DIR/LSPosed-v1.9.2-7024-zygisk-release.zip" \
  "$CONTAINER:/data/local/tmp/lsposed.zip"
docker exec "$CONTAINER" /data/adb/ksud -V
docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/zygisk-next.zip
docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/lsposed.zip
docker exec "$CONTAINER" rm -f /data/local/tmp/zygisk-next.zip /data/local/tmp/lsposed.zip

docker exec "$CONTAINER" sh -c '
  test -f /data/adb/modules/zygisksu/update &&
  test -f /data/adb/modules/zygisk_lsposed/update &&
  test -x /data/adb/modules_update/zygisksu/bin/zygiskd64 &&
  test -f /data/adb/modules_update/zygisk_lsposed/zygisk/arm64-v8a.so
'

echo "Root stack staged successfully. Reboot the VPS, then use Coolify to deploy the Compose service again."
