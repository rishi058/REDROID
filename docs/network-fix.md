# redroid14 Network Outage — Root Cause & Fix

**Date:** 2026-08-27  
**Container:** `redroid14-kkssbzfd0c3sjec5nhs6g2mi` (prod, port 5555)  
**Symptom:** Unable to ADB-connect to redroid14 after VPS reboot; `adb connect 127.0.0.1:5555` returned `offline`

---

## What the network looked like before the reboot

redroid14 was connected to **two** Docker bridge networks simultaneously:

| Network | Subnet | IP assigned | Gateway | Purpose |
|---|---|---|---|---|
| `kkssbzfd0c3sjec5nhs6g2mi` | 172.17.0.0/16 | 172.17.0.3 | 172.17.0.1 | Coolify service network (shared with `coolify-proxy`) |
| `redroid-persistent` | 172.29.14.0/24 | 172.29.14.2 | — | Persistent named network, no gateway |

The Coolify service network was the primary interface (`eth0`) with the default route pointing at `172.17.0.1`. `redroid-persistent` was a secondary interface (`eth1`) used to keep the container alive across Coolify redeploys. This setup worked because the default route was via the Coolify net.

---

## What went wrong during the VPS reboot

When the VPS host rebooted, Docker restarted all containers. The order in which Docker reconnects networks to a restarting container is **non-deterministic** — it depends on which network's bridge comes up first.

This time, `redroid-persistent` won the race and became **eth0** (the first interface). Because it was assigned as eth0, Docker also made it the default route interface. But `redroid-persistent` has **no gateway configured** — it is an isolated bridge with no route to the internet or the host's network stack.

Result inside the container:
- `eth0` = 172.29.14.2/24 (redroid-persistent, no gateway)
- No default route → no internet, no DNS
- `adbd` bound to the container's IP correctly, but the SSH tunnel `127.0.0.1:5555 → 5555` on the VPS could no longer route through to anything useful

Docker's metadata (from `docker inspect`) still showed the container as connected to both networks, including `172.17.0.3` for `kkssbzfd0c3sjec5nhs6g2mi`. This is what made the problem hard to spot — the metadata looked correct, but inside the container only `eth0` (redroid-persistent) was active. The Coolify network veth pair was present in Docker's records but **not materialized as an interface inside the running container**.

The same broken state blocked the attempted fix: running `docker network connect` to re-add the Coolify network failed with:
```
Error response from daemon: updating gateway endpoint: failed to set gateway:
route for the gateway 172.21.0.1 could not be found: network is unreachable
```
Docker's `network connect` requires the container to already have a route to the new gateway — which it couldn't have because it had no default route at all.

---

## Why `adbd` appeared up but adb was offline

TCP port 5555 was open and listening (confirmed by `nc -zv 127.0.0.1 5555` from the VPS). `adbd` was running and bound. But `adbd` in TCP mode requires internet reachability for the initial ADB authentication handshake to complete — it reaches out to validate the RSA key exchange. With no default route, the handshake stalled and every `adb connect` reported `offline` immediately.

---

## How it was fixed

### Step 1 — Disconnect the gateway-less network

```bash
sudo docker network disconnect redroid-persistent redroid14-kkssbzfd0c3sjec5nhs6g2mi
```

This removed the `redroid-persistent` veth from the container. After this, Docker metadata showed the container on only `kkssbzfd0c3sjec5nhs6g2mi` (172.17.0.3, gw=172.17.0.1). However, the container's running network namespace still had **no eth0** — only loopback — because the Coolify network's veth pair was never materialized at boot time.

### Step 2 — Restart the container

```bash
sudo docker restart redroid14-kkssbzfd0c3sjec5nhs6g2mi
```

A container restart causes Docker to tear down and recreate **all** veth pairs from scratch, using the current network configuration (which is now only `kkssbzfd0c3sjec5nhs6g2mi`). On boot:
- `eth0` = 172.17.0.3/16
- Default route = via 172.17.0.1 (`coolify-proxy` is on the same network)
- Internet works, DNS works, `adbd` completes the ADB auth handshake

