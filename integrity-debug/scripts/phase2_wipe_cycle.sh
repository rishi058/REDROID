#!/usr/bin/env bash
# Phase 2 - Play Store certification wipe cycle. exp ONLY.
# Clears ONLY com.android.vending (never GMS, never app_dg_cache). Loops N times.
# For the "Device is certified" banner (cached; FAQ Q11 needs repeated wipes).
set -uo pipefail
C="$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid-experimental' | head -n1)"
[ -z "$C" ] && { echo "exp not running"; exit 1; }
dex() { sudo docker exec "$C" sh -c "$*"; }
N="${1:-3}"
echo "== GUARD: confirm we target exp only ($C) =="
for i in $(seq 1 "$N"); do
  echo "-- cycle $i/$N: pm clear com.android.vending --"
  dex 'pm clear com.android.vending'
  sleep 3
  echo "-- reopen Play Store, let it settle --"
  dex 'am start -n com.android.vending/com.google.android.finsky.activities.MainActivity >/dev/null 2>&1'
  sleep 20
done
echo "== current certification state (best-effort from Finsky prefs) =="
dex 'run-as com.android.vending cat /data/data/com.android.vending/shared_prefs/finsky.xml 2>/dev/null | grep -io "certif[^<]*" | head || echo "(prefs not readable; check UI: Play Store > Settings > About > Play Protect certification)"'
echo "== DONE (do NOT clear GMS data; that resets GSF and establishment) =="
