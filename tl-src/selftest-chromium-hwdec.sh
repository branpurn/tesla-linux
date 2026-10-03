#!/usr/bin/env bash
# Host-side plantable gates: Chromium (Pi archive build, V4L2 HW H.264 decode),
# apt pin so only chromium comes from archive.raspberrypi.com, managed
# policy/flags, h264-only extension, Chromium as the default/only browser.
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
if grep -Eq 'snap[[:space:]]+(remove|install)' "$INST"; then
    bad "install uses snap"
else
    pass "install does not use snap"
fi
grep -q 'set_default_browser ""' "$INST" \
    && pass "install makes chromium the default browser" || bad "install does not set the default browser"

# hooks in main install + bake
grep -q 'ensure_chromium_hwdec' "$MAIN" \
    && pass "install-tesla-linux.sh runs ensure_chromium_hwdec" || bad "install-tesla-linux.sh not hooked"
if "$MAIN" --print-packages | grep -qiE 'firefox|google-chrome'; then
    bad "main PKGS still has firefox / chrome"
else
    pass "main PKGS has no firefox / google-chrome (chromium is the only browser)"
fi
# Exclusion/verification of other browsers (apt pin + --verify-xubuntu: comments,
# `Package:` pin lines, lines that also name thunderbird, snap-file probes) is not a reference.
if cat "$MAIN" "$BUILD" | grep -vE '^[[:space:]]*#|^Package:|thunderbird|snaps/firefox_' \
    | grep -qiE 'firefox|mozilla|google-chrome|chrome-stable'; then
    bad "install/build scripts still reference firefox / google-chrome"
else
    pass "install/build scripts have no firefox / google-chrome references"
fi
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
PY
    python3 - "$EXT" <<'PY' && pass "extension YouTube-mobile DNR rules: scoped redirect + UA, version bumped" || bad "extension YouTube-mobile DNR rules invalid"
import json, os, re, sys
d = sys.argv[1]
m = json.load(open(os.path.join(d, "manifest.json")))
ver = tuple(int(x) for x in m["version"].split("."))
assert ver >= (1, 1), "manifest version must be >= 1.1 (DNR rules shipped)"
assert m["permissions"] == ["declarativeNetRequest"], m["permissions"]
# host permissions: YouTube + its media/image CDNs only - never Prime/Amazon or <all_urls>
hp = m["host_permissions"]
assert hp and all(re.search(r"(youtube\.com|googlevideo\.com|ytimg\.com)/\*$", h) for h in hp), hp
assert not any("amazon" in h or "<all_urls>" in h or h.startswith("*://*/") for h in hp), hp
rr = m["declarative_net_request"]["rule_resources"]
assert len(rr) == 1 and rr[0]["enabled"] is True
rules = json.load(open(os.path.join(d, rr[0]["path"])))
ids = [r["id"] for r in rules]
assert len(ids) == len(set(ids)), "duplicate rule ids"
red = [r for r in rules if r["action"]["type"] == "redirect"]
allow = [r for r in rules if r["action"]["type"] == "allow"]
hdr = [r for r in rules if r["action"]["type"] == "modifyHeaders"]
assert len(red) == 1 and len(hdr) == 1 and len(allow) >= 3
# (1) redirect: youtube.com main frame -> m.youtube.com, path+query kept, desktop-only hosts
r = red[0]
assert r["condition"]["resourceTypes"] == ["main_frame"]
assert r["action"]["redirect"]["regexSubstitution"] == "https://m.youtube.com/\\1"
rx = re.compile(r["condition"]["regexFilter"])
for u in ("https://www.youtube.com/watch?v=abc", "https://youtube.com/", "http://www.youtube.com/@x"):
    assert rx.match(u), u
for u in ("https://music.youtube.com/", "https://m.youtube.com/watch", "https://studio.youtube.com/",
          "https://accounts.youtube.com/x", "https://www.amazon.com/youtube.com/x", "https://notyoutube.com/"):
    assert not rx.match(u), u
