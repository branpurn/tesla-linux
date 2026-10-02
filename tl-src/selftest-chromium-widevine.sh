#!/usr/bin/env bash
# Host-side plantable gates: Widevine for EVERY Chromium launch path
# (libwidevinecdm0 from the Pi archive, own apt pin, /etc/chromium.d/tesla-linux-widevine
# hint-file snippet, chromium-drm compatibility shim, no split launcher, probe page).
# (Live proof: see docs/CHROMIUM-WIDEVINE.md.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INST="$HERE/install-chromium-widevine.sh"
MAIN="$HERE/install-tesla-linux.sh"
BUILD="$HERE/build-image.sh"
PROBE="$HERE/chromium/drm-test"
n_pass=0
n_fail=0
fail=0
OUT="$(mktemp -d /tmp/tl-wv-out.XXXXXX)"

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

TREE="$(mktemp -d /tmp/tl-wv-tree.XXXXXX)"
cleanup() { rm -rf "$TREE" "$OUT"; }
trap cleanup EXIT

# --- static gates on the scripts -------------------------------------------
bash -n "$INST" && pass "install-chromium-widevine.sh parses" || bad "install-chromium-widevine.sh syntax"
[ "$("$INST" --print-packages)" = "libwidevinecdm0" ] \
    && pass "installs exactly libwidevinecdm0" || bad "print-packages is not libwidevinecdm0"
grep -q 'Pin: origin archive.raspberrypi.com' "$INST" && grep -q 'Pin-Priority: 990' "$INST" \
    && pass "CDM comes from the (pinned) Pi archive" || bad "install missing Pi-archive pin for the CDM"
if grep -Eq 'apt-get[^|]*install[^|]*(chromium|firefox|linux-image)|sources\.list\.d/[^ ]*armhf|--add-architecture' "$INST"; then
    bad "installer pulls more than the CDM / adds an architecture"
else
    pass "installer pulls only the CDM, no multiarch"
fi
if grep -v -E 'grep|ERROR' "$INST" | grep -Eq -- '--no-sandbox|--disable-gpu-sandbox|--disable-web-security|trusted=yes|--allow-unauthenticated'; then
    bad "installer weakens the sandbox / signatures"
else
    pass "installer does not weaken sandbox or signatures"
fi
grep -q 'TL_SKIP_CHROMIUM_WIDEVINE' "$INST" \
    && pass "installer honours TL_SKIP_CHROMIUM_WIDEVINE" || bad "installer missing TL_SKIP_CHROMIUM_WIDEVINE"
# It must not write the files the HW-video / black-video work owns.
if grep -Eq '(>|tee)[[:space:]]+"?\$r?/?etc/chromium\.d/|(>|tee)[[:space:]]+/etc/chromium\.d/|policies/managed/tesla-linux|raspberrypi-chromium"?[[:space:]]*<<' "$INST"; then
    bad "installer writes /etc/chromium.d, the managed policy or the chromium pin"
else
    pass "installer leaves /etc/chromium.d, policy and the chromium pin alone"
fi
if grep -Eq 'update-alternatives|apt-get[[:space:]]+(remove|purge)' "$INST"; then
    bad "installer touches alternatives / removes packages"
else
    pass "installer does not touch alternatives or remove packages"
fi

# hooks in main install + bake
grep -q 'ensure_chromium_widevine' "$MAIN" \
    && pass "install-tesla-linux.sh runs ensure_chromium_widevine" || bad "install-tesla-linux.sh not hooked"
grep -q -- '--verify-chromium-widevine' "$MAIN" \
    && pass "install-tesla-linux.sh has --verify-chromium-widevine" || bad "missing --verify-chromium-widevine"
grep -q 'TL_SKIP_CHROMIUM_WIDEVINE' "$MAIN" \
    && pass "install-tesla-linux.sh honours TL_SKIP_CHROMIUM_WIDEVINE" || bad "main installer missing skip env"
grep -q 'install-chromium-widevine.sh' "$BUILD" \
    && pass "build-image.sh stages install-chromium-widevine.sh" || bad "build-image.sh does not stage it"
grep -q -- '--verify-chromium-widevine' "$BUILD" \
    && pass "build-image.sh verifies Widevine" || bad "build-image.sh missing --verify-chromium-widevine"
if "$MAIN" --print-packages | grep -qiE 'firefox|google-chrome'; then
    bad "main PKGS has firefox / chrome"
else
    pass "main PKGS has no firefox / google-chrome"
fi

# --- probe page / runner ----------------------------------------------------
[ -f "$PROBE/drm.html" ] && [ -f "$PROBE/probe.py" ] && [ -f "$PROBE/blank.html" ] && [ -f "$PROBE/clear.html" ] \
    && pass "probe files present" || bad "probe files missing"
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PROBE/probe.py" \
        && pass "probe.py parses" || bad "probe.py syntax"
