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
grep -q 'xrandr' "$D" && bad "desktop.html must not touch xrandr" || ok "no xrandr"
if command -v node >/dev/null; then
  t=$(mktemp --suffix=.js); sed -n '/<script>/,/<\/script>/p' "$D" | sed '1d;$d' >"$t"
  node --check "$t" && ok "JS syntax" || bad "JS syntax"; rm -f "$t"
fi
