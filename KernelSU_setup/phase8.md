# Phase 8+ Execution Record: Deploying `6.8.12-zksu-multi` to Production and Validating Multi-Instance KernelSU

This document records everything done **after Phase 7** (the local build) during the
2026-08-20 session: copying the compiled kernel to the production Oracle ARM64 VPS,
booting it, validating production `redroid14`, diagnosing and fixing a **network
bridge outage**, applying a `dw-fast-api` hotfix, and finally bringing up
`redroid-experimental` to prove the multi-instance objective.

The build procedure (Phases 1–7) lives in
[multi-instance-kernel-patch-plan.md](multi-instance-kernel-patch-plan.md). This file
is the deployment/runtime record (Phases 8–15) plus the incidents encountered.

Access: `ssh -i "<key>" ubuntu@141.148.151.172` (see [VPS_access_guide.md](../VPS_access_guide.md)).
Package release under test: `6.8.12-zksu-multi` (`6.8.12-5`), rollback default `6.8.12-zksu`.

---

## Outcome summary

| Item | Result |
|---|---|
| New kernel booted on production host | ✅ `6.8.12-zksu-multi`, no panic/BUG/ENXIO |
| Production `redroid14` rooted (KernelSU/Zygisk/LSPosed) | ✅ `lspd` pid 357 |
| **Network bridge outage (dw-fast-api ↔ redroid14)** | ⚠️ hit, root-caused, fixed (see below) |
| `dw-fast-api` hotfix (SSH tunnel in prod) | ✅ `USE_SSH_TUNNEL` |
| **`redroid-experimental` rooted (2nd instance)** | ✅ `lspd` pid 76, Zygisk Next + LSPosed |
| Both instances rooted **simultaneously** | ✅ **multi-instance objective achieved** |
| Guarded KernelSU replay watcher | ✅ watches both `5555` and `5557`; ignores manual `docker stop`; schedules one full VPS reboot only if a running container loses root injection state after container-only restart |
| Rollback path preserved | ✅ `saved_entry` still `6.8.12-zksu` |

---

## Pre-flight decisions (Phase 8)

Confirmed with the operator before touching production:

- **Boot-volume backup:** exists. ✅
- **Serial console:** not set up — accepted the risk because the one-time
  `grub-reboot` auto-recovers to the known-good kernel on the next boot, and OCI
  console hard-reset + boot-volume backup remain as fallbacks. Recovery strategy:
  **poll SSH** until the host returns.
- **Maintenance window:** open (production traffic could stop briefly).
- **Scope:** full deployment — transfer, install, one-time reboot, validate.

Baseline captured (running `6.8.12-zksu`, `/boot` 616M free, all rollback kernels
installed). Services mapped: `dw-fast-api`, `tera-box-video-downloader` (terabox),
`redroid14`, `openobserve`, `flare-solverr-patch`, coolify stack — all healthy.
`redroid-experimental` existed as a Coolify service but was not running (root stack
already staged in `/home/ubuntu/redroid-experimental-data`).

---

## Phase 9 — Transfer packages

```powershell
$Key='C:/Users/Rishi/.ssh/ssh-key-2026-07-06(pvt).key'; $Target='ubuntu@141.148.151.172'
$Pkg='.\KernelSU_setup\artifacts\kernel-build\packages-zksu-multi'
ssh -i $Key $Target 'mkdir -p /home/ubuntu/kbuild/artifacts/packages-zksu-multi'
scp -i $Key "$Pkg\linux-image-6.8.12-zksu-multi_6.8.12-5_arm64.deb" `
            "$Pkg\linux-headers-6.8.12-zksu-multi_6.8.12-5_arm64.deb" `
            "$Pkg\SHA256SUMS" "${Target}:/home/ubuntu/kbuild/artifacts/packages-zksu-multi/"
```

Verified on the VPS: `sha256sum -c SHA256SUMS` OK, both packages `Architecture: arm64`,
`/boot` had ~615M free.

---

## Phase 10 — Install without changing the default

```bash
cd /home/ubuntu/kbuild/artifacts/packages-zksu-multi
sudo cp -a /etc/default/grub "/etc/default/grub.before-zksu-multi.$(date +%s)"
sudo grub-editenv list > "$HOME/grubenv.before-zksu-multi"
sudo dpkg -i linux-headers-6.8.12-zksu-multi_6.8.12-5_arm64.deb \
             linux-image-6.8.12-zksu-multi_6.8.12-5_arm64.deb
sudo update-initramfs -u -k 6.8.12-zksu-multi
sudo update-grub
```