After restart, `adb connect 127.0.0.1:5555` succeeded.

---

## Why not just `docker network connect` directly?

`docker network connect` inserts a new veth into a **running** container's network namespace. It can do this even without a restart — but only if the container has an existing default route from which Docker can reach the new network's gateway to set it up. With no default route at all (only an isolated bridge), Docker cannot set the gateway for the new network and the command fails. You're stuck in a chicken-and-egg: the container needs a gateway to add the gateway-bearing network.

The only exits are:
1. Manually add a temporary static route inside the container (`ip route add`) to make the new gateway reachable — then `docker network connect` will succeed.
2. Disconnect the gateway-less network first, then restart so Docker re-creates everything cleanly. **(What we did)**

---

## Prevention

The original single-home recovery was later replaced by an explicitly ordered
dual-network configuration because `redroid-persistent` is required for stable
FastAPI-to-ReDroid addressing. The maintained Compose source pins that auxiliary
endpoint to `eth1` with `gw_priority: -1`; Coolify's NAT-capable service network
therefore remains the `eth0`/default-route path. Do not rely on YAML key order
alone: Docker restoration order after a host reboot is not a stable interface
assignment contract.

The Coolify service network also uses a restricted dynamic allocation pool so
its generated static ReDroid address cannot be claimed by `coolify-proxy`. See
Incident 4 below.

---

## Addendum (same day) — post-reboot app-level network warm-up window

**Symptom:** After a full VPS reboot (a second one, later the same day, done to clear a stale KernelSU/Magic Mount GApps overlay — see below), `adb`/ADB connectivity came back immediately and `sys.boot_completed=1` reported healthy, but **app-level network calls inside redroid14 kept failing for several more minutes**:

- Every fresh Diskwala process hit `java.net.SocketException: socket failed: EPERM` on its first network attempts (Firebase Crashlytics, Firebase Sessions, and the app's own `/session` bootstrap call).
- The app's own connectivity check surfaced a user-visible "No connection — Could not reach DiskWala" dialog.
- The FastAPI capture pipeline (`POST /video`) timed out exactly as before the reboot — device-level `ping`/DNS/raw `nc` TCP:443 all worked fine throughout, and Android's own per-network routing (`ip route get <host>` via table `eth0`) resolved correctly the whole time, so this was **not** a routing/DNS problem.
- Without any further action, the condition cleared on its own somewhere between ~3 and ~11 minutes after the reboot. A clean `POST /video` afterward succeeded in 2.3s.

**Leading theory:** Docker's iptables-managed NAT/port-publish rules (and whatever rules the DOCKER-USER fix from the ADB-worm incident added) take some time to be fully (re)installed after `dockerd` restarts every container on the host post-reboot, especially with ~10 containers competing for reinitialization at once. During that window, outbound socket creation for the container's app UIDs can intermittently fail even though basic ICMP/DNS/raw-TCP checks (which may hit a different, already-ready path) succeed. This wasn't confirmed via kernel audit logs (`dmesg` showed zero `EPERM`/`denied`/`audit` entries during the affected window — a DROP-style iptables rule normally isn't audit-logged unless it uses the `LOG` target, so absence of audit evidence doesn't rule this out).

**Practical takeaway:** After any full VPS reboot, don't trust `sys.boot_completed=1` or ADB reachability alone as the signal that the capture pipeline is ready. Budget roughly **10 minutes** of warm-up before relying on `POST /video`/`POST /playlist` succeeding, or poll `logcat` for a clean (non-`EPERM`) app-level network call as the real readiness signal.

### 2026-09-04 correction — confirmed cgroup BPF collision, not a warm-up window

The same failure was reproduced long after boot and traced from the host while
Diskwala attempted `/session`:

```text
socket(AF_INET6, SOCK_STREAM, IPPROTO_IP) = -1 EPERM (Operation not permitted)
```

Both ReDroid containers were running with Docker's host cgroup namespace on a
cgroup-v1 host. Android 14's netd in each instance attached
`prog_netd_cgroupsock_inet_create` to the same cgroup-v2 root. The later-started
experimental instance replaced production's program:

```text
production pinned program:   55
experimental pinned program: 88
program attached at root:    88
```

The attached program used the experimental instance's
`map_netd_uid_permission_map`. Experimental app ID `10095` had permission value
`0x00`; production Diskwala independently used the same app ID. The foreign
netd program consequently rejected production's socket creation before proxy,
DNS, TCP connect, TLS, or HTTP. This explains why shell-level connectivity was
healthy, app restarts did nothing, and reboot outcome depended on instance
startup order.

The permanent fix has two required parts:

1. Boot the VPS with unified cgroup v2 (remove
   `systemd.unified_cgroup_hierarchy=0` and
   `systemd.legacy_systemd_cgroup_controller=1` from GRUB and its drop-ins).
2. Set `cgroup: private` for **every** ReDroid Compose service and recreate the
   containers. Private namespaces alone were tested on the old cgroup-v1 host
   and did not isolate the attachment.

After migration Docker reported cgroup v2 with the systemd driver. Production
and experimental had different pinned and attached program IDs (`87` and
`134` respectively), `POST /video` returned HTTP 200 in 2.677 seconds, and no
new `socket failed: EPERM` or `/session` bootstrap errors appeared. Coolify
4.1.2's generated Compose (Docker Compose 5.4.0) accepted and persisted the
`cgroup: private` service key; this was validated rather than inferred from the
Custom Docker Options whitelist.

**Separately, in the same reboot cycle:** Play Store (`com.android.vending`) failed to launch with `Failed to open APK '/system/product/priv-app/Phonesky/Phonesky.apk': I/O error` — caused by an *earlier, docker-only* restart of redroid14 (done to fix the ADB issue documented above) not fully replaying KernelSU's Magic Mount overlay for the GApps module. This is a distinct issue from the network warm-up above; it was fixed immediately by the full VPS reboot (matches `rev-eng/docs/05-Follow-Up-Fixes.md`'s existing warning that a docker-only restart doesn't reliably re-arm KernelSU's boot stages — only a full host reboot does).

