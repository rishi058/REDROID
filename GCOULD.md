Project dashboard:
https://console.cloud.google.com/home/dashboard?project=redroid-vm-20260919

VM details:
https://console.cloud.google.com/compute/instancesDetail/zones/us-central1-c/instances/redroid-vm?project=redroid-vm-20260919

All VM instances:
https://console.cloud.google.com/compute/instances?project=redroid-vm-20260919

Billing account and credit usage:
https://console.cloud.google.com/billing/01B804-F41C1A-EBF4D4

Project billing reports:
https://console.cloud.google.com/billing/reports?project=redroid-vm-20260919

Budgets and alerts:
https://console.cloud.google.com/billing/budgets?project=redroid-vm-20260919


use gcloud prefix to acess gcloud cli

ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" Rishi@35.188.214.74

ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" -N `
  -L 5555:127.0.0.1:5555 `
  Rishi@35.188.214.74

adb connect 127.0.0.1:5555

scrcpy -s 127.0.0.1:5555 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

---

ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" -N `
  -L 5557:127.0.0.1:5557 `
  Rishi@35.188.214.74

adb connect 127.0.0.1:5557

scrcpy -s 127.0.0.1:5557 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

---

ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" -N `
  -L 5559:127.0.0.1:5559 `
  Rishi@35.188.214.74

adb connect 127.0.0.1:5559

scrcpy -s 127.0.0.1:5559 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

---

ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" -N `
  -L 5556:127.0.0.1:5556 `
  Rishi@35.188.214.74

adb connect 127.0.0.1:5556

scrcpy -s 127.0.0.1:5556 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

---

ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" -N `
  -L 5558:127.0.0.1:5558 `
  Rishi@35.188.214.74

adb connect 127.0.0.1:5558

scrcpy -s 127.0.0.1:5558 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

---


ssh -i "C:\Users\Rishi\.ssh\redroid-vm-20260919" -N `
  -L 6000:127.0.0.1:6000 `
  Rishi@35.188.214.74

adb connect 127.0.0.1:6000

scrcpy -s 127.0.0.1:6000 --max-size=720 --max-fps=24 --video-bit-rate=2M --video-codec=h264 --no-audio

