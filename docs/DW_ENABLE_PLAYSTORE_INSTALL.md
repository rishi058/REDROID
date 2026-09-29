# DiskWala on ReDroid 15 (Pixel 8) — Genuine Play Install + PairIP VM‑Encryption Pass

> **Outcome (2026‑09‑27):** On a fresh **ReDroid Android 15** instance (`redroid17_64only`) built to impersonate a **Google Pixel 8 (`shiba`)**, DiskWala 26.4 was **installed directly from the Play Store** (`installerPackageName` **and** `initiatingPackageName` = `com.android.vending`), the **PairIP VM‑encryption key‑transfer returned TRUSTED**, the app **decrypted its VM assets and launched successfully** — with **no RePairip capture needed**.
>
> **Key finding:** This worked with **BASIC + DEVICE integrity passing but STRONG *failing*** (2‑pass / 1‑fail). PairIP's Play‑mediated key delivery did **not** require STRONG. The decisive, previously‑missing lever was making the device **eligible in Play's device catalog** by publishing a full **Pixel 8 hardware‑feature profile**, which flipped Play from *"app not available for your device"* to **Install** and enabled a **genuine Play transaction**.

---

## 0. Environment

| Item | Value |
|---|---|
| Host | GCloud VM `redroid-vm-20260919`, `35.254.242.42`, user `Rishi` |
| Host arch | `aarch64` (ARM64), **no GPU** (`/dev/dri` absent) |
| Host kernel | `6.8.12-zksu-multi` (KernelSU‑patched, multi‑instance) |
| Docker | rootful, `sudo docker` |
| ADB on host | `/usr/bin/adb` |
| Existing instance (untouched) | `redroid14-ksu` (Android 14, port 5555) — used only as a source of `ksud`/modules |

SSH:
```powershell
ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" Rishi@35.254.242.42
# ADB tunnel from Windows:
ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" -N -L 5557:127.0.0.1:5557 Rishi@35.254.242.42
adb connect 127.0.0.1:5557
```

### Why Android 15 (not 16 or 17)
- **No ReDroid Android 17 image exists** — the newest published tag is Android 16 (`redroid/redroid:16.0.0_64only-latest`).
- **Android 16 does not boot headless on a GPU‑less host.** A16 removed the legacy GLES render engine and forces **Skia**, whose render targets need GPU‑writeable gralloc buffers that ReDroid's software gralloc can't provide → `surfaceflinger SIGABRT: "output buffer not gpu writeable"` → endless zygote/SF restart loop → black screen + scrcpy `InputManagerGlobal` NPE.
- **Android 15 (`redroid/redroid:15.0.0_64only-latest`) still ships the GLES render engine** and boots cleanly headless (like A14). It also supports recent (2026) security patch levels, so it is fully adequate for the integrity work.

---

## 1. Create the ReDroid 15 instance

### 1.1 Private BinderFS devices
Each concurrent Android container needs its own binder devices. Helper script `/usr/local/sbin/prepare-redroid-17-binder`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
MOUNTPOINT=/dev/binderfs-17
ADD_DEVICE=/usr/local/sbin/binderfs-add-device
test "$(id -u)" -eq 0
install -d -m 0755 "$MOUNTPOINT"
if ! mountpoint -q "$MOUNTPOINT"; then
  mount -t binder -o max=1048576 binder-17 "$MOUNTPOINT"
fi
test -c "$MOUNTPOINT/binder-control"
for name in binder hwbinder vndbinder; do
  [ -c "$MOUNTPOINT/$name" ] || "$ADD_DEVICE" "$MOUNTPOINT/binder-control" "$name"
  chmod 0666 "$MOUNTPOINT/$name"
