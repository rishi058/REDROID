#!/usr/bin/env bash
# Run the Flezen stack inside WSL with REAL interception (README §6.2.3).
#
# WHY WSL AND NOT WINDOWS
# -----------------------
# Interception needs a Linux netns, iptables and mitmdump. WSL2 has all three,
# and the local Redroid container already has the app at uid 10107 and trusts
# the mitmproxy CA -- so no image build is required. The sidecar runs as a plain
# process under `nsenter` into Redroid's network namespace.
#
# WHY DW-fast-api MUST ALSO RUN HERE
# ----------------------------------
# The sidecar's control plane binds INSIDE Redroid's netns. Measured:
#   Windows  -> WSL host port        : works (WSL2 localhost forwarding)
#   Windows  -> netns container IP   : FAILS
#   WSL host -> netns container IP   : works
# So a Windows-hosted consumer cannot reach it. Both halves live in WSL.
#
# USAGE
#   wsl-dev.sh sidecar   # sync, then run the sidecar in intercept mode
#   wsl-dev.sh api       # sync, then run DW-fast-api pointed at it
#   wsl-dev.sh sync      # copy only
#   wsl-dev.sh status    # what is up, and is the chain installed
#   wsl-dev.sh stop      # stop both and remove the redirect chain
set -Eeuo pipefail

SRC="${FLEZEN_SRC:-/mnt/d/PROJECT/_TRASH/REDROID}"
# NOT under $HOME: /root is 0700, and the self-test re-execs main.py as the
# Android app uid (10107). That child must be able to traverse and read the
# tree, or the probe dies with "can't open file: Permission denied" and the
# verdict is ERROR rather than INTERCEPTED.
DST="${FLEZEN_DST:-/opt/flezen-dev}"
REDROID="${REDROID_CONTAINER:-redroid14}"
LOCK=/tmp/flezen-dev-sync.lock
KEY="${FLEZEN_DEV_KEY:-devkey}"

trap 'rc=$?; [ $rc -ne 0 ] && printf "[31mwsl-dev: aborted at line $LINENO (exit $rc)[0m
" >&2; exit $rc' ERR

die() { printf '\033[31mwsl-dev: %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[36mwsl-dev:\033[0m %s\n' "$*"; }

# ── the container's facts, read fresh every time ─────────────────────────────
# Hardcoding any of these is how this breaks silently after a recreate.
netns_pid() { docker inspect -f '{{.State.Pid}}' "$REDROID" 2>/dev/null || true; }
netns_ip()  {
    docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' \
        "$REDROID" 2>/dev/null || true
}
app_uid()   {
    docker exec "$REDROID" sh -c 'pm list packages -U 2>/dev/null | grep flezen' 2>/dev/null \
        | sed -n 's/.*uid:\([0-9]\+\).*/\1/p' | head -1
}

require_redroid() {
    [ -n "$(netns_pid)" ] || die "container '$REDROID' is not running (docker ps)"
}

# ── sync ─────────────────────────────────────────────────────────────────────
# Copies to a WSL-NATIVE path, not /mnt/d: ext4 is far faster for Python imports
# than drvfs, and drvfs cannot represent POSIX modes, which the CA needs (0400).
#
# rsync flags: -rlt deliberately, NOT -a. `-a` implies -pog, and preserving
# perms/owner from a drvfs source either fails or produces a wall of noise.
#
# flock because both VS Code tasks launch in parallel and both call this. The
# loser waits, then finds nothing changed, so it costs almost nothing.
sync_code() {
    mkdir -p "$DST"
    (
        flock -x 9
        for proj in flezen-sidecar DW-fast-api; do
            [ -d "$SRC/$proj" ] || die "missing source: $SRC/$proj"
            mkdir -p "$DST/$proj"
            rsync -rlt --delete \
                  --exclude '.git/' --exclude '__pycache__/' --exclude '*.py[co]' \
                  --exclude '.venv/' --exclude 'ca/' --exclude '*.jsonl' \
                  --exclude 'data/' --exclude '*.sqlite3' --exclude '*.db*' \
                  "$SRC/$proj/" "$DST/$proj/"
        done
        # The self-test child runs as the app uid, so the tree must be
        # traversable and readable by it. The CA keeps its own 0400 (see
        # ensure_ca); the child verifies against the world-readable anchor
        # the supervisor publishes under /run/flezencap instead.
        chmod -R a+rX "$DST/flezen-sidecar" "$DST/DW-fast-api" 2>/dev/null || true
    ) 9>"$LOCK"
    say "synced -> $DST"
}

