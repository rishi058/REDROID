# Redroid 14 + KernelSU Deployment Record

Validated on 2026-07-28 against VPS `YOUR_VPS_PUBLIC_IP`.

## Installed stack

- Host kernel: `6.8.12-zksu #14` on ARM64 Ubuntu 24.04.
- Redroid: Android 14 64-bit-only, immutable image digest `sha256:0a611199ba2e0b5d60af39b3327a517f6407231f4352114ed3bd3cbfe2be69aa`.
- KernelSU Next kernel/userspace: v3.3.0, Manager build 33214.
- Zygisk Next: v1.4.3 build 817, runtime reports `zygote` and KernelSU root active.
- LSPosed: v1.9.2 build 7024, daemon, bridge, companion, and runtime log verified.

## Host containment

- Container restart policy: `no`; systemd starts it once after Docker and binderfs are ready.
- CPU: 1.5 of the 2 VPS CPUs during normal operation.
- Memory: 8 GiB hard RAM limit; 10 GiB combined RAM+swap limit.
- Tasks: 8,192 hard cgroup limit; permanent watchdog kills at 7,000.
- ADB: `127.0.0.1:5555` only.
- Binder: the three binderfs device inodes are explicitly bind-mounted.
- Android `/dev/kmsg`: mapped to `/dev/null` so Android log storms cannot flood the host journal/serial console.
- Persistent services: `redroid14.service`, `redroid14-watchdog.service`, and `redroid14-validate.service`.

## Root cause of the prior lockups

The failed containers used recreated Binder device nodes. Binderfs device state is attached to the binderfs inode, so the look-alike nodes returned `ENXIO`. Android repeatedly restarted `servicemanager` and related services. Redroid redirects init output to `/dev/kmsg`; this produced bursts near 400 host journal lines per second. There was no host OOM, kernel panic, or hung task in those incidents.

Exit 137 in the later canary was the original 600-task watchdog sending
`SIGKILL`; Docker counts Android threads in PIDS. The root-only stack later used
1,400/1,536, but a healthy LiteGapps first boot reached 1,403 tasks and was
mistakenly killed. The modding-friendly watchdog/hard-cap pair is therefore
7,000/8,192, still below the prior runaway workload of about 8,230 tasks.

## Operations

Check status:

```bash
sudo systemctl status redroid14.service redroid14-watchdog.service
sudo docker stats --no-stream redroid14-ksu
sudo docker exec redroid14-ksu getprop sys.boot_completed
```

Connect ADB from the local computer:

```bash
ssh -N -L 5555:127.0.0.1:5555 ubuntu@YOUR_VPS_PUBLIC_IP
adb connect 127.0.0.1:5555
```

KernelSU's init and zygote hooks are one-shot per host-kernel boot. For a full root-stack restart, reboot the VPS with `sudo systemctl reboot`; do not use `docker restart redroid14-ksu`.

## Distribution artifacts

- `kernel-build/packages/linux-image-6.8.12-zksu_6.8.12-14_arm64.deb` — SHA-256 `38111a5d8d81135cebdd19d90c95b31978d36f27cfefe828645c0e7c82aefb16`.
- `kernel-build/packages/linux-headers-6.8.12-zksu_6.8.12-14_arm64.deb` — SHA-256 `26eaee701ac33316f5c22151154576161132a75e6376f512b4b2f4899becb80a`.
- Android Manager, `ksud`, Zygisk Next, and LSPosed are under `artifacts/android`; verify them with its `SHA256SUMS` before distribution.

KernelSU Next officially documents kernel support only through Linux 6.6. This 6.8 package is a tested compatibility port, not an upstream-supported combination; retain the stock Ubuntu kernel as the rollback path.
