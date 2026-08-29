#!/usr/bin/env bash
# Phase 0 - READ-ONLY state assessment of exp (full) + prod (summary).
# Runs ON the VPS. Pipe to: ssh ubuntu@host 'bash -s'
# Makes NO changes. Safe on the shared host.
set -uo pipefail

resolve() { sudo docker ps -q --filter "label=coolify.serviceName=$1" | head -n1; }
dex() { local c="$1"; shift; sudo docker exec "$c" sh -c "$*" 2>/dev/null; }

gsf_id() {
  local c="$1" tmp; tmp="$(mktemp -d)"
  sudo docker cp "$c:/data/data/com.google.android.gsf/databases/gservices.db" "$tmp/g.db" >/dev/null 2>&1 \
    || { echo "NO_DB"; rm -rf "$tmp"; return; }
  python3 - "$tmp/g.db" <<'PY'
import sqlite3,sys
try:
    con=sqlite3.connect(sys.argv[1]); cur=con.cursor()
    cur.execute("select value from main where name='android_id'")
    r=cur.fetchone(); v=int(r[0]) if r and r[0] else 0
    print(f"{v} (hex {v:016x})")
except Exception as e:
    print("ERR",e)
PY
  rm -rf "$tmp"
}

report() { # $1 = serviceName  $2 = full|summary
  local name="$1" mode="$2" c; c="$(resolve "$name")"
  echo "================ $name  ($c) ================"
  [ -z "$c" ] && { echo "  NOT RUNNING"; return; }
  echo "-- uptime --"; sudo docker ps --filter "id=$c" --format '{{.Status}}'
  echo "-- identity --"
  dex "$c" 'getprop ro.build.fingerprint; getprop ro.product.model; getprop ro.build.version.security_patch; getprop ro.product.cpu.abi; getprop ro.hardware; echo secure=$(getprop ro.secure) debuggable=$(getprop ro.debuggable) boot=$(getprop sys.boot_completed)'
  echo "-- modules (ksud) --"
  dex "$c" '/data/adb/ksud module list 2>/dev/null | grep -Ei "id=|enabled|name=" || ls /data/adb/modules'
  echo "-- PIF injected into gms.unstable? --"
  dex "$c" 'P=$(pidof com.google.android.gms.unstable); echo pid=$P; [ -n "$P" ] && grep -Ec "playintegrity" /proc/$P/maps'
  echo "-- attestation injected into keystore2? --"
  dex "$c" 'P=$(pidof keystore2); echo pid=$P; [ -n "$P" ] && grep -Eio "teesim|tricky|TEESimulator|libteesim[a-z_]*\.so" /proc/$P/maps | sort -u'
  echo "-- keybox sha256 (path only, never contents) --"
  dex "$c" 'for f in /data/adb/tricky_store/keybox.xml /data/adb/teesim/keybox.xml; do [ -f "$f" ] && (echo -n "$f "; sha256sum "$f" | cut -d" " -f1); done'
  echo "-- tricky_store target.txt --"
  dex "$c" 'cat /data/adb/tricky_store/target.txt 2>/dev/null'
  echo "-- GSF android_id --"; gsf_id "$c"
  echo "-- signed-in Google accounts --"
  dex "$c" 'dumpsys account 2>/dev/null | grep -Eo "name=[^,}]*com.google[^,}]*|Account \{name=[^,]*" | head -5'
  echo "-- http_proxy / eth0 --"
  dex "$c" 'echo proxy=$(settings get global http_proxy); ip -o -4 addr show eth0 2>/dev/null | awk "{print \$2, \$4}"'
  echo "-- app_dg_cache present (DroidGuard VM) --"
  dex "$c" 'ls -d /data/data/com.google.android.gms/app_dg_cache 2>/dev/null && echo PRESENT || echo MISSING'
  if [ "$mode" = full ]; then
    echo "-- GMS / Finsky versions --"
    dex "$c" 'for p in com.google.android.gms com.android.vending; do echo -n "$p "; dumpsys package $p 2>/dev/null | grep -m1 versionName; done'
    echo "-- integrity checker installed? --"
    dex "$c" 'pm list packages 2>/dev/null | grep -Ei "integritycheck|integrity" '
  fi
  echo
}

report redroid-experimental full
report redroid14 summary
echo "===== ASSESSMENT COMPLETE ====="
