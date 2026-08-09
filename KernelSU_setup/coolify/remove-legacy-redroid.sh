#!/usr/bin/env bash
set -Eeuo pipefail

# Removes the old hand-managed ReDroid deployment without touching the custom
# kernel, BinderFS prerequisites, or reusable Android installation artifacts.

CONTAINER=redroid14-ksu
DATA_DIR=/home/ubuntu/redroid14-data
IMAGE=redroid/redroid@sha256:0a611199ba2e0b5d60af39b3327a517f6407231f4352114ed3bd3cbfe2be69aa
PURGE_DATA=false
REMOVE_IMAGE=false
REMOVE_LEGACY_UNITS=false

usage() {
  cat <<'EOF'
Usage: sudo ./remove-legacy-redroid.sh --purge-data [--remove-image] [--remove-legacy-units]

--purge-data           Required: permanently removes /home/ubuntu/redroid14-data.
--remove-image          Also removes the pinned ReDroid Docker image if unused.
--remove-legacy-units   Removes the old redroid14 systemd service, validator,
                        watchdog unit, and legacy watchdog binary.

The script intentionally preserves the KernelSU kernel, BinderFS units, and
/home/ubuntu/kbuild/artifacts/android because the Coolify deployment reuses them.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --purge-data) PURGE_DATA=true ;;
    --remove-image) REMOVE_IMAGE=true ;;
    --remove-legacy-units) REMOVE_LEGACY_UNITS=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$PURGE_DATA" != true ]; then
  echo "Refusing to delete Android data without --purge-data." >&2
  usage >&2
  exit 2
fi

test "$(id -u)" -eq 0 || {
  echo "Run this script with sudo." >&2
  exit 1
}

for unit in redroid14-validate.service redroid14-watchdog.service redroid14.service; do
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
rm -rf --one-file-system "$DATA_DIR"

if [ "$REMOVE_LEGACY_UNITS" = true ]; then
  rm -f \
    /etc/systemd/system/redroid14.service \
    /etc/systemd/system/redroid14-watchdog.service \
    /etc/systemd/system/redroid14-validate.service \
    /usr/local/sbin/validate-redroid14 \
    /usr/local/sbin/monitor-redroid14-10m \
    /usr/local/sbin/redroid14-watchdog
  systemctl daemon-reload
fi

if [ "$REMOVE_IMAGE" = true ]; then
  docker image rm "$IMAGE" >/dev/null 2>&1 || \
    echo "Pinned image was already absent or is still used by another container."
fi

echo "Legacy ReDroid container and persistent Android data were removed."
