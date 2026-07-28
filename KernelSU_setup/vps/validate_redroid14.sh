#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER=redroid14-ksu
ADB_SERIAL=127.0.0.1:5555

for _ in $(seq 1 42); do
  if [ "$(sudo docker inspect --format '{{.State.Status}}' "$CONTAINER")" != running ]; then
    echo "Redroid exited before validation." >&2
    exit 80
  fi
  if [ "$(sudo docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; then
    break
  fi
  sleep 5
done

test "$(sudo docker exec "$CONTAINER" getprop sys.boot_completed)" = 1
test "$(sudo docker inspect --format '{{.State.OOMKilled}}' "$CONTAINER")" = false
test "$(sudo docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER")" = no

sudo docker exec "$CONTAINER" sh -c '
  test ! -e /data/adb/modules/zygisksu/update &&
  test ! -e /data/adb/modules/zygisk_lsposed/update &&
  test -x /data/adb/modules/zygisksu/bin/zygiskd64 &&
  test -f /data/adb/modules/zygisk_lsposed/zygisk/arm64-v8a.so
'

sudo docker exec "$CONTAINER" /data/adb/ksud -V
sudo docker exec "$CONTAINER" /data/adb/ksud module list \
  | tee /tmp/redroid14-module-list.json
grep -q '"id": "zygisksu"' /tmp/redroid14-module-list.json
grep -q '"id": "zygisk_lsposed"' /tmp/redroid14-module-list.json

adb start-server
adb connect "$ADB_SERIAL" >/dev/null
adb -s "$ADB_SERIAL" wait-for-device
adb -s "$ADB_SERIAL" shell pm list packages \
  | grep -Fx 'package:com.rifsxd.ksunext'

echo VERIFY_REDROID_FINAL
sudo docker stats --no-stream \
  --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' \
  "$CONTAINER"
sudo systemctl is-active redroid14.service redroid14-watchdog.service
cat /proc/pressure/memory
