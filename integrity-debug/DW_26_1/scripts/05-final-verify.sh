#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-redroid14}
ready=0
for _ in $(seq 1 60); do
  [[ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" == 1 ]] && { ready=1; break; }
  sleep 2
done
[[ "$ready" == 1 ]] || { echo 'Android is not ready; validation stopped' >&2; exit 2; }

docker exec "$CONTAINER" cmd package list packages --show-versioncode com.recon.dw26gate
docker exec "$CONTAINER" cmd activity force-stop --user 0 com.diskwalaapp
docker exec "$CONTAINER" rm -f /data/user/0/com.diskwalaapp/cache/dw26gate-responses.jsonl
docker exec "$CONTAINER" logcat -b main -c
docker exec "$CONTAINER" /system/bin/sh -c 'printf observe > /data/local/tmp/dw26gate.mode'
docker exec "$CONTAINER" cmd activity start-activity --user 0 -n com.diskwalaapp/.app.MainActivity
sleep 8
pid=$(docker exec "$CONTAINER" pidof com.diskwalaapp)
test -n "$pid"

docker exec "$CONTAINER" logcat -d --pid="$pid" -v threadtime | grep -F '[DW26Gate]' |
while IFS= read -r line; do
  if [[ "$line" == *'BODY endpoint=token/refresh '* || "$line" == *'BODY endpoint=login '* ]]; then
    [[ "$line" == *'auth_values_omitted'* ]] || {
      echo 'Authentication response withheld: install probe 0.4 or later' >&2
      continue
    }
  fi
  printf '%s\n' "$line"
done