done
```
```bash
sudo chmod +x /usr/local/sbin/prepare-redroid-17-binder
sudo /usr/local/sbin/prepare-redroid-17-binder   # creates /dev/binderfs-17/{binder,hwbinder,vndbinder}
```

### 1.2 Run the container
```bash
mkdir -p /home/Rishi/redroid17-data
sudo docker run -d --name redroid17_64only --privileged --restart unless-stopped \
  -p 127.0.0.1:5557:5555 \
  -v /home/Rishi/redroid17-data:/data \
  -v /dev/binderfs-17/binder:/dev/binder \
  -v /dev/binderfs-17/hwbinder:/dev/hwbinder \
  -v /dev/binderfs-17/vndbinder:/dev/vndbinder \
  -v /dev/null:/dev/kmsg \
  redroid/redroid:15.0.0_64only-latest \
  androidboot.redroid_gpu_mode=guest androidboot.use_memfd=1 ro.secure=0 ro.debuggable=1 \
  androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=320
```

| Container fact | Value |
|---|---|
| Image | `redroid/redroid:15.0.0_64only-latest` (Android 15, SDK 35, arm64‑v8a) |
| Port | `127.0.0.1:5557 → 5555` |
| Data bind | `/home/Rishi/redroid17-data:/data` |
| BinderFS | `/dev/binderfs-17` |
| GPU mode | `guest` (software; host has no GPU) |
| `ro.secure` / `ro.debuggable` (boot) | `0` / `1` (kept adb keyless; hardened later via module) |

Verify boot: `sudo docker exec redroid17_64only getprop sys.boot_completed` → `1`.

> **scrcpy note:** A vanilla ReDroid has *no launcher* and, until fully booted, no input device — that's why early `scrcpy` throws `KeyCharacterMap.load … InputManagerGlobal … null`. After the full stack (below) is up, `scrcpy -s 127.0.0.1:5557 --max-size=720 --video-codec=h264 --no-audio` works (control included).

---

## 2. Root — KernelSU

The host kernel is already KernelSU (`zksu`). ReDroid's root is **kernel‑driven**: the kernel auto‑execs `/data/adb/ksud` at boot (no in‑image init hook). Staging the KernelSU userspace into the new `/data/adb` activates root on restart.

```bash
# Copy ksud + ksu runtime from the working A14 instance (version-independent)
sudo mkdir -p /home/Rishi/redroid17-data/adb
sudo cp -a /home/Rishi/redroid14-data/adb/ksud /home/Rishi/redroid17-data/adb/
sudo cp -a /home/Rishi/redroid14-data/adb/ksu  /home/Rishi/redroid17-data/adb/
sudo mkdir -p /home/Rishi/redroid17-data/adb/modules /home/Rishi/redroid17-data/adb/modules_update
sudo chmod 0755 /home/Rishi/redroid17-data/adb/ksud
sudo chown -R 0:0 /home/Rishi/redroid17-data/adb
sudo docker restart redroid17_64only
```

- `ksud 3.3.0 (uapi: 2)`.
- **Root access model:** `docker exec redroid17_64only …` runs as **uid 0 (root)** directly — modules are installed with `ksud module install` via `docker exec`, no `su` needed. The ADB‑shell `su` is intentionally denied (empty allowlist) — irrelevant here.
- Confirm: `dmesg | grep KernelSU` shows the kernel handling the container's zygote children.

---

## 3. Magic Mount + Zygisk

### 3.1 `meta-mm` (Magic Mount metamodule)
Enables systemless overlaying of `/system`, `/product`, `/system_ext` (needed for GApps and the feature XML).
```bash
sudo docker cp /home/Rishi/kbuild/artifacts/gapps/meta-magic_mount-v1.0.1-sprout-release.zip redroid17_64only:/data/local/tmp/meta-mm.zip
sudo docker exec redroid17_64only sh -c 'cd /data/local/tmp && /data/adb/ksud module install meta-mm.zip'
```

### 3.2 Zygisk Next (required by PIF)
PIF is a **Zygisk** module, so Zygisk must be present first.
```bash
sudo docker cp /home/Rishi/kbuild/artifacts/android/Zygisk-Next-1.4.3-817-e815170-release.zip redroid17_64only:/data/local/tmp/zn.zip
sudo docker exec redroid17_64only sh -c 'cd /data/local/tmp && /data/adb/ksud module install zn.zip'
sudo docker restart redroid17_64only        # activates Zygisk (zygiskd / zygiskd64)
```
- **Zygisk Next `1.4.3 (817-e815170)`**. Verify: `bin/` has `zygiskd`, `zygiskd64`.

---

## 4. Google Apps — MindTheGapps 15 (arm64)

ReDroid ships no GApps, and there is **no Android‑15 LiteGApps** build. Used **MindTheGapps 15.0.0 arm64** (a plain `system/` tree) and repackaged it as a Magic‑Mount module.

```bash
# Download (from s1204IT/MindTheGappsBuilder)
curl -L -o /home/Rishi/kbuild/artifacts/gapps/MindTheGapps-15.0.0-arm64-20250330.zip \
  https://github.com/s1204IT/MindTheGappsBuilder/releases/download/20250330/MindTheGapps-15.0.0-arm64-20250330.zip

