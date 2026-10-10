#!/system/bin/sh
ALIAS="${1:-vp_test_0}"
CHALLENGE="${2:-test_challenge}"
UID_APP="${3:-10113}"
OUT="/data/data/com.diskwalaapp/files/attestgen/${ALIAS}.txt"

/system/xbin/su "$UID_APP" /system/bin/sh -c ". /data/local/tmp/andenv.sh; export CLASSPATH=/data/local/tmp/attestgen.jar; exec app_process /system/bin com.recon.attestgen.AttestGen $ALIAS $CHALLENGE $OUT"
echo "RC=$?"
sleep 1
echo "=== output file ($OUT) ==="
/system/xbin/su "$UID_APP" cat "$OUT" 2>&1 | head -80
