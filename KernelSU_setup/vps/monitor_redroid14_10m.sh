#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER=redroid14-ksu
LOG_FILE=/home/ubuntu/kbuild/artifacts/logs/redroid14-stability-10m.log
started_iso=$(date --iso-8601=seconds)

printf '%s stability monitor started\n' "$started_iso" | tee "$LOG_FILE"
for sample in $(seq 0 10); do
  now=$(date --iso-8601=seconds)
  state=$(docker inspect --format '{{.State.Status}}' "$CONTAINER")
  boot=$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)
  watchdog=$(systemctl is-active redroid14-watchdog.service || true)
  stats=$(timeout 8 docker stats --no-stream \
    --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' \
    "$CONTAINER")
  mem_available_kib=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
  psi_full_avg10=$(awk '/^full/ { sub("avg10=", "", $2); print $2 }' /proc/pressure/memory)
  critical=$(journalctl -k -b --since "$started_iso" --no-pager \
    | grep -Eic 'Kernel panic|Oops:|BUG:|Call trace:|Out of memory|oom-kill|soft lockup|hard lockup' \
    || true)
  printf '%s sample=%s state=%s boot=%s watchdog=%s %s mem_available_kib=%s psi_full_avg10=%s kernel_critical=%s\n' \
    "$now" "$sample" "$state" "$boot" "$watchdog" "$stats" \
    "$mem_available_kib" "$psi_full_avg10" "$critical" \
    | tee -a "$LOG_FILE"

  test "$state" = running
  test "$boot" = 1
  test "$watchdog" = active
  test "$critical" -eq 0
  (( sample == 10 )) && break
  sleep 60
done

printf '%s stability monitor passed\n' "$(date --iso-8601=seconds)" | tee -a "$LOG_FILE"
