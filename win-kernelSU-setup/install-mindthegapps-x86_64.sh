#!/usr/bin/env bash
set -Eeuo pipefail

# Lay down MindTheGapps x86_64 (Android 14) as a KernelSU / Magic Mount module.
#
# Why this works where LiteGApps did not: the MindTheGapps zip payload is a plain
# top-level system/ tree (no arch-detecting customize.sh). We repackage it as a
# module (module.prop + system/) and let the already-installed Magic Mount
# metamodule overlay it onto redroid's read-only /system. Verified layout is the
# same one redroid-script uses (it copies <zip>/system/ verbatim).
#
#   bash install-mindthegapps-x86_64.sh          # install + stage
#   then: wsl --shutdown, restart docker + redroid14 to activate.

CONTAINER=${CONTAINER:-redroid14}
REPO=${REPO:-/mnt/d/PROJECT/_TRASH/REDROID}
ART="$REPO/local-setup/artifacts/gapps"
MODID=mindthegapps

NAME=MindTheGapps-14.0.0-x86_64-20240226.zip
URL="https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20240226/$NAME"
MD5=a827a84ccb0cf5914756e8561257ed13

command -v curl  >/dev/null || { echo "Install curl"  >&2; exit 1; }
command -v unzip >/dev/null || { echo "Install unzip" >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker required" >&2; exit 1; }
command -v zip >/dev/null || sudo apt-get install -y zip >/dev/null
zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_KSU=y' || { echo "KernelSU kernel not active" >&2; exit 1; }
test "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true || { echo "$CONTAINER not running" >&2; exit 1; }
docker exec "$CONTAINER" test -x /data/adb/ksud || { echo "/data/adb/ksud missing" >&2; exit 1; }
docker exec "$CONTAINER" /data/adb/ksud module metamodule 2>&1 | grep -qi installed || {
  echo "Magic Mount not active. Run install-litegapps-x86_64.sh metamodule + WSL restart first." >&2; exit 1; }

install -d -m 0755 "$ART"
zpath="$ART/$NAME"
if [ ! -f "$zpath" ]; then
  curl -fL --retry 3 --retry-delay 2 -o "$zpath.part" "$URL"
  mv "$zpath.part" "$zpath"
fi
printf '%s  %s\n' "$MD5" "$zpath" | md5sum -c -
unzip -tq "$zpath" >/dev/null

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q "$zpath" 'system/*' -d "$work"
test -d "$work/system" || { echo "zip has no top-level system/ tree" >&2; exit 1; }

mod="$work/$MODID"
install -d -m 0755 "$mod"
cp -a "$work/system" "$mod/system"
cat > "$mod/module.prop" <<EOF
id=$MODID
name=MindTheGapps (x86_64, Android 14)
version=14.0.0-20240226
versionCode=20240226
author=MindTheGapps / s1204IT (repackaged for Magic Mount)
description=Google Apps + Play Store laid down via Magic Mount for redroid x86_64
EOF

( cd "$mod" && zip -qry "$work/$MODID.zip" module.prop system )
docker cp "$work/$MODID.zip" "$CONTAINER:/data/local/tmp/$MODID.zip"
docker exec "$CONTAINER" /data/adb/ksud module install "/data/local/tmp/$MODID.zip"
docker exec "$CONTAINER" rm -f "/data/local/tmp/$MODID.zip"
docker exec "$CONTAINER" sh -c "test -f /data/adb/modules_update/$MODID/module.prop || test -f /data/adb/modules/$MODID/module.prop"

echo "GAPPS_STAGED: restart WSL (wsl --shutdown) to activate, then verify:"
echo "  docker exec $CONTAINER pm list packages | grep -iE 'vending|gms|gsf'"
