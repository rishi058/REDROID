#!/bin/bash
# Capture the WSL ReDroid container state for comparison against the failing VPS exp container.
# Run inside WSL:  wsl.exe -d Ubuntu -- bash /mnt/d/PROJECT/_TRASH/REDROID/integrity-debug/scripts/wsl_capture.sh
# Read-only. Makes no changes.
C=redroid14

dex() { docker exec "$C" "$@"; }

echo "@@UNAME $(uname -r)"
echo "@@CONTAINER $C"
echo ""

echo "=== HARDWARE PROPS ==="
for p in ro.hardware ro.boot.hardware ro.hardware.egl ro.hardware.vulkan \
         ro.board.platform ro.product.board ro.boot.mode ro.bootmode ro.kernel.qemu; do
  echo "$p = $(dex getprop "$p" 2>/dev/null | tr -d '\r')"
done
echo ""

echo "=== IDENTITY ==="
for p in ro.build.fingerprint ro.system.build.fingerprint ro.vendor.build.fingerprint \
         ro.product.build.fingerprint ro.odm.build.fingerprint ro.bootimage.build.fingerprint \
         ro.product.model ro.product.device ro.product.brand ro.product.name \
         ro.product.manufacturer ro.build.version.security_patch ro.product.first_api_level \
         ro.board.first_api_level ro.build.tags ro.build.type ro.build.id ro.build.description; do
  echo "$p = $(dex getprop "$p" 2>/dev/null | tr -d '\r')"
done
echo ""

echo "=== SECURITY / VERIFIED BOOT ==="
for p in ro.secure ro.debuggable ro.adb.secure ro.boot.verifiedbootstate \
         ro.boot.flash.locked ro.boot.veritymode ro.boot.vbmeta.device_state \
         ro.oem_unlock_supported ro.build.selinux; do
  echo "$p = $(dex getprop "$p" 2>/dev/null | tr -d '\r')"
done
echo ""

echo "=== SELINUX ==="
dex getenforce 2>/dev/null | tr -d '\r'
echo ""

echo "=== MODULES ==="
dex ls /data/adb/modules/ 2>/dev/null | tr -d '\r'
echo ""
echo "--- enabled states ---"
dex sh -c 'for m in /data/adb/modules/*/; do n=$(basename "$m"); s=""; [ -f "$m/disable" ] && s=" [DISABLED]"; echo "$n$s"; done' 2>/dev/null | tr -d '\r'
echo ""

echo "=== redroid_pixel5 system.prop ==="
dex cat /data/adb/modules/redroid_pixel5/system.prop 2>/dev/null | tr -d '\r'
echo ""

echo "=== redroid_pixel5 module.prop ==="
dex cat /data/adb/modules/redroid_pixel5/module.prop 2>/dev/null | tr -d '\r'
echo ""

echo "=== PIF present? ==="
dex sh -c 'if [ -d /data/adb/modules/playintegrityfix ]; then echo PRESENT; cat /data/adb/modules/playintegrityfix/pif.prop 2>/dev/null; else echo ABSENT; fi' 2>/dev/null | tr -d '\r'
echo ""

echo "=== tricky_store ==="
dex ls /data/adb/tricky_store/ 2>/dev/null | tr -d '\r'
echo "--- target.txt ---"
dex cat /data/adb/tricky_store/target.txt 2>/dev/null | tr -d '\r'
echo "--- security_patch.txt ---"
dex cat /data/adb/tricky_store/security_patch.txt 2>/dev/null | tr -d '\r'
echo "--- keybox sha256 (hash only) ---"
dex sha256sum /data/adb/tricky_store/keybox.xml 2>/dev/null | tr -d '\r'
echo ""

echo "=== TrickyStore module version ==="
dex cat /data/adb/modules/tricky_store/module.prop 2>/dev/null | tr -d '\r'
echo ""

echo "=== GMS MOUNTINFO LEAKAGE ==="
dex sh -c 'P=$(pidof com.google.android.gms.unstable); echo "gms_pid=$P";
  if [ -n "$P" ]; then
    echo -n "total_mounts="; wc -l < /proc/$P/mountinfo
    echo -n "overlay_count="; grep -c overlay /proc/$P/mountinfo
    echo -n "docker_containerd_strings="; grep -coE "containerd|/docker/|overlay2" /proc/$P/mountinfo
    echo -n "ksu_module_paths="; grep -coE "/data/adb|ksu|/modules/" /proc/$P/mountinfo
    echo "--- sample overlay line ---"
    grep overlay /proc/$P/mountinfo | head -1
  fi' 2>/dev/null | tr -d '\r'
echo ""

echo "=== /proc/1/cgroup ==="
dex cat /proc/1/cgroup 2>/dev/null | tr -d '\r'
echo ""

echo "=== INJECTION ==="
dex sh -c 'P=$(pidof com.google.android.gms.unstable); echo "gms_pid=$P";
  [ -n "$P" ] && grep -oE "/data/adb/modules/[a-z_]+/zygisk/[a-z0-9-]+\.so" /proc/$P/maps | sort -u
  K=$(pidof keystore2); echo "keystore2_pid=$K";
  [ -n "$K" ] && grep -ioE "tricky|teesim" /proc/$K/maps | sort -u' 2>/dev/null | tr -d '\r'
echo ""

echo "=== PROCESSES ==="
dex sh -c 'ps -A | grep -iE "zygote|lspd|zygisk|ksud|tricky|TEE" ' 2>/dev/null | tr -d '\r'
echo ""

echo "@@DONE"
