#!/system/bin/sh
# Make exp identity byte-match the PASSING WSL device: install redroid_pixel5
# global system.prop identity module + disable PIF. exp ONLY. Reversible.
M=/data/adb/modules/redroid_pixel5
mkdir -p "$M"

cat > "$M/module.prop" <<'EOF'
id=redroid_pixel5
name=ReDroid Pixel 5 identity
version=14-UP1A.231105.001.B2
versionCode=1
author=local (rev-eng/docs 05 section 4.5)
description=Coherent Pixel 5 (redfin) Android 14 identity for Play + attestation
EOF

cat > "$M/system.prop" <<'EOF'
# Pixel 5 (redfin) Android 14 identity
ro.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys
ro.system.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys
ro.system_ext.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys
ro.product.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys
ro.vendor.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys
ro.odm.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys
ro.bootimage.build.fingerprint=google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys
ro.product.model=Pixel 5
ro.product.brand=google
ro.product.name=redfin
ro.product.device=redfin
ro.product.manufacturer=Google
ro.product.system.model=Pixel 5
ro.product.system.brand=google
ro.product.system.name=redfin
ro.product.system.device=redfin
ro.product.system.manufacturer=Google
ro.product.system_ext.model=Pixel 5
ro.product.system_ext.brand=google
ro.product.system_ext.name=redfin
ro.product.system_ext.device=redfin
ro.product.system_ext.manufacturer=Google
ro.product.product.model=Pixel 5
ro.product.product.brand=google
ro.product.product.name=redfin
ro.product.product.device=redfin
ro.product.product.manufacturer=Google
ro.product.vendor.model=Pixel 5
ro.product.vendor.brand=google
ro.product.vendor.name=redfin
ro.product.vendor.device=redfin
ro.product.vendor.manufacturer=Google
ro.product.odm.model=Pixel 5
ro.product.odm.brand=google
ro.product.odm.name=redfin
ro.product.odm.device=redfin
ro.product.odm.manufacturer=Google
ro.build.product=redfin
ro.build.id=UP1A.231105.001.B2
ro.build.tags=release-keys
ro.build.type=user
ro.build.description=redfin-user 14 UP1A.231105.001.B2 11260668 release-keys
ro.product.first_api_level=30
ro.board.first_api_level=30
ro.boot.verifiedbootstate=green
ro.boot.flash.locked=1
ro.boot.veritymode=enforcing
ro.secure=1
ro.debuggable=0
EOF

chmod 644 "$M/module.prop" "$M/system.prop"
echo "== redroid_pixel5 installed =="; ls -la "$M"

echo "== disable PIF (WSL has none) =="
touch /data/adb/modules/playintegrityfix/disable && echo "playintegrityfix disabled"

echo "== module states =="
for d in /data/adb/modules/*/; do id=$(basename "$d"); [ -f "$d/disable" ] && s=DISABLED || s=enabled; echo "$id: $s"; done
echo "@@DONE (restart container to apply system.prop)"
