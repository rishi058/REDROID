#!/usr/bin/env bash
set -Eeuo pipefail

# Install the boot-order fix used by the 2026-09-10 three-instance LSPosed
# incident. Run this from the uploaded KernelSU_setup/coolify directory.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

V2_UUID=${V2_UUID:-gdbnhtayragkw0jhha7a58hk}
EXPERIMENTAL_UUID=${EXPERIMENTAL_UUID:-bk6ojzx98y1dlabu4d63c6d3}
PRODUCTION_DATA=${PRODUCTION_DATA:-/home/ubuntu/redroid14-data}
V2_DATA=${V2_DATA:-/home/ubuntu/redroid14-v2-data}
EXPERIMENTAL_DATA=${EXPERIMENTAL_DATA:-/home/ubuntu/redroid-experimental-data}

test "$(id -u)" -eq 0 || {
  echo "Run with sudo." >&2
  exit 1
}
[ "$(uname -r)" = 6.8.12-zksu-multi ] || {
  echo "This fix requires the multi-instance kernel 6.8.12-zksu-multi." >&2
  exit 1
}
test -f "$SCRIPT_DIR/redroid-sequential-start.sh"
test -f "$SCRIPT_DIR/redroid-sequential-start.service"
test -f "$SCRIPT_DIR/redroid-kernelsu-replay.sh"
test -f "$SCRIPT_DIR/redroid-kernelsu-replay.service"
systemctl cat redroid-binder-permissions.service >/dev/null
systemctl cat redroid-v2-binder.service >/dev/null
systemctl cat redroid-experimental-binder.service >/dev/null

patch_lsposed_retry() {
  local data=$1
  local launcher=$data/adb/modules/zygisk_lsposed/service.sh

  test -f "$launcher" || {
    echo "Missing LSPosed launcher: $launcher" >&2
    return 1
  }
  if grep -q -- '--system-server-max-retry=3' "$launcher"; then
    [ -e "$launcher.pre-sequential-start" ] || cp -a "$launcher" "$launcher.pre-sequential-start"
    sed -i 's/--system-server-max-retry=3/--system-server-max-retry=60/g' "$launcher"
  fi
  grep -q -- '--system-server-max-retry=60' "$launcher"
}

persist_restart_no() {
  local uuid=$1
  local compose=/data/coolify/services/$uuid/docker-compose.yml
  local container
  local -a containers

  test -f "$compose"
  sed -i -E 's/^([[:space:]]*restart:).*/\1 "no"/' "$compose"

  # Persist the setting in Coolify's raw definition as well as its generated
  # Compose file, otherwise a future Coolify deployment restores the old policy.
  docker exec coolify php artisan tinker --execute \
    "\$s=App\\Models\\Service::where('uuid','$uuid')->firstOrFail(); \$raw=str_replace(['restart: on-failure:5','restart: unless-stopped'],['restart: \"no\"','restart: \"no\"'],\$s->docker_compose_raw); \$s->update(['docker_compose_raw'=>\$raw]);" \
    >/dev/null

  mapfile -t containers < <(docker ps -q --filter "label=com.docker.compose.project=$uuid")
  if [ "${#containers[@]}" -eq 0 ]; then
    mapfile -t containers < <(docker ps -aq --filter "label=com.docker.compose.project=$uuid")
  fi
  if [ "${#containers[@]}" -gt 0 ]; then
    container=$(docker inspect --format '{{.Created}} {{.Id}}' "${containers[@]}" \
      | sort -r -k1,1 | head -n 1 | cut -d ' ' -f 2)
    docker update --restart=no "$container" >/dev/null
  fi
}

patch_lsposed_retry "$PRODUCTION_DATA"
patch_lsposed_retry "$V2_DATA"
patch_lsposed_retry "$EXPERIMENTAL_DATA"
persist_restart_no "$V2_UUID"
persist_restart_no "$EXPERIMENTAL_UUID"

install -m 0755 -o root -g root \
  "$SCRIPT_DIR/redroid-sequential-start.sh" \
  /usr/local/sbin/redroid-sequential-start
install -m 0755 -o root -g root \
  "$SCRIPT_DIR/redroid-kernelsu-replay.sh" \
  /usr/local/sbin/redroid-kernelsu-replay
install -m 0644 -o root -g root \
  "$SCRIPT_DIR/redroid-sequential-start.service" \
  /etc/systemd/system/redroid-sequential-start.service
install -m 0644 -o root -g root \
  "$SCRIPT_DIR/redroid-kernelsu-replay.service" \
  /etc/systemd/system/redroid-kernelsu-replay.service

bash -n /usr/local/sbin/redroid-sequential-start
bash -n /usr/local/sbin/redroid-kernelsu-replay
systemctl daemon-reload
systemctl enable redroid-sequential-start.service redroid-kernelsu-replay.service

# Do not restart the recovery watcher here. If the current LSPosed runtime is
# already broken, restarting it deliberately schedules a host reboot. Both the
# new watcher and sequencer are loaded naturally by the requested validation boot.
echo "Installed. Validate with: sudo systemctl reboot"
