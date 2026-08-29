#!/system/bin/sh
# DroidGuard Signal Tracer/Harmonizer - post-fs-data stage.
# 1) DIAGNOSTIC: snapshot the environment signals DroidGuard/CTS-profile inspect.
# 2) HARMONIZE (opt-in via /data/adb/droidguard_tracer/harmonize): normalize the
#    PROPPABLE signals that are incoherent with the spoofed redfin/Pixel 5 identity.
# Deeper signals (0 sensors, SELinux Disabled, kernel name, ro.hardware) can NOT be
# fixed by props alone - they need the Zygisk component (see README).
MODDIR=${0%/*}
CFG=/data/adb/droidguard_tracer
LOG=$CFG/trace.log
mkdir -p "$CFG"

{
  echo "==== $(date) post-fs-data ===="
  echo "uname: $(uname -a)"
  echo "getenforce: $(getenforce 2>/dev/null)"
  echo "ro.hardware=$(getprop ro.hardware) board=$(getprop ro.board.platform) soc=$(getprop ro.soc.model)/$(getprop ro.soc.manufacturer)"
  echo "fingerprint=$(getprop ro.build.fingerprint)"
  echo "security_patch=$(getprop ro.build.version.security_patch)"
} >> "$LOG" 2>&1

# Opt-in prop harmonization toward real redfin (Pixel 5) values.
if [ -f "$CFG/harmonize" ]; then
  resetprop_if_diff() { c="$(resetprop "$1")"; [ -z "$c" ] || [ "$c" = "$2" ] || resetprop "$1" "$2"; }
  # Real redfin SoC identity (coherence with the spoofed redfin fingerprint)
  resetprop_if_diff ro.board.platform lito
  resetprop_if_diff ro.soc.manufacturer Qualcomm
  resetprop_if_diff ro.soc.model SM7250
  resetprop_if_diff ro.hardware.chipname SM7250
  echo "harmonized board/soc props -> lito/SM7250" >> "$LOG"
  echo "NOTE: ro.hardware=redroid, 0 sensors, SELinux=Disabled, kernel name NOT changed (needs Zygisk)." >> "$LOG"
fi
