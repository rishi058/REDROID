#!/usr/bin/env bash
#
# scope-probe-lspd.sh — enable + scope the dw26gate probe in LSPosed's DB.
#
# Runs in WSL as root. The probe is deployed as a system app by
# install-probe-system.sh, but LSPosed only LOADS a module that is also
# enabled and scoped to the target in /data/adb/lspd/config/modules_config.db.
# The clean-integrity test (DW_26_1.md section 6) removed the LSPosed manager and
# modules, which wiped that scope, so a redeployed system APK still never injects
# (empty module log, no [DW26Gate] lines) until this is repaired.
#
# The on-device sqlite3 is ABI-broken on this image, so it patches a COPY of the
# DB with the host's Python (rev-eng/mod_build/patch_lspd.py), copies it back
# while the container is stopped, and clears the stale WAL/SHM sidecars. A
# container start (Zygote reload) is required afterwards.
set -euo pipefail

CONTAINER=${CONTAINER:-redroid14}
REPO_ROOT=${REPO_ROOT:-/mnt/d/PROJECT/_TRASH/REDROID}
MODULE_PKG=${MODULE_PKG:-com.recon.dw26gate}
TARGET=${TARGET:-com.diskwalaapp}
APK_PATH=${APK_PATH:-/system/app/DW26Gate/base.apk}
PATCH=${PATCH:-$REPO_ROOT/rev-eng/mod_build/patch_lspd.py}

test -f "$PATCH"
data=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")
[[ -n "$data" && -d "$data/adb/lspd/config" ]] || { echo 'Cannot locate LSPosed config dir' >&2; exit 2; }
DB="$data/adb/lspd/config/modules_config.db"
test -f "$DB" || { echo "No modules_config.db at $DB" >&2; exit 2; }

echo "[scope] stopping $CONTAINER so the LSPosed DB is quiescent..."
docker stop -t 30 "$CONTAINER" >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cp "$DB" "$tmp/modules_config.db"

echo "[scope] patching a copy (enable + scope $MODULE_PKG -> $TARGET)..."
python3 "$PATCH" "$tmp/modules_config.db" "$MODULE_PKG" "$TARGET" "$APK_PATH"

echo "[scope] installing patched DB and clearing stale WAL/SHM..."
cp "$tmp/modules_config.db" "$DB"
rm -f "$DB-wal" "$DB-shm"
chown 0:0 "$DB"
chmod 0660 "$DB"
sync
echo "[scope] DONE. Start the container to reload Zygote:"
echo "        docker start $CONTAINER"