DKMS ran, initramfs generated, GRUB found `6.8.12-zksu-multi` plus rollback kernels
(`6.8.12-zksu`, `6.8.0-138-generic`). Boot files, `/lib/modules/6.8.12-zksu-multi`,
and the modular `binder_linux.ko.zst` confirmed present with correct vermagic and
depmod entry.

---

## Phase 11 — One-time boot into the new kernel

Exact GRUB path extracted from `/boot/grub/grub.cfg`:

```
gnulinux-advanced-832e6a94-...>gnulinux-6.8.12-zksu-multi-advanced-832e6a94-...
```

```bash
sudo grub-reboot 'gnulinux-advanced-...>gnulinux-6.8.12-zksu-multi-advanced-...'
sudo grub-editenv list   # next_entry = zksu-multi, saved_entry stays zksu
# reboot scheduled via systemd-run so the SSH call returns cleanly
sudo systemd-run --on-active=2 systemctl reboot
```

Host returned after ~64s on `6.8.12-zksu-multi` (new `boot_id` confirmed a real reboot).

---

## Phase 12 — Post-boot validation

Host/kernel: `uname -r` = `6.8.12-zksu-multi`, **no failed units**, `binder_linux`
loaded, `dev-binderfs.mount` / `binder-bindmounts.service` /
`redroid-binder-permissions.service` all active, binderfs nodes (main + experimental)
mode 666, **no panic/BUG/Oops/ENXIO/binder errors** in `dmesg`.

Production `redroid14` (auto-started via Docker `restart: unless-stopped`):

```
boot_completed=1 · OOM=false · ksud 3.3.0 · lspd running (357)
litegapps / meta-mm / zygisk_lsposed enabled
```

`coolify-sentinel` briefly `Exited (255)` during boot then self-recovered. **But**
`dw-fast-api` came up **unhealthy** — which led to the incident below.

---

## ⚠️ INCIDENT — Docker network bridge outage (dw-fast-api ↔ redroid14)

**Symptom:** After the reboot, `dw-fast-api` `/health` reported `status: degraded`,
`adb_ready: false`, with:

```
"adb_connect": "failed to connect to 'redroid14:5555': No route to host"
```

`redroid14` itself was healthy — scrcpy and host `adb connect 127.0.0.1:5555` worked
(that path is host NAT → `redroid14` eth0 `172.20.0.2`). The break was **only**
container-to-container on the `redroid-persistent` bridge.

### Diagnosis (layer by layer)

1. **Not the firewall.** `DOCKER-USER` rule `! -s 172.16.0.0/12 --dport 5555 -j DROP`
   had 0 drops, and `dw` (`172.29.14.4`) is inside `172.16/12`. `dw → coolify-proxy
   (172.29.14.3)` worked — so the bridge itself was fine.
2. **redroid14's `eth1` had no IPv4.** Docker assigned `172.29.14.2` on
   `redroid-persistent`, but inside the container only `eth0` had an address; `eth1`
   (the persistent-network interface) was UP but **address-less** → host ARP for
   `172.29.14.2` was `INCOMPLETE` → `No route to host`.
3. **After manually adding the IP**, the error changed to a **timeout**: adbd's reply
   fell through Android's policy routing rule `31000 → table eth0 → default via eth0`
   and left the wrong interface.
4. **Root cause found:** inside the container, Android's netd (which uses
   **iptables-legacy**) reported `filter/mangle/nat: Table does not exist`. On the
   host, `lsmod` showed `ip_tables` loaded but **`iptable_filter` / `iptable_mangle`
   / `iptable_nat` were NOT loaded**. Config was identical in both kernels
   (`IP_NF_FILTER/MANGLE/NAT = m`) — the old kernel had these auto-loaded during its
   long uptime (privileged redroid netd triggered it); the fresh new-kernel boot did
   not, so netd could not build `eth1`'s address + reply routing.

**Highlighted lesson:** a fresh boot of the multi kernel exposed a latent host
dependency — the **legacy iptables table modules must be loaded before Redroid's
netd runs**, or the second (and, this time, the first) container's
`redroid-persistent` interface is left unconfigured and unreachable from other
containers, even though the container looks "healthy" via the host NAT path.

### Fixes applied

**Live recovery (restored production immediately, no reboot):**

```bash
R=$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid14')
sudo docker exec "$R" ip addr add 172.29.14.2/24 dev eth1
sudo docker exec "$R" ip rule add from 172.29.14.2 lookup eth1 pref 9000
# → dw /health: status ok, adb_ready true
```

**Persistent host fix (survives future boots):**

```bash
sudo modprobe iptable_raw iptable_filter iptable_mangle iptable_nat
printf 'iptable_raw\niptable_filter\niptable_mangle\niptable_nat\n' | \
  sudo tee /etc/modules-load.d/redroid-iptables-legacy.conf
```

