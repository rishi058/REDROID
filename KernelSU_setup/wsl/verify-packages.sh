#!/usr/bin/env bash
# Prove the Binder fix survived into the shipped image package, not just the
# build tree. Extracts binder_linux.ko out of the .deb and re-checks it.
set -Eeuo pipefail

BUILD_ROOT=${BUILD_ROOT:-/home/builder/kbuild}
PACKAGE_DIR="$BUILD_ROOT/artifacts/packages-zksu-multi"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$PACKAGE_DIR"
echo "=== packages ==="
ls -la
sha256sum -c SHA256SUMS

# Assert a single revision before assigning, so a stale package left beside the
# current one cannot silently make the checks below verify the wrong artifact.
mapfile -t images < <(find . -maxdepth 1 -type f \
  -name 'linux-image-6.8.12-zksu-multi_*_arm64.deb' | sort)
mapfile -t headers < <(find . -maxdepth 1 -type f \
  -name 'linux-headers-6.8.12-zksu-multi_*_arm64.deb' | sort)
test "${#images[@]}" -eq 1 || {
  echo "expected exactly one image package, found ${#images[@]}: ${images[*]}" >&2
  exit 1
}
test "${#headers[@]}" -eq 1 || {
  echo "expected exactly one headers package, found ${#headers[@]}: ${headers[*]}" >&2
  exit 1
}
IMAGE=${images[0]}
HEADERS=${headers[0]}

echo
echo "=== package metadata ==="
for package in "$IMAGE" "$HEADERS"; do
  dpkg-deb -f "$package" Package Version Architecture Depends
  echo "---"
done

echo "=== extract the image package ==="
dpkg-deb -x "$IMAGE" "$WORK/image"

KO="$WORK/image/lib/modules/6.8.12-zksu-multi/kernel/drivers/android/binder_linux.ko"
test -f "$KO.zst" || test -f "$KO"
if [ -f "$KO.zst" ]; then
  zstd -qdf "$KO.zst" -o "$KO"
fi

echo "=== shipped binder_linux.ko ==="
modinfo "$KO"

echo "=== it must have an init function ==="
aarch64-linux-gnu-nm "$KO" | grep -w init_module

echo "=== kernel image and BinderFS presence ==="
ls -la "$WORK/image/boot/"
grep -c 'binder' "$WORK/image/lib/modules/6.8.12-zksu-multi/modules.dep"

# KernelSU is built in (CONFIG_KSU=y), so the multi-instance lifecycle code has to
# be proven inside vmlinux rather than in a module.
#
# Assert on the record table's data symbols, not on its accessor functions.
# ksu_claim_post_fs_data, ksu_mark_instance_booting, and ksu_reap_dead_instances
# are static and each has exactly one caller, so GCC inlines all three and they
# never reach System.map. The list head, mutex, and counter cannot be inlined
# away, so their presence is the reliable end-to-end evidence that the Phase 4
# record keeping actually reached the shipped kernel.
echo "=== multi-instance lifecycle symbols must be in the shipped kernel ==="
SYSTEM_MAP="$WORK/image/boot/System.map-6.8.12-zksu-multi"
test -s "$SYSTEM_MAP"
for symbol in \
  ksu_android_instances \
  ksu_android_instances_lock \
  ksu_android_instance_count \
  ksu_instance_locked \
  android_init_lock \
  ksu_handle_execveat_ksud
do
  grep -qw "$symbol" "$SYSTEM_MAP" || {
    echo "multi-instance symbol missing from shipped kernel: $symbol" >&2
    exit 1
  }
  printf '  present: %s\n' "$symbol"
done

# The upstream host-global one-shot flags must not have come back.
for symbol in first_zygote init_second_stage_executed; do
  if grep -qw "$symbol" "$SYSTEM_MAP"; then
    echo "upstream one-shot flag present in shipped kernel: $symbol" >&2
    exit 1
  fi
done
echo "  absent: first_zygote, init_second_stage_executed"

echo "=== vermagic must match the release ==="
test "$(modinfo -F vermagic "$KO" | awk '{print $1}')" = 6.8.12-zksu-multi

echo PACKAGE_CONTENTS_VERIFIED
