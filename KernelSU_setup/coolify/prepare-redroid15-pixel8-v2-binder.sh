#!/usr/bin/env bash
set -Eeuo pipefail

MOUNTPOINT=/dev/binderfs-v2
ADD_DEVICE=/usr/local/sbin/binderfs-add-device

test "$(id -u)" -eq 0
mkdir -p "$MOUNTPOINT"
if ! mountpoint -q "$MOUNTPOINT"; then
  mount -t binder -o max=1048576 binder-v2 "$MOUNTPOINT"
fi
test -c "$MOUNTPOINT/binder-control"
for name in binder hwbinder vndbinder; do
  test -c "$MOUNTPOINT/$name" || "$ADD_DEVICE" "$MOUNTPOINT/binder-control" "$name"
  chmod 0666 "$MOUNTPOINT/$name"
done
