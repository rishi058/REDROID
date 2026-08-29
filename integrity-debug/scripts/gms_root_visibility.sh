#!/system/bin/sh
# READ-ONLY: does the GMS/DroidGuard process see root traces in ITS mount namespace?
# BASIC (A13+ DroidGuard heuristic) can fail if GMS sees /data/adb or module mounts.
for proc in com.google.android.gms com.google.android.gms.unstable com.google.android.gms.persistent; do
  pid=$(pidof "$proc" 2>/dev/null | tr ' ' '\n' | head -1)
  [ -z "$pid" ] && { echo "@@ $proc : not running"; continue; }
  echo "@@ $proc pid=$pid"
  echo "  mountinfo root-trace lines:"
  grep -Eic 'adb|/modules|worker|magisk|tricky|teesim|mindthegapps|litegapps|redroid_pixel5|zygisk' /proc/$pid/mountinfo 2>/dev/null
  grep -Ei 'adb|/modules|worker|magisk|tricky|teesim|mindthegapps|litegapps|redroid_pixel5|zygisk' /proc/$pid/mountinfo 2>/dev/null | sed 's/ - .*//' | awk '{print "    "$5}' | sort -u | head -20
  echo "  can this proc see /data/adb? (via /proc/$pid/root):"
  ls /proc/$pid/root/data/adb 2>/dev/null | head -8 || echo "    NOT visible"
done
echo "@@DONE"
