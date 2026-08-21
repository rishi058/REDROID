#!/usr/bin/env bash
set -Eeuo pipefail

compose_file=${COMPOSE_FILE:-/mnt/d/PROJECT/_TRASH/REDROID/local-setup/docker-compose.redroid14.yml}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed in this WSL distro" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not reachable" >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  compose=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  compose=(docker-compose)
else
  echo "docker compose is not installed" >&2
  exit 1
fi

if ! grep -qw binder /proc/filesystems; then
  echo "current WSL kernel does not expose binderfs; install/boot the patched WSL kernel first" >&2
  exit 2
fi

mkdir -p /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
  mount -t binder binder /dev/binderfs
fi

for device in binder hwbinder vndbinder; do
  if [ ! -e "/dev/binderfs/$device" ]; then
    echo "missing /dev/binderfs/$device after binderfs mount" >&2
    exit 2
  fi
done

"${compose[@]}" -f "$compose_file" up -d
docker ps --filter name=redroid14