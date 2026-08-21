#!/usr/bin/env bash
set -u

# KernelSU/Zygisk/LSPosed are initialized by the host kernel boot path. A
# container-only Coolify restart preserves /data but cannot reliably recreate
# LSPosed's daemon/injection state. Detect that condition per ReDroid service and
# perform one guarded host reboot, which is the tested recovery path.

STATE_DIR=/var/lib/redroid-kernelsu-replay
SERVICES=(
  "redroid14|coolify.serviceName=redroid14|redroid14-ksu|production"
  "redroid-experimental|coolify.serviceName=redroid-experimental|redroid-experimental|experimental"
)
declare -A last_starts

install -d -m 0755 "$STATE_DIR"

log() {
  logger -t redroid-kernelsu-replay -- "$*"
  printf '%s\n' "$*"
}

is_running() {
  local container=$1

  [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ]
}

is_healthy() {
  local container=$1
  local service_type=$2
  local modules

  modules=$(docker exec "$container" /data/adb/ksud module list 2>/dev/null) || return 1

  docker exec "$container" /data/adb/ksud -V >/dev/null 2>&1 \
    && [[ "$modules" == *'"id": "zygisksu"'* ]] \
    && [[ "$modules" == *'"id": "zygisk_lsposed"'* ]] \
    && docker exec "$container" sh -c 'ps -A | grep -Eq "(^|[[:space:]])lspd([[:space:]]|$)"' \
    && docker exec "$container" pm path com.google.android.gsf >/dev/null 2>&1 \
    && docker exec "$container" pm path com.google.android.gms >/dev/null 2>&1 \
    && docker exec "$container" pm path com.android.vending >/dev/null 2>&1 \
    && { [ "$service_type" != production ] || docker exec "$container" test -f /apex/com.android.conscrypt/cacerts/c8750f0d.0; }
}

while sleep 5; do
  for service in "${SERVICES[@]}"; do
    IFS='|' read -r service_name label hostname service_type <<< "$service"
    pending_file=$STATE_DIR/pending-host-recovery-$service_name
    container=$(docker ps -q --filter "label=$label" | head -n 1)
    [ -n "$container" ] || continue

    started=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null) || continue
    start_key="$container@$started"
    [ "$start_key" != "${last_starts[$service_name]:-}" ] || continue
    is_running "$container" || continue

    booted=false
    for _ in $(seq 1 72); do
      is_running "$container" || break
      if [ "$(docker exec "$container" getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; then
        booted=true
        break
      fi
      sleep 5
    done
    [ "$booted" = true ] || continue
    is_running "$container" || continue

    # Android init resets the kernel hostname to localhost even when Docker's
    # Config.Hostname is stable. Reapply the service identity after every boot.
    docker exec "$container" hostname "$hostname" || true

    # LSPosed can appear shortly after Android reports boot completion.
    for _ in $(seq 1 12); do
      is_running "$container" || break
      is_healthy "$container" "$service_type" && break
      sleep 5
    done

    if ! is_running "$container"; then
      last_starts[$service_name]=$start_key
      log "$service_name stopped while being checked; treating as manual/container lifecycle event, not KernelSU recovery failure"
      continue
    fi

    if is_healthy "$container" "$service_type"; then
      rm -f "$pending_file"
      last_starts[$service_name]=$start_key
      log "KernelSU, Zygisk Next, LSPosed, and GApps are healthy for $service_name ($start_key)"
      continue
    fi

    if [ -f "$pending_file" ]; then
      last_starts[$service_name]=$start_key
      log "KernelSU recovery for $service_name is still incomplete after the guarded host reboot; refusing a reboot loop"
      continue
    fi

    printf '%s\n' "$start_key" > "$pending_file"
    sync
    log "Container-only restart lost KernelSU/LSPosed state for $service_name; scheduling one guarded VPS reboot"
    systemctl reboot
    exit 0
  done
done
