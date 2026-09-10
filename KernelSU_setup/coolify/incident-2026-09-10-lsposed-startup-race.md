# Incident: three-instance LSPosed startup race

**Date:** 2026-09-10  
**Host kernel:** `6.8.12-zksu-multi`  
**Affected services:** `redroid14`, `redroid14-v2`, and `redroid-experimental` (all production)  
**Trigger:** adding `redroid14-v2`, followed by concurrent startup of three ReDroid containers

## Summary

After cloning `redroid14` Android data into `redroid14-v2`, the VPS booted these
three Android containers concurrently:

1. `redroid14`
2. `redroid14-v2`
3. `redroid-experimental`

Docker considered all three healthy because their health checks cover Android
boot completion and `adbd`, not LSPosed injection. Diskwala on `redroid14` opened
`com.pairip.licensecheck.LicenseActivity` and redirected to Play Store.

PairIPFix was not missing or incorrectly scoped. `redroid14`'s LSPosed bridge had
failed its system-server Binder handshake during the concurrent boot. The v2
instance completed the handshake, showing this was a startup-order race rather
than a one-container KernelSU limitation.

All three instances are production peers and all three are required to load
KernelSU, Zygisk, and LSPosed. The deterministic sequence does not express
business or availability priority; it merely prevents concurrent initialization.
`redroid14` is the Docker-auto-start seed, after which systemd starts v2 and
experimental one at a time. Every instance must pass Android and LSPosed Binder
readiness before the sequence succeeds. All containers remain Coolify-managed;
only host-boot ordering is delegated to systemd.

## Configuration at the time of the incident

| Service | Coolify UUID | ADB host port | BinderFS | Android data |
|---|---|---:|---|---|
| `redroid14` | `kkssbzfd0c3sjec5nhs6g2mi` | `5555` | `/dev/binderfs` | `/home/ubuntu/redroid14-data` |
| `redroid14-v2` | `gdbnhtayragkw0jhha7a58hk` | `5559` | `/dev/binderfs-v2` | `/home/ubuntu/redroid14-v2-data` |
| `redroid-experimental` | `bk6ojzx98y1dlabu4d63c6d3` | `5557` | `/dev/binderfs-experimental` | `/home/ubuntu/redroid-experimental-data` |

The BinderFS mounts and `/data` directories were already independent. Sharing a
BinderFS device or Android data directory was not the cause.

## Symptom and initial evidence

`redroid14` was Android/Docker healthy:

```text
running=true
health=healthy
sys.boot_completed=1
```

PairIPFix and TalsecKill were installed:

```text
io.github.ahmedmani.io.github.ahmedmani.pairipfixio.github.ahmedmani.pairipfix
  versionName=1.0

com.recon.talsecbypass
  versionName=1.5
```

The copied LSPosed SQLite database showed both modules enabled, with current APK
paths and the correct scope:

```text
(5, 1, 'com.recon.talsecbypass', '<current base.apk>')
(2, 1, 'io.github.ahmedmani...pairipfix', '<current base.apk>')

(5, 'com.recon.talsecbypass', 'com.diskwalaapp', 0)
(2, 'io.github.ahmedmani...pairipfix', 'com.diskwalaapp', 0)
```

Despite that valid static state, `redroid14`'s current LSPosed log contained:

```text
Fail to get binder for system server, try again in 1s
Fail to get binder for system server
Failed to get system server binder, system server initialization failed.
```

There were root-owned `lspd` processes, but the current LSPosed module log had no
`LSPosed-Bridge binder received` and no PairIPFix/TalsecKill load records. The
presence of an `lspd` PID alone was therefore a false health signal.

Diskwala's runtime log confirmed the unhooked path:

```text
START ... com.diskwalaapp/com.pairip.licensecheck.LicenseActivity
START ... com.android.vending/com.google.android.finsky.activities.MainActivityPrivate
```

## Cross-instance comparison

The same host boot produced three different outcomes:

