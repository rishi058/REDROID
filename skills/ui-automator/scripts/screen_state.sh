#!/bin/bash
# screen_state.sh - snapshot the current foreground window/activity + optional UI dump.
# usage: screen_state.sh [serial] [--dump]
SERIAL="${1:-127.0.0.1:5557}"
echo "== focus =="
adb -s "$SERIAL" shell dumpsys window | grep -E "mCurrentFocus|mFocusedApp" | head -4
echo "== top activity =="
adb -s "$SERIAL" shell dumpsys activity activities 2>/dev/null | grep -E "topResumedActivity|ResumedActivity" | head -3
echo "== screen size =="
adb -s "$SERIAL" shell wm size
if [ "$2" == "--dump" ]; then
  bash "$(dirname "$0")/ui_dump.sh" "$SERIAL"
fi
