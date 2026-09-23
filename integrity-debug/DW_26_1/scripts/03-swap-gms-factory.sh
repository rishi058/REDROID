#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-redroid14}
: "${GMS_BACKUP:?Set GMS_BACKUP to the /data/adb/gms-factory-fix-* path printed by staging}"
FACTORY_REL=${FACTORY_REL:-adb/modules/mindthegapps/system/product/priv-app/GmsCore}

[[ "$GMS_BACKUP" == /data/adb/gms-factory-fix-* ]] || {
  echo "Unexpected backup path: $GMS_BACKUP" >&2; exit 2;
}

data=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")
[[ -n "$data" && -d "$data/adb" ]] || { echo 'Cannot locate verified /data mount' >&2; exit 2; }
factory="$data/$FACTORY_REL"
backup="$data/${GMS_BACKUP#/data/}"
test -f "$factory/GmsCore.apk"
test -f "$backup/active-apks/base.apk"
test ! -e "$backup/factory-original"

docker stop -t 30 "$CONTAINER"
mv "$factory" "$backup/factory-original"
restore_on_failure() {
  status=$?
  if [[ "$status" != 0 ]]; then
    rm -rf -- "$factory"
    mv "$backup/factory-original" "$factory"
    sync
    echo 'Replacement failed; original factory directory restored' >&2
  fi
}
trap restore_on_failure EXIT
cp -a "$backup/active-apks" "$factory"
chown -R 0:0 "$factory"
chmod 0755 "$factory"
chmod 0644 "$factory"/*.apk
for apk in "$backup"/active-apks/*.apk; do cmp "$apk" "$factory/$(basename "$apk")"; done
sync
trap - EXIT

echo 'Factory GMS APK set replaced byte-for-byte; container remains stopped.'
echo "Rollback: $backup/factory-original"
echo 'No account/app/Keystore data was modified.'
