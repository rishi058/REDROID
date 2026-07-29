## What this folder contains

> “lsposed.zip” = the upstream LSPosed/Vector v1.11.0 package used for the setup.

> “zygisk_lsposed” = a locally generated, patched LSPosed Zygisk module directory created from that release.

### lsposed.zip / zygisk_lsposed

The archive in this folder is the Magisk/Zygisk module payload for the upstream LSPosed framework project, not a custom fork. The embedded package README identifies the project as “LSPosed Framework” and points to the GitHub repository:

- Repository: https://github.com/JingMatrix/LSPosed
- Release page: https://github.com/JingMatrix/LSPosed/releases

The specific build used in this workflow is the documented “Vector v1.11.0” release, which was chosen because its `/data/adb/lspd` database layout matched the headless-scoping workflow used in the Redroid/KernelSU setup.

#### What was patched / rebuilt locally

The local folder named `zygisk_lsposed` was not just copied from the archive. The documented workflow used a host-side helper script to recreate the module’s Magisk install logic and then patch the packaged binaries for this environment:

- Recreate the module’s `customize.sh` behavior on the host.
- Extract the architecture-specific payloads from the release package:
  - `zygisk/arm64-v8a.so`
  - `zygisk/armeabi-v7a.so`
  - `bin/arm64-v8a/dex2oat`
  - `bin/armeabi-v7a/dex2oat`
  - `bin/arm64-v8a/liboat_hook.so`
  - `bin/armeabi-v7a/liboat_hook.so`
- Apply the documented `DEV_PATH` binary patch by replacing the placeholder value `5291374ceda0aef7c5d86cd2a4f6a3ac` with a fresh random 32-hex string in the packaged `daemon.apk` and the `dex2oat32/64` binaries.
- Assemble the resulting module tree into the folder `zygisk_lsposed/`.

The helper scripts referenced in the notes were:

- `build_lsposed.py` — generates the patched `zygisk_lsposed/` tree.
- `place_lsposed.sh` — pushes the generated tree into `/data/adb/modules/zygisk_lsposed/` with the expected permissions.
- `setup_magiskbin.sh` — repopulates the Magisk binary payload in the container.
- `scope_pairipfix.sh` — enables the module and scopes it to the target app in the LSPosed database.
- `check_lspd_db.sh` — verifies that the `lspd` daemon and the LSPosed database are present.

> Note: these helper scripts are referenced in the reverse-engineering notes, but they are not currently present as checked-in files in this workspace snapshot. The commands below are the ones documented for the workflow.

#### Commands used in the documented workflow

```powershell
# repopulate the Magisk payload inside the container
MSYS_NO_PATHCONV=1 adb push setup_magiskbin.sh /data/local/tmp/
MSYS_NO_PATHCONV=1 adb shell "/system/xbin/su 0 sh /data/local/tmp/setup_magiskbin.sh"

# build the patched module tree on the host
python build_lsposed.py

# push the generated module into the device module directory
MSYS_NO_PATHCONV=1 adb push modules/zygisk_lsposed /data/local/tmp/
MSYS_NO_PATHCONV=1 adb push place_lsposed.sh /data/local/tmp/
MSYS_NO_PATHCONV=1 adb shell "/system/xbin/su 0 sh /data/local/tmp/place_lsposed.sh"

# restart the container and verify the LSPosed DB
docker restart a13_1
# then run the verification helper
# sh /data/local/tmp/check_lspd_db.sh
```

#### What the package contains

The archive includes the normal LSPosed Magisk module payload files such as:

- `module.prop`
- `customize.sh`
- `service.sh`
- `action.sh`
- `uninstall.sh`
- `daemon.apk`
- `manager.apk`
- the architecture-specific `bin/` and `lib/` payloads for `dex2oat`, `liboat_hook.so`, and `liblspd.so`

In other words, `lsposed.zip` is the upstream source package, while `zygisk_lsposed/` is the locally assembled, patched, device-installable module tree produced from it.

### pairipfix.apk

`exp/modules/pairipfix.apk` is the ready-made v1.2 module from the upstream
[ahmedmani/pairipfix](https://github.com/ahmedmani/pairipfix) project. 

> Rebuild `pairipfix.apk` from upstream source

To reproduce the preserved v1.2 APK, use the upstream source tag rather than
anything in this repository. The project is a normal Gradle Android project
(`app/`, `gradlew`, and Gradle Kotlin build files), not a hand-built module
like `mod_build`.

```powershell
git clone --branch v1.2 --depth 1 https://github.com/ahmedmani/pairipfix.git pairipfix-src
Set-Location pairipfix-src
.\gradlew.bat assembleRelease
Copy-Item .\app\build\outputs\apk\release\app-release.apk ..\exp\modules\pairipfix.apk
```

Requirements are a JDK compatible with the repository's Gradle wrapper and
an Android SDK available to Gradle. The upstream build uses Android Gradle
Plugin and declares Xposed API 82 as a compile-only dependency; Gradle obtains
these dependencies during the first build. A locally rebuilt APK will have
the same module behaviour but will normally have a different signing key and
may not have byte-identical archive metadata. If an old copy is installed,
uninstall it before installing a locally rebuilt copy:

```powershell
adb uninstall io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
```

The unusual installed package name is produced by the upstream v1.2 Gradle
settings (`rootProject.name` is duplicated), not by the local setup.

Install the preserved module APK twice. The reinstall re-emits package-added state
so LSPosed registers it.

```powershell
adb install exp\modules\pairipfix.apk
adb install -r exp\modules\pairipfix.apk
adb shell 'pm list packages | grep -i pairip'
```

This build registers under the malformed-but-real package ID below; do not replace it
with an assumed package name:

```text
io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
```

Enable and scope it only to target-app from a root ADB shell:

```powershell
adb shell
```

Then run these commands inside that device shell:

```sh
DB=/data/adb/lspd/config/modules_config.db
PKG=io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
sqlite3 "$DB" "UPDATE modules SET enabled=1 WHERE module_pkg_name='$PKG';"
sqlite3 "$DB" "INSERT OR IGNORE INTO scope(mid,app_pkg_name,user_id) SELECT mid,'com.target-appapp',0 FROM modules WHERE module_pkg_name='$PKG';"
```

The script updates `modules_config.db` to set `enabled=1` and adds the scope row for
`com.target-appapp`, user `0`. Confirmed database state:

```text
2|1|io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
2|io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix|com.target-appapp|0
```

### Talseckill.apk
This is the o/p generated by mod_build
