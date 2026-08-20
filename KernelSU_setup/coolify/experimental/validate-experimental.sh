#!/usr/bin/env bash
set -Eeuo pipefail

MODE=${1:-boot}
ADB_SERIAL=127.0.0.1:5557
mapfile -t containers < <(docker ps -q --filter 'label=coolify.serviceName=redroid-experimental')
test "${#containers[@]}" -eq 1
CONTAINER=${containers[0]}

for node in binder hwbinder vndbinder; do
  test -c "/dev/binderfs-experimental/$node"
  test "$(stat -c '%a' "/dev/binderfs-experimental/$node")" = 666
done

for _ in $(seq 1 120); do
  [ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" = 1 ] && break
  sleep 5
done
test "$(docker exec "$CONTAINER" getprop sys.boot_completed)" = 1
test "$(docker inspect --format '{{.State.OOMKilled}}' "$CONTAINER")" = false
test "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER")" = unless-stopped

if [ "$MODE" = root ] || [ "$MODE" = gapps ]; then
  docker exec "$CONTAINER" /data/adb/ksud -V
  docker exec "$CONTAINER" /data/adb/ksud module list | tee /tmp/redroid-experimental-modules.json
  grep -q '"id": "zygisksu"' /tmp/redroid-experimental-modules.json
  grep -q '"id": "zygisk_lsposed"' /tmp/redroid-experimental-modules.json
  docker exec "$CONTAINER" pidof lspd
fi

adb start-server
adb connect "$ADB_SERIAL" >/dev/null
test "$(adb -s "$ADB_SERIAL" get-state)" = device

if [ "$MODE" = gapps ]; then
  grep -q '"id": "litegapps"' /tmp/redroid-experimental-modules.json
  for package in com.google.android.gsf com.google.android.gms com.android.vending; do
    adb -s "$ADB_SERIAL" shell pm path "$package" | grep -q '^package:'
  done
fi

docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$CONTAINER"