# The CA must be 0400 and readable by the running user. It is the device's
# trusted anchor AND its private key, so it is copied to an ext4 path and never
# left on drvfs where the mode cannot be enforced.
ensure_ca() {
    local pem="$SRC/DW-fast-api/certs/mitmproxy-ca.pem"
    [ -f "$pem" ] || die "CA not found: $pem"
    mkdir -p "$DST/ca"
    # rm first: the destination is left 0400, and cp onto it is not reliably
    # permitted. This aborted the whole script with no message before the ERR
    # trap above existed.
    rm -f "$DST/ca/mitmproxy-ca.pem"
    cp "$pem" "$DST/ca/mitmproxy-ca.pem"
    chmod 400 "$DST/ca/mitmproxy-ca.pem"
    grep -q 'PRIVATE KEY' "$DST/ca/mitmproxy-ca.pem" \
        || die "that PEM has no private key; mitmproxy cannot forge certs with it"
}

# ── run: sidecar ─────────────────────────────────────────────────────────────
run_sidecar() {
    require_redroid
    sync_code
    ensure_ca
    local pid ip uid
    pid="$(netns_pid)"; ip="$(netns_ip)"; uid="$(app_uid)"
    if [ -z "$uid" ]; then
        # A restarted Redroid answers `docker exec` long before Android's
        # package manager is up, so an immediate read returns nothing and the
        # rule would be installed against uid "" -- matching nothing, and
        # looking perfectly healthy.
        say "waiting for Android to finish booting (pm not ready yet)"
        for _ in $(seq 1 30); do
            sleep 2
            uid="$(app_uid)"
            [ -n "$uid" ] && break
        done
    fi
    [ -n "$uid" ] || die "could not read the Flezen app uid after 60s; is the app installed?"

    # These beat the repo .env: load_env_file never overrides the environment,
    # which is exactly what makes it safe to keep an api-mode .env for Windows
    # while forcing intercept mode here.
    export FLEZENCAP_MODE=intercept
    export FLEZENCAP_DEVICE_ID="${FLEZENCAP_DEVICE_ID:-wsl}"
    export FLEZENCAP_TARGET_CONTAINER="$REDROID"
    export FLEZENCAP_APP_UID="$uid"
    export FLEZENCAP_NETNS_EXPECT_IP="$ip"
    # 0.0.0.0 INSIDE the netns, so the WSL host can reach it at $ip:8002.
    # 127.0.0.1 here would be unreachable even from the WSL host.
    export FLEZENCAP_API_HOST=0.0.0.0
    export FLEZENCAP_API_PORT="${FLEZENCAP_API_PORT:-8002}"
    export FLEZENCAP_API_KEY="$KEY"
    # DNS does not work in that netns: it inherits docker's embedded resolver
    # at 127.0.0.11, whose nat rules Android's netd has flushed, and
    # `nsenter --net` shares the NETWORK namespace but not the MOUNT one, so
    # /etc/resolv.conf is still the WSL host's and points at a resolver that
    # netns cannot reach. Measured: scope=ips then resolves nothing and the
    # supervisor exits 73 (EXIT_NO_TARGETS). Seeding the known Cloudflare
    # edges removes the DNS dependency entirely -- which is why
    # .env.example ships them pre-seeded.
    export FLEZENCAP_EXTRA_IPS="${FLEZENCAP_EXTRA_IPS:-104.21.26.188,172.67.138.92}"
    export FLEZENCAP_CA_DIR="$DST/ca"
    export FLEZENCAP_SINK_DIR="$DST/sink"
    export FLEZENCAP_LOG_FORMAT=text
    export FLEZENCAP_API_LOG_LEVEL=info
    # wsl.exe does not always present a TTY, and the readable format is the
    # entire point of running this in a terminal.
    export FORCE_COLOR="${FORCE_COLOR:-1}"
    mkdir -p "$DST/sink"

    say "netns pid=$pid  ip=$ip  app_uid=$uid  ->  http://$ip:8002"
    say "Ctrl+C tears down the FLEZENCAP chain; check with 'wsl-dev.sh status'"
    cd "$DST/flezen-sidecar"
    # exec replaces this shell, so $$ is python's pid. Recorded because
    # `pkill -f` cannot find it: the cmdline is just "python3 main.py" --
    # the project path is only the CWD, so a path pattern never matches and
    # `stop` silently did nothing while the reconcile loop kept the chain up.
    echo $$ > /tmp/flezencap-sidecar.pid
    # exec so signals reach python directly. nsenter execs (no --fork needed for
    # a net-only namespace), so Ctrl+C runs the supervisor's teardown.
    exec nsenter --net="/proc/$pid/ns/net" python3 main.py
}

