## HOW TO START REDROID CONTAINER

`wsl` to enter the inside Ubuntu .
Here no ssh tunneling is needed port of wsl = post of host

just do `adb connect 127.0.0.1:5555`

AND 

> scrcpy -s 127.0.0.1:5555 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

for Launching GUI

## Current root-stack status

Installed APKs inside this local Redroid instance:

- KernelSU Manager: `com.rifsxd.ksunext`
- LSPosed Manager UI: `org.lsposed.manager`

Install commands used:

```bash
adb -s 127.0.0.1:5555 install -r \
	/mnt/d/PROJECT/_TRASH/REDROID/KernelSU_setup/artifacts/android/KernelSU_Next_v3.3.0_33214-release.apk

adb -s 127.0.0.1:5555 install -r \
	/mnt/d/PROJECT/_TRASH/REDROID/rev-eng/modules/zygisk_lsposed/manager.apk
```

Important: these are UI APKs only on the current local WSL setup. Zygisk Next,
LSPosed runtime, and LiteGApps are not active because this WSL kernel is the
BinderFS-only kernel, not a KernelSU kernel. Runtime checks currently show:

```text
/proc/config.gz: no CONFIG_KSU
/data/adb/ksud: missing
adb shell su -c id: fails
ps -A | grep -Ei 'zygisk|lspd|ksud': no runtime processes
```

The repo's KernelSU setup docs install modules through:

```bash
/data/adb/ksud module install <module.zip>
```

That requires a host kernel with KernelSU built in and a matching local `ksud`.
Until that exists for this x86_64 WSL/Redroid setup, do not treat the manager UI
as proof that KernelSU, Zygisk Next, LSPosed, or LiteGApps are active.