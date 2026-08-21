#!/usr/bin/env bash
set -Eeuo pipefail

# Play Integrity / genuine-device stack for the local x86_64 WSL ReDroid, adapted
# from rev-eng/docs/05-Follow-Up-Fixes.md and KernelSU_setup/coolify (both ARM64).
# Goal: coherent Pixel 5 (redfin) Android 14 identity + Basic/Device/Strong.
#
#   bash install-integrity-stack.sh fetch          # download + verify + inspect arch
#   bash install-integrity-stack.sh pif-trickystore# PIF (Pixel 5) + TrickyStore + keybox
#   ... wsl --shutdown / restart ...
#   bash install-integrity-stack.sh teesimulator   # replace TrickyStore w/ TEESimulator
#   ... wsl --shutdown / restart ... then verify with Play Integrity Checker
#
# Modules share the same multi-arch zips (arm64 + x86_64 libs); TrickyStore and
# TEESimulator BOTH use KernelSU module id `tricky_store` and replace each other,
# while their config lives separately in /data/adb/tricky_store/.

CONTAINER=${CONTAINER:-redroid14}
REPO=${REPO:-/mnt/d/PROJECT/_TRASH/REDROID}
ART="$REPO/local-setup/artifacts/integrity"
KEYBOX="$REPO/local-setup/keybox/keybox.xml"

PIF_NAME=PlayIntegrityFix_v4.7-1-inject-s.zip
PIF_URL=https://github.com/KOWX712/PlayIntegrityFix/releases/download/v4.7-inject-s/$PIF_NAME
PIF_SHA=10eec591735cafee437332871443a2fadf6632b1a58abb16fe2461d9df100ab1

TS_NAME=Tricky-Store-v1.4.1-245-72b2e84-release.zip
TS_URL=https://github.com/5ec1cff/TrickyStore/releases/download/1.4.1/$TS_NAME
TS_SHA=2f5e73fcba0e4e43b6e96b38f333cbe394873e3a81cf8fe1b831c2fbd6c46ea9

TEE_NAME=TEESimulator-RS-v6.0.1-282-Release.zip
TEE_URL=https://github.com/Enginex0/TEESimulator-RS/releases/download/v6.0.1-282/$TEE_NAME
TEE_SHA=4cde854bdc6add7a3f587dae24d3cefff519206716b2d0dea7ff4c2772bb86ef

# Pixel 5 (redfin) Android 14 identity — from rev-eng/docs/05-Follow-Up-Fixes.md 4.5
FINGERPRINT="google/redfin/redfin:14/UP1A.231105.001.B2/11260668:user/release-keys"
DESCRIPTION="redfin-user 14 UP1A.231105.001.B2 11260668 release-keys"
SECURITY_PATCH=2026-07-05

log() { printf '\n=== %s ===\n' "$*"; }
have() { command -v "$1" >/dev/null; }

