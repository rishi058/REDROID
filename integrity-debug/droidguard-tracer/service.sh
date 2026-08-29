#!/system/bin/sh
# DroidGuard Signal Tracer - late stage (after boot). Records post-boot signal state
# so it can be diffed against a passing device (WSL) with ../scripts/env_diff.py.
MODDIR=${0%/*}
CFG=/data/adb/droidguard_tracer
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 5
{
  echo "==== $(date) boot_completed ===="
  echo "sensors: $(dumpsys sensorservice 2>/dev/null | grep -c '0x')"
  echo "gms.unstable maps: $(P=$(pidof com.google.android.gms.unstable); [ -n "$P" ] && grep -Eio 'playintegrity|tricky|teesim|zygisk' /proc/$P/maps | sort -u | tr '\n' ' ')"
  echo "keystore2 maps: $(K=$(pidof keystore2); [ -n "$K" ] && grep -Eio 'tricky|teesim|TEESimulator' /proc/$K/maps | sort -u | tr '\n' ' ')"
} >> "$CFG/trace.log" 2>&1
