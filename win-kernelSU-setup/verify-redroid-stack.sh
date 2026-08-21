#!/usr/bin/env bash
# Wait for redroid14 to boot after a WSL restart, then report root-stack +
# GApps status. Safe to run repeatedly.
set -u
CONTAINER=${CONTAINER:-redroid14}

systemctl start docker 2>/dev/null || true
sleep 4
docker start "$CONTAINER" >/dev/null 2>&1 || true

echo "waiting for boot..."
b=""
for _ in $(seq 1 30); do
  b=$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  if [ "$b" = "1" ]; then break; fi
  sleep 5
done
echo "boot=$b"

echo "=== root stack (persistence) ==="
docker exec "$CONTAINER" sh -c 'ps -A | grep -iE "zygisk|lspd|nsdaemon|tricky"' 2>/dev/null | head
docker exec "$CONTAINER" su -c id 2>/dev/null || true

echo "=== device identity (Pixel 5) ==="
for p in ro.product.model ro.product.manufacturer ro.product.device ro.product.brand \
         ro.build.fingerprint ro.build.tags ro.build.type \
         ro.boot.verifiedbootstate ro.boot.flash.locked; do
  printf '%s = %s\n' "$p" "$(docker exec "$CONTAINER" getprop "$p" 2>/dev/null | tr -d '\r')"
done

echo "=== TrickyStore ==="
docker exec "$CONTAINER" ls -la /data/adb/tricky_store/ 2>/dev/null
docker exec "$CONTAINER" sh -c 'logcat -d 2>/dev/null | grep -iE "TrickyStore|tricky_store|TS_" | tail -8' 2>/dev/null || true

echo "=== mindthegapps module ==="
docker exec "$CONTAINER" ls -la /data/adb/modules/mindthegapps 2>/dev/null | head
docker exec "$CONTAINER" sh -c 'mount | grep -iE "product|system_ext"' 2>/dev/null | head

echo "=== gapps packages ==="
docker exec "$CONTAINER" pm list packages 2>/dev/null | grep -iE "vending|com.google.android.gms|com.google.android.gsf|googlequicksearchbox"
