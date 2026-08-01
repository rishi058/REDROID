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

# Connecting PORT to use "adb connect 127.0.0.1:5555"

ssh -i "C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key" `
  -o ExitOnForwardFailure=yes `
  -o ServerAliveInterval=30 `
  -N `
  -L 127.0.0.1:5555:127.0.0.1:5555 `
  ubuntu@141.148.151.172