# allow rules (one urlFilter per path prefix; a single big regex exceeds Chrome's RE2
# memory limit and is silently dropped) must outrank both the redirect and the header rule
paths = set()
for a in allow:
    assert a["priority"] > r["priority"] and a["priority"] > hdr[0]["priority"], "allow must have the highest priority"
    assert a["condition"]["resourceTypes"] == ["main_frame"]
    mt = re.fullmatch(r"\|\|youtube\.com/([a-z0-9_]+)\^", a["condition"]["urlFilter"])
    assert mt, a["condition"]
    paths.add(mt.group(1))
for need in ("embed", "api", "youtubei", "oauth", "accounts", "signin"):
    assert need in paths, need
for bad in ("watch", "results", "shorts", "feed", "playlist", "channel"):
    assert bad not in paths, bad
# (2) UA header: only YouTube/googlevideo/ytimg request domains, never Amazon/Prime or generic
h = hdr[0]
dom = h["condition"]["requestDomains"]
assert sorted(dom) == ["googlevideo.com", "youtube.com", "ytimg.com"], dom
assert "regexFilter" not in h["condition"] and "urlFilter" not in h["condition"]
assert not any("amazon" in x or "primevideo" in x for x in dom)
ex = h["condition"]["excludedRequestDomains"]
for need in ("music.youtube.com", "studio.youtube.com", "accounts.youtube.com"):
    assert need in ex, need
ops = {x["header"].lower(): x for x in h["action"]["requestHeaders"]}
assert ops["user-agent"]["operation"] == "set" and "Android" in ops["user-agent"]["value"] and "Mobile" in ops["user-agent"]["value"]
assert ops["sec-ch-ua-mobile"]["value"] == "?1"
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
    cp "$EXT/manifest.json" "$EXT/h264only.js" "$EXT/youtube-mobile-rules.json" "$t/usr/share/chromium/extensions/tl-h264-only/"
    mkdir -p "$t/usr/share/chromium/extensions/tl-h264-only/_metadata"
    mkdir -p "$t/usr/local/share/applications"
    bash -c 'set -e; r="$1"; TL_USER=nobody; DESKTOP_ID=chromium.desktop; DESKTOP_DIR=/usr/local/share/applications
             OLD_DESKTOP_IDS="tesla-linux-chromium.desktop tesla-linux-chromium-drm.desktop"
             eval "$(sed -n "/^write_desktop() {/,/^}/p" "$2")"
             write_desktop "$r"' _ "$t" "$INST"
    mkdir -p "$t/etc/xdg/xfce4"
    printf '[Default Applications]\nx-scheme-handler/https=chromium.desktop\n' > "$t/etc/xdg/mimeapps.list"
    printf 'WebBrowser=chromium\n' > "$t/etc/xdg/xfce4/helpers.rc"
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

rm -f "$TREE/usr/share/chromium/extensions/tl-h264-only/youtube-mobile-rules.json"
expect_fail "missing YouTube mobile rules fail gate" "YouTube mobile rules missing" "$INST" --verify "$TREE"
plant "$TREE"

rmdir "$TREE/usr/share/chromium/extensions/tl-h264-only/_metadata"
expect_fail "missing extension _metadata dir (DNR index) fails gate" "_metadata dir missing" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/usr/local/share/applications/chromium.desktop"
expect_fail "missing desktop entry fails gate" "desktop entry missing" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's|^Name=Chromium$|Name=Chromium (HW video)|' "$TREE/usr/local/share/applications/chromium.desktop"
expect_fail "launcher renamed away from the single 'Chromium' fails gate" "single" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's|^Exec=/usr/bin/chromium %U|Exec=/usr/bin/chromium --user-data-dir=/tmp/x %U|' "$TREE/usr/local/share/applications/chromium.desktop"
expect_fail "launcher with a custom Exec fails gate" "not plain /usr/bin/chromium" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's|^Exec=/usr/bin/chromium %U|Exec=/usr/local/bin/chromium-drm %U|' "$TREE/usr/local/share/applications/chromium.desktop"
expect_fail "launcher via a wrapper fails gate" "not plain /usr/bin/chromium" "$INST" --verify "$TREE"
plant "$TREE"

