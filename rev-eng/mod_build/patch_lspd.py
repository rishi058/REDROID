#!/usr/bin/env python3
"""patch_lspd.py — HOST-side repair of TalsecKill's LSPosed registration.

Does the same three things as fix_lspd_scope.sh (enable the module, rewrite its
stored apk_path, ensure the target-app scope row) but runs OFF the device using
the host's Python sqlite3 against a COPY of the database.

Why a host-side patcher is needed on ReDroid + KernelSU:
  1. The container's /system/bin/sqlite3 is ABI-broken and core-dumps
     ("Aborted") on this image, so fix_lspd_scope.sh cannot run in-container.
  2. The `adb shell` user has zero effective capabilities (CapEff=0) and cannot
     read /data/adb, so it cannot reach the DB either.
The workflow that avoids both problems (run from the VPS host):
     sudo docker cp <ctr>:/data/adb/lspd/config/modules_config.db /tmp/db
     sudo python3 patch_lspd.py /tmp/db com.recon.talsecbypass com.target-appapp "<apk_path>"
     sudo docker cp /tmp/db <ctr>:/data/adb/lspd/config/modules_config.db
     # then remove the container's stale -wal/-shm sidecars and reboot the host

WAL caveat: copy out (and patch) the whole config/ dir, or delete the stale
modules_config.db-wal / -shm inside the container after copying the patched .db
back. Python commits+checkpoints on close, so the copied-out .db is a lone,
consistent file; leaving old sidecars beside it makes SQLite refuse writes.

Arguments:
  db_path      path to the (copied-out) modules_config.db
  module_pkg   LSPosed module package    (com.recon.talsecbypass)
  target_pkg   app to scope the module to (com.target-appapp placeholder)
  apk_path     current on-device APK path (from `pm path <module_pkg>`)

Idempotent: safe to re-run. Inserts a module row if none exists, updates
enabled+apk_path, adds the scope row only when missing, and prints verification.
A host reboot (Zygote restart) is still required for LSPosed to load the module.

Usage: python3 patch_lspd.py <db_path> <module_pkg> <target_pkg> <apk_path>
"""
import sqlite3
import sys

db_path   = sys.argv[1]
mod_pkg   = sys.argv[2]   # com.recon.talsecbypass
target    = sys.argv[3]   # com.target-appapp
apk_path  = sys.argv[4]   # from pm path

con = sqlite3.connect(db_path)
cur = con.cursor()

# Show tables for sanity
cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
print("tables:", [r[0] for r in cur.fetchall()])

# Get current module row
cur.execute("SELECT mid, enabled, apk_path FROM modules WHERE module_pkg_name=?", (mod_pkg,))
row = cur.fetchone()
if row is None:
    print("ERROR: module not found in DB — inserting new row")
    cur.execute("INSERT INTO modules(module_pkg_name, apk_path, enabled) VALUES(?,?,1)", (mod_pkg, apk_path))
    con.commit()
    cur.execute("SELECT mid, enabled, apk_path FROM modules WHERE module_pkg_name=?", (mod_pkg,))
    row = cur.fetchone()

mid = row[0]
print(f"module: mid={mid} enabled={row[1]} apk={row[2]}")

# Update enabled + apk_path
cur.execute("UPDATE modules SET enabled=1, apk_path=? WHERE module_pkg_name=?", (apk_path, mod_pkg))
print(f"updated {cur.rowcount} row(s)")

# Ensure scope
cur.execute("SELECT 1 FROM scope WHERE mid=? AND app_pkg_name=? AND user_id=0", (mid, target))
if cur.fetchone() is None:
    cur.execute("INSERT INTO scope(mid, app_pkg_name, user_id) VALUES(?,?,0)", (mid, target))
    print(f"inserted scope: {target}")
else:
    print(f"scope already exists: {target}")

con.commit()

# Verify
cur.execute("SELECT mid, enabled, apk_path FROM modules WHERE module_pkg_name=?", (mod_pkg,))
print("verified modules:", cur.fetchone())
cur.execute("SELECT app_pkg_name FROM scope s JOIN modules m ON s.mid=m.mid WHERE m.module_pkg_name=?", (mod_pkg,))
print("verified scope:", [r[0] for r in cur.fetchall()])

con.close()
print("DONE")
