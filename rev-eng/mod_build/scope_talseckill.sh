#!/system/bin/sh
DB=/data/adb/lspd/config/modules_config.db
PKG=com.recon.talsecbypass
sqlite3 "$DB" "UPDATE modules SET enabled=1 WHERE module_pkg_name='$PKG';"
sqlite3 "$DB" "INSERT OR IGNORE INTO scope(mid,app_pkg_name,user_id) SELECT mid,'com.target-appapp',0 FROM modules WHERE module_pkg_name='$PKG';"
echo "=== enabled modules ==="; sqlite3 "$DB" "SELECT mid,enabled,module_pkg_name FROM modules WHERE enabled=1;"
echo "=== scope for com.target-appapp ==="; sqlite3 "$DB" "SELECT m.module_pkg_name FROM scope s JOIN modules m ON s.mid=m.mid WHERE s.app_pkg_name='com.target-appapp';"
