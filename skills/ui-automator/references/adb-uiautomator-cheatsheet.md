# ADB + uiautomator Command Cheatsheet

All commands assume a device serial (default `127.0.0.1:5557` for the redroid-experimental
instance over an SSH tunnel). Substitute your serial.

## 0. Connectivity

```bash
adb kill-server && adb start-server      # reset daemon
adb connect 127.0.0.1:5557               # connect over SSH tunnel
adb devices                              # must show: 127.0.0.1:5557   device
adb -s SERIAL shell getprop sys.boot_completed   # "1" = Android fully booted
```

SSH tunnel that provides the serial (run in a background job / separate terminal):

```powershell
ssh -i "C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key" `
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=no `
  -N -L 127.0.0.1:5557:127.0.0.1:5557 ubuntu@141.148.151.172
```

## 1. UI hierarchy dump

```bash
# on-device dump, then pull (uiautomator writes UTF-16-ish XML; pulling avoids encoding pain)
adb -s SERIAL shell uiautomator dump /sdcard/dump.xml
adb -s SERIAL pull /sdcard/dump.xml ./dump.xml
adb -s SERIAL shell rm -f /sdcard/dump.xml

# one-liner variant (streams text; watch for CRLF/encoding artifacts)
adb -s SERIAL exec-out uiautomator dump /dev/tty
```

Notes:
- `uiautomator dump` captures the **active window only** (dialogs, bottom sheets included;
  system bars excluded unless visible).
- It fails silently-ish (`ERROR: could not get idle state`) when animations run; retry after
  1–2 s or press BACK first.
- Compressed XML omits nothing important, but nodes are self-closing `<node ... />`.

## 2. Input injection

```bash
adb -s SERIAL shell input tap X Y                 # coordinates from node center
adb -s SERIAL shell input swipe X1 Y1 X2 Y2 MS    # scroll/fling (MS = duration ms)
adb -s SERIAL shell input swipe 360 900 360 400 300   # typical scroll-up in 720x1280
adb -s SERIAL shell input text 'hello world'      # no spaces allowed unescaped; type into focused field
adb -s SERIAL shell input keyevent KEYCODE_BACK       # 4
adb -s SERIAL shell input keyevent KEYCODE_ENTER      # 66
adb -s SERIAL shell input keyevent KEYCODE_HOME       # 3
```

Keyevent codes worth memorizing: BACK=4, HOME=3, ENTER=66, TAB=61, DEL=67.

## 3. App lifecycle

```bash
adb -s SERIAL shell am start -n PKG/.MainActivity            # cold/warm launch by component
adb -s SERIAL shell am start -W -n PKG/.Activity             # wait-for-launch; prints Status/LaunchState/TotalTime
adb -s SERIAL shell monkey -p PKG -c android.intent.category.LAUNCHER 1   # launcher-intent launch
adb -s SERIAL shell am force-stop PKG                        # hard stop before relaunch
adb -s SERIAL shell pm clear PKG                             # ⚠ wipes app data — destructive!
adb -s SERIAL shell pm path PKG                              # installed APK paths
```

`am start -W` output fields: `Status: ok|timeout`, `LaunchState: COLD|WARM|HOT`,
`TotalTime` ms — use to confirm the screen is actually up before dumping.

## 4. State inspection

```bash
adb -s SERIAL shell dumpsys window | grep mCurrentFocus      # what window has focus right now
adb -s SERIAL shell dumpsys activity activities | grep ResumedActivity
adb -s SERIAL shell wm size                                   # screen resolution (e.g. 720x1280)
adb -s SERIAL shell settings list global | grep http_proxy    # proxy sanity check (:0 = none)
adb -s SERIAL logcat -c                                       # clear ring buffer before an action
adb -s SERIAL logcat -d | grep -i TAG                         # dump after action (-d = don't block)
adb -s SERIAL screencap -p /sdcard/s.png && adb -s SERIAL pull /sdcard/s.png .
```

## 5. File transfer

```bash
adb -s SERIAL push local.xml /sdcard/remote.xml
adb -s SERIAL pull /sdcard/remote.xml local.xml
adb -s SERIAL exec-out cat /sdcard/file > local.bin           # binary-safe stream
```

## 6. Deep links / intents

```bash
adb -s SERIAL shell am start -a android.intent.action.VIEW -d https://example.com
adb -s SERIAL shell am start -a android.intent.action.VIEW -d "market://details?id=PKG"
```

Caution: VIEW URLs without a package filter may open a browser/webview instead of the
target app (observed with Play Store URLs → WebView shell). Prefer explicit `-n pkg/activity`.

## 7. Multi-device hygiene

- Always pass `-s SERIAL`; with two instances connected (`127.0.0.1:5557`, `emulator-5556`)
  bare commands fail or hit the wrong device.
- After any container restart, adbd restarts too: re-run `adb connect`, expect brief
  `offline`, then `device`.
