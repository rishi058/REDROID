#!/usr/bin/env bash
# Start (deploy) the pre-created redroid-experimental Coolify service via the
# local Coolify API, self-bootstrapping a short-lived root token like
# create-coolify-service.sh does. Restores the API-enabled flag to its prior
# value on exit.
set -Eeuo pipefail

UUID=${1:-bk6ojzx98y1dlabu4d63c6d3}
ACTION=${2:-start}
TOKEN_NAME=kilo-redroid-experimental-start

test "$(id -u)" -eq 0 || { echo "Run with sudo." >&2; exit 1; }

API_WAS=$(docker exec coolify php artisan tinker --execute \
  'echo App\Models\InstanceSettings::get()->is_api_enabled ? "enabled" : "disabled";')

cleanup() {
  docker exec coolify php artisan tinker --execute \
    "Laravel\\Sanctum\\PersonalAccessToken::where(\"name\",\"$TOKEN_NAME\")->delete();" \
    >/dev/null 2>&1 || true
  if [ "$API_WAS" = disabled ]; then
    docker exec coolify php artisan tinker --execute \
      'App\Models\InstanceSettings::get()->update(["is_api_enabled"=>false]);' \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ "$API_WAS" = disabled ]; then
  docker exec coolify php artisan tinker --execute \
    'App\Models\InstanceSettings::get()->update(["is_api_enabled"=>true]);' >/dev/null
fi

TOKEN=$(docker exec coolify php artisan tinker --execute \
  '$team=App\Models\Team::findOrFail(0); session(["currentTeam"=>$team]); $user=App\Models\User::findOrFail(0); echo $user->createToken("kilo-redroid-experimental-start",["root"])->plainTextToken;')
test -n "$TOKEN"

echo "=== $ACTION service $UUID ==="
HTTP=$(curl -sS -o /tmp/exp-start.json -w '%{http_code}' \
  -X POST "http://127.0.0.1:8000/api/v1/services/$UUID/$ACTION" \
  -H "Authorization: Bearer $TOKEN")
echo "HTTP=$HTTP"
cat /tmp/exp-start.json 2>/dev/null; echo
test "$HTTP" = 200 -o "$HTTP" = 201