fetch_one() {
  local name=$1 url=$2 sha=$3 path="$ART/$1"
  install -d -m 0755 "$ART"
  if [ ! -f "$path" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$path.part" "$url" >&2
    mv "$path.part" "$path"
  fi
  printf '%s  %s\n' "$sha" "$path" | sha256sum -c - >&2
  printf '%s\n' "$path"
}

require_env() {
  have curl || { echo "need curl" >&2; exit 1; }
  have unzip || { echo "need unzip" >&2; exit 1; }
  have docker || { echo "need docker" >&2; exit 1; }
  zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_KSU=y' || { echo "KernelSU kernel not active" >&2; exit 1; }
  test "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true || { echo "$CONTAINER not running" >&2; exit 1; }
  docker exec "$CONTAINER" test -x /data/adb/ksud || { echo "/data/adb/ksud missing" >&2; exit 1; }
}

ksud_install() { # <host-zip> <tmp-name>
  wait_boot
  docker exec "$CONTAINER" mount -o remount,size=768M /dev 2>/dev/null || true
  docker cp "$1" "$CONTAINER:/data/local/tmp/$2"
  docker exec "$CONTAINER" /data/adb/ksud module install "/data/local/tmp/$2"
  docker exec "$CONTAINER" rm -f "/data/local/tmp/$2"
}

wait_boot() {
  local b=""
  for _ in $(seq 1 40); do
    b=$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [ "$b" = "1" ]; then return 0; fi
    sleep 3
  done
  echo "container did not finish booting (sys.boot_completed=$b)" >&2
  return 1
}

# ro.secure=1 + ro.debuggable=0 (set by the identity module for a genuine device)
# makes adbd require key auth. Trust the host key so `adb connect` still works.
authorize_adb() {
  local pub=${ADBKEY_PUB:-}
  if [ -z "$pub" ]; then
    pub=$(ls /mnt/c/Users/*/.android/adbkey.pub 2>/dev/null | head -1 || true)
  fi
  if [ -z "$pub" ] || [ ! -f "$pub" ]; then
    echo "adb pubkey not found (set ADBKEY_PUB=/mnt/c/Users/<you>/.android/adbkey.pub); skipping adb auth" >&2
    return 0
  fi
  docker exec -i "$CONTAINER" sh -c 'mkdir -p /data/misc/adb; cat > /data/misc/adb/adb_keys; chown 1000:2000 /data/misc/adb/adb_keys; chmod 640 /data/misc/adb/adb_keys' < "$pub"
  docker exec "$CONTAINER" setprop ctl.restart adbd || true
  echo "adb key authorized from $pub"
}

build_identity_module() { # <workdir> -> echoes zip path
  local work=$1 mod="$1/redroid_pixel5"
  install -d -m 0755 "$mod"
  cat > "$mod/module.prop" <<EOF
id=redroid_pixel5
name=ReDroid Pixel 5 identity
version=14-UP1A.231105.001.B2
versionCode=1
author=local (rev-eng/docs 05 section 4.5)
description=Coherent Pixel 5 (redfin) Android 14 identity for Play + attestation
EOF
  # Set top-level AND per-partition variants so every getter agrees (Android 14
  # resolves ro.product.* from the partition-scoped props).
  {
    echo "# Pixel 5 (redfin) Android 14 identity"
    for part in "" .system .system_ext .product .vendor .odm .bootimage; do
      echo "ro${part}.build.fingerprint=$FINGERPRINT"
    done
    for part in "" system. system_ext. product. vendor. odm.; do
      echo "ro.product.${part}model=Pixel 5"
      echo "ro.product.${part}brand=google"
      echo "ro.product.${part}name=redfin"
      echo "ro.product.${part}device=redfin"
      echo "ro.product.${part}manufacturer=Google"
    done
    echo "ro.build.product=redfin"
    echo "ro.build.id=UP1A.231105.001.B2"
    echo "ro.build.tags=release-keys"
    echo "ro.build.type=user"
    echo "ro.build.description=$DESCRIPTION"
    echo "ro.product.first_api_level=30"
    echo "ro.board.first_api_level=30"
    echo "ro.boot.verifiedbootstate=green"
    echo "ro.boot.flash.locked=1"
    echo "ro.boot.veritymode=enforcing"
    echo "ro.secure=1"
    echo "ro.debuggable=0"
  } > "$mod/system.prop"
  ( cd "$mod" && zip -qry "$work/redroid_pixel5.zip" module.prop system.prop )
  printf '%s\n' "$work/redroid_pixel5.zip"
}

case "${1:-}" in
  fetch)
    p1=$(fetch_one "$PIF_NAME" "$PIF_URL" "$PIF_SHA")
    p2=$(fetch_one "$TS_NAME"  "$TS_URL"  "$TS_SHA")
    p3=$(fetch_one "$TEE_NAME" "$TEE_URL" "$TEE_SHA")
    for p in "$p1" "$p2" "$p3"; do
      log "$(basename "$p")"
      echo "-- native/arch --"
      unzip -l "$p" | grep -ioE '(lib/)?(arm64-v8a|arm64|x86_64|x64|x86|armeabi-v7a|arm)/[^ ]*\.so|zygisk/[^ ]*\.so|machikado\.[a-z0-9]+' | sort -u || true
      echo "-- key files --"
      unzip -l "$p" | grep -iE 'customize.sh|service.sh|post-fs-data|module.prop|libcertgen|classes.dex' | awk '{print $NF}' | sort -u || true
    done
    ;;

  identity-trickystore)
    require_env
    have zip || sudo apt-get install -y zip >/dev/null
    test -f "$KEYBOX" || { echo "keybox not found at $KEYBOX" >&2; exit 1; }
    tsz=$(fetch_one "$TS_NAME" "$TS_URL" "$TS_SHA")

    log "Pixel 5 identity module"
    work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
    idz=$(build_identity_module "$work")
    ksud_install "$idz" redroid_pixel5.zip

    log "TrickyStore"
    ksud_install "$tsz" tricky_store.zip

    log "Stage keybox + targets"
    docker exec "$CONTAINER" mkdir -p /data/adb/tricky_store
    docker cp "$KEYBOX" "$CONTAINER:/data/adb/tricky_store/keybox.xml"
    # target.txt: '!' on gms = TrickyStore generate/leaf-hack mode (rev-eng/docs 5.1)
    printf 'com.android.vending\ncom.google.android.gms!\ngr.nikolasspyr.integritycheck\n' \
      | docker exec -i "$CONTAINER" sh -c 'cat > /data/adb/tricky_store/target.txt'
    printf 'system=202607\nboot=2026-07-05\nvendor=2026-07-05\n' \
      | docker exec -i "$CONTAINER" sh -c 'cat > /data/adb/tricky_store/security_patch.txt'
    docker exec "$CONTAINER" sh -c 'chown 0:0 /data/adb/tricky_store/keybox.xml /data/adb/tricky_store/target.txt /data/adb/tricky_store/security_patch.txt; chmod 600 /data/adb/tricky_store/keybox.xml; chmod 644 /data/adb/tricky_store/target.txt /data/adb/tricky_store/security_patch.txt'
    docker exec "$CONTAINER" sh -c 'echo keybox_sha256:; sha256sum /data/adb/tricky_store/keybox.xml; echo target.txt:; cat /data/adb/tricky_store/target.txt'
    authorize_adb
    echo "STAGED: restart WSL (wsl --shutdown) then run verify-redroid-stack.sh and check props/integrity."
    ;;

  authorize-adb)
    require_env
    authorize_adb
    ;;

  teesimulator)
    echo "BLOCKED on x86_64: TEESimulator-RS v6.0.1-282 ships libcertgen.so for arm64-v8a only" >&2
    echo "(lib/x86_64/ has no libcertgen.so), so its keybox forge path cannot run here." >&2
    echo "Use the 'identity-trickystore' step instead; TrickyStore has x86_64 (lib/x64) support." >&2
    exit 3
    ;;

  *)
    echo "Usage: $0 {fetch|identity-trickystore|authorize-adb|teesimulator}" >&2; exit 2;;
esac