# ── run: DW-fast-api ─────────────────────────────────────────────────────────
run_api() {
    require_redroid
    sync_code
    local ip; ip="$(netns_ip)"

    export FLEZEN_CAPTURE_BACKEND=sidecar
    export FLEZEN_SIDECAR_URL="http://$ip:${FLEZENCAP_API_PORT:-8002}"
    export FLEZEN_SIDECAR_KEY="$KEY"
    export FLEZEN_ADB_SERIAL="127.0.0.1:5555"
    # No tunnels: the device is local. Without these the committed .env can send
    # this at the production VPS and force-stop the live app.
    export FLEZEN_USE_SSH_TUNNEL=false
    export USE_SSH_TUNNEL=false
    export VPS_HOST=""
    # WSL's adb has its OWN ~/.android/adbkey, which the device has never seen --
    # so without this you get "device unauthorized" even though Windows works.
    # The repo's baked key is already authorised on the device.
    export ADB_VENDOR_KEYS="$SRC/DW-fast-api/adb-keys/adbkey"

    say "sidecar at $FLEZEN_SIDECAR_URL  ·  adb 127.0.0.1:5555  ·  vendor key from repo"
    cd "$DST/DW-fast-api"
    echo $$ > /tmp/flezencap-api.pid
    exec python3 main.py
}

# ── status / stop ────────────────────────────────────────────────────────────
status() {
    local pid ip code body
    pid="$(netns_pid)"; ip="$(netns_ip)"
    if [ -n "$pid" ]; then
        printf '  %-22s running  pid=%s  ip=%s\n' "$REDROID" "$pid" "$ip"
        printf '  %-22s ' "FLEZENCAP chain"
        if nsenter --net="/proc/$pid/ns/net" iptables-legacy -t nat -S OUTPUT 2>/dev/null \
             | grep -q FLEZENCAP; then echo "installed"; else echo "absent"; fi
        printf '  %-22s ' "sidecar :8002"
        body="$(curl -s -m 3 "http://$ip:8002/healthz" 2>/dev/null || true)"
        [ -n "$body" ] && echo "$body" || echo "unreachable"
    else
        printf '  %-22s NOT RUNNING\n' "$REDROID"
    fi
    printf '  %-22s ' "dw-fast-api :8001"
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8001/health 2>/dev/null || true)"
    if [ "$code" = "200" ]; then echo "200 ok"
    else echo "unreachable${code:+ (http $code)}"; fi
}

stop() {
    local pidfile pid stopped=0
    for pidfile in /tmp/flezencap-api.pid /tmp/flezencap-sidecar.pid; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # SIGTERM, not KILL: the supervisor's handler is what removes the
            # chain and stops mitmdump. SIGKILL would strand both.
            kill -TERM "$pid" 2>/dev/null && stopped=1
            for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        fi
        rm -f "$pidfile"
    done
    # Any orphaned mitmdump the supervisor did not get to reap.
    pkill -f 'mitmdump --mode transparent' 2>/dev/null && stopped=1 || true
    [ "$stopped" = 1 ] && say "stopped" || say "nothing was running"
    sleep 1

    # Belt and braces. A chain left behind with nothing on :8081 black-holes the
    # app's flezen.com traffic entirely, which is worse than no interception.
    local npid; npid="$(netns_pid)"
    if [ -n "$npid" ]; then
        nsenter --net="/proc/$npid/ns/net" sh -c '
            iptables-legacy -t nat -D OUTPUT -j FLEZENCAP 2>/dev/null
            iptables-legacy -t nat -F FLEZENCAP 2>/dev/null
            iptables-legacy -t nat -X FLEZENCAP 2>/dev/null' 2>/dev/null || true
        say "redirect chain removed"
    fi
}

case "${1:-}" in
    sidecar) run_sidecar ;;
    api)     run_api ;;
    sync)    sync_code ;;
    status)  status ;;
    stop)    stop ;;
    *) sed -n '2,25p' "$0" >&2; exit 2 ;;
esac
