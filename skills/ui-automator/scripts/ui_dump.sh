#!/bin/bash
# ui_dump.sh - dump the current screen's UI hierarchy and pull it locally.
# usage: ui_dump.sh [serial] [outfile]
#   serial   default: 127.0.0.1:5557
#   outfile  default: /tmp/ui_dump_<timestamp>.xml
SERIAL="${1:-127.0.0.1:5557}"
OUT="${2:-/tmp/ui_dump_$(date +%s).xml}"
REMOTE="/sdcard/_ui_dump.xml"

adb -s "$SERIAL" shell uiautomator dump "$REMOTE" || exit 1
adb -s "$SERIAL" pull "$REMOTE" "$OUT" || exit 1
adb -s "$SERIAL" shell rm -f "$REMOTE"
echo "DUMPED: $OUT"