---

# Incident 2 — App "no internet" caused by a stale system proxy (dead mitmdump tunnel)

**Date:** 2026-09-02
**Container:** `redroid14-kkssbzfd0c3sjec5nhs6g2mi` (prod, port 5555)
**Symptom:** ADB connected fine on `127.0.0.1:5555`, SSH tunnel up, device booted and healthy — but apps inside redroid14 could not load anything. WebView Browser Tester showed:

```
Webpage not available
The webpage at http://www.google.com/m?... could not be loaded because:
net::ERR_PROXY_CONNECTION_FAILED
```

This looked identical to a network outage ("app has no internet") and had "fixed itself" before after a VPS reboot — so it was easy to misdiagnose as a recurrence of Incident 1 (the dual-homing race). **It is a completely different root cause.**

---

## This was NOT a network outage — the OS-level network was fully healthy

Diagnostics run inside the container proved the network stack itself was working perfectly the entire time:

| Check | Result |
|---|---|
| `eth0` address | `172.17.0.2/16` on `kkssbzfd0c3sjec5nhs6g2mi` (Coolify net — the network that *has* a gateway won the boot race this time) |
| Default route | `default via 172.17.0.1 dev eth0 table eth0` ✅ present in netd's per-network table |
| `ping 8.8.8.8` (raw IP) | replies, 2.5 ms ✅ |
| `ping google.com` (DNS) | resolves to `142.251.181.102` and replies ✅ |
| `eth1` / `redroid-persistent` | **not materialized** inside the container (only `eth0` + `lo`) — the "lucky" boot; Incident 1's failure mode did not trigger |
| `sys.boot_completed` | `1` |

So DNS, routing, and raw internet were all fine. The failure was **exclusively** in apps that honor the Android **system HTTP proxy**.

---

## Root cause: a permanently-persisted system proxy pointing at a dead port