After loading, the container netns immediately gained `filter/mangle/nat` tables,
so on future boots netd can self-configure `eth1`. (Caveat: the live `ip addr`/`ip
rule` are in-memory only; a `redroid14` restart before a reboot drops them. This is
what motivated the `dw-fast-api` hotfix below, which removes the dependency on that
bridge path entirely.)

---

## Hotfix — `dw-fast-api` SSH tunnel in production

To make `dw-fast-api` immune to the `redroid-persistent` bridge issue, the operator
chose to route production ADB through the **VPS host's own loopback** (`127.0.0.1:5555`,
the proven-working NAT path) via an SSH tunnel — the same mechanism `DEV_MODE` already
used, now enabled explicitly in production.

Code changes (all in [../DW-fast-api](../DW-fast-api)):

- [main.py](../DW-fast-api/main.py): added `USE_SSH_TUNNEL` env and
  `TUNNEL_ENABLED = DEV_MODE or USE_SSH_TUNNEL`; the tunnel start, fallback tunnel,
  and `/health` reporting now key on `TUNNEL_ENABLED`.
- [Dockerfile](../DW-fast-api/Dockerfile): `ARG USE_SSH_TUNNEL`; bake the VPS key when
  `DEV_MODE` **or** `USE_SSH_TUNNEL` is true.
- [docker-compose.yml](../DW-fast-api/docker-compose.yml): pass the build arg and add
  `extra_hosts: host.docker.internal:host-gateway`.
- [.env.example](../DW-fast-api/.env.example): documented the new variable.

Production `.env`:

```dotenv
USE_SSH_TUNNEL=true
VPS_HOST=host.docker.internal
VPS_USER=ubuntu
DEFAULT_ADB_SERIAL=127.0.0.1:5555
REDROID_ADB_PORT=5555
```

After deploy: `/health` → `status: ok`, `adb_ready: true`, `ssh_tunnel: up`. Production
restored and no longer depends on the container-to-container bridge.

---

## `redroid-experimental` — bring-up and multi-instance validation (the objective)

The Coolify service already existed (uuid `bk6ojzx98y1dlabu4d63c6d3`) with its root
stack staged, but was not running and its DB state had drifted (`start` returned
"Service is already running" while no container existed). Started it via the Coolify
API with a self-bootstrapped short-lived token, using the **restart** action to force
a redeploy. Helper saved at
[coolify/experimental/start-experimental-service.sh](coolify/experimental/start-experimental-service.sh):

```bash
sudo bash /home/ubuntu/kbuild/coolify/experimental/start-experimental-service.sh \
  bk6ojzx98y1dlabu4d63c6d3 restart
# → HTTP 200 {"message":"Service restarting request queued."}
```

Result — the **second instance is independently rooted**, which was impossible on the
old `6.8.12-zksu`:

```
boot_completed=1 · own /dev/binderfs-experimental (666) · restart unless-stopped
ksud 3.3.0
zygisk_lsposed  enabled, update=false   (pending markers CONSUMED)
zygisksu        enabled, update=false
Zygisk Next 1.4.3  "Root: ✅KernelSU (33223), ZL"
lspd running (76)
```

Both instances live **simultaneously**: `redroid14` `lspd` = **357**,
`redroid-experimental` `lspd` = **76**. Production `dw-fast-api` stayed `status: ok`
throughout.

**Multi-instance KernelSU objective: achieved and validated on the production host.**

---

## Phase 16 — Multi-instance KernelSU replay watcher

Production already had `redroid-kernelsu-replay.service` for the known Docker/Coolify
restart failure mode: a container-only restart preserves `/data`, but it can lose the
runtime KernelSU/Zygisk/LSPosed injection chain until the host boots again. After
`redroid-experimental` became the second rooted instance, the watcher was expanded
from production-only to multi-instance.

Updated host files:

```text
/usr/local/sbin/redroid-kernelsu-replay
/etc/systemd/system/redroid-kernelsu-replay.service
/home/ubuntu/kbuild/coolify/redroid-kernelsu-replay.sh
/home/ubuntu/kbuild/coolify/redroid-kernelsu-replay.service
```

The active watcher now tracks separate services and separate recovery guards:

| Service | ADB port | Docker label | Guard file |
|---|---:|---|---|
| `redroid14` | `5555` | `coolify.serviceName=redroid14` | `/var/lib/redroid-kernelsu-replay/pending-host-recovery-redroid14` |
| `redroid-experimental` | `5557` | `coolify.serviceName=redroid-experimental` | `/var/lib/redroid-kernelsu-replay/pending-host-recovery-redroid-experimental` |

