#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-redroid14}
ready=0
for _ in $(seq 1 90); do
  [[ "$(docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" == 1 ]] && { ready=1; break; }
  sleep 2
done
[[ "$ready" == 1 ]] || { echo 'Boot did not complete; inspect/revert the factory backup' >&2; exit 2; }

docker exec "$CONTAINER" dumpsys package com.google.android.gms |
  grep -E 'codePath=|versionName=|versionCode=|PROVIDE_DEFAULT_ENABLED_CREDENTIAL_SERVICE:|pkgFlags='
docker exec "$CONTAINER" dumpsys account | grep -E '^[[:space:]]*Accounts: [0-9]+[[:space:]]*$'
docker exec "$CONTAINER" logcat -d -v brief -s 'CredentialProviderInfoFactory:E' 'CredManSysService:I' '*:S'

grants=$(docker exec "$CONTAINER" dumpsys package com.google.android.gms |
  grep -c 'PROVIDE_DEFAULT_ENABLED_CREDENTIAL_SERVICE: granted=true' || true)
[[ "$grants" -ge 1 ]] || { echo 'Credential-provider permission is still denied' >&2; exit 2; }
