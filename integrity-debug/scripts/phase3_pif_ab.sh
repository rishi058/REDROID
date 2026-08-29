#!/usr/bin/env bash
# Phase 3 - A/B swap KOWX712 PIF -> chiteroman v15.9.9 PIF on exp. exp ONLY.
# Keeps tricky_store + keybox unchanged. Requires a BUILT chiteroman v15.9.9 zip on the VPS.
# NOTE: reframed as LOW priority (prod uses a richer stack and also fails; the real
#   differentiator is VPS-vs-WSL env). Kept for completeness / controlled experiment.
# Usage on VPS: ZIP=/path/PlayIntegrityFix-v15.9.9.zip bash -s < phase3_pif_ab.sh
set -uo pipefail
C="$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid-experimental' | head -n1)"
[ -z "$C" ] && { echo "exp not running"; exit 1; }
ZIP="${ZIP:-}"
[ -z "$ZIP" ] && { echo "set ZIP=/path/to/PlayIntegrityFix-v15.9.9.zip (build from workspace PlayIntegrityFix/ with gradlew, or download official v15.9.9 tag)"; exit 1; }
[ -f "$ZIP" ] || { echo "zip not found: $ZIP"; exit 1; }
dex() { sudo docker exec "$C" sh -c "$*"; }

echo "== backup current pif config =="
dex 'cp -f /data/adb/modules/playintegrityfix/pif.prop /data/local/tmp/pif.prop.bak 2>/dev/null; cp -f /data/adb/pif.json /data/local/tmp/pif.json.bak 2>/dev/null; true'
echo "== ensure /dev big enough for ksud unzip =="
dex 'mount -o remount,size=768M /dev 2>/dev/null; true'
echo "== install chiteroman v15.9.9 (overwrites module id playintegrityfix) =="
sudo docker cp "$ZIP" "$C:/data/local/tmp/pif-chiteroman.zip"
dex '/data/adb/ksud module install /data/local/tmp/pif-chiteroman.zip'
echo "== write redfin/Pixel5 pif.json (controlled A/B: SAME identity as KOWX712 build) =="
dex 'cat > /data/adb/modules_update/playintegrityfix/pif.json << "EOF"
{
  "MANUFACTURER": "Google",
  "MODEL": "Pixel 5",
  "FINGERPRINT": "google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys",
  "BRAND": "google",
  "PRODUCT": "redfin",
  "DEVICE": "redfin",
  "SECURITY_PATCH": "2024-05-05",
  "DEVICE_INITIAL_SDK_INT": "30"
}
EOF
cp -f /data/adb/modules_update/playintegrityfix/pif.json /data/adb/modules/playintegrityfix/pif.json 2>/dev/null; true'
echo "== restart exp container to activate (re-arms KSU/Zygisk here) =="
sudo docker restart "$C" >/dev/null
echo "== waiting for boot (up to 180s) =="
for i in $(seq 1 60); do
  b="$(dex 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r')"
  [ "$b" = "1" ] && { echo "booted"; break; }
  sleep 3
done
echo "== NOTE: fix DNS (single-home) + adb keys if they broke, then capture verdict =="
echo "== DONE. Revert: ksud module install the KOWX712 zip again =="