# Repackage as a KSU module (module.prop + the system/ tree)
D=/home/Rishi/redroid17-data/adb/modules_update/mindthegapps
sudo mkdir -p "$D"
sudo unzip -oq /home/Rishi/kbuild/artifacts/gapps/MindTheGapps-15.0.0-arm64-20250330.zip "system/*" -d "$D"
sudo tee "$D/module.prop" >/dev/null <<'EOF'
id=mindthegapps
name=MindTheGapps 15 arm64
version=15.0.0-20250330
versionCode=20250330
author=MindTheGapps
description=Google Apps (Play Store, GMS, GSF) for Android 15 arm64
EOF
sudo touch "$D/auto_mount" "$D/update"
sudo chown -R 0:0 "$D"
sudo docker restart redroid17_64only
```

After restart, `/system/product` is magic‑mounted and these register and self‑update over the network:
`com.google.android.gms` (+ Dynamite / GoogleCertificates splits), `com.android.vending` (Phonesky), `com.google.android.gsf`, `com.google.android.googlequicksearchbox`.

---

## 5. Device identity profile — `redroid_pixel8`

System‑wide Pixel 8 identity + locked/verified boot state. Module `/data/adb/modules/redroid_pixel8/system.prop`:

```properties
# Pixel 8 (shiba) identity
ro.product.model=Pixel 8
ro.product.brand=google
ro.product.name=shiba
ro.product.device=shiba
ro.product.manufacturer=Google
ro.product.system.model=Pixel 8
ro.product.system.brand=google
ro.product.system.name=shiba
ro.product.system.device=shiba
ro.product.system.manufacturer=Google
ro.product.product.model=Pixel 8
ro.product.product.brand=google
ro.product.product.name=shiba
ro.product.product.device=shiba
ro.product.product.manufacturer=Google
ro.product.vendor.model=Pixel 8
ro.product.vendor.brand=google
ro.product.vendor.name=shiba
ro.product.vendor.device=shiba
ro.product.vendor.manufacturer=Google
ro.product.system_ext.model=Pixel 8
ro.product.odm.model=Pixel 8
# Boot state (locked, verified)
ro.boot.verifiedbootstate=green
ro.boot.flash.locked=1
ro.boot.veritymode=enforcing
ro.boot.vbmeta.device_state=locked
ro.debuggable=0
# Recent patch (coherent with PIF + TrickyStore)
ro.build.version.security_patch=2026-09-05
ro.product.first_api_level=34
ro.board.first_api_level=34
ro.adb.secure=0
```

`module.prop`:
```properties
id=redroid_pixel8
name=ReDroid Pixel 8 Identity
version=1.0
versionCode=1
author=local
description=System-wide Pixel 8 (shiba) identity + locked/green boot state for integrity
```

> **`ro.secure` deliberately NOT set to 1.** Setting it would force adbd key‑auth and break scrcpy/adb from Windows (the container would need the *Windows* adb pubkey). `ro.debuggable=0` (the real integrity tell) is set; `ro.adb.secure=0` keeps adb keyless.

---

## 6. Fingerprint / signature spoof — PlayIntegrityFix (PIF)

**PIF injects the Pixel 8 fingerprint into the GMS/Play processes only** (via the Zygisk `.so`), so the attestation‑facing identity is coherent without corrupting the Android‑15 base. The fingerprint is a **verified, current Pixel 8 Canary** obtained live from Google's Flash Tool via `autopif4.sh` (osm0sis) forced to `shiba_beta`.

Module: `PlayIntegrityFix_v4.7-1-redroid.2-no-vending.zip` (chiteroman‑based, redroid variant).

`/data/adb/modules/playintegrityfix/pif.prop`:
```properties
FINGERPRINT=google/shiba_beta/shiba:CANARY/ZP11.260821.010/16290768:user/release-keys
MANUFACTURER=Google
MODEL=Pixel 8
SECURITY_PATCH=2026-09-05
spoofBuild=true
spoofProps=true
spoofProvider=false
spoofSignature=false
spoofVendingBuild=false
spoofVendingSdk=false
DEBUG=false
```

| Field | Value / meaning |
|---|---|
| Fingerprint | `google/shiba_beta/shiba:CANARY/ZP11.260821.010/16290768:user/release-keys` (Pixel 8, Canary `202609`) |
| Security patch | **2026‑09‑05** (fresh — matches TrickyStore + system prop) |
| `spoofBuild` | `true` — spoof `Build` fields in GMS |
| `spoofProps` | `true` — spoof system props inside the GMS process |
| `spoofSignature` | `false` (not needed; TrickyStore handles attestation) |

Install:
```bash
sudo docker cp /home/Rishi/kbuild/artifacts/modules/PlayIntegrityFix_v4.7-1-redroid.2-no-vending.zip redroid17_64only:/data/local/tmp/pif.zip
sudo docker exec redroid17_64only sh -c 'cd /data/local/tmp && /data/adb/ksud module install pif.zip'
# then write pif.prop above
```
Verify injection after restart: `libplayintegrityfix`/module path appears in `/proc/$(pidof com.google.android.gms.unstable)/maps`.

---

## 7. Hardware‑backed attestation — TrickyStore + keybox

TrickyStore injects `keystore2` and, in **generate mode (`!`)**, builds a full KeyMint attestation chain from a private keybox → this is the "software TEE simulation" that makes DEVICE integrity pass.

- **Module:** copied from `redroid14-ksu` (`/data/adb/modules/tricky_store`, `libtricky_store.so`).
- **Keybox:** `sha256 0214bdb42fe462a43e38a986943778a1624b3969f4ae72cc431c6130e481a19a` (private, unrevoked).

`/data/adb/tricky_store/target.txt`:
```
com.android.vending
com.google.android.gms!
gr.nikolasspyr.integritycheck
```
`/data/adb/tricky_store/security_patch.txt`:
```
system=202609
boot=2026-09-05
vendor=2026-09-05
```

```bash
R17=/home/Rishi/redroid17-data/adb
sudo cp -a /home/Rishi/redroid14-data/adb/modules/tricky_store $R17/modules_update/tricky_store
sudo touch $R17/modules_update/tricky_store/update
sudo mkdir -p $R17/tricky_store
sudo cp /home/Rishi/redroid14-data/adb/tricky_store/keybox.xml $R17/tricky_store/keybox.xml
printf 'com.android.vending\ncom.google.android.gms!\ngr.nikolasspyr.integritycheck\n' | sudo tee $R17/tricky_store/target.txt
printf 'system=202609\nboot=2026-09-05\nvendor=2026-09-05\n'                        | sudo tee $R17/tricky_store/security_patch.txt
sudo chown -R 0:0 $R17/modules_update/tricky_store $R17/tricky_store
sudo chmod 600 $R17/tricky_store/keybox.xml
```
Verify: `grep -E 'tricky|libtricky' /proc/$(pidof keystore2)/maps`.

> **Coherence is the point:** system prop, PIF `SECURITY_PATCH`, and TrickyStore `security_patch.txt` all read **2026‑09‑05**, matching the fresh Pixel 8 Canary fingerprint.

---

## 8. GSF `android_id` (attempted; not durable)

Injecting a pre‑registered id into `com.google.android.gms/databases/gservices.db` (`main.android_id`) **reverts on checkin** — Google reasserts the device's own server id. The pre‑registered numbers only stick with their matching checkin security token (not available). The device kept its fresh, validly‑checked‑in id. **This did not affect the final success.**

```bash
# (reference only — reverted)
sudo docker exec redroid17_64only sh -c 'am force-stop com.google.android.gms; am force-stop com.google.android.gsf'
sudo sqlite3 /home/Rishi/redroid17-data/data/com.google.android.gms/databases/gservices.db \
  'UPDATE main SET value="4235531228661065400" WHERE name="android_id"; PRAGMA wal_checkpoint(TRUNCATE);'
