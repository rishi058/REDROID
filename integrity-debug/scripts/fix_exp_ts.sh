#!/system/bin/sh
# Match exp's TrickyStore config to the PASSING WSL device. exp ONLY. Reversible.
# Runs as root inside the exp container.
TS=/data/adb/tricky_store
BAK=/data/local/tmp/ts_bak_$(date +%Y%m%d_%H%M%S)
echo "== backup $TS -> $BAK =="
mkdir -p "$BAK"; cp -a "$TS/." "$BAK/" 2>/dev/null && echo "backup ok: $(ls "$BAK" | tr '\n' ' ')"

echo "== 1) remove TEESimulator-RS leftovers (TrickyStore v1.4.1 does not use these) =="
for f in boot_key.bin boot_hash.bin hbk persistent_keys logs; do
  [ -e "$TS/$f" ] && { rm -rf "$TS/$f" && echo "removed $f"; }
done

echo "== 2) write security_patch.txt (mirror WSL) =="
cat > "$TS/security_patch.txt" <<EOF
system=202607
boot=2026-07-05
vendor=2026-07-05
EOF
echo "security_patch.txt:"; cat "$TS/security_patch.txt"

echo "== 3) set target.txt (match WSL: add com.android.vending) =="
cat > "$TS/target.txt" <<EOF
com.android.vending
com.google.android.gms!
gr.nikolasspyr.integritycheck
EOF
echo "target.txt:"; cat "$TS/target.txt"

chmod 644 "$TS/security_patch.txt" "$TS/target.txt"
echo "== final dir =="; ls "$TS/" | tr '\n' ' '; echo
echo "@@DONE (restart container to activate)"
