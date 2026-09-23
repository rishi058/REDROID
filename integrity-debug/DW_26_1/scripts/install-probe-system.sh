#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-redroid14}
REPO_ROOT=${REPO_ROOT:-/mnt/d/PROJECT/_TRASH/REDROID}
APK=${APK:-$REPO_ROOT/rev-eng/modules/dw26gate.apk}
MODULE_PROP=${MODULE_PROP:-$REPO_ROOT/rev-eng/mod_build/gate/module.prop}
MODULE_ID=${MODULE_ID:-dw26_gate_probe}

test -f "$APK"
test -f "$MODULE_PROP"
data=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")
[[ -n "$data" && -d "$data/adb/modules" ]] || { echo 'Cannot locate verified module parent' >&2; exit 2; }
module="$data/adb/modules/$MODULE_ID"

docker cp "$APK" "$CONTAINER":/data/local/tmp/dw26gate.apk
docker cp "$MODULE_PROP" "$CONTAINER":/data/local/tmp/dw26gate-module.prop
docker stop -t 30 "$CONTAINER"
mkdir -p "$module/system/app/DW26Gate"
if [[ -f "$module/system/app/DW26Gate/base.apk" && ! -f "$data/adb/dw26-gate-before-update.apk" ]]; then
  cp -p "$module/system/app/DW26Gate/base.apk" "$data/adb/dw26-gate-before-update.apk"
fi
cp "$data/local/tmp/dw26gate.apk" "$module/system/app/DW26Gate/base.apk"
cp "$data/local/tmp/dw26gate-module.prop" "$module/module.prop"
chown -R 0:0 "$module"
chmod 0755 "$module" "$module/system" "$module/system/app" "$module/system/app/DW26Gate"
chmod 0644 "$module/module.prop" "$module/system/app/DW26Gate/base.apk"
cmp "$data/local/tmp/dw26gate.apk" "$module/system/app/DW26Gate/base.apk"
sync
echo 'Probe persisted as a system app; container remains stopped for overlay restart.'
