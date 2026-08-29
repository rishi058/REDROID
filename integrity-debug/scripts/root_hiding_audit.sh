#!/system/bin/sh
# Root-hiding / SUSFS audit. READ-ONLY. Run as ROOT inside android:
#   adb -s <serial> shell su -c 'sh -s' < root_hiding_audit.sh
# Compares what makes a device hide root from Google's DroidGuard.
echo "@@UNAME $(uname -r)"
KSUD=$(ls /data/adb/ksu/bin/ksud 2>/dev/null | head -1)
[ -z "$KSUD" ] && KSUD=$(command -v ksud 2>/dev/null)
[ -z "$KSUD" ] && KSUD=/data/adb/ksud
echo "@@KSUD $KSUD $($KSUD -V 2>/dev/null | head -1)"
KSU_SUSFS=$(ls /data/adb/ksu/bin/ksu_susfs 2>/dev/null | head -1)
echo "@@KSU_SUSFS_BIN $KSU_SUSFS"

echo "== SUSFS =="
echo "@@SUSFS_SUPPORT $($KSUD susfs support 2>&1)"
echo "@@SUSFS_VERSION $($KSUD susfs version 2>&1)"
echo "@@SUSFS_VARIANT $($KSUD susfs variant 2>&1)"
echo "@@SUSFS_FEATURES_BEGIN"; $KSUD susfs features 2>&1; echo "@@SUSFS_FEATURES_END"
echo "@@SUSFS_DMESG_BEGIN"; dmesg 2>/dev/null | grep -iE 'susfs|sus_' | tail -6; echo "@@SUSFS_DMESG_END"
echo "@@SUSFS_FILES"; ls -la /data/adb/susfs* /data/adb/ksu/susfs* 2>/dev/null

echo "== KernelSU manager package (hidden/repackaged?) =="
echo "@@MANAGER_BEGIN"; pm list packages 2>/dev/null | grep -Ei "kernelsu|sukisu|apatch|magisk|weishu|rifsxd|5ec1cff|zako|bear" ; echo "@@MANAGER_END"

echo "== su allowlist / granted apps =="
echo "@@KSU_DIR"; ls -la /data/adb/ksu 2>/dev/null | head -40
# KernelSU-Next stores grants in a sqlite or binary allowlist; try to read package grants
echo "@@GRANTS_BEGIN"
for db in /data/adb/ksu/*.db /data/adb/ksu/db/* ; do [ -f "$db" ] && { echo "db=$db"; strings "$db" 2>/dev/null | grep -Ei "com\.(google|android)" | sort -u | head -40; }; done
echo "@@GRANTS_END"

echo "== are Google apps granted root? (should be NO) =="
echo "@@GOOGLE_UIDS_BEGIN"
for p in com.google.android.gms com.google.android.gsf com.android.vending com.google.android.gms.unstable; do
  u=$(stat -c %u /data/data/$p 2>/dev/null); echo "$p data_uid=$u"
done
echo "@@GOOGLE_UIDS_END"

echo "== per-app umount / hide config (SukiSU/KSU 'umount modules') =="
echo "@@UMOUNT_BEGIN"; ls -la /data/adb/ksu/profile* /data/adb/ksu/.umount* 2>/dev/null; cat /data/adb/ksu/*.conf 2>/dev/null | head; echo "@@UMOUNT_END"

echo "== module mount visibility (is /data/adb hidden from apps via susfs?) =="
echo "@@OVERLAY_COUNT $(grep -c overlay /proc/mounts)"
echo "@@KSU_PATHS_IN_MOUNTS $(grep -Ec 'adb/modules|worker|magisk|KSU' /proc/mounts)"
echo "@@MODULE_LIST_BEGIN"; $KSUD module list 2>&1 | grep -Ei 'id=|name=|enabled' | head -30; echo "@@MODULE_LIST_END"

echo "== TrickyStore / keybox present =="
echo "@@TS $(ls /data/adb/tricky_store/ 2>/dev/null | tr '\n' ' ')"
echo "@@TS_TARGET_BEGIN"; cat /data/adb/tricky_store/target.txt 2>/dev/null; echo "@@TS_TARGET_END"

echo "== GMS granted su? check allowlist for gms uid =="
echo "@@DONE"