For each new running container start timestamp, the watcher waits for Android boot,
reapplies the stable hostname, then verifies:

- `/data/adb/ksud -V` works;
- `ksud module list` contains `zygisksu` and `zygisk_lsposed`;
- `lspd` is running;
- GSF, GMS, and Play Store packages exist;
- production additionally has the active Conscrypt mitmproxy CA file.

If a running, booted container fails that health check, the watcher writes that
instance's pending guard and schedules **one full VPS reboot**. This intentionally
distinguishes Docker/Coolify restart from host reboot: Docker restart is not trusted
to reconstruct Zygisk/LSPosed state, while a full VPS reboot is the tested recovery
path.

Manual stop safety was added at the same time. A container that the operator stops
with `docker stop` is ignored because the watcher enumerates only running containers.
If a container is stopped while the watcher is mid boot/health polling, it records
that start timestamp as a manual/container lifecycle event and does **not** write a
pending recovery guard or reboot the VPS.

Deployment / validation commands used:

```powershell
scp -i "C:\Users\Rishi\.ssh\ssh-key-2026-07-06(pvt).key" `
  "KernelSU_setup\coolify\redroid-kernelsu-replay.sh" `
  ubuntu@141.148.151.172:/tmp/redroid-kernelsu-replay.new

ssh -i "C:\Users\Rishi\.ssh\ssh-key-2026-07-06(pvt).key" `
  -o StrictHostKeyChecking=accept-new ubuntu@141.148.151.172 `
  "bash -n /tmp/redroid-kernelsu-replay.new"

ssh -i "C:\Users\Rishi\.ssh\ssh-key-2026-07-06(pvt).key" `
  -o StrictHostKeyChecking=accept-new ubuntu@141.148.151.172 `
  "sudo install -m 0755 -o root -g root /tmp/redroid-kernelsu-replay.new /usr/local/sbin/redroid-kernelsu-replay; sudo systemctl restart redroid-kernelsu-replay.service"

ssh -i "C:\Users\Rishi\.ssh\ssh-key-2026-07-06(pvt).key" `
  -o StrictHostKeyChecking=accept-new ubuntu@141.148.151.172 `
  "systemctl is-enabled redroid-kernelsu-replay.service; systemctl is-active redroid-kernelsu-replay.service; sudo journalctl -u redroid-kernelsu-replay.service --since '2026-08-21 08:16:00 UTC' --no-pager -o cat | tail -20"
```

Validated result:

```text
redroid-kernelsu-replay.service: enabled
redroid-kernelsu-replay.service: active
KernelSU, Zygisk Next, LSPosed, and GApps are healthy for redroid14 (...)
KernelSU, Zygisk Next, LSPosed, and GApps are healthy for redroid-experimental (...)
```

---

## Current state / follow-ups

- Running kernel: `6.8.12-zksu-multi` (one-time boot; `saved_entry` still `6.8.12-zksu`).
  Not yet promoted to the persistent GRUB default (Phase 15 pending more test cycles).
- All production services healthy: `redroid14`, `dw-fast-api` (via SSH-tunnel hotfix),
  terabox, openobserve, flare-solverr, coolify.
- **Experimental ADB-over-TCP (`:5557`) — resolved.** It first showed `device offline`.
  Root cause was **not** key auth (`ro.adb.secure=0`): the experimental image is
  debuggable, so its `adbd` starts in root mode (`adbd --root_seclabel=u:r:su:s0`)
  and came up without a TCP transport (`service.adb.tcp.port` unset). Fix:
  `setprop service.adb.tcp.port 5555; setprop service.adb.root 0; setprop ctl.restart adbd`
  → `adb connect 127.0.0.1:5557` returns `device`. Made durable with a KernelSU boot
  script `/data/adb/service.d/adb-tcp.sh` that re-arms TCP adbd after every boot. To
  reach it from a workstation, open the `:5557` SSH tunnel first (see
  [VPS_access_guide.md](../VPS_access_guide.md)).
- Standing operating rules while two rooted instances run (kernel does not enforce):
  keep the KernelSU `su` allowlist **empty**, and manage modules per-instance with the
  `ksud` CLI (the Manager GUI de-registers across instances). Never expose ADB to the
  internet.

### Rollback (if needed)

```bash
sudo awk '/^submenu |^[[:space:]]*menuentry / { print }' /boot/grub/grub.cfg
sudo grub-reboot 'gnulinux-advanced-...>gnulinux-6.8.12-zksu-advanced-...'
sudo reboot
# or OCI console hard-reset (one-time next_entry already consumed → boots saved zksu)
```