touch "$TREE/usr/share/applications/tesla-linux-chromium-drm.desktop"
expect_fail "leftover 'Chromium (DRM)' launcher fails gate" "split launcher" "$INST" --verify "$TREE"
plant "$TREE"

touch "$TREE/usr/share/applications/tesla-linux-chromium.desktop"
expect_fail "leftover 'Chromium (HW video)' launcher fails gate" "split launcher" "$INST" --verify "$TREE"
plant "$TREE"

# Desktop icon + old-launcher cleanup on a root with a user home
mkdir -p "$TREE/home/teslalinux/Desktop" "$TREE/usr/share/applications"
touch "$TREE/home/teslalinux/Desktop/Chromium-DRM.desktop" "$TREE/home/teslalinux/Desktop/Chromium-HW-video.desktop" \
      "$TREE/usr/share/applications/tesla-linux-chromium-drm.desktop"
bash -c 'set -e; r="$1"; TL_USER=teslalinux; DESKTOP_ID=chromium.desktop; DESKTOP_DIR=/usr/local/share/applications
         OLD_DESKTOP_IDS="tesla-linux-chromium.desktop tesla-linux-chromium-drm.desktop"
         eval "$(sed -n "/^write_desktop() {/,/^}/p" "$2")"
         write_desktop "$r"' _ "$TREE" "$INST"
if [ -x "$TREE/home/teslalinux/Desktop/Chromium.desktop" ] \
   && [ ! -e "$TREE/home/teslalinux/Desktop/Chromium-DRM.desktop" ] \
   && [ ! -e "$TREE/home/teslalinux/Desktop/Chromium-HW-video.desktop" ] \
   && [ ! -e "$TREE/usr/share/applications/tesla-linux-chromium-drm.desktop" ]; then
    pass "installer collapses the split launchers into one Desktop 'Chromium' icon"
else
    bad "split launchers not collapsed"
fi
plant "$TREE"

rm -f "$TREE/etc/xdg/mimeapps.list"
expect_fail "missing https mime default fails gate" "https default is not chromium" "$INST" --verify "$TREE"
plant "$TREE"

printf 'WebBrowser=firefox\n' > "$TREE/etc/xdg/xfce4/helpers.rc"
expect_fail "XFCE preferred browser != chromium fails gate" "WebBrowser is not chromium" "$INST" --verify "$TREE"
plant "$TREE"

# set_default_browser on a plant root writes the defaults (no live alternatives)
H="$TREE/home/teslalinux/.config"
mkdir -p "$H"
printf '[Default Applications]\nx-scheme-handler/https=userapp-Firefox-X.desktop\ntext/html=userapp-Firefox-X.desktop\n' > "$H/mimeapps.list"
sed -n '/^set_default_browser() {/,/^}/p' "$INST" > "$TREE/sdb.sh"
if bash -c 'set -e; TL_USER=teslalinux; . "$1"; set_default_browser "$2"' _ "$TREE/sdb.sh" "$TREE"; then
    pass "set_default_browser runs on a plant root"
else
    bad "set_default_browser failed on plant root"
fi
if grep -q '^x-scheme-handler/https=chromium.desktop$' "$H/mimeapps.list" && ! grep -qi firefox "$H/mimeapps.list"; then
    pass "user mimeapps: stale Firefox association replaced by chromium"
else
    bad "user mimeapps not rewritten"
fi
grep -q '^WebBrowser=chromium$' "$H/xfce4/helpers.rc" \
    && pass "user XFCE helpers.rc WebBrowser=chromium" || bad "user helpers.rc not written"

echo
echo "selftest-chromium-hwdec: $n_pass passed, $n_fail failed"
exit "$fail"
