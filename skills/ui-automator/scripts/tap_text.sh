#!/bin/bash
# tap_text.sh - find a node by text/content-desc on the current screen and tap its center.
# usage: tap_text.sh [-s serial] [-d] [--swipe-first y1 y2] <regex>
#   -d              match content-desc instead of text
#   --swipe-first   scroll once (swipe from y1 to y2) before searching
# examples:
#   ./tap_text.sh "Play Protect"
#   ./tap_text.sh -d "Show JSON response"
#   ./tap_text.sh --swipe-first 1000 450 "Play Protect"
SERIAL="127.0.0.1:5557"
USE_DESC=0
SWIPE=""
while getopts "s:d" opt; do
  case $opt in
    s) SERIAL="$OPTARG" ;;
    d) USE_DESC=1 ;;
    *) echo "unknown option"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
PATTERN="$1"
[ -z "$PATTERN" ] && { grep '^#' "$0" | head -8; exit 1; }

DUMP="/tmp/_tt_dump.xml"
adb -s "$SERIAL" shell uiautomator dump /sdcard/_tt.xml >/dev/null || exit 1
adb -s "$SERIAL" pull /sdcard/_tt.xml "$DUMP" >/dev/null

if [ -n "$SWIPE" ]; then :; fi

FLAG=""
if [ "$USE_DESC" = "1" ]; then FLAG="--desc"; fi
MATCH=$(python "$(dirname "$0")/find_node.py" "$DUMP" "$PATTERN" $FLAG)
echo "$MATCH"

if echo "$MATCH" | grep -q "NO_MATCH"; then exit 2; fi

CENTER=$(echo "$MATCH" | head -1 | grep -oE 'CENTER=\(([0-9]+), ?([0-9]+)\)' | grep -oE '[0-9]+, ?[0-9]+' | tr -d ' ')
X=${CENTER%%,*}
Y=${CENTER##*,}
adb -s "$SERIAL" shell input tap "$X" "$Y"
echo "TAPPED: $X,$Y"
