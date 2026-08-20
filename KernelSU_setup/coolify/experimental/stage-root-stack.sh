#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER=${CONTAINER:-}
ADB_SERIAL=127.0.0.1:5557
DATA_DIR=/home/ubuntu/redroid-experimental-data
ARTIFACT_DIR=/home/ubuntu/kbuild/artifacts/android

test "$(id -u)" -eq 0 || { echo "Run with sudo." >&2; exit 1; }
test "$(uname -r)" = 6.8.12-zksu

if [ -z "$CONTAINER" ]; then
  mapfile -t containers < <(docker ps -q --filter 'label=coolify.serviceName=redroid-experimental')
  test "${#containers[@]}" -eq 1
  CONTAINER=${containers[0]}
fi

(
  cd "$ARTIFACT_DIR"
  sha256sum -c SHA256SUMS
)

for _ in $(seq 1 120); do
  [ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" = 1 ] && break
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
