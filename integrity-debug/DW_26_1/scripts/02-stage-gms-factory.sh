#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-redroid14}
FACTORY=${FACTORY:-/data/adb/modules/mindthegapps/system/product/priv-app/GmsCore}
BACKUP=${BACKUP:-/data/adb/gms-factory-fix-$(date -u +%Y%m%dT%H%M%SZ)}

ready=0
for _ in $(seq 1 90); do
  [[ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" == 1 ]] && { ready=1; break; }
  sleep 2
done
[[ "$ready" == 1 ]] || { echo 'Android is not ready; no change made' >&2; exit 2; }

docker exec -e FACTORY="$FACTORY" -e BACKUP="$BACKUP" "$CONTAINER" /system/bin/sh -c '
set -e
test -f "$FACTORY/GmsCore.apk"
test ! -e "$BACKUP"
paths=$(cmd package path com.google.android.gms | sed -n "s/^package://p")
test -n "$paths"
mkdir -p "$BACKUP/active-apks"
printf "%s\n" "$paths" > "$BACKUP/active-package-paths.txt"
count=0
for apk in $paths; do
  case "$apk" in
    /data/app/*/com.google.android.gms-*/base.apk|/data/app/*/com.google.android.gms-*/split_*.apk) ;;
    *) echo "Unexpected GMS source: $apk" >&2; exit 2 ;;
  esac
  test -r "$apk"
  cp -p "$apk" "$BACKUP/active-apks/$(basename "$apk")"
  cmp "$apk" "$BACKUP/active-apks/$(basename "$apk")"
  count=$((count + 1))
done
test "$count" -ge 2
test -f "$BACKUP/active-apks/base.apk"
chown -R 0:0 "$BACKUP"
chmod 0755 "$BACKUP" "$BACKUP/active-apks"
chmod 0644 "$BACKUP"/active-apks/*.apk
echo "Verified copied APKs: $count"
echo "GMS_BACKUP=$BACKUP"
echo "Factory package and account data are unchanged."
'

echo 'Before swapping, compare factory/update manifests and public signing certificates as documented.'
