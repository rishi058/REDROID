#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER=${1:-redroid14-ksu}
MAX_PIDS=${2:-1400}
MAX_SECONDS=${3:-240}
LOG_FILE=${4:-/home/ubuntu/kbuild/artifacts/logs/redroid14-watchdog.log}

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$LOG_FILE"
}

kill_namespace() {
  local reason=$1
  log "WATCHDOG TRIPPED: $reason; killing container init PID $init_pid"
  kill -KILL "$init_pid" 2>/dev/null || true
}

on_stop() {
  elapsed=$(( $(date +%s) - started ))
  log "watchdog stopped normally after ${elapsed}s; peak task count was $peak"
  exit 0
}

log "waiting for $CONTAINER (max_pids=$MAX_PIDS max_seconds=$MAX_SECONDS)"
init_pid=0
for _ in $(seq 1 120); do
  candidate=$(timeout 2 docker inspect --format '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || true)
  if [[ "$candidate" =~ ^[0-9]+$ ]] && (( candidate > 1 )); then
    init_pid=$candidate
    break
  fi
  sleep 0.25
done

if (( init_pid <= 1 )); then
  log "container did not enter running state within 30 seconds"
  exit 70
fi

cgroup_rel=$(awk -F: '$2 == "pids" { print $3; exit }' "/proc/$init_pid/cgroup")
if [ -n "$cgroup_rel" ]; then
  pids_file="/sys/fs/cgroup/pids${cgroup_rel}/pids.current"
else
  cgroup_rel=$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' "/proc/$init_pid/cgroup")
  pids_file="/sys/fs/cgroup${cgroup_rel}/pids.current"
fi
if [ ! -r "$pids_file" ]; then
  log "cannot read pids controller for PID $init_pid: $pids_file"
  kill_namespace "PID accounting unavailable"
  exit 71
fi

started=$(date +%s)
peak=0
next_milestone=100
trap on_stop TERM INT
log "tracking PID $init_pid through $pids_file"
while kill -0 "$init_pid" 2>/dev/null; do
  current=$(cat "$pids_file" 2>/dev/null || printf '%s' "$MAX_PIDS")
  if ! [[ "$current" =~ ^[0-9]+$ ]]; then
    kill_namespace "invalid pids.current value"
    exit 72
  fi
  if (( current > peak )); then
    peak=$current
  fi
  if (( current >= next_milestone )); then
    log "task count reached $current (peak=$peak)"
    next_milestone=$(( (current / 100 + 1) * 100 ))
  fi
  if (( current >= MAX_PIDS )); then
    kill_namespace "task count reached $current"
    exit 73
  fi
  elapsed=$(( $(date +%s) - started ))
  if (( MAX_SECONDS > 0 && elapsed >= MAX_SECONDS )); then
    kill_namespace "boot deadline exceeded after ${elapsed}s with $current tasks"
    exit 74
  fi
  sleep 1
done

elapsed=$(( $(date +%s) - started ))
log "container init PID $init_pid exited after ${elapsed}s before a guard limit was reached; peak=$peak"
