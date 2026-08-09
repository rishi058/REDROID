#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the VPS before deploying docker-compose.yml through Coolify.
# Coolify cannot create BinderFS devices; these must be prepared by the host.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VPS_DIR="$SCRIPT_DIR/../vps"

test "$(id -u)" -eq 0 || {
  echo "Run this script with sudo." >&2
  exit 1
}
test "$(uname -r)" = 6.8.12-zksu || {
  echo "Expected the KernelSU host kernel 6.8.12-zksu; found $(uname -r)." >&2
  exit 1
}
test "$(dpkg --print-architecture)" = arm64 || {
  echo "This deployment requires an ARM64 VPS." >&2
  exit 1
}
test "$(getconf PAGESIZE)" -eq 4096 || {
  echo "This deployment requires 4 KiB host pages." >&2
  exit 1
}
test -r /proc/pressure/memory

for file in dev-binderfs.mount binder-bindmounts.service redroid-binder-permissions.service; do
  test -f "$VPS_DIR/$file" || {
    echo "Missing required host unit: $VPS_DIR/$file" >&2
    exit 1
  }
done

echo binder_linux > /etc/modules-load.d/redroid-binder.conf
echo 'options binder_linux devices=binder,hwbinder,vndbinder' > /etc/modprobe.d/redroid-binder.conf
modprobe binder_linux devices=binder,hwbinder,vndbinder
install -d -m 0755 /dev/binderfs

install -m 0644 "$VPS_DIR/dev-binderfs.mount" /etc/systemd/system/dev-binderfs.mount
install -m 0644 "$VPS_DIR/binder-bindmounts.service" /etc/systemd/system/binder-bindmounts.service
install -m 0644 "$VPS_DIR/redroid-binder-permissions.service" /etc/systemd/system/redroid-binder-permissions.service

systemctl daemon-reload
systemctl enable --now dev-binderfs.mount binder-bindmounts.service redroid-binder-permissions.service

for device in /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder; do
  test -c "$device"
  test "$(stat -c '%a' "$device")" = 666
done

command -v docker >/dev/null || {
  echo "Docker is required before preparing the persistent ReDroid network." >&2
  exit 1
}

if docker network inspect redroid-persistent >/dev/null 2>&1; then
  subnet=$(docker network inspect redroid-persistent \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
  test "$subnet" = 172.29.14.0/24 || {
    echo "redroid-persistent already exists with unexpected subnet: $subnet" >&2
    exit 1
  }
else
  docker network create \
    --driver bridge \
    --attachable \
    --subnet 172.29.14.0/24 \
    --label com.redroid.persistent=true \
    redroid-persistent >/dev/null
fi

echo "BinderFS and redroid-persistent are ready for the Coolify deployment."