# checkin overrides it back → keep the fresh id
```

---

## 9. ⭐ The decisive fix: "App not available" → **Install** (Play device catalog)

### The problem
After sign‑in, DiskWala briefly showed **Install**, then flipped to **"This app won't work on your device."** Finsky logs:
```
Finsky: # ceig@… not available [restriction=9].
Finsky: Item is not available. Reason: 6
```
`restriction=9` = Play's **HARDWARE_RULE / device‑catalog filter**. Play uploads a **DeviceConfig** (feature list, GL, ABIs, RAM…) after first sync; DiskWala's developer catalog then rejected the device because its real profile advertised only **54 features** — nothing like a real Pixel 8 (no telephony, few sensors, no StrongBox feature, no Pixel‑experience features). Clearing Play did **not** help (config cached server‑side).

### The fix — publish a full Pixel 8 feature profile
Module `pixel8_features` supplying `/system/etc/permissions/pixel8-features.xml` with the complete Pixel 8 hardware/software feature set. This raised the advertised feature count **54 → 123**, so the DeviceConfig Play uploads matches a real Pixel 8, and `restriction=9` disappeared.

`module.prop`:
```properties
id=pixel8_features
name=Pixel 8 Feature Profile
version=1.0
versionCode=1
author=local
description=Declares Pixel 8 hardware/software features so Play device catalog treats device as a real Pixel 8
```

`system/etc/permissions/pixel8-features.xml` (full set applied):
```xml
<?xml version="1.0" encoding="utf-8"?>
<permissions>
  <!-- Telephony -->
  <feature name="android.hardware.telephony" />
  <feature name="android.hardware.telephony.gsm" />
  <feature name="android.hardware.telephony.ims" />
  <feature name="android.hardware.telephony.calling" />
  <feature name="android.hardware.telephony.data" />
  <feature name="android.hardware.telephony.messaging" />
  <feature name="android.hardware.telephony.radio.access" />
  <feature name="android.hardware.telephony.subscription" />
  <feature name="android.hardware.telephony.euicc" />
  <!-- Camera -->
  <feature name="android.hardware.camera" />
  <feature name="android.hardware.camera.any" />
  <feature name="android.hardware.camera.autofocus" />
  <feature name="android.hardware.camera.flash" />
  <feature name="android.hardware.camera.front" />
  <feature name="android.hardware.camera.level.full" />
  <feature name="android.hardware.camera.capability.manual_post_processing" />
  <feature name="android.hardware.camera.capability.manual_sensor" />
  <feature name="android.hardware.camera.capability.raw" />
  <feature name="android.hardware.camera.concurrent" />
  <!-- Connectivity -->
  <feature name="android.hardware.bluetooth" />
  <feature name="android.hardware.bluetooth_le" />
  <feature name="android.hardware.nfc" />
  <feature name="android.hardware.nfc.any" />
  <feature name="android.hardware.nfc.hce" />
  <feature name="android.hardware.nfc.hcef" />
  <feature name="android.hardware.nfc.ese" />
  <!-- Biometrics -->
  <feature name="android.hardware.fingerprint" />
  <feature name="android.hardware.biometrics.face" />
  <!-- Sensors -->
  <feature name="android.hardware.sensor.accelerometer" />
  <feature name="android.hardware.sensor.barometer" />
  <feature name="android.hardware.sensor.compass" />
  <feature name="android.hardware.sensor.gyroscope" />
  <feature name="android.hardware.sensor.light" />
  <feature name="android.hardware.sensor.proximity" />
  <feature name="android.hardware.sensor.stepcounter" />
  <feature name="android.hardware.sensor.stepdetector" />
  <feature name="android.hardware.sensor.hinge_angle" />
  <!-- Location / WiFi / USB / Audio -->
  <feature name="android.hardware.location" />
  <feature name="android.hardware.location.gps" />
  <feature name="android.hardware.location.network" />
  <feature name="android.hardware.wifi" />
  <feature name="android.hardware.wifi.direct" />
  <feature name="android.hardware.wifi.aware" />
  <feature name="android.hardware.wifi.passpoint" />
  <feature name="android.hardware.wifi.rtt" />
  <feature name="android.hardware.usb.host" />
  <feature name="android.hardware.usb.accessory" />
  <feature name="android.hardware.audio.output" />
  <feature name="android.hardware.audio.low_latency" />
  <feature name="android.hardware.audio.pro" />
  <feature name="android.hardware.microphone" />
  <!-- Graphics -->
  <feature name="android.hardware.opengles.aep" />
  <feature name="android.hardware.vulkan.compute" />
  <feature name="android.hardware.vulkan.level" version="1" />
  <feature name="android.hardware.vulkan.version" version="4198403" />
  <!-- Secure element / keystore (integrity-relevant) -->
  <feature name="android.hardware.se.omapi.ese" />
  <feature name="android.hardware.se.omapi.uicc" />
  <feature name="android.hardware.strongbox_keystore" />
  <feature name="android.hardware.hardware_keystore" version="300" />
  <feature name="android.hardware.identity_credential" />
  <feature name="android.hardware.keystore.app_attest_key" />
  <feature name="android.hardware.ram.normal" />
  <feature name="android.software.device_id_attestation" />
  <feature name="android.software.verified_boot" />
  <!-- Software -->
  <feature name="android.software.midi" />
  <feature name="android.software.sip" />
  <feature name="android.software.sip.voip" />
  <feature name="android.software.ipsec_tunnels" />
  <feature name="android.software.telecom" />
  <feature name="android.software.connectionservice" />
  <feature name="android.software.controls" />
  <feature name="android.software.credentials" />
  <feature name="android.software.companion_device_setup" />
  <!-- Google / Pixel experience -->
  <feature name="com.google.android.feature.PIXEL_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2023_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2022_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2021_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2020_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2020_MIDYEAR_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2019_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2019_MIDYEAR_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2018_EXPERIENCE" />
  <feature name="com.google.android.feature.PIXEL_2017_EXPERIENCE" />
  <feature name="com.google.android.feature.GOOGLE_BUILD" />
  <feature name="com.google.android.feature.GOOGLE_EXPERIENCE" />
  <feature name="com.google.android.feature.TURBO_PRELOAD" />
  <feature name="com.google.android.feature.WELLBEING" />
  <feature name="com.google.android.feature.ASI" />
  <feature name="com.google.android.feature.ANDROID_ONE_EXPERIENCE_2017" />
  <feature name="com.google.android.apps.dialer.SUPPORTED" />
  <feature name="com.google.android.apps.dialer.call_recording_audio" />
  <feature name="com.google.android.feature.EXCHANGE_6_2" />
  <feature name="com.google.android.feature.NEXT_GENERATION_ASSISTANT" />
  <feature name="com.verizon.hardware.telephony.ehrpd" />
  <feature name="com.verizon.hardware.telephony.lte" />
