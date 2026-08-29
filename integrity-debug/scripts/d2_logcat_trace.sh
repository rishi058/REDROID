#!/usr/bin/env bash
# Phase D.2 - logcat trace around a fresh integrity request. exp ONLY.
# Pipe over ssh: ssh ubuntu@host 'bash -s'
# READ-ONLY (only force-stops GMS/checker to trigger a fresh request).
set -uo pipefail
C="$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid-experimental' | head -n1)"
[ -z "$C" ] && { echo "exp not running"; exit 1; }
dex() { sudo docker exec "$C" sh -c "$*"; }

TAGS='DroidGuard|GmsCore|Finsky|Integrity|integrity|keystore|Keymaster|KeyMint|TEESimulator|tricky|Auth|CheckinService|PlayProtect|Vending|DeviceIntegrity|attest'

echo "== clearing logcat buffer =="
dex 'logcat -c'
echo "== triggering a fresh integrity request (checker) =="
dex 'am force-stop com.google.android.gms; am force-stop gr.nikolasspyr.integritycheck; sleep 2; am start -n gr.nikolasspyr.integritycheck/.MainActivity >/dev/null 2>&1'
echo "== capturing 25s of filtered logcat =="
dex "timeout 25 logcat -v time | grep -EI '$TAGS'" | sed 's/  */ /g' | tail -n 200
echo "== recent tombstones / ANR =="
dex 'ls -t /data/tombstones 2>/dev/null | head -3; ls -t /data/anr 2>/dev/null | head -3'
echo "== DONE =="
