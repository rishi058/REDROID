#!/usr/bin/env bash
set -Eeuo pipefail

MOUNTPOINT=/dev/binderfs-experimental
ADD_DEVICE=/usr/local/sbin/binderfs-add-device

test "$(id -u)" -eq 0
install -d -m 0755 "$MOUNTPOINT"

if ! mountpoint -q "$MOUNTPOINT"; then
  mount -t binder -o max=3 binder-experimental "$MOUNTPOINT"
fi

test -c "$MOUNTPOINT/binder-control"
for name in binder hwbinder vndbinder; do
  if [ ! -c "$MOUNTPOINT/$name" ]; then
    "$ADD_DEVICE" "$MOUNTPOINT/binder-control" "$name"
  fi
  chmod 0666 "$MOUNTPOINT/$name"
done

for name in binder hwbinder vndbinder; do
  test -c "$MOUNTPOINT/$name"
  test "$(stat -c '%a' "$MOUNTPOINT/$name")" = 666
done
