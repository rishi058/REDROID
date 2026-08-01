#!/bin/sh
#
# fix_lspd_scope.sh — repair TalsecKill's LSPosed registration after a reinstall.
#
# Runs ON the device/ReDroid container as root (KernelSU shell, or via
# `docker exec`). It is the superset of scope_talseckill.sh: besides enabling the
# module and scoping it to the target app, it also rewrites the module's stored
# `apk_path`.
#
# Why the apk_path rewrite matters:
#   LSPosed's modules_config.db caches an ABSOLUTE path to the module APK
#   (e.g. /data/app/~~<rand>/com.recon.talsecbypass-<rand>/base.apk). Every
#   `adb install -r` randomizes both directory segments, so the path recorded at
#   first install goes stale. LSPosed then finds the row enabled+scoped but the
#   file missing, and silently fails to load the module — no hook, no log line,
#   and the app behaves as if TalsecKill were absent. This script re-resolves the
#   live path with `pm path` and writes it back, which is the usual reason a
#   freshly-rebuilt module "installs fine" yet never injects.
#
# What it does (all against /data/adb/lspd/config/modules_config.db):
#   1. Resolve the current APK path via `pm path` (aborts if the module is absent).
#   2. UPDATE modules: set enabled=1 and apk_path to the live path.
#   3. INSERT OR IGNORE a scope row for the target app, Android user 0.
#   4. Print the resulting module + scope rows for verification.
#
# Requirements: root, and a WORKING on-device `sqlite3`. Some ReDroid images ship
# an ABI-broken /system/bin/sqlite3 that core-dumps ("Aborted"); when that
# happens, use patch_lspd.py from the host instead.
#
# TARGET uses the com.target-appapp placeholder (same convention as
# scope_talseckill.sh / Hook.java); build_module.sh substitutes the real package
# at deploy time. A Zygote restart (host reboot) is still required afterwards for
# LSPosed to load the module into a fresh process.
#
# Usage (on device):   sh fix_lspd_scope.sh
set -e

DB=/data/adb/lspd/config/modules_config.db
PKG=com.recon.talsecbypass
TARGET=com.target-appapp

echo "[fix_lspd] resolving apk path..."
NEW_PATH=$(pm path "$PKG" | sed 's/package://')
if [ -z "$NEW_PATH" ]; then
  echo "[fix_lspd] ERROR: pm path returned empty — is $PKG installed?"
  exit 1
fi
echo "[fix_lspd] apk path: $NEW_PATH"

echo "[fix_lspd] updating modules table..."
sqlite3 "$DB" "UPDATE modules SET enabled=1, apk_path='$NEW_PATH' WHERE module_pkg_name='$PKG';"

echo "[fix_lspd] ensuring scope entry..."
sqlite3 "$DB" "INSERT OR IGNORE INTO scope(mid, app_pkg_name, user_id) SELECT mid, '$TARGET', 0 FROM modules WHERE module_pkg_name='$PKG';"

echo "[fix_lspd] --- verification ---"
echo "[fix_lspd] modules:"
sqlite3 "$DB" "SELECT mid, enabled, apk_path FROM modules WHERE module_pkg_name='$PKG';"

echo "[fix_lspd] scope:"
sqlite3 "$DB" "SELECT app_pkg_name FROM scope s JOIN modules m ON s.mid=m.mid WHERE m.module_pkg_name='$PKG';"

echo "[fix_lspd] DONE"
