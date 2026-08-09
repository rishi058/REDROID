#!/usr/bin/env bash
set -u

# Persist FastAPI's Redroid network attachment and recover stale/offline ADB
# transports without restarting the Redroid container. Container-only Redroid
# restarts break KernelSU/LSPosed and are intentionally not used for ADB repair.

APPLICATION_ID=14
NETWORK=redroid-persistent
ADB_GATEWAY=172.29.14.1
ADB_SERIAL=redroid14:5555
HEALTH_INTERVAL=30
OFFLINE_THRESHOLD=2
RECOVERY_COOLDOWN=300

last_start=
last_health=0
last_recovery=0
offline_checks=0

log() {
  logger -t redroid-api-network -- "$*"
  printf '%s\n' "$*"
}

wait_for_api() {
  local container=$1
  for _ in $(seq 1 30); do
    if docker exec "$container" python -c \
        'import socket; s=socket.create_connection(("127.0.0.1",8001),2); s.close()' \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

api_connect() {
  local container=$1 response
  response=$(docker exec "$container" python -c '
import os
import urllib.request
request = urllib.request.Request("http://127.0.0.1:8001/adb/connect", method="POST")
key = os.getenv("API_KEY_ADMIN", "")
if key:
    request.add_header("x-api-key", key)
print(urllib.request.urlopen(request, timeout=45).read().decode())
' 2>/dev/null || true)
  printf '%s' "$response" | grep -Eq '"connected"[[:space:]]*:[[:space:]]*true'
}

adb_state() {
  local container=$1
  timeout 12 docker exec "$container" adb -s "$ADB_SERIAL" get-state \
    2>/dev/null | tr -d '\r\n'
}

reset_api_adb() {
  local container=$1
  timeout 12 docker exec "$container" adb disconnect "$ADB_SERIAL" >/dev/null 2>&1 || true
  timeout 12 docker exec "$container" adb kill-server >/dev/null 2>&1 || true
  timeout 12 docker exec "$container" adb start-server >/dev/null 2>&1 || true
}

connect_api_transport() {
  local container=$1
  timeout 15 docker exec "$container" adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
  [ "$(adb_state "$container")" = device ]
}

ensure_container_network() {
  local container=$1

  if ! docker inspect "$container" \
      --format '{{json .NetworkSettings.Networks}}' | grep -q '"redroid-persistent"'; then
    docker network connect --alias dw-fast-api "$NETWORK" "$container" || return 1
    log "Attached API container $container to $NETWORK"
  else
    log "API container $container is already attached to $NETWORK"
  fi

  if ! docker exec "$container" grep -qE \
      "^${ADB_GATEWAY}[[:space:]]+redroid14([[:space:]]|$)" /etc/hosts; then
    docker exec "$container" sh -c \
      "echo '${ADB_GATEWAY} redroid14 redroid14-ksu' >> /etc/hosts" || return 1
    log "Mapped redroid14 to the persistent ADB gateway $ADB_GATEWAY"
  fi
}

recover_adb() {
  local container=$1 redroid

  log "Resetting the API-side ADB server after repeated offline checks"
  reset_api_adb "$container"
  if connect_api_transport "$container"; then
    api_connect "$container" || true
    log "Recovered $ADB_SERIAL by resetting only the API-side ADB transport"
    return 0
  fi

  redroid=$(docker ps -q --filter 'label=coolify.serviceName=redroid14' | head -n 1)
  [ -n "$redroid" ] || return 1

  log "API-side reset failed; restarting only Android adbd (not the container)"
  docker exec "$redroid" setprop ctl.stop adbd >/dev/null 2>&1 || true
  sleep 2
  docker exec "$redroid" setprop service.adb.tcp.port 5555 >/dev/null 2>&1 || return 1
  docker exec "$redroid" setprop ctl.start adbd >/dev/null 2>&1 || return 1
  for _ in $(seq 1 12); do
    [ "$(docker exec "$redroid" getprop init.svc.adbd 2>/dev/null || true)" = running ] \
      && break
    sleep 1
  done
  reset_api_adb "$container"
  if connect_api_transport "$container"; then
    api_connect "$container" || true
    log "Recovered $ADB_SERIAL after the targeted Android adbd restart"
    return 0
  fi

  log "ADB remains unavailable; refusing to restart Redroid or the VPS automatically"
  return 1
}

while sleep 5; do
  container=$(docker ps -q --filter "label=coolify.applicationId=$APPLICATION_ID" | head -n 1)
  [ -n "$container" ] || continue
  started=$(docker inspect --format '{{.State.StartedAt}}' "$container" 2>/dev/null) || continue
  start_key="$container@$started"

  if [ "$start_key" != "$last_start" ]; then
    if ! ensure_container_network "$container"; then
      log "Failed to prepare API networking for $container"
      sleep 10
      continue
    fi
    if wait_for_api "$container" && api_connect "$container"; then
      log "API connected to $ADB_SERIAL successfully"
    else
      log "Initial API /adb/connect did not report success"
    fi
    last_start=$start_key
    offline_checks=0
  fi

  now=$(date +%s)
  [ $((now - last_health)) -ge "$HEALTH_INTERVAL" ] || continue
  last_health=$now

  state=$(adb_state "$container")
  if [ "$state" = device ]; then
    offline_checks=0
    continue
  fi

  offline_checks=$((offline_checks + 1))
  log "ADB health check $offline_checks/$OFFLINE_THRESHOLD failed (state=${state:-missing})"
  [ "$offline_checks" -ge "$OFFLINE_THRESHOLD" ] || continue
  [ $((now - last_recovery)) -ge "$RECOVERY_COOLDOWN" ] || continue

  last_recovery=$now
  recover_adb "$container" || true
  offline_checks=0
done