fi
grep -q 'com.widevine.alpha' "$PROBE/drm.html" && grep -q 'axtest.net' "$PROBE/drm.html" \
    && pass "drm.html targets Widevine + the public Axinom test vector" || bad "drm.html is not a Widevine test"

# --- plant tree: verify gates ----------------------------------------------
plant() {
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/etc/apt/preferences.d" "$t/usr/local/bin" "$t/usr/share/applications" \
             "$t/usr/share/tesla-linux/chromium-drm" "$t/etc/chromium.d"
    cat > "$t/etc/apt/preferences.d/raspberrypi-widevine" <<'EOF'
Package: libwidevinecdm0
Pin: origin archive.raspberrypi.com
Pin-Priority: 990
EOF
    # Use the installer's own writers so the plant is the real content.
    bash -c 'set -e; r="$1"; FLAGS_FILE=/etc/chromium.d/tesla-linux-widevine; WRAPPER=/usr/local/bin/chromium-drm
             eval "$(sed -n "/^write_flags() {/,/^}/p;/^write_wrapper() {/,/^}/p" "$2")"
             write_flags "$r"; write_wrapper "$r"' _ "$t" "$INST"
    cp "$PROBE/drm.html" "$t/usr/share/tesla-linux/chromium-drm/drm.html"
    cp "$PROBE/probe.py" "$t/usr/share/tesla-linux/chromium-drm/probe.py"
    chmod +x "$t/usr/share/tesla-linux/chromium-drm/probe.py"
}

plant "$TREE"
expect_ok "verify good tree" "$INST" --verify "$TREE"

rm -f "$TREE/etc/apt/preferences.d/raspberrypi-widevine"
expect_fail "missing pin fails gate" "Widevine apt pin" "$INST" --verify "$TREE"
plant "$TREE"

printf 'Package: libwidevinecdm0 chromium firefox\nPin: origin archive.raspberrypi.com\nPin-Priority: 990\n' \
    > "$TREE/etc/apt/preferences.d/raspberrypi-widevine"
expect_fail "pin naming more than the CDM fails gate" "libwidevinecdm0 only" "$INST" --verify "$TREE"
plant "$TREE"

printf 'Package: libwidevinecdm0\nPin: origin archive.raspberrypi.com\nPin-Priority: 990\nPackage: *\nPin: origin archive.raspberrypi.com\nPin-Priority: 990\n' \
    > "$TREE/etc/apt/preferences.d/raspberrypi-widevine"
expect_fail "wildcard Pi-archive pin fails gate" "more than libwidevinecdm0" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/usr/local/bin/chromium-drm"
expect_fail "missing shim fails gate" "missing or not executable" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/etc/chromium.d/tesla-linux-widevine"
expect_fail "missing /etc/chromium.d snippet fails gate" "bare chromium would have no Widevine" "$INST" --verify "$TREE"
plant "$TREE"

sed -i '/latest-component/d' "$TREE/etc/chromium.d/tesla-linux-widevine"
expect_fail "snippet without the hint file fails gate" "hint file" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's|--user-data-dir=|--udd=|g' "$TREE/etc/chromium.d/tesla-linux-widevine"
expect_fail "snippet ignoring --user-data-dir fails gate" "ignores --user-data-dir" "$INST" --verify "$TREE"
plant "$TREE"

echo 'CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox"' >> "$TREE/etc/chromium.d/tesla-linux-widevine"
expect_fail "snippet with --no-sandbox fails gate" "sandbox" "$INST" --verify "$TREE"
plant "$TREE"

printf '#!/bin/sh\nexec /usr/bin/chromium --user-data-dir=/home/x/.config/chromium-drm "$@"\n' > "$TREE/usr/local/bin/chromium-drm"
expect_fail "shim forcing a separate profile fails gate" "separate profile" "$INST" --verify "$TREE"
plant "$TREE"

printf '#!/bin/sh\necho nope\n' > "$TREE/usr/local/bin/chromium-drm"
expect_fail "shim not exec'ing /usr/bin/chromium fails gate" "does not exec" "$INST" --verify "$TREE"
plant "$TREE"

touch "$TREE/usr/share/applications/tesla-linux-chromium-drm.desktop"
expect_fail "leftover split DRM launcher fails gate" "split launcher" "$INST" --verify "$TREE"
plant "$TREE"

touch "$TREE/usr/share/applications/tesla-linux-chromium.desktop"
expect_fail "leftover split HW-video launcher fails gate" "split launcher" "$INST" --verify "$TREE"
plant "$TREE"