| Service | LSPosed result |
|---|---|
| `redroid14` | root-owned waiting `lspd`; system-server Binder handshake failed |
| `redroid14-v2` | system-owned `lspd`; `LSPosed-Bridge binder received` |
| `redroid-experimental` | no `lspd`; its current `/data` did not contain `zygisk_lsposed` |

Repository history already proved that `redroid14` and experimental LSPosed could
run simultaneously on `6.8.12-zksu-multi`. The evidence therefore ruled out a
hard one-container limit and pointed to concurrent boot timing.

## Recovery attempts and blockers

### 1. Restarting only the LSPosed daemon

The lowest-impact attempt terminated the root-owned waiting daemon with `TERM`
and invoked LSPosed's own launcher:

```bash
sh /data/adb/modules/zygisk_lsposed/service.sh
```

The daemon exited without completing a new system-server handshake. Starting the
daemon directly also returned exit status `0` without leaving an `lspd` process.

### 2. Restarting only Android's primary zygote

The host was verified as `6.8.12-zksu-multi`, whose KernelSU hook can process new
`app_process -Xzygote` executions. A controlled `ctl.restart zygote` produced a
new zygote and `system_server`, and both mapped the Zygisk Next and LSPosed
libraries. It still did not recreate the LSPosed daemon/Binder relationship.

A stricter stop/start attempt stopped primary zygote, ran the LSPosed launcher,
then started zygote under a shell trap. The launcher still did not retain an
`lspd` process. No direct `SIGKILL` of `system_server`, zygote, or `lspd` was used.

The safe no-container/no-host-reboot options were exhausted at this point. A host
boot remained necessary to reconstruct the complete KernelSU module lifecycle.

### 3. First boot-order implementation: `on-failure:5`

The first sequencer version changed secondary Docker policies from
`unless-stopped` to `on-failure:5`. This did not prevent simultaneous startup:
dockerd recorded a non-zero exit during host shutdown and restarted both
secondaries at the next daemon start.

**Correction:** secondary services now use the quoted Compose value
`restart: "no"`. The systemd sequencer starts them automatically after `redroid14`,
so they remain automatic at VPS boot without racing dockerd.

### 4. First LSPosed readiness predicate

The first predicate used nested `awk` quoting to read the `Uid:` line from
`/proc/<lspd>/status`. The generated shell expression was over-escaped and
misclassified healthy `redroid14`. The guarded recovery watcher then scheduled
one reboot even though that instance had logged `binder received`.

**Correction:** the final predicate reads ownership directly from procfs:

```bash
p=$(pidof lspd 2>/dev/null | cut -d " " -f1)
stat -c %u "/proc/$p"
```

A successful LSPosed state requires both:

1. the daemon's procfs owner is Android system UID `1000`; and
2. the current module log contains `LSPosed-Bridge.*binder received`.

### 5. Experimental LSPosed installation drift

The experimental `/data` no longer contained `zygisk_lsposed`, although older
documentation recorded it as installed. The live incident workaround temporarily
gated experimental only on Android boot and excluded it from the replay watcher;
that workaround does **not** satisfy the final requirement that all three
production instances load LSPosed.

**Final repository correction:** the canonical sequencer and watcher require a
current-boot LSPosed Binder handshake from experimental too. Before deploying
these canonical scripts to the VPS, restore and validate `zygisk_lsposed` in
`/home/ubuntu/redroid-experimental-data`. The user explicitly deferred further
VPS changes while this documentation was updated, so this remains a recorded
follow-up rather than a falsely claimed completed repair.

## Permanent fix

The canonical files are:

- `redroid-sequential-start.sh` — performs ordered startup and readiness gates.
- `redroid-sequential-start.service` — runs the sequencer after Docker and all
  three BinderFS services.
- `install-redroid-sequential-start.sh` — applies the complete host/Coolify fix.
- `redroid-kernelsu-replay.sh` — validates the real LSPosed bridge state after
  later container/Coolify restarts.

