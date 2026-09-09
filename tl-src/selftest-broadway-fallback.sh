#!/usr/bin/env bash
# Static + HTTP decode checks: WebCodecs path stays, Broadway when VideoDecoder is gone.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
n_pass=0
n_fail=0
pass() { echo "PASS: $*"; n_pass=$((n_pass + 1)); }
bad() { echo "FAIL: $*"; n_fail=$((n_fail + 1)); fail=1; }

DESK="$HERE/desktop.html"
PROBE="$HERE/probe.html"
INST="$HERE/install-tesla-linux.sh"
BAKE="$HERE/build-image.sh"

grep -q 'NO WebCodecs — needs HTTPS' "$DESK" \
  && bad "desktop.html still has HTTPS dead-end" \
  || pass "HTTPS dead-end removed"

grep -q 'broadway fallback' "$DESK" \
  && pass "desktop.html broadway fallback HUD" \
  || bad "desktop.html missing broadway fallback"

grep -q "hasWC?mkDecoder" "$DESK" \
  && pass "desktop.html WebCodecs when VideoDecoder present" \
  || bad "desktop.html missing WebCodecs gate"

grep -q "broadway/Decoder.js" "$DESK" \
  && pass "desktop.html origin-relative broadway scripts" \
  || bad "desktop.html missing broadway script path"

grep -qE 'cdn\.|https://.*broadway|unpkg|jsdelivr' "$DESK" \
  && bad "desktop.html loads broadway from CDN" \
  || pass "desktop.html no CDN broadway"

for f in Decoder.js Player.js YUVCanvas.js avc.wasm LICENSE NOTICE; do
  [ -f "$HERE/broadway/$f" ] && pass "vendored broadway/$f" || bad "missing broadway/$f"
done
python3 -c "p=open('$HERE/broadway/avc.wasm','rb').read(4); assert p==b'\\x00asm'" \
  && pass "avc.wasm is WASM" || bad "avc.wasm magic"

grep -q 'install -d /var/www/tl/broadway' "$INST" \
  && pass "install copies broadway/" || bad "install missing broadway copy"
grep -q 'avc.wasm' "$INST" \
  && pass "install plants avc.wasm" || bad "install missing avc.wasm"
grep -q 'application/wasm' "$INST" \
  && pass "nginx wasm MIME" || bad "nginx missing wasm MIME"
grep -q 'broadway' "$BAKE" \
  && pass "build-image stages broadway" || bad "build-image missing broadway"

grep -q 'desktop Broadway fallback' "$PROBE" \
  && pass "probe.html broadway note" || bad "probe.html missing broadway note"
grep -q "t_wc" "$PROBE" && grep -q "VideoDecoder" "$PROBE" \
  && pass "probe.html still probes WebCodecs" || bad "probe.html WebCodecs probe broken"

if git -C "$HERE/.." diff --quiet -- tl-src/ta_display_backend.py tl-src/ta_touch_backend.py tl-src/ta_audio_backend.py 2>/dev/null; then
  pass "ta_* backends untouched"
else
  bad "ta_* backends were edited"
fi

if [ -x /usr/local/bin/google-chrome ] || [ -x /usr/bin/google-chrome ] || [ -x /usr/bin/chromium ]; then
  python3 "$HERE/selftest-broadway-fallback.py" && pass "HTTP decode (broadway + webcodecs)" \
    || bad "HTTP decode selftest"
else
  echo "SKIP: no chrome for live decode"
fi

echo "--- $n_pass pass / $n_fail fail ---"
exit "$fail"
