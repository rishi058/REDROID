#!/system/bin/sh
# READ-ONLY: inspect LSPosed state + enabled modules + their scope (esp. GMS/DroidGuard).
echo "@@LSPD_RUNNING pid=$(pidof lspd 2>/dev/null)"
echo "@@ZYGISK_LSPOSED_MODULE"; cat /data/adb/modules/zygisk_lsposed/module.prop 2>/dev/null | grep -E 'name=|version'
echo "@@LSPD_TREE"; ls -laR /data/adb/lspd 2>/dev/null | grep -Ev '^total|^d.*\s\.$|^d.*\s\.\.$' | head -60
echo "@@DBS"; find /data/adb/lspd /data/misc 2>/dev/null -name '*.db' | grep -iE 'lsp|module|config' | head
echo "@@INSTALLED_XPOSED_ISH"; pm list packages -f 2>/dev/null | grep -iE 'xposed|lsposed|pif|integrity|tricky|safetynet|hidemy|shamiko|hma|playintegrit'
# dump likely LSPosed config db(s) with strings (sqlite3 not in container)
for db in /data/adb/lspd/config/modules_config.db /data/adb/lspd/config/*.db; do
  [ -f "$db" ] || continue
  echo "=== strings $db (packages / enable / scope) ==="
  strings "$db" 2>/dev/null | grep -iE '^com\.|^org\.|^de\.|enable|scope|mid|apk' | sort -u | head -60
done
echo "@@DONE"