The installer increases LSPosed's bounded system-server retry window from 3 to
60 for all three instances. Those files reside under persistent Android data,
so the change survives container recreation:

```text
/home/ubuntu/redroid14-data/adb/modules/zygisk_lsposed/service.sh
/home/ubuntu/redroid14-v2-data/adb/modules/zygisk_lsposed/service.sh
/home/ubuntu/redroid-experimental-data/adb/modules/zygisk_lsposed/service.sh
```

It persists `restart: "no"` in both the generated Compose file and Coolify's
`docker_compose_raw`; changing only the generated file would be reverted during
the next Coolify deployment.

### Install

Upload this directory to the VPS as described in `setup-guide-coolify.md`, then:

```bash
cd /home/ubuntu/kbuild/coolify
sudo bash ./install-redroid-sequential-start.sh
sudo systemctl reboot
```

Override UUIDs or data paths only if Coolify recreated the resources:

```bash
sudo V2_UUID=<new-v2-uuid> \
  EXPERIMENTAL_UUID=<new-experimental-uuid> \
  PRODUCTION_DATA=/home/ubuntu/redroid14-data \
  V2_DATA=/home/ubuntu/redroid14-v2-data \
  EXPERIMENTAL_DATA=/home/ubuntu/redroid-experimental-data \
  bash ./install-redroid-sequential-start.sh
```

Do not restart `redroid-kernelsu-replay.service` while the current LSPosed state
is known to be broken: the watcher is designed to schedule a guarded reboot.
Install the files, then perform the deliberate validation reboot.

## Expected boot sequence

```text
redroid14 Android ready
redroid14 LSPosed ready
Starting redroid14-v2
redroid14-v2 Android ready
redroid14-v2 LSPosed ready
Starting redroid-experimental
redroid-experimental Android ready
redroid-experimental LSPosed ready
All ReDroid instances completed serialized startup
```

Inspect it with:

```bash
sudo journalctl -u redroid-sequential-start.service -b --no-pager
```

`redroid14` retains `restart: unless-stopped` solely as the deterministic sequence
seed. This does not give it higher production importance. v2 and experimental
use `restart: "no"`; the enabled sequencer is their automatic host-boot path.
Coolify can still deploy, start, stop, and recreate all three services.

## Validation evidence

The corrected reboot produced these start times:

```text
redroid14              2026-09-10T05:25:45Z
redroid14-v2           2026-09-10T05:26:51Z
redroid-experimental   2026-09-10T05:27:25Z
```

All three Docker health checks passed. `redroid14` and v2 each had a system-owned
`lspd` and logged `LSPosed-Bridge binder received` before the live sequencer
advanced. Experimental passed only Android/Docker health because its LSPosed
module was missing. That was partial incident recovery evidence, not validation
of the final all-three-LSPosed requirement.

A controlled `redroid14` Diskwala launch then showed:

```text
topResumedActivity=... com.diskwalaapp/.MainActivity
[TalsecKill] loaded in com.diskwalaapp
[TalsecKill] FNatives.x native self-kill guard installed
[PairIPFix] Module loaded for package: com.diskwalaapp
[PairIPFix] 4/4 hooks applied
```

Diskwala retained a live PID and did not foreground PairIP's `LicenseActivity` or
Play Store. The live recovery watcher reported `redroid14` and v2 healthy, and
`/var/lib/redroid-kernelsu-replay` contained no pending recovery guards.

The corrected final acceptance gate is stricter: repeat this evidence for all
three instances after restoring experimental LSPosed, and require the sequencer
to log `redroid-experimental LSPosed ready` before declaring the permanent repair
fully deployed.

## Operational trade-off

Docker no longer independently restarts v2 or experimental after a dockerd/VPS
restart; systemd does so in the required technical order. If either later-starting
container
exits later during normal uptime, restart it through Coolify or with
`docker start` after confirming the preceding LSPosed service is healthy. Do not
restore `unless-stopped` or `on-failure` without replacing them with another
ordering mechanism, or concurrent boot can return.
