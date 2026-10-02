#!/usr/bin/env bash
# Host-side plantable gates: Chromium (Pi archive build, V4L2 HW H.264 decode),
# apt pin so only chromium comes from archive.raspberrypi.com, managed
# policy/flags, h264-only extension. Firefox must be untouched.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INST="$HERE/install-chromium-hwdec.sh"
MAIN="$HERE/install-tesla-linux.sh"
BUILD="$HERE/build-image.sh"
EXT="$HERE/chromium/h264-only"
fail=0
n_pass=0
n_fail=0
OUT="$(mktemp -d /tmp/tl-cr-out.XXXXXX)"

pass() { echo "PASS: $*"; n_pass=$((n_pass + 1)); }
bad() { echo "FAIL: $*"; n_fail=$((n_fail + 1)); fail=1; }

expect_ok() {
    local name="$1"
    shift
    if "$@" >"$OUT/ok.out" 2>"$OUT/ok.err"; then
        pass "$name"
    else
        bad "$name (exit $?) stderr=$(tr '\n' ' ' <"$OUT/ok.err")"
    fi
}

expect_fail() {
    local name="$1" needle="$2"
    shift 2
    if "$@" >"$OUT/bad.out" 2>"$OUT/bad.err"; then
        bad "$name (expected fail, passed)"
    elif grep -q "$needle" "$OUT/bad.err"; then
        pass "$name"
    else
        bad "$name (wrong error: $(tr '\n' ' ' <"$OUT/bad.err"))"
    fi
}

TREE="$(mktemp -d /tmp/tl-cr-tree.XXXXXX)"
cleanup() { rm -rf "$TREE" "$OUT"; }
trap cleanup EXIT

# --- static gates on the scripts -------------------------------------------
bash -n "$INST" && pass "install-chromium-hwdec.sh parses" || bad "install-chromium-hwdec.sh syntax"
"$INST" --print-packages | grep -qw chromium \
    && pass "print-packages includes chromium" || bad "print-packages missing chromium"
if "$INST" --print-packages | grep -q 'rpi-chromium-mods'; then
    bad "rpi-chromium-mods must not be installed (forces accessibility + remote ext)"
else
    pass "rpi-chromium-mods not installed"
fi
grep -q 'archive.raspberrypi.com' "$INST" \
    && pass "install uses the Raspberry Pi archive" || bad "install missing archive.raspberrypi.com"
grep -q 'signed-by=\$RPI_KEYRING' "$INST" \
    && pass "apt source is signed-by a keyring" || bad "apt source not signed-by"
grep -q 'CF8A1AF502A2AA2D763BAE7E82B129927FA3303E' "$INST" \
    && pass "install pins the Pi key fingerprint" || bad "install missing key fingerprint"
grep -q 'Pin-Priority: -10' "$INST" \
    && pass "install pins the Pi archive out by default" || bad "install missing -10 pin"
grep -q 'JPEG62_SHA256=[0-9a-f]\{64\}' "$INST" \
    && pass "libjpeg62-turbo deb is sha256-pinned" || bad "libjpeg62-turbo sha256 missing"
grep -q 'NEEDRESTART_SUSPEND=1' "$INST" \
    && pass "install suspends needrestart (no service restarts)" || bad "needrestart not suspended"
if grep -Eq 'dpkg[[:space:]]+(-i|--install)[^|]*--force|--force-depends|apt-get[^|]*--allow-unauthenticated|trusted=yes' "$INST"; then
    bad "install bypasses dependency / signature checks"
else
    pass "install does not force deps or skip signatures"
fi
if grep -Eq 'apt-get[[:space:]]+(remove|purge)[^|]*firefox|snap[[:space:]]+(remove|install)' "$INST"; then
    bad "install touches Firefox / snap"
else
    pass "install does not touch Firefox / snap"
fi

# hooks in main install + bake
grep -q 'ensure_chromium_hwdec' "$MAIN" \
    && pass "install-tesla-linux.sh runs ensure_chromium_hwdec" || bad "install-tesla-linux.sh not hooked"
