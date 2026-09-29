#!/usr/bin/env bash
set -euo pipefail

# Builds the STANDALONE DiskWala signer (dwsigner.jar) that runs as
# com.diskwalaapp's uid via app_process - NO app injection, so PairIP never runs.
# Reuses the exact request-proof code shared with the LSPosed gate variant.
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/SOFTWARES/01_ANDROID_SDK_HOME}}"
SDK="$(cygpath -u "$SDK" 2>/dev/null || printf '%s' "$SDK")"
BT="$SDK/build-tools/35.0.1"
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
OUT="$ROOT/../modules/dwsigner.jar"
SRC="$ROOT/gate/src/com/recon/dw26gate"

for input in "$ANDROID_JAR" "$SRC/SignerMain.java" "$SRC/SignerBridge.java" \
        "$SRC/AndroidKeyStoreSigner.java" "$SRC/SignerPolicy.java"; do
    test -f "$input" || { echo "Missing build input: $input" >&2; exit 2; }
done

BUILD="$ROOT/.signer-build"
rm -rf "$BUILD"
mkdir -p "$BUILD/classes" "$BUILD/dex"

if command -v cygpath >/dev/null 2>&1; then
    CP="$(cygpath -m "$ANDROID_JAR")"
else
    CP="$ANDROID_JAR"
fi

echo '[1/3] Compile signer classes'
javac --release 11 -cp "$CP" -d "$BUILD/classes" \
    "$SRC/SignerMain.java" "$SRC/SignerBridge.java" \
    "$SRC/AndroidKeyStoreSigner.java" "$SRC/SignerPolicy.java"

echo '[2/3] Compile DEX'
"$BT/d8.bat" --min-api 26 --lib "$ANDROID_JAR" --output "$BUILD/dex" \
    "$BUILD"/classes/com/recon/dw26gate/*.class

echo '[3/3] Package jar (classes.dex at zip root)'
python -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED); z.write(sys.argv[2],"classes.dex"); z.close()' \
    "$OUT" "$BUILD/dex/classes.dex"
rm -rf "$BUILD"
echo "Built: $OUT"
