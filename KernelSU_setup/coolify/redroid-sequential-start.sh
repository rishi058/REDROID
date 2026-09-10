#!/usr/bin/env bash
set -Eeuo pipefail

# redroid14 is the deterministic first starter; this ordering is technical only.
# All three instances are equal production services and must pass LSPosed readiness.
REDROID14_SERVICE=${REDROID14_SERVICE:-redroid14}
V2_SERVICE=${V2_SERVICE:-redroid14-v2}
EXPERIMENTAL_SERVICE=${EXPERIMENTAL_SERVICE:-redroid-experimental}

log() {
  logger -t redroid-sequential-start -- "$*"
  printf '%s\n' "$*"
}

container_for() {
  local service=$1
  local -a containers

  mapfile -t containers < <(docker ps -q --filter "label=coolify.serviceName=$service")
  if [ "${#containers[@]}" -eq 0 ]; then
    mapfile -t containers < <(docker ps -aq --filter "label=coolify.serviceName=$service")
  fi
  [ "${#containers[@]}" -gt 0 ] || return 0

  # Coolify force-recreates can leave historical containers carrying the same
  # service label. Select the newest matching container explicitly.
  docker inspect --format '{{.Created}} {{.Id}}' "${containers[@]}" \
    | sort -r -k1,1 \
    | head -n 1 \
    | cut -d ' ' -f 2
}

wait_android() {
  local service=$1
  local container

  for _ in $(seq 1 180); do
    container=$(container_for "$service")
    if [ -n "$container" ] \
      && [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ] \
      && [ "$(docker exec "$container" getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; then
      log "$service Android ready"
      return 0
    fi
    sleep 5
  done

  log "$service did not become Android-ready"
  return 1
}

wait_lsposed() {
  local service=$1
  local container
  local lspd_uid
  local started_epoch
  local log_epoch
  local log_path

  wait_android "$service"
  container=$(container_for "$service")

  for _ in $(seq 1 120); do
    # A root-owned waiting daemon is not sufficient. After a successful
    # system-server handshake, lspd runs as Android's system UID (1000).
    lspd_uid=$(docker exec "$container" sh -c \
      'p=$(pidof lspd 2>/dev/null | cut -d " " -f1); [ -n "$p" ] && stat -c %u "/proc/$p"' \
      2>/dev/null || true)

    started_epoch=$(date -d "$(docker inspect --format '{{.State.StartedAt}}' "$container")" +%s)
    read -r log_epoch log_path < <(docker exec "$container" sh -c \
      'f=$(ls -t /data/adb/lspd/log/modules_* 2>/dev/null | head -n 1); [ -n "$f" ] && printf "%s %s\n" "$(stat -c %Y "$f")" "$f"' \
      2>/dev/null || true) || true

    if [ "$lspd_uid" = 1000 ] \
      && [[ "${log_epoch:-}" =~ ^[0-9]+$ ]] \
      && [ "$log_epoch" -ge "$started_epoch" ] \
      && docker exec "$container" grep -q "LSPosed-Bridge.*binder received" "$log_path"; then
      log "$service LSPosed ready"
      return 0
    fi
    sleep 5
  done

  log "$service did not become LSPosed-ready"
  return 1
}

start_service() {
  local service=$1
  local container

  container=$(container_for "$service")
  [ -n "$container" ] || {
    log "No Coolify container found for $service"
    return 1
  }

  if [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]; then
    log "Starting $service"
    docker start "$container" >/dev/null
  fi
}

wait_lsposed "$REDROID14_SERVICE"
start_service "$V2_SERVICE"
wait_lsposed "$V2_SERVICE"
start_service "$EXPERIMENTAL_SERVICE"
wait_lsposed "$EXPERIMENTAL_SERVICE"
log "All ReDroid instances completed serialized startup"
