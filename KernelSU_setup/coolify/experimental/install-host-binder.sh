#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

test "$(id -u)" -eq 0 || {
  echo "Run this script with sudo." >&2
  exit 1
}
test "$(uname -r)" = 6.8.12-zksu
command -v gcc >/dev/null

gcc -O2 -Wall -Wextra -Werror \
  "$SCRIPT_DIR/binderfs-add-device.c" \
  -o /usr/local/sbin/binderfs-add-device
chmod 0755 /usr/local/sbin/binderfs-add-device
install -m 0755 "$SCRIPT_DIR/prepare-experimental-binder.sh" \
  /usr/local/sbin/prepare-redroid-experimental-binder
install -m 0644 "$SCRIPT_DIR/redroid-experimental-binder.service" \
  /etc/systemd/system/redroid-experimental-binder.service

systemctl daemon-reload
systemctl enable --now redroid-experimental-binder.service

stat -Lc '%n inode=%i mode=%a major=%t minor=%T' \
  /dev/binderfs-experimental/binder \
  /dev/binderfs-experimental/hwbinder \
  /dev/binderfs-experimental/vndbinder
