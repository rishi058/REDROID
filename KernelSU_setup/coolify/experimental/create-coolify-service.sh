#!/usr/bin/env bash
set -Eeuo pipefail

COMPOSE_FILE=${1:-/home/ubuntu/kbuild/coolify/experimental/docker-compose.yml}
PAYLOAD=$(mktemp)
RESPONSE=$(mktemp)
TOKEN_NAME=kilo-redroid-experimental-bootstrap

cleanup() {
  docker exec coolify php artisan tinker --execute \
    "Laravel\\Sanctum\\PersonalAccessToken::where(\"name\",\"$TOKEN_NAME\")->delete(); App\\Models\\InstanceSettings::get()->update([\"is_api_enabled\"=>false]);" \
    >/dev/null 2>&1 || true
  rm -f "$PAYLOAD" "$RESPONSE"
}
trap cleanup EXIT

test "$(id -u)" -eq 0 || { echo "Run with sudo." >&2; exit 1; }
test -f "$COMPOSE_FILE"
test "$(docker exec coolify php artisan tinker --execute \
  'echo App\Models\InstanceSettings::get()->is_api_enabled ? "enabled" : "disabled";')" = disabled || {
  echo "Refusing to change an API that was already enabled." >&2
  exit 1
}

docker exec coolify php artisan tinker --execute \
  'App\Models\InstanceSettings::get()->update(["is_api_enabled"=>true]);' >/dev/null

TOKEN=$(docker exec coolify php artisan tinker --execute \
  '$team=App\Models\Team::findOrFail(0); session(["currentTeam"=>$team]); $user=App\Models\User::findOrFail(0); echo $user->createToken("kilo-redroid-experimental-bootstrap",["root"],now()->addMinutes(15))->plainTextToken;')
test -n "$TOKEN"

python3 - "$COMPOSE_FILE" >"$PAYLOAD" <<'PY'
import json
import pathlib
import sys
import base64

compose = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
print(json.dumps({
    "name": "redroid-experimental",
    "description": "Isolated experimental ReDroid 14 with private BinderFS devices",
    "project_uuid": "osy1edehk4padit1tsaps28j",
    "environment_uuid": "bu7i0dr5zy6qnrz2537px9bh",
    "server_uuid": "t2o05qhujpab1ikyk0yi5uu3",
    "instant_deploy": True,
    "docker_compose_raw": base64.b64encode(compose.encode("utf-8")).decode("ascii"),
}))
PY

HTTP_CODE=$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
  -X POST http://127.0.0.1:8000/api/v1/services \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary "@$PAYLOAD")

if [ "$HTTP_CODE" != 201 ]; then
  echo "Coolify service creation failed with HTTP $HTTP_CODE:" >&2
  cat "$RESPONSE" >&2
  exit 1
fi

python3 - "$RESPONSE" <<'PY'
import json
import pathlib
import sys

response = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(response["uuid"])
PY
