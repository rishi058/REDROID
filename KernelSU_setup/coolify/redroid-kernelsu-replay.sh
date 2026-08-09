#!/usr/bin/env bash
set -u

# KernelSU/Zygisk/LSPosed are initialized by the host kernel boot path. A
# container-only Coolify restart preserves /data but cannot reliably recreate
# LSPosed's daemon/injection state. Detect that condition and perform one guarded
# host reboot, which is the tested recovery path.

LABEL=coolify.serviceName=redroid14
STATE_DIR=/var/lib/redroid-kernelsu-replay
PENDING_FILE=$STATE_DIR/pending-host-recovery
last_start=

install -d -m 0755 "$STATE_DIR"

log() {
  logger -t redroid-kernelsu-replay -- "$*"
  printf '%s\n' "$*"
}

is_healthy() {
  local container=$1

  docker exec "$container" pm path com.google.android.gsf >/dev/null 2>&1 \
    && docker exec "$container" test -f /apex/com.android.conscrypt/cacerts/c8750f0d.0 \
    && docker exec "$container" sh -c 'ps -A | grep -Eq "(^|[[:space:]])lspd([[:space:]]|$)"'
}

while sleep 5; do
  container=$(docker ps -q --filter "label=$LABEL" | head -n 1)
  [ -n "$container" ] || continue

  started=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null) || continue
  start_key="$container@$started"
  [ "$start_key" != "$last_start" ] || continue

  booted=false
  for _ in $(seq 1 72); do
    if [ "$(docker exec "$container" getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; then
      booted=true
      break
    fi
    sleep 5
  done
  [ "$booted" = true ] || continue

  # Android init resets the kernel hostname to localhost even when Docker's
  # Config.Hostname is stable. Reapply the service identity after every boot.
  docker exec "$container" hostname redroid14-ksu || true

  # LSPosed can appear shortly after Android reports boot completion.
  for _ in $(seq 1 12); do
    is_healthy "$container" && break
    sleep 5
  done

  if is_healthy "$container"; then
    rm -f "$PENDING_FILE"
    last_start=$start_key
    log "KernelSU, LSPosed, GApps, and CA are healthy for $start_key"
    continue
  fi

  if [ -f "$PENDING_FILE" ]; then
    last_start=$start_key
    log "KernelSU recovery is still incomplete after the guarded host reboot; refusing a reboot loop"
    continue
  fi

  printf '%s\n' "$start_key" > "$PENDING_FILE"
  sync
  log "Container-only restart lost KernelSU/LSPosed state; scheduling one guarded VPS reboot"
  systemctl reboot
  exit 0
done
