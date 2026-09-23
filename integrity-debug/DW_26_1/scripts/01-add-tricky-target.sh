#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-redroid14}
TARGET_PACKAGE=${TARGET_PACKAGE:-com.diskwalaapp}
TARGET_FILE=${TARGET_FILE:-/data/adb/tricky_store/target.txt}

[[ "$TARGET_PACKAGE" == com.diskwalaapp ]] || {
  echo "Unexpected target package: $TARGET_PACKAGE" >&2; exit 2;
}

ready=0
for _ in $(seq 1 60); do
  [[ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" == 1 ]] && { ready=1; break; }
  sleep 2
done
[[ "$ready" == 1 ]] || { echo 'Android is not ready; no change made' >&2; exit 2; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="${TARGET_FILE}.before-diskwala-${stamp}"
docker exec -e TARGET_PACKAGE="$TARGET_PACKAGE" -e TARGET_FILE="$TARGET_FILE" -e BACKUP="$backup" \
  "$CONTAINER" /system/bin/sh -c '
set -e
test -f "$TARGET_FILE"
if grep -Eq "^[[:space:]]*com[.]diskwalaapp[!?]?[[:space:]]*$" "$TARGET_FILE"; then
  echo "DiskWala already exists; preserving its configured mode"
else
  test ! -e "$BACKUP"
  cp -p "$TARGET_FILE" "$BACKUP"
  printf "\n%s!\n" "$TARGET_PACKAGE" >> "$TARGET_FILE"
  echo "Added $TARGET_PACKAGE!"
  echo "Rollback: $BACKUP"
fi
cat "$TARGET_FILE"
'

echo 'Restart DiskWala and verify real attest/verify returns HTTP 200.'
