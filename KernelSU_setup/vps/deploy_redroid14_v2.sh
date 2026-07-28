#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER=redroid14-ksu
IMAGE_REPOSITORY=redroid/redroid
IMAGE_DIGEST=sha256:0a611199ba2e0b5d60af39b3327a517f6407231f4352114ed3bd3cbfe2be69aa
IMAGE="${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
DATA_DIR=/home/ubuntu/redroid14-data
ARTIFACT_DIR=/home/ubuntu/kbuild/artifacts/android
ADB_SERIAL=127.0.0.1:5555
WATCHDOG_UNIT=redroid14-watchdog.service
WATCHDOG=/usr/local/sbin/redroid14-watchdog
PIDS_LIMIT=1536
WATCHDOG_PIDS=1400
BOOT_WAIT_SECONDS=210
WATCHDOG_SECONDS=240

dump_failure_context() {
  rc=$?
  trap - ERR
  sudo systemctl stop "$WATCHDOG_UNIT" >/dev/null 2>&1 || true
  if sudo docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    timeout 8 sudo docker stop --timeout 3 "$CONTAINER" >/dev/null 2>&1 \
      || timeout 3 sudo docker kill "$CONTAINER" >/dev/null 2>&1 \
      || true
    timeout 5 sudo docker inspect "$CONTAINER" \
      --format 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' >&2 \
      || true
    timeout 5 sudo docker logs --tail 200 "$CONTAINER" >&2 || true
  fi
  exit "$rc"
}
trap dump_failure_context ERR

start_watchdog() {
  local max_seconds=${1:-$WATCHDOG_SECONDS}
  sudo systemctl stop "$WATCHDOG_UNIT" >/dev/null 2>&1 || true
  sudo systemctl reset-failed "$WATCHDOG_UNIT" >/dev/null 2>&1 || true
  sudo systemd-run \
    --unit="$WATCHDOG_UNIT" \
    --collect \
    --property=Type=exec \
    "$WATCHDOG" "$CONTAINER" "$WATCHDOG_PIDS" "$max_seconds"
}

stop_watchdog() {
  sudo systemctl stop "$WATCHDOG_UNIT" >/dev/null 2>&1 || true
}

wait_for_boot() {
  local booted=0 state attempts
  attempts=$((BOOT_WAIT_SECONDS / 5))
  for attempt in $(seq 1 "$attempts"); do
    state=$(timeout 3 sudo docker inspect "$CONTAINER" --format '{{.State.Status}}')
    [ "$state" = running ] || return 63

    if [ "$(timeout 3 sudo docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; then
      booted=1
      break
    fi
    sleep 5
  done
  test "$booted" -eq 1
}

case "$(uname -r)" in
  6.8.12-zksu) ;;
  *) echo "Refusing Redroid deployment on unverified kernel: $(uname -r)" >&2; exit 60 ;;
esac

cd "$ARTIFACT_DIR"
sha256sum -c SHA256SUMS
command -v adb >/dev/null
test -x "$WATCHDOG"

mem_available_kib=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
disk_available_kib=$(df -Pk /home/ubuntu | awk 'NR == 2 { print $4 }')
host_tasks=$(ps -eLo pid= | wc -l)
console_loglevel=$(awk '{ print $1 }' /proc/sys/kernel/printk)
test "$mem_available_kib" -ge 4194304 || {
  echo "Refusing to start: less than 4 GiB host memory is available." >&2
  exit 64
}
test "$disk_available_kib" -ge 5242880 || {
  echo "Refusing to start: less than 5 GiB is free on /home/ubuntu." >&2
  exit 65
}
test "$host_tasks" -lt 2000 || {
  echo "Refusing to start: host already has $host_tasks tasks." >&2
  exit 66
}
test "$console_loglevel" -le 4 || {
  echo "Refusing to start: kernel console loglevel $console_loglevel may flood the serial console." >&2
  exit 67
}
test -r /proc/pressure/memory

if sudo docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Container $CONTAINER already exists; refusing to replace it." >&2
  exit 61
fi
if [ -d "$DATA_DIR" ] && find "$DATA_DIR" -mindepth 1 -print -quit | grep -q .; then
  echo "Data directory $DATA_DIR is not empty; refusing to reuse it." >&2
  exit 62
fi

