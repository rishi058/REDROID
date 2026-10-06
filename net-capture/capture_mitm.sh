#!/usr/bin/env bash
#
# capture_mitm.sh — full decrypting MITM capture of an app's launch traffic.
#
# Same technique used for DiskWala: mitmdump on the host, reached from the
# device via `adb reverse` + the Android global HTTP proxy, with mitmproxy's CA
# already trusted in the device system store. Every request/response is written
# with full headers + bodies + timings to JSON by the proven
# rev-eng/network-tools/capture-live-networks.py addon.
#
# Unlike capture_vpngate.sh (tcpdump endpoint inventory), this DECRYPTS TLS, so
# you get URLs, request/response headers and bodies — not just hostnames.
#
# Prereqs:
#   - SSH tunnel up + `adb connect 127.0.0.1:5559` (see ../VPS_access_guide.md)
#   - mitmproxy installed locally (`mitmdump --version`)
#   - mitmproxy CA (hash c8750f0d) trusted on the device. Check:
#       MSYS_NO_PATHCONV=1 adb -s 127.0.0.1:5559 shell ls \
#         /apex/com.android.conscrypt/cacerts/c8750f0d.0
#     If missing, install it with ./install_ca.sh first.
#
# Usage:
#   ./capture_mitm.sh                 # 35s decrypting capture of VPN Gate launch
#   ./capture_mitm.sh 60              # custom window (seconds)
#   PKG=com.x APP=X ACTIVITY=com.x/.Main ./capture_mitm.sh 40
#
set -euo pipefail
export MSYS_NO_PATHCONV=1   # keep Git Bash from mangling Android /paths

SERIAL="${SERIAL:-127.0.0.1:5559}"
PKG="${PKG:-com.giamping.sevpn}"
APP="${APP:-VPN Gate}"
ACTIVITY="${ACTIVITY:-com.giamping.sevpn/.ActivityMain}"
PORT="${PORT:-8080}"
DURATION="${1:-35}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON="$SCRIPT_DIR/../rev-eng/network-tools/capture-live-networks.py"
OUT_DIR="$SCRIPT_DIR/out"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/vpngate-mitm-$STAMP.json"
LOG="$OUT_DIR/vpngate-mitm-$STAMP.mitmlog"
mkdir -p "$OUT_DIR"

# mitmdump is a Windows python app; hand it Windows-style (mixed) paths.
winpath() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
WIN_ADDON="$(winpath "$ADDON")"
WIN_OUT="$(winpath "$OUT")"

echo ">> target : $APP ($PKG)  device $SERIAL"
echo ">> window : ${DURATION}s   proxy port $PORT"
echo ">> output : $OUT"

if ! adb -s "$SERIAL" get-state >/dev/null 2>&1; then
    echo "!! device $SERIAL not connected — start the tunnel + adb connect."; exit 1
fi
if ! MSYS_NO_PATHCONV=1 adb -s "$SERIAL" shell ls /apex/com.android.conscrypt/cacerts/c8750f0d.0 >/dev/null 2>&1; then
    echo "!! mitmproxy CA (c8750f0d) not trusted on device. Run ./install_ca.sh"; exit 1
fi

# ---- route device traffic to host mitmdump via adb reverse + global proxy ----
OLD_PROXY="$(adb -s "$SERIAL" shell settings get global http_proxy | tr -d '\r')"
echo ">> previous global proxy: ${OLD_PROXY:-<none>}"
adb -s "$SERIAL" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
adb -s "$SERIAL" shell settings put global http_proxy "127.0.0.1:$PORT"

cleanup() {
    echo ">> restoring device proxy ..."
    local cur
    cur="$(adb -s "$SERIAL" shell settings get global http_proxy | tr -d '\r')"
    if [ "$cur" = "127.0.0.1:$PORT" ]; then
        if [ -n "$OLD_PROXY" ] && [ "$OLD_PROXY" != "null" ] && [ "$OLD_PROXY" != ":0" ]; then
            adb -s "$SERIAL" shell settings put global http_proxy "$OLD_PROXY" || true
        else
            adb -s "$SERIAL" shell settings delete global http_proxy || true
        fi
    fi
    adb -s "$SERIAL" reverse --remove "tcp:$PORT" 2>/dev/null || true
    [ -n "${MPID:-}" ] && kill "$MPID" 2>/dev/null || true
}
trap cleanup EXIT

# ---- start mitmdump (decrypting proxy) in the background --------------------
echo ">> starting mitmdump ..."
mitmdump --listen-host 127.0.0.1 --listen-port "$PORT" \
    --set block_global=false \
    --set "capture_json=$WIN_OUT" \
    -s "$WIN_ADDON" >"$LOG" 2>&1 &
MPID=$!
sleep 3
if ! kill -0 "$MPID" 2>/dev/null; then
    echo "!! mitmdump failed to start — see $LOG"; tail -20 "$LOG"; exit 1
fi

# ---- launch the app and capture --------------------------------------------
echo ">> force-stopping + launching $PKG ..."
adb -s "$SERIAL" shell am force-stop "$PKG" || true
sleep 1
adb -s "$SERIAL" shell am start -n "$ACTIVITY" \
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER || true

echo ">> capturing for ${DURATION}s (decrypting TLS) ..."
sleep "$DURATION"

echo ">> stopping mitmdump ..."
kill "$MPID" 2>/dev/null || true
wait "$MPID" 2>/dev/null || true
MPID=""

# ---- report -----------------------------------------------------------------
cp "$OUT" "$OUT_DIR/vpngate-mitm.latest.json" 2>/dev/null || true
echo
echo ">> DONE"
if [ -f "$OUT" ]; then
    python - "$(winpath "$OUT")" <<'PY'
import json, sys
flows = json.load(open(sys.argv[1], encoding="utf-8"))
hosts = {}
for f in flows:
    h = (f.get("request") or {}).get("host") or f.get("url", "")
    hosts[h] = hosts.get(h, 0) + 1
print(f"   flows captured : {len(flows)}")
print(f"   unique hosts   : {len(hosts)}")
for h, n in sorted(hosts.items(), key=lambda x: -x[1]):
    print(f"     {n:4d}  {h}")
PY
fi
echo "   JSON: $OUT"
echo "   log : $LOG"
