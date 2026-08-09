#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER=${CONTAINER:-}
ADB_SERIAL=127.0.0.1:5555
MODE=${1:-root}

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

case "$MODE" in root|gapps) ;; *) echo "Usage: sudo $0 {root|gapps}" >&2; exit 2;; esac
test "$(id -u)" -eq 0 || { echo "Run this script with sudo." >&2; exit 1; }
command -v adb >/dev/null || { echo "Host ADB is required." >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is required on the Coolify host." >&2; exit 1; }
resolve_container
test "$(uname -r)" = 6.8.12-zksu

for device in /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder; do
  test -c "$device"
  test "$(stat -c '%a' "$device")" = 666
done

for _ in $(seq 1 42); do
  test "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true || {
    echo "Coolify service is not running." >&2; exit 1;
  }
  [ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" = 1 ] && break
  sleep 5
done

test "$(docker exec "$CONTAINER" getprop sys.boot_completed)" = 1
test "$(docker inspect --format '{{.State.OOMKilled}}' "$CONTAINER")" = false
test "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER")" = unless-stopped
docker exec "$CONTAINER" /data/adb/ksud -V
docker exec "$CONTAINER" /data/adb/ksud module list | tee /tmp/coolify-redroid-modules.json
grep -q '"id": "zygisksu"' /tmp/coolify-redroid-modules.json
grep -q '"id": "zygisk_lsposed"' /tmp/coolify-redroid-modules.json

adb start-server
adb connect "$ADB_SERIAL" >/dev/null
adb -s "$ADB_SERIAL" wait-for-device
adb -s "$ADB_SERIAL" shell pm list packages | grep -Fx 'package:com.rifsxd.ksunext'

if [ "$MODE" = gapps ]; then
  grep -q '"id": "litegapps"' /tmp/coolify-redroid-modules.json
  for package in com.google.android.gsf com.google.android.gms com.android.vending; do
    adb -s "$ADB_SERIAL" shell pm path "$package" | grep -q '^package:'
  done
fi

docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$CONTAINER"
echo "Coolify ReDroid validation passed: $MODE"
