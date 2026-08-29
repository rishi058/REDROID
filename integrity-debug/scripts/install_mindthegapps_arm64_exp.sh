#!/usr/bin/env bash
# Repackage arm64 MindTheGapps (A14) as a Magic Mount module and install into exp.
# Disables litegapps. Runs on the VPS HOST. exp ONLY. Reversible (litegapps kept, disabled).
set -Eeuo pipefail
ART=/home/ubuntu/kbuild/artifacts/gapps
NAME=MindTheGapps-14.0.0-arm64-20240226.zip
MD5=a0905cc7bf3f4f4f2e3f59a4e1fc789b
MODID=mindthegapps
C=$(sudo docker ps -q --filter label=coolify.serviceName=redroid-experimental | head -n1)
[ -z "$C" ] && { echo "exp not running"; exit 1; }

echo "== verify zip =="
printf '%s  %s\n' "$MD5" "$ART/$NAME" | md5sum -c -

echo "== unzip system/ tree =="
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
unzip -q "$ART/$NAME" 'system/*' -d "$work"
test -d "$work/system" || { echo "no top-level system/ in zip"; exit 1; }

echo "== build module tree =="
mod="$work/$MODID"; install -d -m 0755 "$mod"
cp -a "$work/system" "$mod/system"
cat > "$mod/module.prop" <<EOF
id=$MODID
name=MindTheGapps (arm64, Android 14)
version=14.0.0-20240226
versionCode=20240226
author=MindTheGapps / s1204IT (repackaged for Magic Mount)
description=Google Apps + Play Store laid down via Magic Mount for redroid arm64
EOF
# module must not be skipped by Magic Mount
: > "$mod/skip_mount" 2>/dev/null || true
rm -f "$mod/skip_mount"

echo "== back up + disable litegapps, remove any prior mindthegapps =="
sudo docker exec "$C" sh -c 'touch /data/adb/modules/litegapps/disable 2>/dev/null; rm -rf /data/adb/modules/'"$MODID"' /data/adb/modules_update/'"$MODID"' 2>/dev/null; mkdir -p /data/adb/modules/'"$MODID"

echo "== inject module into container /data/adb/modules/$MODID (tar over docker exec) =="
( cd "$mod" && tar -cf - module.prop system ) | sudo docker exec -i "$C" tar -xf - -C /data/adb/modules/"$MODID"
sudo docker exec "$C" sh -c 'chown -R 0:0 /data/adb/modules/'"$MODID"'; find /data/adb/modules/'"$MODID"' -type d -exec chmod 0755 {} +; find /data/adb/modules/'"$MODID"'/system -type f -exec chmod 0644 {} +'

echo "== verify =="
sudo docker exec "$C" sh -c 'echo "mindthegapps files:"; find /data/adb/modules/'"$MODID"'/system -name "Phonesky*.apk" -o -name "GmsCore*.apk" 2>/dev/null | head; echo "module states:"; for d in /data/adb/modules/*/; do id=$(basename "$d"); [ -f "$d/disable" ] && s=DISABLED || s=enabled; echo "  $id: $s"; done'
echo "@@DONE (restart exp container to activate; then verify Play Store + GMS + integrity)"
