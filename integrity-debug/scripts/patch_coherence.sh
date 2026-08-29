#!/system/bin/sh
# Compare identity + security_patch coherence. READ-ONLY.
echo "@@GLOBAL_PATCH $(getprop ro.build.version.security_patch)"
echo "@@FP $(getprop ro.build.fingerprint)"
echo "@@VENDOR_PATCH $(getprop ro.vendor.build.security_patch)"
echo "@@TS_PATCH_BEGIN"; cat /data/adb/tricky_store/security_patch.txt 2>/dev/null; echo "@@TS_PATCH_END"
echo "@@PIF_PATCH $(grep -i security_patch /data/adb/modules/playintegrityfix/pif.prop 2>/dev/null)"
echo "@@REDROID_PIXEL5_BEGIN"
for f in /data/adb/modules/redroid_pixel5/system.prop /data/adb/modules/redroid_pixel5/post-fs-data.sh /data/adb/modules/redroid_pixel5/service.sh /data/adb/modules/redroid_pixel5/module.prop; do
  [ -f "$f" ] && { echo "----- $f -----"; cat "$f"; }
done
echo "@@REDROID_PIXEL5_END"
echo "@@DONE"