# --- behaviour of the /etc/chromium.d snippet (what every launch path runs) --
SNIP="$TREE/etc/chromium.d/tesla-linux-widevine"
SB="$OUT/snip"; rm -rf "$SB"; mkdir -p "$SB/cdm" "$SB/h" "$SB/old/WidevineCdm/9.9" "$SB/dangling"
echo '{"version":"4.10.2662.3"}' > "$SB/cdm/manifest.json"
echo '{"version":"4.10.9999.0"}' > "$SB/old/WidevineCdm/9.9/manifest.json"
sed "s|/opt/WidevineCdm|$SB/cdm|g" "$SNIP" > "$SB/snip.sh"
run_snip() { env -i HOME="$SB/h" XDG_CONFIG_HOME="$SB/h/.config" sh -c '. "$1"; shift' _ "$SB/snip.sh" "$@" ; }
hint() { cat "$1/WidevineCdm/latest-component-updated-widevine-cdm" 2>/dev/null || true; }
run_snip
[ "$(hint "$SB/h/.config/chromium")" = "{\"Path\":\"$SB/cdm\"}" ] \
    && pass "snippet: bare launch writes the hint into the default profile" || bad "snippet: default profile hint ($(hint "$SB/h/.config/chromium"))"
run_snip --user-data-dir="$SB/p1" about:blank
[ "$(hint "$SB/p1")" = "{\"Path\":\"$SB/cdm\"}" ] \
    && pass "snippet: --user-data-dir profile gets the hint" || bad "snippet: --user-data-dir hint"
mkdir -p "$SB/p2/WidevineCdm"; printf '{"Path":"%s"}\n' "$SB/old/WidevineCdm/9.9" > "$SB/p2/WidevineCdm/latest-component-updated-widevine-cdm"
run_snip --user-data-dir="$SB/p2"
[ "$(hint "$SB/p2")" = "{\"Path\":\"$SB/old/WidevineCdm/9.9\"}" ] \
    && pass "snippet: a working component-updated CDM is not clobbered" || bad "snippet: clobbered updated CDM"
mkdir -p "$SB/p3/WidevineCdm"; printf '{"Path":"%s/gone"}\n' "$SB" > "$SB/p3/WidevineCdm/latest-component-updated-widevine-cdm"
run_snip --user-data-dir="$SB/p3"
[ "$(hint "$SB/p3")" = "{\"Path\":\"$SB/cdm\"}" ] \
    && pass "snippet: dangling hint is repaired" || bad "snippet: dangling hint kept"
rm -rf "$SB/cdm"; run_snip --user-data-dir="$SB/p4"
[ ! -e "$SB/p4" ] && pass "snippet: no CDM installed -> touches nothing" || bad "snippet: wrote a hint without a CDM"

rm -f "$TREE/usr/share/tesla-linux/chromium-drm/probe.py"
expect_fail "missing probe fails gate" "probe not installed" "$INST" --verify "$TREE"
plant "$TREE"

# skip env: installer is a no-op (must not need root / apt)
TL_SKIP_CHROMIUM_WIDEVINE=1 "$INST" >"$OUT/skip.out" 2>&1 \
    && grep -q skipping "$OUT/skip.out" && pass "TL_SKIP_CHROMIUM_WIDEVINE=1 is a no-op" \
    || bad "TL_SKIP_CHROMIUM_WIDEVINE=1 did not skip ($(cat "$OUT/skip.out"))"
TL_SKIP_CHROMIUM=1 "$INST" >"$OUT/skip2.out" 2>&1 \
    && grep -q skipping "$OUT/skip2.out" && pass "TL_SKIP_CHROMIUM=1 also skips Widevine" \
    || bad "TL_SKIP_CHROMIUM=1 did not skip Widevine"
TL_SKIP_CHROMIUM_WIDEVINE=1 bash "$MAIN" --verify-chromium-widevine "$TREE/nonexistent" >/dev/null 2>&1 \
    && pass "main --verify-chromium-widevine honours the skip env" || bad "main verify ignores skip env"

# --- live checks (only on a Pi that has it installed) -----------------------
if [ -f /opt/WidevineCdm/manifest.json ] && [ -x /usr/local/bin/chromium-drm ]; then
    expect_ok "live: --verify" "$INST" --verify
    ver="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' /opt/WidevineCdm/manifest.json)"
    [ -n "$ver" ] && pass "live: Widevine CDM $ver on disk" || bad "live: no CDM version"
    if [ -n "${DISPLAY:-}" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import websockets' 2>/dev/null; then
        prof="$(mktemp -d /tmp/tl-wv-prof.XXXXXX)"
        if timeout 90 python3 "$PROBE/probe.py" --exe /usr/bin/chromium \
              --profile "$prof" --eme-only --json "$OUT/eme.json" >/dev/null 2>&1 \
           && python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["eme"]; sys.exit(0 if e["SW_SECURE_CRYPTO"]=="ok" and e["default"]=="ok" else 1)' "$OUT/eme.json"; then
            pass "live: navigator.requestMediaKeySystemAccess('com.widevine.alpha') ok"
        else
            bad "live: Widevine EME probe failed"
        fi
        rm -rf "$prof"
    else
        echo "SKIP: live EME probe (no DISPLAY / websockets)"
    fi
fi

echo "---"
echo "passed=$n_pass failed=$n_fail"
exit "$fail"
