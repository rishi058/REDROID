#!/usr/bin/env bash
#
# install_ca.sh — trust the mitmproxy CA in the device system store.
#
# On the production redroid (5559) the shell user cannot `su`, so the install
# script is run as root via `docker exec` on the VPS (same root path the rest
# of this project uses). Reuses rev-eng/network-tools/install_cert.sh and the
# generated certs/c8750f0d.0.
#
set -euo pipefail
export MSYS_NO_PATHCONV=1

KEY="${KEY:-C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key}"
VPS="${VPS:-ubuntu@141.148.151.172}"
CONTAINER="${CONTAINER:-redroid15-pixel8-oracle-rd15oracle20261004clone01}"
SERIAL="${SERIAL:-127.0.0.1:5559}"
HASH=c8750f0d

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NT="$SCRIPT_DIR/../rev-eng/network-tools"
ACCESS="python $SCRIPT_DIR/../access.py -q"

# Generate the hashed CA file from the local mitmproxy CA if absent.
if [ ! -s "$NT/certs/$HASH.0" ]; then
    cp ~/.mitmproxy/mitmproxy-ca-cert.pem "$NT/certs/$HASH.0"
fi

echo ">> pushing CA + installer to device ..."
adb -s "$SERIAL" push "$NT/certs/$HASH.0" "/data/local/tmp/$HASH.0" >/dev/null
adb -s "$SERIAL" push "$NT/install_cert.sh" "/data/local/tmp/install_cert.sh" >/dev/null

echo ">> running installer as root (docker exec) ..."
$ACCESS ssh -i "$KEY" -o StrictHostKeyChecking=no "$VPS" \
    "sudo docker exec $CONTAINER sh /data/local/tmp/install_cert.sh"

echo ">> verifying ..."
MSYS_NO_PATHCONV=1 adb -s "$SERIAL" shell ls -la \
    "/apex/com.android.conscrypt/cacerts/$HASH.0" \
    "/system/etc/security/cacerts/$HASH.0" 2>&1 || true
echo ">> done"
