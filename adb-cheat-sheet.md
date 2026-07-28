# 📱 ADB Cheat Sheet (Power Users / Modders / App Debugging)

---

# 🔌 Connection

```bash
adb devices                 # List connected devices
adb devices -l              # Detailed device info

adb connect IP:5555         # Connect over TCP/IP
adb disconnect              # Disconnect all
adb disconnect IP:5555      # Disconnect one

adb kill-server
adb start-server
```

---

# 📲 Device Information

```bash
adb shell getprop
adb shell getprop ro.build.version.release
adb shell getprop ro.product.model
adb shell getprop ro.product.cpu.abi
adb shell getprop ro.product.cpu.abilist

adb shell uname -a
adb shell cat /proc/cpuinfo
adb shell cat /proc/meminfo
```

---

# 📂 File Operations

```bash
adb push file.txt /sdcard/

adb pull /sdcard/file.txt

adb shell ls
adb shell pwd
adb shell mkdir folder
adb shell rm file
adb shell rm -rf folder

adb shell cp
adb shell mv
```

---

# 📦 Package Management

```bash
adb shell pm list packages

adb shell pm list packages | grep google

adb shell pm path com.example.app

adb shell pm clear com.example.app

adb shell pm uninstall com.example.app

adb shell pm uninstall --user 0 package

adb shell pm install-existing package

adb install app.apk

adb install -r app.apk      # Replace

adb install -g app.apk      # Grant permissions

adb uninstall package
```

---

# 🔍 Package Inspection

```bash
adb shell dumpsys package com.app

adb shell dumpsys package | grep versionName

adb shell dumpsys package | grep versionCode

adb shell cmd package resolve-activity package

adb shell cmd package list packages
```

---

# 🎯 Activity Manager (am)

```bash
adb shell am start -n package/.Activity

adb shell am force-stop package

adb shell am kill package

adb shell am broadcast ...

adb shell am startservice ...

adb shell am instrument ...
```

---

# 📝 Logcat

```bash
adb logcat

adb logcat -c              # Clear

adb logcat | grep TAG

adb logcat *:E

adb logcat ActivityManager:I *:S

adb logcat -v time

adb logcat --pid PID
```

---

# 📊 Dumpsys

```bash
adb shell dumpsys

adb shell dumpsys battery

adb shell dumpsys activity

adb shell dumpsys window

adb shell dumpsys package

adb shell dumpsys meminfo

adb shell dumpsys gfxinfo

adb shell dumpsys cpuinfo
```

---

# 🧠 Process Management

```bash
adb shell ps

adb shell ps -A

adb shell top

adb shell pidof package

adb shell kill PID

adb shell kill -9 PID
```

---

# 🔒 Permissions

```bash
adb shell pm grant package permission

adb shell pm revoke package permission

adb shell appops get package

adb shell appops set package OP allow
```

---

# 📸 Screen & Recording

```bash
adb shell screencap /sdcard/screen.png

adb pull /sdcard/screen.png

adb shell screenrecord /sdcard/video.mp4

adb pull /sdcard/video.mp4
```

---

# ⌨️ Input Automation

```bash
adb shell input tap X Y

adb shell input swipe x1 y1 x2 y2

adb shell input text Hello

adb shell input keyevent KEYCODE_HOME

adb shell input keyevent KEYCODE_BACK

adb shell input keyevent 26    # Power

adb shell input keyevent 82    # Unlock
```

---

# 📡 Networking

```bash
adb shell ip addr

adb shell ifconfig

adb shell netstat

adb shell ping google.com

adb reverse tcp:8080 tcp:8080

adb forward tcp:1234 tcp:1234
```

---

# 🔋 Battery Simulation

```bash
adb shell dumpsys battery unplug

adb shell dumpsys battery set level 20

adb shell dumpsys battery set status 3

adb shell dumpsys battery reset
```

---

# 📍 Location (Mock)

```bash
adb emu geo fix longitude latitude
```

> Works only on emulator.

---

# 💾 APK Extraction

```bash
adb shell pm path package

adb pull /data/app/.../base.apk
```

Root required for many apps.

---

# 🔑 Root (Rooted Devices)

```bash
adb root

adb remount

adb shell

su

adb disable-verity

adb enable-verity
```

---

# 🗄️ SQLite