"$MAIN" --print-packages | grep -q firefox \
    && pass "main PKGS still has firefox" || bad "main PKGS lost firefox"
grep -q -- '--verify-chromium' "$MAIN" \
    && pass "install-tesla-linux.sh has --verify-chromium" || bad "missing --verify-chromium"
grep -q 'install-chromium-hwdec.sh' "$BUILD" \
    && pass "build-image.sh stages install-chromium-hwdec.sh" || bad "build-image.sh does not stage it"
grep -q -- '--verify-chromium' "$BUILD" \
    && pass "build-image.sh verifies chromium" || bad "build-image.sh missing --verify-chromium"
grep -q 'chromium' "$BUILD" && grep -q 'SRC/chromium' "$BUILD" \
    && pass "build-image.sh stages the extension dir" || bad "build-image.sh does not stage chromium/"

# --- extension --------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    python3 - "$EXT/manifest.json" <<'PY' && pass "extension manifest: MV3, MAIN world, document_start" || bad "extension manifest invalid"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["manifest_version"] == 3
cs = m["content_scripts"][0]
assert cs["world"] == "MAIN" and cs["run_at"] == "document_start" and cs["all_frames"] is True
assert "permissions" not in m and "host_permissions" not in m
PY
fi
if command -v node >/dev/null 2>&1; then
    cat > "$OUT/ext.js" <<'EOF'
