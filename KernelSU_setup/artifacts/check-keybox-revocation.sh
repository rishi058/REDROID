#!/usr/bin/env bash
# Check a keybox.xml's certificate serials against Google's attestation CRL.
set -u
KB="${1:-/tmp/keybox-clean.xml}"
CRL=/tmp/crl.json
WORK=/tmp/kbcheck
rm -rf "$WORK"; mkdir -p "$WORK"

# Extract each certificate block into its own file
awk '/-----BEGIN CERTIFICATE-----/{n++} n{print > ("'"$WORK"'/cert-" n ".pem")} /-----END CERTIFICATE-----/{}' "$KB"

curl -s https://android.googleapis.com/attestation/status -o "$CRL"
echo "crl_bytes=$(wc -c < "$CRL")"
echo "---"

any_revoked=0
for c in "$WORK"/cert-*.pem; do
  [ -f "$c" ] || continue
  raw=$(openssl x509 -in "$c" -noout -serial 2>/dev/null | sed 's/serial=//')
  subj=$(openssl x509 -in "$c" -noout -subject 2>/dev/null | sed 's/subject=//')
  # normalize: lowercase, strip leading zeros
  s=$(echo "$raw" | tr 'A-F' 'a-f' | sed 's/^0*//')
  if grep -qiE "\"0*${s}\"[[:space:]]*:" "$CRL"; then
    echo "REVOKED  serial=$s  [$subj]"
    any_revoked=1
  else
    echo "ok       serial=$s  [$subj]"
  fi
done
echo "---"
[ "$any_revoked" = 1 ] && echo "RESULT=REVOKED (DEVICE/STRONG will fail)" || echo "RESULT=NOT_IN_CRL (keybox not revoked)"
