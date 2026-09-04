#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

command -v docker >/dev/null || { echo "docker is not installed" >&2; exit 1; }
docker info >/dev/null || { echo "docker daemon is not reachable" >&2; exit 1; }
if docker compose version 2>&1 | grep -q "Docker Compose"; then
  compose=(docker compose)
  legacy_compose=false
elif command -v docker-compose >/dev/null 2>&1; then
  compose=(docker-compose)
  legacy_compose=true
else
  echo "Docker Compose is not installed" >&2
  exit 1
fi
grep -qw binder /proc/filesystems || {
  echo "the current WSL kernel does not support binderfs" >&2
  exit 2
}

readonly binderfs_path=/dev/binderfs-unified
readonly binder_helper=/tmp/device-controller-binderfs-add-device
sudo mkdir -p "$binderfs_path"
if ! mountpoint -q "$binderfs_path"; then
  sudo mount -t binder -o max=1048576 binder-unified "$binderfs_path"
fi
gcc -O2 -Wall -Wextra -Werror binderfs-add-device.c -o "$binder_helper"
for device in binder hwbinder vndbinder; do
  if ! test -c "$binderfs_path/$device"; then
    sudo "$binder_helper" "$binderfs_path/binder-control" "$device"
  fi
  sudo chmod 0666 "$binderfs_path/$device"
done

"${compose[@]}" -p unified-redroid-local config --quiet
"${compose[@]}" -p unified-redroid-local build device-controller
if "$legacy_compose"; then
  # Compose 1.29 cannot inspect images produced by Docker 29 when recreating a
  # changed service (`ContainerConfig` KeyError). Remove only the stateless
  # controller; the ReDroid container and both persistent volumes stay intact.
  "${compose[@]}" -p unified-redroid-local rm -sf device-controller || true
fi
"${compose[@]}" -p unified-redroid-local up -d
"${compose[@]}" -p unified-redroid-local ps
published_port=$("${compose[@]}" -p unified-redroid-local port device-controller 3003 | sed 's/.*://')
printf '\nController: http://localhost:%s\n' "$published_port"
printf 'GUI:        http://localhost:%s/gui/\n' "$published_port"
printf 'Docs:       http://localhost:%s/docs\n' "$published_port"
