#!/usr/bin/env bash
set -Eeuo pipefail

ARTIFACT_DIR=/home/ubuntu/kbuild/artifacts
PACKAGE_DIR="$ARTIFACT_DIR/packages"
EXPECTED_RELEASE=6.8.12-zksu

cd "$PACKAGE_DIR"
sha256sum -c SHA256SUMS

mapfile -t image_packages < <(find . -maxdepth 1 -type f -name "linux-image-${EXPECTED_RELEASE}_*.deb" -printf '%p\n' | sort)
mapfile -t header_packages < <(find . -maxdepth 1 -type f -name "linux-headers-${EXPECTED_RELEASE}_*.deb" -printf '%p\n' | sort)

test "${#image_packages[@]}" -eq 1
test "${#header_packages[@]}" -eq 1

for package in "${image_packages[@]}" "${header_packages[@]}"; do
  test "$(dpkg-deb -f "$package" Architecture)" = arm64
  dpkg-deb --info "$package"
done

boot_available_kib=$(df --output=avail /boot | tail -n 1 | tr -d ' ')
if (( boot_available_kib < 300 * 1024 )); then
  echo "At least 300 MiB free in /boot is required; available KiB: $boot_available_kib" >&2
  exit 50
fi

cp -a /etc/default/grub "$ARTIFACT_DIR/config/grub.before-install"
sudo grub-editenv list > "$ARTIFACT_DIR/config/grubenv.before-install" 2>/dev/null || true

sudo dpkg -i "${header_packages[@]}" "${image_packages[@]}"
sudo update-initramfs -u -k "$EXPECTED_RELEASE"
sudo update-grub

test -s "/boot/vmlinuz-$EXPECTED_RELEASE"
test -s "/boot/initrd.img-$EXPECTED_RELEASE"
test -d "/lib/modules/$EXPECTED_RELEASE"

sudo awk '/^submenu |^[[:space:]]*menuentry / { print }' /boot/grub/grub.cfg \
  | tee "$ARTIFACT_DIR/config/grub-menu.after-install"
dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' \
  "linux-image-$EXPECTED_RELEASE" "linux-headers-$EXPECTED_RELEASE"
df -hT / /boot /boot/efi

echo "Installation verified. No GRUB default was changed and no reboot was initiated."
