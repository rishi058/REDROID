#!/bin/bash
set -e
SDK=/d/SOFTWARES/01_ANDROID_SDK_HOME
AJAR="$SDK/platforms/android-35/android.jar"
BT="$SDK/build-tools/35.0.1"
cd "$(dirname "$0")"
cleanup() {
  rm -rf classes dexout generated-src base.apk classes.dex mod.apk talseckill-aligned.apk
}
trap cleanup EXIT
rm -rf classes dexout generated-src base.apk mod.apk talseckill-aligned.apk
mkdir -p classes dexout generated-src/com/recon/talsecbypass

TARGET_APP_PACKAGE="${TARGET_APP_PACKAGE:-com.target-appapp}"
ACCEPTED_DEVICE_ID="${ACCEPTED_DEVICE_ID:-accepted-device-id}"
case "$TARGET_APP_PACKAGE" in
  *[!A-Za-z0-9._]*|'') echo "invalid TARGET_APP_PACKAGE: $TARGET_APP_PACKAGE" >&2; exit 2 ;;
esac
case "$ACCEPTED_DEVICE_ID" in
  *[!A-Za-z0-9._-]*|'') echo "invalid ACCEPTED_DEVICE_ID" >&2; exit 2 ;;
esac
sed -e "s/com\.target-appapp/$TARGET_APP_PACKAGE/g" \
  -e "s/accepted-device-id/$ACCEPTED_DEVICE_ID/g" \
  src/com/recon/talsecbypass/Hook.java \
  > generated-src/com/recon/talsecbypass/Hook.java

echo "[1/6] javac"
javac --release 11 -cp "xposed-api.jar" -d classes generated-src/com/recon/talsecbypass/Hook.java

echo "[2/6] d8 -> classes.dex"
"$BT/d8.bat" --min-api 21 --output dexout --lib "$AJAR" classes/com/recon/talsecbypass/*.class
ls -la dexout/classes.dex

echo "[3/6] aapt2 link (manifest)"
"$BT/aapt2.exe" link -o base.apk -I "$AJAR" --manifest AndroidManifest.xml --min-sdk-version 21 --target-sdk-version 35

echo "[4/6] add classes.dex + assets/xposed_init"
cp dexout/classes.dex classes.dex
python -c "import zipfile,shutil; shutil.copy('base.apk','mod.apk'); z=zipfile.ZipFile('mod.apk','a',zipfile.ZIP_DEFLATED); z.write('classes.dex','classes.dex'); z.write('assets/xposed_init','assets/xposed_init'); z.close(); print('  added dex+init')"

echo "[5/6] zipalign"
"$BT/zipalign.exe" -f 4 mod.apk talseckill-aligned.apk

echo "[6/6] sign (openssl key.pk8/cert.der) -> ../modules/talseckill.apk"
"$BT/apksigner.bat" sign --key key.pk8 --cert cert.der --out ../modules/talseckill.apk talseckill-aligned.apk
echo "[done] built ../modules/talseckill.apk"
ls -la ../modules/talseckill.apk
