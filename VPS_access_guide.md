# VPS ACCESS
    key path = C:/Users/YOUR_WINDOWS_USER/.ssh/YOUR_PRIVATE_KEY.key
    env = ubuntu
    instance ip = YOUR_VPS_PUBLIC_IP
---
## Restrict permissions (Windows)

SSH refuses to use keys that are accessible by other users.
Run:
icacls.exe "oracle.key" /inheritance:r
Then:
icacls.exe "oracle.key" /grant:r "$($env:USERNAME):(R)"

i.e 

Run:
icacls.exe "C:/Users/YOUR_WINDOWS_USER/.ssh/YOUR_PRIVATE_KEY.key" /inheritance:r
Then:
icacls.exe "C:/Users/YOUR_WINDOWS_USER/.ssh/YOUR_PRIVATE_KEY.key" /grant:r "$($env:USERNAME):(R)"

> ONE TIME THING (ALREADY DONE)
--- 

## CMD to enter VPS 

ssh -i "C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key" -o StrictHostKeyChecking=no ubuntu@141.148.151.172

## Connecting PORT to use "adb connect 127.0.0.1:5555"

ssh -i "C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key" `
  -o ExitOnForwardFailure=yes `
  -o ServerAliveInterval=30 `
  -N `
  -L 127.0.0.1:5555:127.0.0.1:5555 `
  ubuntu@141.148.151.172

## Accessing GUI of redroid 
scrcpy -s 127.0.0.1:5555 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

# REDROID EXPERIMENTAL COMMANDS:

# The experimental instance publishes ADB on host port 5557 (container 5555).
# Its own /data, hostname (redroid-experimental) and /dev/binderfs-experimental.

## Connecting PORT to use "adb connect 127.0.0.1:5557"

ssh -i "C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key" `
  -o ExitOnForwardFailure=yes `
  -o ServerAliveInterval=30 `
  -N `
  -L 127.0.0.1:5557:127.0.0.1:5557 `
  ubuntu@141.148.151.172

## Then, from another terminal:
adb connect 127.0.0.1:5557

## Accessing GUI of redroid-experimental
scrcpy -s 127.0.0.1:5557 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

# NOTE: the experimental image is debuggable, so its adbd starts in root mode and
# ADB-over-TCP can come up "offline". A KernelSU boot script
# (/data/adb/service.d/adb-tcp.sh) now re-arms TCP adbd after every boot. If it
# ever still shows "offline", re-apply it once on the VPS:
#   C=$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid-experimental')
#   sudo docker exec "$C" sh -c 'setprop service.adb.tcp.port 5555; setprop service.adb.root 0; setprop ctl.restart adbd'
#   adb kill-server; adb connect 127.0.0.1:5557   # -> device