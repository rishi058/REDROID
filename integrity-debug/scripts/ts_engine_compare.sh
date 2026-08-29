#!/system/bin/sh
# Compare TrickyStore/attestation engine + patch config. READ-ONLY.
echo "@@TS_MODULE_PROP"; cat /data/adb/modules/tricky_store/module.prop 2>/dev/null | grep -E 'name=|version'
echo "@@TS_DIR"; ls /data/adb/tricky_store/ 2>/dev/null | tr '\n' ' '; echo
echo "@@SECURITY_PATCH_TXT_BEGIN"; cat /data/adb/tricky_store/security_patch.txt 2>/dev/null; echo "@@SECURITY_PATCH_TXT_END"
echo "@@TEE_STATUS_BEGIN"; cat /data/adb/tricky_store/tee_status 2>/dev/null; echo "@@TEE_STATUS_END"
echo "@@PERSIST_KEYS $(ls /data/adb/tricky_store/persistent_keys 2>/dev/null | wc -l)"
echo "@@ENGINE_HINT boot_key=$( [ -f /data/adb/tricky_store/boot_key.bin ] && echo yes || echo no ) hbk=$( [ -f /data/adb/tricky_store/hbk ] && echo yes || echo no )"
echo "@@KEYSTORE2_INJECT"; K=$(pidof keystore2); [ -n "$K" ] && grep -Eio 'tricky|teesim|TEESimulator|libtee[a-z_]*\.so' /proc/$K/maps 2>/dev/null | sort -u
echo "@@PIF_PROP_BEGIN"; cat /data/adb/modules/playintegrityfix/pif.prop 2>/dev/null; echo "@@PIF_PROP_END"
echo "@@ALL_MODULES_BEGIN"; for m in /data/adb/modules/*/module.prop; do grep -H -E 'name=|version=' "$m" 2>/dev/null | head -2; done; echo "@@ALL_MODULES_END"
echo "@@DONE"