sudo install -d -m 0755 -o root -g root "$DATA_DIR/adb"
sudo install -m 0755 -o root -g root "$ARTIFACT_DIR/ksud-aarch64-linux-android" "$DATA_DIR/adb/ksud"

if ! grep -q '^binder_linux ' /proc/modules; then
  sudo modprobe binder_linux devices=binder,hwbinder,vndbinder
fi
sudo systemctl start redroid-binder-permissions.service
grep -q binder /proc/filesystems
for device in /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder; do
  test -c "$device"
  test "$(stat -c '%a' "$device")" = 666
done
test -c /dev/binderfs/binder-control

sudo docker pull "$IMAGE"
image_id=$(sudo docker image inspect "$IMAGE" --format '{{.Id}}')
test "$image_id" = "$IMAGE_DIGEST"
printf '%s@%s\n' "$IMAGE_REPOSITORY" "$IMAGE_DIGEST" \
  | tee /home/ubuntu/kbuild/artifacts/android/redroid14-image-digest.txt

sudo docker create \
  --name "$CONTAINER" \
  --privileged \
  --restart=no \
  --pids-limit="$PIDS_LIMIT" \
  --memory=6g \
  --memory-swap=8g \
  --cpus=1 \
  --stop-timeout=10 \
  --log-driver=json-file \
  --log-opt max-size=50m \
  --log-opt max-file=2 \
  --mount type=bind,src=/dev/binderfs/binder,dst=/dev/binder \
  --mount type=bind,src=/dev/binderfs/hwbinder,dst=/dev/hwbinder \
  --mount type=bind,src=/dev/binderfs/vndbinder,dst=/dev/vndbinder \
  --mount type=bind,src=/dev/null,dst=/dev/kmsg \
  -v "$DATA_DIR:/data" \
  -p 127.0.0.1:5555:5555 \
  "$IMAGE" \
  androidboot.redroid_gpu_mode=guest \
  androidboot.use_memfd=1 \
  ro.secure=0 \
  ro.debuggable=1
start_watchdog
sudo docker start "$CONTAINER"
wait_for_boot
stop_watchdog

adb start-server
adb connect "$ADB_SERIAL"
adb -s "$ADB_SERIAL" wait-for-device
adb -s "$ADB_SERIAL" install -r "$ARTIFACT_DIR/KernelSU_Next_v3.3.0_33214-release.apk"
adb -s "$ADB_SERIAL" shell pm list packages | grep -Fx 'package:com.rifsxd.ksunext'

adb -s "$ADB_SERIAL" push "$ARTIFACT_DIR/Zygisk-Next-1.4.3-817-e815170-release.zip" /data/local/tmp/zygisk-next.zip
adb -s "$ADB_SERIAL" push "$ARTIFACT_DIR/LSPosed-v1.9.2-7024-zygisk-release.zip" /data/local/tmp/lsposed.zip
sudo docker exec "$CONTAINER" /data/adb/ksud -V
sudo docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/zygisk-next.zip
sudo docker exec "$CONTAINER" /data/adb/ksud module install /data/local/tmp/lsposed.zip
adb -s "$ADB_SERIAL" shell rm -f /data/local/tmp/zygisk-next.zip /data/local/tmp/lsposed.zip

sudo docker exec "$CONTAINER" sh -c '
  test -f /data/adb/modules/zygisksu/update &&
  test -f /data/adb/modules/zygisk_lsposed/update &&
  test -x /data/adb/modules_update/zygisksu/bin/zygiskd64 &&
  test -f /data/adb/modules_update/zygisk_lsposed/zygisk/arm64-v8a.so
'
start_watchdog 0
echo VERIFY_REDROID_STAGING
sudo docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$CONTAINER"
test "$(sudo docker inspect --format '{{.State.OOMKilled}}' "$CONTAINER")" = false
adb -s "$ADB_SERIAL" shell getprop sys.boot_completed
sudo docker exec "$CONTAINER" /data/adb/ksud -V
sudo docker exec "$CONTAINER" /data/adb/ksud module list
echo "Modules are staged. A host reboot is required: KernelSU init hooks run once per host-kernel boot and a Docker restart cannot activate them safely."
echo "Redroid remains restart=no with an indefinite task-count watchdog until the boot-ordered systemd units are installed."
