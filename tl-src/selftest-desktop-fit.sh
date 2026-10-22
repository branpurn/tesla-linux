#!/usr/bin/env bash
# desktop.html Stretch/Fixed toggle selftest (static wiring + JS syntax when node exists).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)/desktop.html"
ok(){ echo "PASS $*"; } ; bad(){ echo "FAIL $*"; exit 1; }
grep -q 'id="fit"' "$D" && ok "fit button in #bar" || bad "fit button missing"
grep -q "tl.desktop.fit" "$D" && ok "localStorage key" || bad "no persistence"
grep -q 'body.fit-stretch #stage canvas{width:100vw!important;height:100vh!important' "$D" && ok "stretch CSS" || bad "stretch CSS"
grep -q 'fullscreenchange' "$D" && ok "relayout on fullscreenchange" || bad "no fullscreenchange"
grep -q "const x=(p.clientX-r.left)/r.width, y=(p.clientY-r.top)/r.height;" "$D" && ok "independent x/y touch mapping" || bad "touch mapping"
grep -q 'xrandr' "$D" && bad "desktop.html must not touch xrandr" || ok "no xrandr (server-side only)"
if command -v node >/dev/null; then
  t=$(mktemp --suffix=.js); sed -n '/<script>/,/<\/script>/p' "$D" | sed '1d;$d' >"$t"
  node --check "$t" && ok "JS syntax" || bad "JS syntax"; rm -f "$t"
fi
# Fit: Adaptive (third mode) + /api/screen wiring
grep -q "FIT_MODES=\['fixed','stretch','adaptive'\]" "$D" && ok "three fit modes" || bad "adaptive mode missing"
grep -q "fetch('/api/screen'" "$D" && ok "adaptive posts /api/screen" || bad "no /api/screen call"
grep -q "postScreen({reset:true})" "$D" && ok "leaving adaptive restores default" || bad "no reset"
grep -q "devicePixelRatio" "$D" && ok "dpr-scaled size" || bad "no dpr"
grep -q "setTimeout(connectVideo" "$D" && ok "video reconnect on encoder restart" || bad "no video reconnect"
"$(dirname "$D")/selftest-screen-api.sh"