The Android global proxy was pinned to `127.0.0.1:5556`:

```
settings get global http_proxy            -> 127.0.0.1:5556
settings get global global_http_proxy_host -> 127.0.0.1
settings get global global_http_proxy_port -> 5556
```

This proxy is set intentionally so Diskwala's traffic funnels through the **mitmdump capture proxy that DW-fast-api consumes**. The critical detail:

> **`127.0.0.1:5556` on the device is not a local server.** It is an **`adb reverse tcp:5556`** tunnel that forwards back over the ADB transport to the mitmdump/DW-fast-api side. The listener on `5556` only exists while that `adb reverse` mapping is alive.

At the time of the failure, that tunnel was gone:

```
adb -s 127.0.0.1:5555 reverse --list        -> (empty)
# inside container:
netstat -tlnp | grep 5556                    -> NOTHING_LISTENING_ON_5556
```

So the whole system was pointed at `127.0.0.1:5556`, but nothing was answering there → every proxy-honoring app (WebView, Chrome, Play Store, Diskwala) fails immediately with `ERR_PROXY_CONNECTION_FAILED`. Apps that ignore the system proxy (e.g. Flezen, which uses `dart:io` directly) would have kept working — which is part of why the failure looked random.

The full path apps depend on:

```
app → 127.0.0.1:5556 (adb reverse) → mitmdump → DW-fast-api → internet
```

When link #2 (`adb reverse`) disappears, the app has no path out even though the device's own `eth0 → 172.17.0.1 → internet` route is perfectly fine.

---

## Why it "was running fine, then broke from nowhere"

The app was **never using direct internet** — it was always routed through the mitmdump proxy. It worked only for as long as the `adb reverse tcp:5556` binding (and the mitmdump behind it) stayed alive.

**`adb reverse` mappings are bound to the ADB transport session, not to the device.** They are silently wiped by any of:

- an ADB reconnect — e.g. running `adb connect 127.0.0.1:5555` again
- `adb kill-server` (or the adb server restarting for any reason)
- the SSH tunnel that carries `5555` dropping/re-establishing
- DW-fast-api or the mitmdump process stopping

Nothing automatically recreates the reverse. So the moment any of the above happened, `5556` went dead while the **persisted** proxy setting kept pointing at it — and every app broke instantly. There was no visible "network event"; the capture tunnel just evaporated underneath a static proxy configuration. That is the "from nowhere" feeling.

---

## Why a VPS reboot appeared to "fix it" previously

A full VPS reboot restarts the DW-fast-api capture pipeline, which re-runs `adb reverse tcp:5556 …` and relaunches mitmdump. That brings the `5556` endpoint back to life, so proxy-honoring apps work again. **The reboot was not fixing the network** — the network was never broken. It was re-arming the proxy hop. This is why the symptom kept coming back: rebooting treated the symptom, not the cause.

---

## How to fix / recover

There are two valid resolutions depending on whether traffic capture is wanted at that moment.

### Option A — you want capture running (keep the proxy)

Bring the `5556` endpoint back up: restart the DW-fast-api capture pipeline so it re-creates the reverse tunnel + mitmdump, or do it manually:

```bash
# re-establish the reverse tunnel to the mitmdump listener, then start mitmdump
adb -s 127.0.0.1:5555 reverse tcp:5556 tcp:<mitmdump_port>
```

Verify with `adb -s 127.0.0.1:5555 reverse --list` (should show `5556`) and, inside the container, `netstat -tlnp | grep 5556` (should show a listener). Apps route through capture again.

### Option B — you just want apps online now (no capture)

Clear the stale proxy so apps use the healthy direct route:

```bash
settings put global http_proxy :0
settings delete global global_http_proxy_host
settings delete global global_http_proxy_port
settings delete global global_proxy_pac_url
```

Apps get internet immediately via `eth0 → 172.17.0.1`. Re-enable the proxy only when the mitmdump/`adb reverse` is actually up.

---

## Prevention