```bash
adb shell

sqlite3 database.db

.tables

.schema

SELECT * FROM table;
```

---

# 📱 System Properties

```bash
adb shell settings list global

adb shell settings list secure

adb shell settings list system

adb shell settings get global adb_enabled

adb shell settings put global airplane_mode_on 1
```

---

# 🔄 Reboot

```bash
adb reboot

adb reboot bootloader

adb reboot recovery

adb reboot fastboot

adb reboot sideload
```

---

# 📈 Performance

```bash
adb shell dumpsys meminfo package

adb shell dumpsys gfxinfo package

adb shell top

adb shell atrace

adb shell perfetto
```

---

# 🧪 App Debugging

```bash
adb shell run-as package

adb shell run-as package ls

adb shell run-as package cat file

adb shell monkey -p package 1000

adb shell monkey -p package -v 10
```

---

# 🧹 Cache & Data

```bash
adb shell pm clear package

adb shell rm -rf /sdcard/Android/data/package

adb shell rm -rf /data/data/package   # Root
```

---

# 📂 Useful Directories

```text
/data/app/
/data/data/
/sdcard/
/storage/emulated/0/

/system/
/vendor/
/product/

/proc/
/sys/
/dev/
```

---

# 🔧 Android Services

```bash
adb shell service list

adb shell cmd package

adb shell cmd activity

adb shell cmd jobscheduler

adb shell cmd notification

adb shell cmd overlay

adb shell cmd shortcut

adb shell cmd wifi

adb shell cmd bluetooth_manager
```

---

# 📋 Content Providers

```bash
adb shell content query --uri URI

adb shell content insert

adb shell content delete

adb shell content update
```

Example:

```bash
adb shell content query --uri content://settings/global
```

---

# 🔍 SELinux

```bash
adb shell getenforce

adb shell setenforce 0      # Root

adb shell sestatus
```

---

# 🐧 Kernel & Logs

```bash
adb shell dmesg

adb shell cat /proc/kmsg

adb bugreport

adb shell logcat -b kernel
```

---

# 📦 Intent Testing

```bash
adb shell am start \
-a android.intent.action.VIEW \
-d https://example.com

adb shell am start \
-a android.settings.APPLICATION_DETAILS_SETTINGS \
-d package:com.example.app
```

---

# 🎛️ Window Manager

```bash
adb shell wm size

adb shell wm density

adb shell wm size reset

adb shell wm density reset

adb shell wm dismiss-keyguard
```

---

# 🛠️ Fast Debugging Workflow

```bash
adb devices

adb logcat -c

adb shell am force-stop package

adb shell monkey -p package 1

adb logcat --pid $(adb shell pidof package)

adb shell dumpsys package package

adb shell dumpsys meminfo package

adb bugreport
```

---

# ⭐ Less-Known but Powerful Commands

| Command                             | Purpose                               |
| ----------------------------------- | ------------------------------------- |
| `adb shell cmd package compile`     | Trigger ART compilation               |
| `adb shell cmd overlay list`        | List overlays                         |
| `adb shell cmd shortcut`            | Manage app shortcuts                  |
| `adb shell cmd jobscheduler run`    | Run scheduled jobs                    |
| `adb shell cmd notification`        | Inspect notifications                 |
| `adb shell cmd activity get-config` | Current device configuration          |
| `adb shell cmd stats`               | System statistics                     |
| `adb shell dumpsys usagestats`      | App usage history                     |
| `adb shell cmd wifi`                | Wi-Fi management                      |
| `adb shell cmd bluetooth_manager`   | Bluetooth operations                  |
| `adb shell cmd deviceidle`          | Doze mode control                     |
| `adb shell cmd appops`              | Advanced permission/AppOps management |
| `adb shell settings`                | Read/modify Android settings          |
| `adb shell cmd media_session`       | Media session inspection              |
| `adb shell cmd uimode`              | UI mode (car, night, etc.)            |
| `adb shell cmd role`                | Manage Android roles                  |

## 🚀 Pro Tip

For reverse engineering, modding, and debugging, you'll use these commands most often:

```bash
adb shell
su
logcat
dumpsys
pm
am
cmd
content
settings
run-as
bugreport
top
pidof
ps
getprop
wm
input
screenrecord
screencap
```
