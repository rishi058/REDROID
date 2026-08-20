#!/usr/bin/env bash
# Regenerate the two Linux Binder patches from the anchor-checked edit scripts.
#
# WHEN TO RUN THIS: only if `linux-mainline-6.8-binder-modules.patch` or
# `linux-mainline-6.8-binder-exports.patch` stops applying, which happens if the
# Linux baseline moves off v6.8.12. Normal reproduction does not need it;
# prepare-source.sh applies the committed patches directly.
#
# Safe to run on a tree that prepare-source.sh has already patched: the edit
# scripts detect the already-applied state and regenerate identical patches.
# No compilation happens here, so it does not need a built object tree.
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
SOURCE_DIR="$BUILD_ROOT/linux-6.8.0"
INPUTS="$BUILD_ROOT/project-inputs"
REPO_WSL=${REPO_WSL:-/mnt/d/PROJECT/_TRASH/REDROID}
SCRIPTS="$REPO_WSL/KernelSU_setup/wsl"
PATCH_DIR="$REPO_WSL/KernelSU_setup/vps/patches"

# The exports patch touches these paths and nothing else. Keeping the list here
# rather than diffing the whole tree stops unrelated work from leaking in.
EXPORT_PATCH_PATHS=(
  fs/file.c
  include/linux/ipc_namespace.h
  ipc/namespace.c
  kernel/sched/core.c
  kernel/sched/wait.c
  kernel/task_work.c
  mm/memory.c
  security/security.c
)

test "$(id -un)" = builder
test -d "$SOURCE_DIR/.git"
mkdir -p "$INPUTS"

# The edit scripts import binder_edit, which would drop a __pycache__ directory
# into the repository checkout on the drvfs mount.
export PYTHONDONTWRITEBYTECODE=1

echo "=== apply the Ubuntu-proven modular-Binder delta ==="
python3 "$SCRIPTS/apply-binder-module-delta.py"

echo "=== apply the Ubuntu-proven core-kernel exports ==="
python3 "$SCRIPTS/apply-binder-exports.py"

echo "=== every edit must be present exactly once ==="
bash "$SCRIPTS/verify-binder-edits.sh"

echo "=== whitespace check ==="
git -C "$SOURCE_DIR" diff --check

echo "=== regenerate linux-mainline-6.8-binder-modules.patch ==="
git -C "$SOURCE_DIR" diff -- drivers/android \
  > "$INPUTS/linux-mainline-6.8-binder-modules.patch"

echo "=== regenerate linux-mainline-6.8-binder-exports.patch ==="
git -C "$SOURCE_DIR" diff -- "${EXPORT_PATCH_PATHS[@]}" \
  > "$INPUTS/linux-mainline-6.8-binder-exports.patch"

wc -l "$INPUTS/linux-mainline-6.8-binder-modules.patch" \
      "$INPUTS/linux-mainline-6.8-binder-exports.patch"

# A patch that reverses cleanly against this tree is exactly the patch that
# applies cleanly forward onto a pristine v6.8.12 checkout, so this validates
# both directions without needing a second source tree.
echo "=== both patches must round-trip against the pristine baseline ==="
git -C "$SOURCE_DIR" apply --check --reverse \
  "$INPUTS/linux-mainline-6.8-binder-modules.patch"
git -C "$SOURCE_DIR" apply --check --reverse \
  "$INPUTS/linux-mainline-6.8-binder-exports.patch"

# The repository is an NTFS drvfs mount that rejects utimensat, chmod, and chown,
# so `cp -a` and `install -m` both fail there even though the data transfers
# fine. Write contents only and let the mount supply the metadata.
echo "=== publish both patches into the repository ==="
cat "$INPUTS/linux-mainline-6.8-binder-modules.patch" \
  > "$PATCH_DIR/linux-mainline-6.8-binder-modules.patch"
cat "$INPUTS/linux-mainline-6.8-binder-exports.patch" \
  > "$PATCH_DIR/linux-mainline-6.8-binder-exports.patch"

echo BINDER_PATCHES_REGENERATED
