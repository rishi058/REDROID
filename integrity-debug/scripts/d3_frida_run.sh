#!/usr/bin/env bash
# Phase D.3 - push frida-server into exp and attach the DroidGuard tracer. exp ONLY.
# Prereq: frida-server-<ver>-android-arm64 present on VPS at $FS (download matching your
#   local `frida --version`). Run this on the VPS: bash -s < d3_frida_run.sh
# Needs the tracer JS on the VPS too (scp scripts/d3_frida_trace.js first).
set -uo pipefail
C="$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid-experimental' | head -n1)"
FS="${FS:-$HOME/frida-server-arm64}"
JS="${JS:-$HOME/d3_frida_trace.js}"
[ -z "$C" ] && { echo "exp not running"; exit 1; }
[ -f "$FS" ] || { echo "frida-server binary not found at $FS (download the android-arm64 build matching your frida client)"; exit 1; }

echo "== pushing frida-server =="
sudo docker cp "$FS" "$C:/data/local/tmp/frida-server"
sudo docker exec "$C" sh -c 'chmod 755 /data/local/tmp/frida-server'
echo "== starting frida-server (root) =="
sudo docker exec -d "$C" sh -c '/data/local/tmp/frida-server &'
sleep 2
echo "== NOTE: DroidGuard runs in an ISOLATED, short-lived process =="
echo "Trigger an integrity check, then from a machine with frida + this container's adb:"
echo "  frida -U -n com.google.android.gms.unstable -l d3_frida_trace.js --runtime=v8"
echo "Or spawn-follow gmscore. frida-server is now running in exp; JS at $JS."
