#!/bin/bash
# Apply a coherent 64-bit-only "redfin_beta_64" identity to the EXPERIMENTAL container.
# Goal: make the claimed device profile consistent with the container's REAL 64-bit-only
#   ABI (ro.zygote=zygote64, abilist32 empty) so DroidGuard's BASIC consistency check
#   stops catching the Pixel-5(64/32)-claim-vs-64-only-reality contradiction.
# Keeps device=redfin + first_api_level=30 so the DEVICE attestation path is unchanged.
# EXP ONLY. prod (redroid14-*) is never touched. Fully reversible (backup taken).
set -euo pipefail

C=$(sudo docker ps -q --filter "label=coolify.serviceName=redroid-experimental")
[ -z "$C" ] && { echo "FATAL: exp container not running"; exit 1; }
echo "exp container: $C"

M=/data/adb/modules/redroid_pixel5
TS=$(date -u +%Y%m%dT%H%M%SZ)

echo "=== 1. backup current identity module ==="
sudo docker exec "$C" sh -c "cp $M/system.prop $M/system.prop.bak-$TS && ls -la $M/system.prop.bak-$TS"

echo "=== 2. stage new system.prop on host ==="
NEW=/tmp/redfin64_system_$TS.prop
cat > "$NEW" <<'PROP'
# redfin_beta_64 : Pixel 5 (redfin) 64-bit-ONLY Android 14 base (real Google beta build).
# Chosen so the device claim matches the container's genuine 64-bit-only ABI.
# device=redfin + first_api_level=30 kept => DEVICE attestation window unaffected.
ro.build.fingerprint=google/redfin_beta_64/redfin:14/UPB5.230623.009/10747070:user/release-keys
ro.system.build.fingerprint=google/redfin_beta_64/redfin:14/UPB5.230623.009/10747070:user/release-keys
ro.system_ext.build.fingerprint=google/redfin_beta_64/redfin:14/UPB5.230623.009/10747070:user/release-keys
ro.product.build.fingerprint=google/redfin_beta_64/redfin:14/UPB5.230623.009/10747070:user/release-keys
ro.vendor.build.fingerprint=google/redfin_beta_64/redfin:14/UPB5.230623.009/10747070:user/release-keys
ro.odm.build.fingerprint=google/redfin_beta_64/redfin:14/UPB5.230623.009/10747070:user/release-keys
ro.bootimage.build.fingerprint=google/redfin_beta_64/redfin:14/UPB5.230623.009/10747070:user/release-keys
ro.product.model=Pixel 5
ro.product.brand=google
ro.product.name=redfin_beta_64
ro.product.device=redfin
ro.product.manufacturer=Google
ro.product.system.model=Pixel 5
ro.product.system.brand=google
ro.product.system.name=redfin_beta_64
ro.product.system.device=redfin
ro.product.system.manufacturer=Google
ro.product.system_ext.model=Pixel 5
ro.product.system_ext.brand=google
ro.product.system_ext.name=redfin_beta_64
ro.product.system_ext.device=redfin
ro.product.system_ext.manufacturer=Google
ro.product.product.model=Pixel 5
ro.product.product.brand=google
ro.product.product.name=redfin_beta_64
ro.product.product.device=redfin
ro.product.product.manufacturer=Google
ro.product.vendor.model=Pixel 5
ro.product.vendor.brand=google
ro.product.vendor.name=redfin_beta_64
ro.product.vendor.device=redfin
ro.product.vendor.manufacturer=Google
ro.product.odm.model=Pixel 5
ro.product.odm.brand=google
ro.product.odm.name=redfin_beta_64
ro.product.odm.device=redfin
ro.product.odm.manufacturer=Google
ro.build.product=redfin
ro.build.id=UPB5.230623.009
ro.build.version.incremental=10747070
ro.build.version.release=14
ro.build.version.sdk=34
ro.build.version.security_patch=2023-06-05
ro.build.tags=release-keys
ro.build.type=user
ro.build.flavor=redfin_beta_64-user
ro.build.description=redfin_beta_64-user 14 UPB5.230623.009 10747070 release-keys
ro.product.first_api_level=30
ro.board.first_api_level=30
ro.boot.verifiedbootstate=green
ro.boot.flash.locked=1
ro.boot.veritymode=enforcing
ro.secure=1
ro.debuggable=0
PROP
echo "staged $(wc -l < "$NEW") lines at $NEW"

echo "=== 3. push into container ==="
sudo docker cp "$NEW" "$C:$M/system.prop"
sudo docker exec "$C" chmod 644 "$M/system.prop"
rm -f "$NEW"

echo "=== 4. verify written content ==="
sudo docker exec "$C" sh -c "grep -E '^ro.build.fingerprint=|^ro.product.name=|^ro.product.device=|^ro.product.first_api_level=|^ro.build.id=' $M/system.prop"

echo "=== 5. module states (unchanged set) ==="
sudo docker exec "$C" sh -c 'for d in /data/adb/modules/*/; do id=$(basename "$d"); s=enabled; [ -f "$d/disable" ] && s=DISABLED; echo "  $id: $s"; done'

echo "@@STAGED_OK  (restart exp to apply system.prop)"
