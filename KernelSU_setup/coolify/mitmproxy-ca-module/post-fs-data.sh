#!/system/bin/sh
set -eu

MODDIR=${0%/*}
HASH=c8750f0d
SRC="$MODDIR/$HASH.0"
CACERTS=/apex/com.android.conscrypt/cacerts

[ -f "$SRC" ] || exit 1
[ -d "$CACERTS" ] || exit 0
[ -f "$CACERTS/$HASH.0" ] && exit 0

WORK="$MODDIR/conscrypt-cacerts-$(date +%s)-$$"
mkdir -p "$WORK"
cp -a "$CACERTS/." "$WORK/"
cp "$SRC" "$WORK/$HASH.0"
chown 0:0 "$WORK"/*
chmod 0644 "$WORK"/*
mount --bind "$WORK" "$CACERTS"
