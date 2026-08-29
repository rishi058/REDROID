# Integrity Probe app (Phase D.1 client)

Mints a **fresh** Play Integrity token on the device so `../decode-harness/decode_token.py`
can decode it **once** with our own service account — the decisive replay-vs-genuine test.

## Build
1. Set `CLOUD_PROJECT_NUMBER` in `app/src/main/java/dev/redroid/integrityprobe/MainActivity.kt`
   to your GCP project number (only needed for the Standard path; Classic works without it).
2. `./gradlew :app:assembleDebug` (needs Android SDK; add a `gradle/wrapper` or run in Android Studio).
3. Install on exp:
   ```
   adb -s 127.0.0.1:5557 install app/build/outputs/apk/debug/app-debug.apk
   ```

## Run
```
adb -s 127.0.0.1:5557 shell am start -n dev.redroid.integrityprobe/.MainActivity
adb -s 127.0.0.1:5557 logcat -s PROBE:I -d        # copy the fresh token
```
Then immediately:
```
cd ../decode-harness
python decode_token.py --package dev.redroid.integrityprobe --token "<TOKEN>" --sa service-account.json
```

The Classic path needs no Play Console linkage. `appRecognitionVerdict` will be `UNRECOGNIZED_VERSION`
(app not published) — irrelevant; we read `deviceIntegrity.deviceRecognitionVerdict` / BASIC.
