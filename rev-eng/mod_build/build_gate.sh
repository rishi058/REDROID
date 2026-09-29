#!/usr/bin/env bash
set -euo pipefail

# Separate artifact: this never rebuilds or overwrites TalsecKill.
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/d/SOFTWARES/01_ANDROID_SDK_HOME}}"
SDK="$(cygpath -u "$SDK" 2>/dev/null || printf '%s' "$SDK")"
BT="$SDK/build-tools/35.0.1"
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
OUT="$ROOT/../modules/dw26gate.apk"

for input in "$ANDROID_JAR" "$ROOT/xposed-api.jar" "$ROOT/key.pk8" "$ROOT/cert.der"; do
    test -f "$input" || { echo "Missing build input: $input" >&2; exit 2; }
done
test -d "$(dirname "$OUT")" || { echo 'Missing modules output directory' >&2; exit 2; }
BUILD="$(mktemp -d "$ROOT/.gate-build.XXXXXX")"
trap 'rm -rf -- "$BUILD"' EXIT
mkdir -p "$BUILD/classes" "$BUILD/dex" "$BUILD/tests"

if command -v cygpath >/dev/null 2>&1; then
    CLASSPATH="$(cygpath -m "$ROOT/xposed-api.jar");$(cygpath -m "$ANDROID_JAR")"
else
    CLASSPATH="$ROOT/xposed-api.jar:$ANDROID_JAR"
fi

echo '[test] Verify fail-open mode selection'
javac --release 11 -d "$BUILD/tests" \
    "$ROOT/gate/src/com/recon/dw26gate/GateMode.java" \
    "$ROOT/gate/src/com/recon/dw26gate/GatePolicy.java" \
    "$ROOT/gate/src/com/recon/dw26gate/GatePrivacy.java" \
    "$ROOT/gate/src/com/recon/dw26gate/SignerPolicy.java" \
    "$ROOT/gate/tests/com/recon/dw26gate/GateModeTest.java" \
    "$ROOT/gate/tests/com/recon/dw26gate/GatePolicyTest.java" \
    "$ROOT/gate/tests/com/recon/dw26gate/GatePrivacyTest.java" \
    "$ROOT/gate/tests/com/recon/dw26gate/SignerPolicyTest.java"
java -cp "$BUILD/tests" com.recon.dw26gate.GateModeTest
java -cp "$BUILD/tests" com.recon.dw26gate.GatePolicyTest
java -cp "$BUILD/tests" com.recon.dw26gate.GatePrivacyTest
java -cp "$BUILD/tests" com.recon.dw26gate.SignerPolicyTest

echo '[1/6] Compile scoped module'
javac --release 11 -cp "$CLASSPATH" -d "$BUILD/classes" \
    "$ROOT"/gate/src/com/recon/dw26gate/*.java

echo '[2/6] Compile DEX'
"$BT/d8.bat" --min-api 26 --lib "$ANDROID_JAR" \
    --classpath "$ROOT/xposed-api.jar" --output "$BUILD/dex" \
    "$BUILD"/classes/com/recon/dw26gate/*.class

echo '[3/6] Package manifest'
"$BT/aapt2.exe" link -o "$BUILD/unsigned.apk" -I "$ANDROID_JAR" \
    --manifest "$ROOT/gate/AndroidManifest.xml" --min-sdk-version 26 --target-sdk-version 34

echo '[4/6] Add DEX and Xposed entry point'
python -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"a",zipfile.ZIP_DEFLATED); z.write(sys.argv[2],"classes.dex"); z.write(sys.argv[3],"assets/xposed_init"); z.close()' \
    "$BUILD/unsigned.apk" "$BUILD/dex/classes.dex" "$ROOT/gate/assets/xposed_init"

echo '[5/6] Align and sign'
"$BT/zipalign.exe" -f 4 "$BUILD/unsigned.apk" "$BUILD/aligned.apk"
"$BT/apksigner.bat" sign --key "$ROOT/key.pk8" --cert "$ROOT/cert.der" \
    --v4-signing-enabled false --out "$BUILD/signed.apk" "$BUILD/aligned.apk"

echo '[6/6] Verify before publishing artifact'
"$BT/apksigner.bat" verify --verbose "$BUILD/signed.apk"
"$BT/zipalign.exe" -c 4 "$BUILD/signed.apk"
cp "$BUILD/signed.apk" "$OUT"
echo "Built: $OUT"
