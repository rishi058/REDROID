#!/usr/bin/env bash
# Re-derive the multi-instance candidate from pinned upstream and regenerate its
# patch, then prove it still compiles for ARM64.
#
# WHEN TO RUN THIS: after editing apply-multi-instance.py. The edit script is not
# idempotent, so the target file must go back to pinned upstream first. That is
# safe here because none of the KernelSU compatibility patches touch
# ksud_integration.c; the script asserts that rather than assuming it.
#
# Incremental: only drivers/kernelsu/ is rebuilt. Never run `make clean`.
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
KSU_DIR="$SOURCE_DIR/KernelSU-Next"
INPUTS="$BUILD_ROOT/project-inputs"
LOG_DIR="$BUILD_ROOT/artifacts/logs"
LOG_FILE="$LOG_DIR/multi-instance-$(date -u +%Y%m%dT%H%M%SZ).log"
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}
SCRIPTS="$REPO_WSL/KernelSU_setup/wsl"
PATCH_DIR="$REPO_WSL/KernelSU_setup/vps/patches"
TARGET=kernel/runtime/ksud_integration.c
JOBS=${JOBS:-6}
MAKE_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=-zksu-multi)

test "$(id -un)" = builder
test -d "$KSU_DIR/.git"
test -f "$SOURCE_DIR/.config"
export PYTHONDONTWRITEBYTECODE=1

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "started=$(date -Is)"

# Reverting the target is only safe if no compatibility patch owns any of it.
echo "=== no compatibility patch may touch $TARGET ==="
if grep -q "^+++ b/$TARGET\$" "$INPUTS/compatibility-baseline.diff"; then
  echo "compatibility-baseline.diff modifies $TARGET; reverting would lose it" >&2
  exit 1
fi

echo "=== revert $TARGET to pinned upstream ==="
git -C "$KSU_DIR" checkout -- "$TARGET"
git -C "$KSU_DIR" diff --quiet -- "$TARGET"

echo "=== re-apply the multi-instance candidate ==="
python3 "$SCRIPTS/apply-multi-instance.py"

echo "=== whitespace check ==="
git -C "$KSU_DIR" diff --check

echo "=== the diff must still be confined to $TARGET plus the compatibility set ==="
git -C "$KSU_DIR" diff --name-only

echo "=== regenerate kernelsu-redroid-multi-instance.patch ==="
git -C "$KSU_DIR" diff -- "$TARGET" \
  > "$BUILD_ROOT/kernelsu-redroid-multi-instance.patch"
wc -l "$BUILD_ROOT/kernelsu-redroid-multi-instance.patch"

# A patch that reverses cleanly against this tree applies cleanly forward onto a
# pinned checkout, which is what prepare-source.sh will do.
echo "=== the patch must round-trip ==="
git -C "$KSU_DIR" apply --check --reverse \
  "$BUILD_ROOT/kernelsu-redroid-multi-instance.patch"

echo "=== the one-shot upstream flags must be gone ==="
for symbol in first_zygote init_second_stage_executed; do
  if grep -q "\b$symbol\b" "$KSU_DIR/$TARGET"; then
    echo "upstream one-shot flag still present: $symbol" >&2
    exit 1
  fi
done

echo "=== the per-instance record and null guards must be present ==="
grep -q 'KSU_MAX_ANDROID_INSTANCES' "$KSU_DIR/$TARGET"
grep -q 'ksu_claim_post_fs_data' "$KSU_DIR/$TARGET"
grep -q 'ksu_mark_instance_booting' "$KSU_DIR/$TARGET"
grep -q 'ksu_reap_dead_instances' "$KSU_DIR/$TARGET"
test "$(grep -c 'ksu_no_custom_rc || !ksu_cred' "$KSU_DIR/$TARGET")" -eq 2

echo "=== on_post_fs_data must only be reachable through the claim ==="
test "$(grep -c 'on_post_fs_data();' "$KSU_DIR/$TARGET")" -eq 1

echo "=== ARM64 compile gate for drivers/kernelsu ==="
cd "$SOURCE_DIR"
rm -f KernelSU-Next/kernel/built-in.a
make -j"$JOBS" "${MAKE_ARGS[@]}" drivers/kernelsu/
test -f KernelSU-Next/kernel/built-in.a

echo "=== publish the compile-validated patch ==="
cat "$BUILD_ROOT/kernelsu-redroid-multi-instance.patch" \
  > "$PATCH_DIR/kernelsu-redroid-multi-instance.patch"

echo "completed=$(date -Is)"
echo MULTI_INSTANCE_REBUILT
