#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/SOFTWARES/01_ANDROID_SDK_HOME}}"
SDK="$(cygpath -u "$SDK" 2>/dev/null || printf '%s' "$SDK")"
BT="$SDK/build-tools/35.0.1"
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
MODULE="$ROOT/pgstrace"
OUT="$ROOT/../modules/pgstrace.apk"

for input in "$ANDROID_JAR" "$ROOT/xposed-api.jar" "$ROOT/key.pk8" "$ROOT/cert.der"; do
    test -f "$input" || { echo "Missing build input: $input" >&2; exit 2; }
done
test -f "$MODULE/src/com/recon/pgstrace/Hook.java" || { echo 'Missing trace hook implementation' >&2; exit 2; }
test -d "$(dirname "$OUT")" || { echo 'Missing modules output directory' >&2; exit 2; }
BUILD="$(mktemp -d "$ROOT/.pgstrace-build.XXXXXX")"
trap 'rm -rf -- "$BUILD"' EXIT
mkdir -p "$BUILD/classes" "$BUILD/dex" "$BUILD/tests"

if command -v cygpath >/dev/null 2>&1; then
    CLASSPATH="$(cygpath -m "$ROOT/xposed-api.jar");$(cygpath -m "$ANDROID_JAR")"
else
    CLASSPATH="$ROOT/xposed-api.jar:$ANDROID_JAR"
fi

echo '[test] Verify metadata-only trace policy'
javac --release 11 -d "$BUILD/tests" \
    "$MODULE/src/com/recon/pgstrace/TracePolicy.java" \
    "$MODULE/tests/com/recon/pgstrace/TracePolicyTest.java"
java -cp "$BUILD/tests" com.recon.pgstrace.TracePolicyTest

echo '[1/6] Compile metadata-only trace module'
javac --release 11 -cp "$CLASSPATH" -d "$BUILD/classes" \
    "$MODULE"/src/com/recon/pgstrace/*.java

echo '[2/6] Compile DEX'
"$BT/d8.bat" --min-api 26 --lib "$ANDROID_JAR" \
    --classpath "$ROOT/xposed-api.jar" --output "$BUILD/dex" \
    "$BUILD"/classes/com/recon/pgstrace/*.class

echo '[3/6] Package manifest'
"$BT/aapt2.exe" link -o "$BUILD/unsigned.apk" -I "$ANDROID_JAR" \
    --manifest "$MODULE/AndroidManifest.xml" --min-sdk-version 26 --target-sdk-version 34

echo '[4/6] Add DEX and Xposed entry point'
python -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"a",zipfile.ZIP_DEFLATED); z.write(sys.argv[2],"classes.dex"); z.write(sys.argv[3],"assets/xposed_init"); z.close()' \
    "$BUILD/unsigned.apk" "$BUILD/dex/classes.dex" "$MODULE/assets/xposed_init"

echo '[5/6] Align and sign'
"$BT/zipalign.exe" -f 4 "$BUILD/unsigned.apk" "$BUILD/aligned.apk"
"$BT/apksigner.bat" sign --key "$ROOT/key.pk8" --cert "$ROOT/cert.der" \
    --v4-signing-enabled false --out "$BUILD/signed.apk" "$BUILD/aligned.apk"

echo '[6/6] Verify before publishing artifact'
"$BT/apksigner.bat" verify --verbose "$BUILD/signed.apk"
"$BT/zipalign.exe" -c 4 "$BUILD/signed.apk"
cp "$BUILD/signed.apk" "$OUT"
echo "Built: $OUT"
