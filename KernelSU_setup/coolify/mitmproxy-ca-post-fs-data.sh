#!/system/bin/sh
set -eu

# Android 14 reads system CAs from the Conscrypt APEX, not only /system.
# Build a writable mirror, add the local CA, and bind it before Zygote starts.
MODDIR=${0%/*}
HASH=c8750f0d
SRC="$MODDIR/$HASH.0"
CACERTS=/apex/com.android.conscrypt/cacerts

[ -f "$SRC" ] || exit 1
[ -d "$CACERTS" ] || exit 0
[ -f "$CACERTS/$HASH.0" ] && exit 0

# Never delete an older overlay directory: it may still back a live bind mount
# after a KernelSU stage replay or Android soft reboot.
WORK="$MODDIR/conscrypt-cacerts-$(date +%s)-$$"
mkdir -p "$WORK"
cp -a "$CACERTS/." "$WORK/"
cp "$SRC" "$WORK/$HASH.0"
chown 0:0 "$WORK"/*
chmod 0644 "$WORK"/*
mount --bind "$WORK" "$CACERTS"
