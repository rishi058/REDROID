#!/usr/bin/env bash
# Extract only the Ubuntu Noble source files needed to recover the proven
# modular-Binder delta. Never overlay this tree on the v6.8.12 build tree.
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
REF="$BUILD_ROOT/ubuntu-source-reference"
TARBALL="$REF/extracted/usr/src/linux-source-6.8.0.tar.bz2"
TREE="$REF/tree"

test "$(id -un)" = builder
test -f "$TARBALL"

mkdir -p "$TREE"
cd "$TREE"

if [ ! -d linux-source-6.8.0/drivers/android ]; then
  tar -xjf "$TARBALL" \
    linux-source-6.8.0/drivers/android \
    linux-source-6.8.0/kernel/sched/wait.c \
    linux-source-6.8.0/kernel/sched/core.c \
    linux-source-6.8.0/kernel/task_work.c \
    linux-source-6.8.0/security/security.c \
    linux-source-6.8.0/fs/file.c \
    linux-source-6.8.0/ipc/namespace.c \
    linux-source-6.8.0/ipc/msgutil.c \
    linux-source-6.8.0/mm/memory.c
fi

echo "=== extracted files ==="
find linux-source-6.8.0 -type f | sort
du -sh "$TREE"
echo UBUNTU_REFERENCE_EXTRACTED
