#!/usr/bin/env bash
# ta_screen_api.py dry-run selftest: clamp/8-align, state file, rate limit, reset, guard parses state.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
ok(){ echo "PASS $*"; } ; bad(){ echo "FAIL $*"; exit 1; }
T=$(mktemp -d); P=$((20000 + RANDOM % 20000))
TA_SCREEN_DRY=1 TA_SCREEN_STATE_DIR="$T" TA_SCREEN_PORT=$P TA_SCREEN_MIN_S=2 python3 "$H/ta_screen_api.py" & PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
for i in $(seq 1 30); do curl -sf "http://127.0.0.1:$P/api/screen" >/dev/null && break; sleep 0.1; done
post(){ curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$P/api/screen"; }
[ "$(post '{"w":1283,"h":701}')" = 200 ] && [ "$(cat "$T/screen-size")" = 1280x704 ] && ok "8-aligned 1280x704" || bad "align"
[ "$(post '{"w":800,"h":600}')" = 429 ] && ok "rate limited" || bad "no rate limit"
sleep 2.1
[ "$(post '{"w":99999,"h":10}')" = 200 ] && [ "$(cat "$T/screen-size")" = 1920x480 ] && ok "clamped" || bad "clamp"
[ "$(post 'junk')" = 400 ] && ok "bad body 400" || bad "400"
sleep 2.1
[ "$(post '{"reset":true}')" = 200 ] && [ "$(cat "$T/screen-size")" = 1088x832 ] && ok "reset 1088x832" || bad "reset"
grep -q 'STATE=/run/tesla-linux/screen-size' "$H/tl-screen-guard.sh" && ok "guard reads state" || bad "guard state"
grep -q 'flock' "$H/tl-screen-guard.sh" && ok "guard shares lock" || bad "guard lock"
grep -q '/run/tesla-linux/screen-size' "$H/ta_display_backend.py" && ok "encoder follows state" || bad "encoder"
sh -n "$H/tl-screen-guard.sh" && ok "guard sh syntax"
grep -q 'location /api/screen' "$H/install-tesla-linux.sh" && ok "nginx /api/screen (inherits auth_request)" || bad "nginx loc"