const fs = require('fs');
let ok = true;
const t = (c, m) => { if (!c) { ok = false; console.error('assert: ' + m); } };
global.window = global;
global.MediaSource = { isTypeSupported: (x) => true };
global.HTMLMediaElement = function () {};
HTMLMediaElement.prototype.canPlayType = function () { return 'probably'; };
global.navigator = { mediaCapabilities: { decodingInfo: async (c) => ({ supported: true, smooth: true, powerEfficient: false }) } };
eval(fs.readFileSync(process.argv[2], 'utf8'));
(async () => {
  t(MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028"') === true, 'avc1 stays supported');
  t(MediaSource.isTypeSupported('video/webm; codecs="vp9"') === false, 'vp9 blocked');
  t(MediaSource.isTypeSupported('video/webm; codecs="vp09.00.40.08"') === false, 'vp09 blocked');
  t(MediaSource.isTypeSupported('video/mp4; codecs="av01.0.08M.08"') === false, 'av01 blocked');
  t(MediaSource.isTypeSupported('audio/webm; codecs="opus"') === true, 'opus audio stays');
  const el = new HTMLMediaElement();
  t(el.canPlayType('video/webm; codecs="vp9"') === '', 'canPlayType vp9 empty');
  t(el.canPlayType('video/mp4; codecs="avc1.4d401f"') === 'probably', 'canPlayType avc1 ok');
  const d = await navigator.mediaCapabilities.decodingInfo({ type: 'media-source', video: { contentType: 'video/webm; codecs="vp09.00.40.08"' } });
  t(d.supported === false && d.powerEfficient === false, 'decodingInfo vp9 unsupported');
  const e = await navigator.mediaCapabilities.decodingInfo({ type: 'media-source', video: { contentType: 'video/mp4; codecs="avc1.640028"' } });
  t(e.supported === true, 'decodingInfo avc1 passes through');
  process.exit(ok ? 0 : 1);
})();
EOF
    expect_ok "extension hides VP9/AV1, keeps H.264 (node mock)" node "$OUT/ext.js" "$EXT/h264only.js"
fi

# --- plant tree: verify gates ----------------------------------------------
plant() {
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/etc/apt/sources.list.d" "$t/etc/apt/preferences.d" "$t/etc/apt/keyrings" \
             "$t/etc/chromium/policies/managed" "$t/etc/chromium.d" \
             "$t/usr/bin" "$t/usr/share/applications" \
             "$t/usr/share/chromium/extensions/tl-h264-only"
    cat > "$t/etc/apt/sources.list.d/raspberrypi-chromium.list" <<'EOF'
deb [signed-by=/etc/apt/keyrings/raspberrypi-archive.asc arch=arm64] https://archive.raspberrypi.com/debian trixie main
EOF
    cat > "$t/etc/apt/preferences.d/raspberrypi-chromium" <<'EOF'
Package: *
Pin: origin archive.raspberrypi.com
Pin-Priority: -10

Package: chromium chromium-common chromium-sandbox chromium-l10n zenoty
Pin: origin archive.raspberrypi.com
Pin-Priority: 990
EOF
    printf '#!/bin/sh\necho Chromium\n' > "$t/usr/bin/chromium"
    chmod +x "$t/usr/bin/chromium"
    cat > "$t/etc/chromium/policies/managed/tesla-linux.json" <<'EOF'
{ "HardwareAccelerationModeEnabled": true }
EOF
    echo 'export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ozone-platform=x11"' > "$t/etc/chromium.d/tesla-linux"
    cp "$EXT/manifest.json" "$EXT/h264only.js" "$t/usr/share/chromium/extensions/tl-h264-only/"
    cat > "$t/usr/share/applications/tesla-linux-chromium.desktop" <<'EOF'
[Desktop Entry]
Name=Chromium (HW video)
Exec=/usr/bin/chromium %U
Type=Application
Categories=Network;WebBrowser;
EOF
}

plant "$TREE"
expect_ok "verify good tree" "$INST" --verify "$TREE"

rm -f "$TREE/etc/apt/sources.list.d/raspberrypi-chromium.list"
expect_fail "missing apt source fails gate" "chromium apt source" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's/signed-by=[^ ]*/trusted=yes/' "$TREE/etc/apt/sources.list.d/raspberrypi-chromium.list"
expect_fail "unsigned apt source fails gate" "signed-by" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's/^Pin-Priority: -10$/Pin-Priority: 500/' "$TREE/etc/apt/preferences.d/raspberrypi-chromium"
expect_fail "Pi archive not pinned out fails gate" "pinned out" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's/^Package: chromium .*/Package: chromium firefox linux-image-raspi/' "$TREE/etc/apt/preferences.d/raspberrypi-chromium"
expect_fail "pin allow-listing firefox/kernel fails gate" "more than chromium" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/usr/bin/chromium"
expect_fail "missing chromium binary fails gate" "chromium binary missing" "$INST" --verify "$TREE"
plant "$TREE"

printf '#!/bin/sh\nexec snap run chromium "$@"\n' > "$TREE/usr/bin/chromium"
expect_fail "snap stub fails gate" "snap stub" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/etc/chromium/policies/managed/tesla-linux.json"
expect_fail "missing policy fails gate" "managed policy missing" "$INST" --verify "$TREE"
plant "$TREE"

echo '{ "HardwareAccelerationModeEnabled": false }' > "$TREE/etc/chromium/policies/managed/tesla-linux.json"
expect_fail "policy disabling HW accel fails gate" "hardware acceleration" "$INST" --verify "$TREE"
plant "$TREE"

echo 'export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --disable-accelerated-video-decode"' > "$TREE/etc/chromium.d/tesla-linux"
expect_fail "flags disabling HW decode fail gate" "disables HW decode" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/usr/share/chromium/extensions/tl-h264-only/h264only.js"
expect_fail "missing h264-only extension fails gate" "extension script missing" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/usr/share/applications/tesla-linux-chromium.desktop"
expect_fail "missing desktop entry fails gate" "desktop entry missing" "$INST" --verify "$TREE"
plant "$TREE"

# Firefox gate must be independent and still pass-able alongside chromium
if [ -x "$HERE/selftest-firefox.sh" ]; then
    expect_ok "selftest-firefox still passes" "$HERE/selftest-firefox.sh"
fi

echo
echo "selftest-chromium-hwdec: $n_pass passed, $n_fail failed"
exit "$fail"
