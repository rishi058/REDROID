#!/usr/bin/env bash
#
# capture_vpngate.sh — capture every network endpoint an Android app contacts
# during launch, inside a Redroid container on the Oracle VPS, and save them
# to JSON.
#
# How it works:
#   1. tcpdump runs INSIDE the container (root via `docker exec`) on eth0 and
#      writes a pcap. Capturing at the container NIC sees all traffic even for
#      certificate-pinned HTTPS.
#   2. The app is force-stopped and launched via adb (over the local SSH tunnel
#      to 127.0.0.1:5559).
#   3. After DURATION seconds tcpdump is stopped, the pcap is parsed on the VPS
#      with tshark (parse_endpoints.py) into an endpoints JSON, and both the
#      pcap and JSON are copied back to ./out/.
#
# Endpoints are recovered from: DNS queries/answers, TLS ClientHello SNI,
# plaintext HTTP host/URL, and every outbound TCP/UDP destination IP:port.
#
# Prereqs: the SSH tunnel from VPS_access_guide.md must be up and
#          `adb connect 127.0.0.1:5559` must show the device.
#
# Usage:
#   ./capture_vpngate.sh                 # 30s capture of VPN Gate launch
#   ./capture_vpngate.sh 45              # custom duration (seconds)
#   PKG=com.other.app ./capture_vpngate.sh 30
#
set -euo pipefail

# ----------------------------- config --------------------------------------
KEY="${KEY:-C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key}"
VPS="${VPS:-ubuntu@141.148.151.172}"
CONTAINER="${CONTAINER:-redroid15-pixel8-oracle-rd15oracle20261004clone01}"
IFACE="${IFACE:-eth0}"
SERIAL="${SERIAL:-127.0.0.1:5559}"
PKG="${PKG:-com.giamping.sevpn}"          # VPN Gate
APP="${APP:-VPN Gate}"
ACTIVITY="${ACTIVITY:-com.giamping.sevpn/.ActivityMain}"  # launcher component
DURATION="${1:-30}"                         # seconds to watch the launch

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="vpngate-$STAMP"
REMOTE_PCAP="/data/local/tmp/${BASE}.pcap"   # path inside the container
VPS_PCAP="/tmp/${BASE}.pcap"                  # path on the VPS host
VPS_JSON="/tmp/${BASE}.json"

mkdir -p "$OUT_DIR"

# access.py wraps privileged/ssh commands so they show up in the approval
# middleware. Fall back to raw ssh/scp if it isn't present.
ACCESS="python $SCRIPT_DIR/../access.py -q"
ssh_vps()  { $ACCESS ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS" "$@"; }
scp_down() { $ACCESS scp -i "$KEY" -o StrictHostKeyChecking=no "$VPS:$1" "$2"; }

echo ">> target: $APP ($PKG) on $SERIAL"
echo ">> container: $CONTAINER  iface: $IFACE  duration: ${DURATION}s"

# ----------------------------- preflight ------------------------------------
if ! adb -s "$SERIAL" get-state >/dev/null 2>&1; then
    echo "!! adb device $SERIAL not connected. Start the SSH tunnel and run:"
    echo "   adb connect $SERIAL"
    exit 1
fi

# ----------------------------- capture --------------------------------------
echo ">> starting tcpdump in container ..."
ssh_vps "sudo docker exec $CONTAINER pkill -f tcpdump || true"   # clear any stale run
ssh_vps "sudo docker exec -d $CONTAINER /system/bin/tcpdump -i $IFACE -s 0 -U -w $REMOTE_PCAP 'not port 5555'"
sleep 2   # let tcpdump bind before we generate traffic

echo ">> force-stopping and launching $PKG ..."
adb -s "$SERIAL" shell am force-stop "$PKG" || true
sleep 1
START_EPOCH="$(date +%s)"
# `am start` is more reliable than monkey and its non-zero warnings are ignored.
adb -s "$SERIAL" shell am start -n "$ACTIVITY" \
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER || true

echo ">> capturing launch traffic for ${DURATION}s ..."
sleep "$DURATION"

echo ">> stopping tcpdump ..."
ssh_vps "sudo docker exec $CONTAINER pkill -f tcpdump || true"
sleep 1

# ----------------------------- parse ----------------------------------------
echo ">> copying pcap out of container and parsing on VPS ..."
# Upload the parser (idempotent) and run it against the pcap on the VPS.
$ACCESS scp -i "$KEY" -o StrictHostKeyChecking=no \
    "$SCRIPT_DIR/parse_endpoints.py" "$VPS:/tmp/parse_endpoints.py"
LOCAL_IP="$(ssh_vps "sudo docker exec $CONTAINER ip -o -4 addr show $IFACE | awk '{print \$4}' | cut -d/ -f1" | tr -d '\r')"
echo ">> container $IFACE ip: ${LOCAL_IP:-unknown}"
ssh_vps "sudo docker cp $CONTAINER:$REMOTE_PCAP $VPS_PCAP && sudo chmod 644 $VPS_PCAP \
         && python3 /tmp/parse_endpoints.py $VPS_PCAP \
              --package '$PKG' --app '$APP' --started $START_EPOCH --duration $DURATION \
              --local-ip '$LOCAL_IP' \
              > $VPS_JSON && echo '   parsed OK'"
ssh_vps "sudo docker exec $CONTAINER rm -f $REMOTE_PCAP || true"

# ----------------------------- fetch ----------------------------------------
echo ">> downloading results to $OUT_DIR ..."
scp_down "$VPS_JSON"  "$OUT_DIR/${BASE}.json"
scp_down "$VPS_PCAP"  "$OUT_DIR/${BASE}.pcap"
ssh_vps "sudo rm -f $VPS_JSON $VPS_PCAP"   # pcap is root-owned (docker cp)

# stable "latest" copy
cp "$OUT_DIR/${BASE}.json" "$OUT_DIR/vpngate-endpoints.latest.json"

echo
echo ">> DONE"
echo "   JSON: $OUT_DIR/${BASE}.json"
echo "   PCAP: $OUT_DIR/${BASE}.pcap"
echo "   (latest: $OUT_DIR/vpngate-endpoints.latest.json)"
