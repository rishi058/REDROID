#!/usr/bin/env sh
# Phase D.4 - Environment signal snapshot. POSIX/toybox-safe.
# Runs INSIDE an Android shell (VPS: docker exec <c> sh -s < this ;
#   WSL: adb -s <serial> shell sh -s < this). Prints a labeled snapshot to stdout.
# READ-ONLY. Compare two snapshots with env_diff.py.
echo "@@HOST $(getprop ro.product.model) $(getprop ro.build.fingerprint)"
echo "@@UNAME $(uname -a)"
echo "@@KERNEL $(cat /proc/version 2>/dev/null)"
echo "@@ABI $(getprop ro.product.cpu.abi) list=$(getprop ro.product.cpu.abilist)"
echo "@@HARDWARE hw=$(getprop ro.hardware) board=$(getprop ro.board.platform) soc=$(getprop ro.soc.model) plat=$(getprop ro.boot.hardware.platform)"
echo "@@BOOT verifiedboot=$(getprop ro.boot.verifiedbootstate) flash.locked=$(getprop ro.boot.flash.locked) vbmeta=$(getprop ro.boot.vbmeta.device_state) veritymode=$(getprop ro.boot.veritymode)"
echo "@@SECURE secure=$(getprop ro.secure) debuggable=$(getprop ro.debuggable) type=$(getprop ro.build.type) tags=$(getprop ro.build.tags)"
echo "@@SELINUX $(cat /sys/fs/selinux/enforce 2>/dev/null || echo NA) getenforce=$(getenforce 2>/dev/null)"
echo "@@PATCH system=$(getprop ro.build.version.security_patch) vendor=$(getprop ro.vendor.build.security_patch)"
echo "@@GSM gsm.version=$(getprop gsm.version.baseband) radio=$(getprop ro.baseband)"
# CPU / hypervisor signals
echo "@@CPUINFO_BEGIN"; cat /proc/cpuinfo 2>/dev/null | grep -Ei "processor|model name|Hardware|Features|CPU implementer|CPU part|BogoMIPS|flags|hypervisor" | sort -u; echo "@@CPUINFO_END"
echo "@@HYPERVISOR flag=$(grep -c hypervisor /proc/cpuinfo 2>/dev/null); dmesg_virt=$(dmesg 2>/dev/null | grep -Eic 'kvm|qemu|virtio|hypervisor')"
# Device nodes DroidGuard may probe
echo "@@DEVNODES_BEGIN"; ls /dev 2>/dev/null | grep -Ei "binder|ashmem|kvm|virtio|hvc|mali|kgsl|dri|fb0|ion|hwbinder|vndbinder" | sort; echo "@@DEVNODES_END"
echo "@@BINDERFS"; ls /dev/binderfs 2>/dev/null
# Sensors (real devices have many; emulators few/none)
echo "@@SENSORS $(dumpsys sensorservice 2>/dev/null | grep -Ec '0x[0-9a-f]+.*\|')"
echo "@@SENSORLIST_BEGIN"; dumpsys sensorservice 2>/dev/null | sed -n '1,25p'; echo "@@SENSORLIST_END"
# Mounts (overlay/container tells)
echo "@@MOUNTS_BEGIN"; cat /proc/mounts 2>/dev/null | grep -Ei "overlay|/system |/vendor |/data |9p|virtiofs|fuse" | awk '{print $1,$2,$3}'; echo "@@MOUNTS_END"
# GMS DroidGuard process injected libs
echo "@@GMS_MAPS_BEGIN"; P=$(pidof com.google.android.gms.unstable); echo "pid=$P"; [ -n "$P" ] && grep -Eio "playintegrity|teesim|tricky|frida|xposed|lsposed|zygisk|magisk" /proc/$P/maps 2>/dev/null | sort -u; echo "@@GMS_MAPS_END"
# keystore2 injected libs
echo "@@KS2_MAPS_BEGIN"; K=$(pidof keystore2); echo "pid=$K"; [ -n "$K" ] && grep -Eio "teesim|tricky|TEESimulator|libteesim[a-z_]*\.so|keymint" /proc/$K/maps 2>/dev/null | sort -u; echo "@@KS2_MAPS_END"
# Network
echo "@@NET route=$(ip route 2>/dev/null | grep default) dns=$(getprop net.dns1) proxy=$(settings get global http_proxy 2>/dev/null)"
echo "@@DONE"