The trap is a **persistent** proxy setting that depends on an **ephemeral** `adb reverse` tunnel. To stop the recurrence:

- **Tie the proxy to the tunnel's lifecycle.** Whatever sets `settings put global http_proxy 127.0.0.1:5556` should also be responsible for (re)creating `adb reverse tcp:5556` on every ADB (re)connect, and for clearing the proxy (`http_proxy :0`) when the capture pipeline stops. Never leave the proxy set while the reverse is down.
- **Re-assert the reverse after any reconnect.** Since `adb connect` / `adb kill-server` / SSH-tunnel blips wipe reverse mappings, the capture startup (and any reconnect helper) must re-run `adb reverse tcp:5556 …` before relying on app traffic.
- **Diagnose by the error, not the vibe.** `net::ERR_PROXY_CONNECTION_FAILED` (proxy failure) is categorically different from `ERR_NAME_NOT_RESOLVED`/`ERR_INTERNET_DISCONNECTED` (real network failure). First triage step: `settings get global http_proxy` + `adb reverse --list` + in-container `ping 8.8.8.8`/`ping google.com`. If ping/DNS work but apps don't, it's the proxy, not the network — do **not** reboot the VPS for this.

---

# Incident 3 — Experimental ADB offline after VPS reboot (stale Docker endpoint)

**Date:** 2026-09-03
**Container:** `redroid-experimental-bk6ojzx98y1dlabu4d63c6d3` (experimental, VPS loopback port 5557 → container port 5555)
**Symptom:** The SSH tunnel was reachable, but `adb connect 127.0.0.1:5557` returned `offline`, `failed to connect`, or a protocol reset. `scrcpy` failed with `state=offline`.

## What was healthy

Android itself had completed boot:

```text
sys.boot_completed=1
dev.bootcomplete=1
init.svc.adbd=running
```

Real `adbd` owned `*:5555`; no known `com.hagaseca.thost9`/`thost4` ADB-worm packages or non-`adbd` port owner were present. Restarting `adbd` and reasserting `service.adb.tcp.port=5555` therefore did not address the root cause.

## Root cause

Docker's published-port path was stale after the host reboot:

```text
127.0.0.1:5557 → Docker proxy/NAT → 172.21.0.2:5555
```

`docker inspect` claimed that the Coolify network `bk6ojzx98y1dlabu4d63c6d3` had assigned `172.21.0.2` to the container. The running network namespace disagreed:

```text
eth0 = 172.29.14.2/24 (redroid-persistent)
eth1 = link-local IPv6 only; no 172.21.0.2 IPv4 address
```

Consequently, the VPS could reach `172.29.14.2:5555` directly, but Docker's published port targeted the nonexistent `172.21.0.2:5555` path and returned `No route to host`. A TCP listener on host port 5557 was not proof that its container-side destination was usable.

This is the same dual-network materialization class as Incident 1, but with a different visible state: the secondary interface existed while its Docker-assigned IPv4 address was missing.

## Recovery used (experimental only; no container or VPS restart)

First reconnect the Coolify endpoint with negative gateway priority. The negative priority is important: reconnecting normally failed while Docker attempted to install the Coolify gateway.

```bash
C=$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid-experimental')
N=bk6ojzx98y1dlabu4d63c6d3

sudo docker network disconnect -f "$N" "$C"
sudo docker network connect \
  --gw-priority -1 \
  --ip 172.21.0.2 \
  --alias redroid-experimental \
  "$N" "$C"

# ReDroid/Android still omitted the IPv4 address from the live namespace.
sudo docker exec "$C" ip addr add 172.21.0.2/16 dev eth1
```

ARP resolution for that endpoint also remained incomplete, so the VPS bridge neighbor was restored using the interface's actual MAC address:

```bash
MAC=$(sudo docker exec "$C" cat /sys/class/net/eth1/address)
sudo ip neigh replace 172.21.0.2 lladdr "$MAC" nud permanent \
  dev br-58de1859c45f
```

Then reset the client transport:

```powershell
adb disconnect 127.0.0.1:5557
adb kill-server
adb start-server
adb connect 127.0.0.1:5557
adb devices -l
```

Final validation returned `device`, `sys.boot_completed=1`, and scrcpy successfully streamed the Android 14 display.

## Diagnostic checklist

Do not classify every `offline` result as the documented ADB worm. Check each layer:

```bash
# Docker's intended destination
sudo docker inspect "$C" --format '{{json .NetworkSettings.Networks}} {{json .NetworkSettings.Ports}}'

# Actual interfaces and routes (source of truth)
sudo docker exec "$C" ip -br addr
sudo docker exec "$C" ip route

# Real owner of the Android port
sudo docker exec "$C" ss -ltnp | grep ':5555'

# Compare both network paths
nc -vz 172.21.0.2 5555
nc -vz 172.29.14.2 5555
```

If Docker metadata lists an IPv4 address that `ip -br addr` does not show, repair the network endpoint before changing `adbd`.

## Permanent fix applied

The explicit `ip addr` and static-neighbor commands above were only the initial runtime recovery. On 2026-09-03, the Coolify-managed deployment was permanently changed to make `redroid-experimental` **single-homed**:

- removed `redroid-persistent` from the experimental service;
- retained only Coolify's NAT-capable per-service network;
- configured that endpoint as `eth0` with gateway priority `1` in the generated live Compose file;
- removed `redroid-persistent` from both `docker_compose_raw` and parsed `docker_compose` for Coolify service ID `4`, preventing a later Coolify redeploy from restoring the broken topology;
- aligned `/home/ubuntu/kbuild/coolify/experimental/docker-compose.yml` with the repository rule that the experimental service must not declare `redroid-persistent`.

Only `redroid-experimental` was force-recreated. Production `redroid14` was not restarted or modified.

Post-recreation validation:

```text
Docker network count: 1
Interface: eth0 = 172.21.0.2/16
Android policy route: default via 172.21.0.1 table 1002
Internet: 8.8.8.8 reachable
Container health: healthy
ADB 127.0.0.1:5557: device
sys.boot_completed: 1
scrcpy: Android 14 video stream successful
```

ARP now resolves dynamically to the container endpoint; the temporary permanent-neighbor entry was removed before recreation. Because the service now has only one network, Docker cannot reverse the attachment order or publish port 5557 toward a missing secondary IPv4 endpoint after a reboot.

### Required dependent recovery: recreate `flezen-sidecar`

Recreating `redroid-experimental` gives it a new container ID and network namespace. The Flezen sidecar's configured `network_mode: container:<redroid-name>` is resolved by Docker to that container ID **when the sidecar is created**. Restarting an existing sidecar does not retarget its `HostConfig.NetworkMode` to the replacement ReDroid container.

Immediately after the permanent network fix, the old sidecar remained pinned to deleted ReDroid ID `ddd75aea…`, while the new ReDroid ID was `90c20c4b…`. It exited and port `172.21.0.2:8002` had no listener, causing:

```text
Flezen sidecar unavailable: GET /v1/captures failed:
ClientConnectorError: Cannot connect to host 172.21.0.2:8002
```

Recovery requires a sidecar **recreate**, not merely a restart:

```bash
D=/data/coolify/applications/n4dzpuxm9h70p95d2dmcbwo4
sudo docker compose \
  --project-directory "$D" \
  --env-file "$D/.env" \
  -f "$D/docker-compose.yaml" \
  up -d --force-recreate --no-deps sidecar
```

After recreation, `HostConfig.NetworkMode` referenced the new ReDroid ID, the sidecar became healthy, `0.0.0.0:8002` listened in the shared namespace, DW-fast-api's authenticated `/v1/captures` request succeeded, and a Flezen `file_details` flow was captured.

---

# Incident 4 — Production ReDroid failed to start after reboot (static IP collision)

**Date:** 2026-09-04

**Container:** `redroid14-kkssbzfd0c3sjec5nhs6g2mi` (production)

**Symptom:** After a full VPS reboot, Docker left production ReDroid stopped with
exit code `255` and no Android boot state:

