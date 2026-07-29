#!/system/bin/sh
# Install the mitmproxy CA into every system trust-store path used by ReDroid.
# Android 14's active Conscrypt store is in the com.android.conscrypt APEX;
# /system/etc/security/cacerts is retained for older Android images.

HASH=c8750f0d
SRC=/data/local/tmp/$HASH.0

install_store() {
  CACERTS=$1
  LABEL=$2
  DST=$CACERTS/$HASH.0

  [ -d "$CACERTS" ] || return 0
  cp "$SRC" "$DST" 2>/dev/null
  if [ -f "$DST" ]; then
    chmod 644 "$DST"
    chown 0:0 "$DST"
    echo "$LABEL: DIRECT_COPY_OK"
  else
    echo "$LABEL: direct copy failed -> bind-mount overlay"
    WORK=/data/local/tmp/cacerts_overlay_$LABEL
    rm -rf "$WORK"
    mkdir -p "$WORK"
    cp "$CACERTS"/* "$WORK"/ 2>/dev/null
    cp "$SRC" "$WORK/$HASH.0"
    chmod 644 "$WORK"/*
    chown 0:0 "$WORK"/*
    mount --bind "$WORK" "$CACERTS" && echo "$LABEL: BIND_MOUNT_OK"
  fi

  echo "=== $LABEL verify ==="
  ls -la "$CACERTS/$HASH.0" 2>&1
}

mount -o rw,remount /system 2>/dev/null
mount -o rw,remount / 2>/dev/null

install_store /system/etc/security/cacerts system
install_store /apex/com.android.conscrypt/cacerts conscrypt_apex

echo "=== certificate subject ==="
openssl x509 -in "$SRC" -noout -subject 2>/dev/null || head -1 "$SRC"