</permissions>
```

Apply + force Play to re‑upload the DeviceConfig:
```bash
D=/home/Rishi/redroid17-data/adb/modules_update/pixel8_features
sudo mkdir -p "$D/system/etc/permissions"
# write module.prop + pixel8-features.xml above
sudo touch "$D/update"; sudo chown -R 0:0 "$D"
sudo docker restart redroid17_64only
# after boot, re-sync Play so it re-uploads the richer DeviceConfig:
sudo docker exec redroid17_64only sh -c 'pm clear com.android.vending'
# reopen the store page:
sudo docker exec redroid17_64only sh -c 'am start -a android.intent.action.VIEW -d market://details?id=com.diskwalaapp com.android.vending'
```

Result: `pm list features` → **123**; Finsky no longer logs `restriction=9`; DiskWala shows **Install**.

---

## 10. Sign‑in, install, result

1. `scrcpy -s 127.0.0.1:5557 --max-size=720 --video-codec=h264 --no-audio`
2. Play Store → sign in with a Google account.
3. Install DiskWala **from Play** (real transaction).

**Verified final state:**
```
com.diskwalaapp  versionName=26.4
installerPackageName=com.android.vending
initiatingPackageName=com.android.vending   ← genuine Play install (both = vending)
```
- **PairIP key‑transfer = TRUSTED** → Play delivered the AES VM‑encryption key → VM assets decrypted → **app launched**.
- No `dictionary/pairip.json` (no RePairip capture needed — the real key lives in the device Keystore).
- Play Integrity checker (`gr.nikolasspyr.integritycheck`): **BASIC ✅, DEVICE ✅, STRONG ❌** (2‑pass / 1‑fail).

---

## 11. Why it worked — and what actually mattered

There were **two independent PairIP gates**, both cleared by a **genuine Play install on a coherent, catalog‑eligible Pixel 8**:

1. **Native install‑source / signature gate** (`libpairipcore.so`): requires `initiatingPackageName = com.android.vending` + original signature. A **real Play transaction** satisfies this natively — no patching.
2. **VM‑encryption key‑transfer gate** (Play `securedatatransfer` anti‑tamper): returned **TRUSTED** and delivered the key.

**Decisive levers, in order of importance:**
1. **Play device‑catalog eligibility** (the `pixel8_features` profile) — without it, no genuine install path exists (`restriction=9`), so neither gate can be satisfied.
2. **Coherent recent Pixel 8 identity** — PIF Canary fingerprint + `redroid_pixel8` props + all patch levels aligned to **2026‑09‑05**.
3. **DEVICE integrity** via TrickyStore + unrevoked keybox.
4. **Locked/verified boot state** (`green` / `flash.locked=1` / `veritymode=enforcing`).

**Notably NOT required:**
- **STRONG integrity** — it failed throughout, yet the key‑transfer was TRUSTED. This corrects the earlier hypothesis that PairIP's key‑transfer needs STRONG. It needs a *genuine Play‑delivered install on a DEVICE‑trusted, catalog‑eligible device*.
- **A durable pre‑registered GSF id** — the fresh checkin id was fine.
- **RePairip capture** — unnecessary once the real key is delivered.

---

## 12. Final module stack (`/data/adb/modules`)

| Module | Purpose |
|---|---|
| `zygisksu` | Zygisk Next 1.4.3 (hosts PIF) |
| `meta-mm` | Magic Mount (systemless overlays) |
| `mindthegapps` | Google Play / GMS / GSF (A15 arm64) |
| `redroid_pixel8` | System‑wide Pixel 8 identity + locked/verified boot |
| `playintegrityfix` | Pixel 8 Canary fingerprint into GMS (BASIC + recognition) |
| `tricky_store` | KeyMint attestation from keybox (DEVICE) |
| `pixel8_features` | **Pixel 8 feature profile → Play catalog eligibility (Install)** |

## 13. Reproduce / verify

```bash
C=redroid17_64only
# stack
sudo docker exec $C sh -c 'ls /data/adb/modules'
sudo docker exec $C sh -c 'pm list features | wc -l'            # 123
# identity
sudo docker exec $C sh -c 'getprop ro.product.model; getprop ro.boot.verifiedbootstate; getprop ro.build.version.security_patch'
# injections
sudo docker exec $C sh -c 'grep -l tricky /proc/$(pidof keystore2)/maps'
# DiskWala install attribution
sudo docker exec $C sh -c 'dumpsys package com.diskwalaapp | grep -iE "installerPackageName|initiatingPackageName|versionName"'
# integrity: launch gr.nikolasspyr.integritycheck, tap CHECK, "Show JSON"
```

## 14. Caveats / gotchas
- **Android 16/17 are not usable** on this GPU‑less host (SF Skia crash). Stay on **A15**.
- **Keybox `0214bdb4` is private/unrevoked** — if it lands on Google's CRL, DEVICE (and this whole flow) can break; keep a spare.
- **`ro.secure` left at 0** to preserve keyless adb/scrcpy; set `ro.debuggable=0` for the integrity tell only.
- **`pm clear com.android.vending`** is the reliable way to force Play to re‑upload the DeviceConfig after changing the feature profile.
- The **feature profile is the crux** — if Play ever flips back to "not available," re‑check `pm list features` and the `restriction=` code in Finsky logs first.