```text
failed to set up container networking: Address already in use
```

## Diagnosis

This error occurred before Android started; it was not an ADB, BinderFS,
KernelSU, memory, or app failure. Coolify's generated Compose pinned ReDroid on
its service network:

```yaml
kkssbzfd0c3sjec5nhs6g2mi:
  ipv4_address: 172.17.0.2
```

The network's default dynamic pool covered the entire `172.17.0.0/16` subnet.
During daemon restoration, `coolify-proxy` attached first and dynamically
received `172.17.0.2`. ReDroid then attempted to claim the same generated static
address and Docker rejected its network setup. The decisive comparison was:

```text
Coolify-generated redroid14 address: 172.17.0.2
coolify-proxy runtime address:       172.17.0.2
```

`docker inspect` of the service network and the generated file under
`/data/coolify/services/kkssbzfd0c3sjec5nhs6g2mi/` are required for this
diagnosis. A host-port check alone is insufficient.

## Durable fix

Recreate the Coolify service network with a dynamic allocation range that does
not include the low static address. Perform this only while ReDroid is stopped,
after confirming the network contains no application endpoint other than
`coolify-proxy`:

```bash
N=kkssbzfd0c3sjec5nhs6g2mi

sudo docker network inspect "$N"
sudo docker network disconnect "$N" coolify-proxy
sudo docker network rm "$N"
sudo docker network create \
  --driver bridge \
  --attachable \
  --subnet 172.17.0.0/16 \
  --gateway 172.17.0.1 \
  --ip-range 172.17.128.0/17 \
  "$N"
sudo docker network connect "$N" coolify-proxy
```

The resulting contract is:

```text
ReDroid generated static address: 172.17.0.2
Dynamic addresses:                172.17.128.0/17
```

The dynamic allocator can no longer hand ReDroid's address to the proxy. This
network is external and survived the subsequent validation reboot.

The second half of the fix makes interface/default-route selection deterministic.
Persist these properties in both Coolify's `docker_compose_raw` source and its
normalized Compose, not only in the generated deployment file:

```yaml
networks:
  redroid-persistent:
    interface_name: eth1
    gw_priority: -1
    aliases:
      - redroid14
      - redroid14-ksu
```

Coolify injects its own service network, which remains `eth0` and wins the
default gateway. The repository source at
`KernelSU_setup/coolify/docker-compose.yml` carries the same settings so a
future GUI paste or service recreation does not regress the ordering.

After applying the generated Compose change, recreate ReDroid and perform the
documented full VPS reboot. A container-only recreation is not the final state:
KernelSU boot stages must re-establish Zygisk, LSPosed, GApps, and the CA overlay
during the host boot sequence.

## Validation

The repair was tested through a full VPS reboot, not only a force-recreate:

```text
redroid14 container: running, healthy, restart_count=0
sys.boot_completed:  1
init.svc.adbd:        running
Coolify endpoint:    eth0 = 172.17.0.2/16
Internet:            8.8.8.8 reachable
KernelSU watcher:    KernelSU, Zygisk Next, LSPosed, and GApps healthy
DW-fast-api /health: status=ok, adb_ready=true, adb_transport_online=true
DW-fast-api /ready:  HTTP 200
```

Use these checks after any future service-network recreation:

```bash
N=kkssbzfd0c3sjec5nhs6g2mi
C=$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid14')

sudo docker network inspect "$N" --format \
  '{{range .IPAM.Config}}subnet={{.Subnet}} ip_range={{.IPRange}}{{end}} {{json .Containers}}'
sudo docker inspect "$C" --format \
  'status={{.State.Status}} health={{.State.Health.Status}} networks={{json .NetworkSettings.Networks}}'
sudo docker exec "$C" sh -c \
  'getprop sys.boot_completed; ip -br addr; ip route; ping -c 1 -W 3 8.8.8.8'
sudo journalctl -u redroid-kernelsu-replay.service -b --no-pager
curl -fsS http://127.0.0.1:8001/ready
```
