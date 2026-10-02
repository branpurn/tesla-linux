#!/usr/bin/env bash
# Host-side plantable gates: Google Chrome (ARM64) from Google's apt repo
# (signed-by keyring, pinned to google-chrome-stable only), flags/policy/wrapper/
# launcher, Firefox still x-www-browser, existing Chromium files untouched.
# Live proof (Widevine version, EME, DRM playback): see docs/GOOGLE-CHROME-ARM64.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INST="$HERE/install-google-chrome-arm64.sh"
MAIN="$HERE/install-tesla-linux.sh"
BUILD="$HERE/build-image.sh"
PROBE="$HERE/chromium/drm-test"
n_pass=0
n_fail=0
fail=0
OUT="$(mktemp -d /tmp/tl-gc-out.XXXXXX)"

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

TREE="$(mktemp -d /tmp/tl-gc-tree.XXXXXX)"
cleanup() { rm -rf "$TREE" "$OUT"; }
trap cleanup EXIT

# --- static gates on the scripts -------------------------------------------
bash -n "$INST" && pass "install-google-chrome-arm64.sh parses" || bad "install-google-chrome-arm64.sh syntax"
[ "$("$INST" --print-packages)" = "google-chrome-stable" ] \
    && pass "installs exactly google-chrome-stable" || bad "print-packages is not google-chrome-stable"
grep -q 'dl.google.com/linux/chrome/deb' "$INST" \
    && pass "install uses Google's apt repo" || bad "install missing dl.google.com repo"
grep -q 'GC_KEY_FP=EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796' "$INST" \
    && pass "install pins the Google signing key fingerprint" || bad "install missing key fingerprint"
grep -q 'Signed-By: \$GC_KEYRING' "$INST" \
    && pass "apt source is Signed-By a keyring" || bad "apt source not Signed-By"
grep -q 'Architectures: arm64' "$INST" \
    && pass "apt source is arm64-only" || bad "apt source not arm64-only"
grep -q 'Pin-Priority: -10' "$INST" \
    && pass "install pins the Google repo out by default" || bad "install missing -10 pin"
grep -q 'NEEDRESTART_SUSPEND=1' "$INST" \
    && pass "install suspends needrestart (no service restarts)" || bad "needrestart not suspended"
grep -q 'TL_SKIP_GOOGLE_CHROME' "$INST" \
    && pass "install honours TL_SKIP_GOOGLE_CHROME" || bad "install missing TL_SKIP_GOOGLE_CHROME"
grep -q 'x-www-browser' "$INST" && grep -q 'update-alternatives --remove x-www-browser' "$INST" \
    && pass "install undoes Chrome's x-www-browser registration" || bad "install does not protect x-www-browser"
grep -q 'TL_GC_MIN_FREE_MB' "$INST" \
    && pass "install checks free disk first" || bad "install has no disk check"
if grep -v -E 'grep|ERROR' "$INST" | grep -Eq -- '--no-sandbox|--disable-gpu-sandbox|--disable-web-security|trusted=yes|--allow-unauthenticated'; then
    bad "install weakens the sandbox / signatures"
else
    pass "install does not weaken sandbox or signatures"
fi
if grep -Eq 'apt-get[[:space:]]+(remove|purge)|snap[[:space:]]+(remove|install)' "$INST"; then
    bad "install removes packages / touches snap"
else
    pass "install removes no packages"
fi
if grep -Eq 'etc/chromium\.d|etc/chromium/policies|raspberrypi-(chromium|widevine)' "$INST"; then
    bad "install touches the Pi Chromium flags/policy/pins"
else
    pass "install leaves the Pi Chromium flags, policy and pins alone"
fi

# hooks in main install + bake
grep -q 'ensure_google_chrome' "$MAIN" \
    && pass "install-tesla-linux.sh runs ensure_google_chrome" || bad "install-tesla-linux.sh not hooked"
grep -q -- '--verify-google-chrome' "$MAIN" \
    && pass "install-tesla-linux.sh has --verify-google-chrome" || bad "missing --verify-google-chrome"
grep -q 'TL_SKIP_GOOGLE_CHROME' "$MAIN" \
    && pass "install-tesla-linux.sh honours TL_SKIP_GOOGLE_CHROME" || bad "main installer missing skip env"
grep -q 'install-google-chrome-arm64.sh' "$BUILD" \
    && pass "build-image.sh stages install-google-chrome-arm64.sh" || bad "build-image.sh does not stage it"
grep -q -- '--verify-google-chrome' "$BUILD" \
    && pass "build-image.sh verifies Google Chrome" || bad "build-image.sh missing --verify-google-chrome"
"$MAIN" --print-packages | grep -q firefox \
    && pass "main PKGS still has firefox" || bad "main PKGS lost firefox"

# --- plant tree: verify gates ----------------------------------------------
plant() {
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/etc/apt/sources.list.d" "$t/etc/apt/preferences.d" "$t/etc/apt/apt.conf.d" \
             "$t/etc/tesla-linux" "$t/etc/opt/chrome/policies/managed" \
             "$t/usr/local/bin" "$t/usr/share/applications"
    cat > "$t/etc/apt/sources.list.d/google-chrome.sources" <<'EOF'
Types: deb
URIs: https://dl.google.com/linux/chrome/deb/
Suites: stable
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/google-chrome.asc
EOF
    cat > "$t/etc/apt/preferences.d/google-chrome" <<'EOF'
Package: *
Pin: origin dl.google.com
Pin-Priority: -10

Package: google-chrome-stable
Pin: origin dl.google.com
Pin-Priority: 990
EOF
    echo 'DPkg::Post-Invoke { "true"; };' > "$t/etc/apt/apt.conf.d/99tesla-linux-google-chrome"
    echo 'CHROME_FLAGS="--ozone-platform=x11 --start-maximized"' > "$t/etc/tesla-linux/google-chrome.conf"
    printf '#!/bin/sh\n. /etc/tesla-linux/google-chrome.conf\nexec /usr/bin/google-chrome-stable $CHROME_FLAGS "$@"\n' > "$t/usr/local/bin/google-chrome-tl"
    chmod +x "$t/usr/local/bin/google-chrome-tl"
    echo '{ "DefaultBrowserSettingEnabled": false }' > "$t/etc/opt/chrome/policies/managed/tesla-linux.json"
    cat > "$t/usr/share/applications/tesla-linux-google-chrome.desktop" <<'EOF'
[Desktop Entry]
Name=Google Chrome (DRM)
Exec=/usr/local/bin/google-chrome-tl %U
Type=Application
Categories=Network;WebBrowser;
EOF
}

plant "$TREE"
expect_ok "verify good tree" "$INST" --verify "$TREE"

rm -f "$TREE/etc/apt/sources.list.d/google-chrome.sources"
expect_fail "missing apt source fails gate" "apt source" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's/^Signed-By: .*/Trusted: yes/' "$TREE/etc/apt/sources.list.d/google-chrome.sources"
expect_fail "unsigned apt source fails gate" "Signed-By" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's/^Architectures: arm64$/Architectures: arm64 amd64/' "$TREE/etc/apt/sources.list.d/google-chrome.sources"
expect_fail "non-arm64-only source fails gate" "arm64-only" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's/^Pin-Priority: -10$/Pin-Priority: 500/' "$TREE/etc/apt/preferences.d/google-chrome"
expect_fail "Google repo not pinned out fails gate" "pinned out" "$INST" --verify "$TREE"
plant "$TREE"

printf 'Package: google-chrome-stable google-chrome-beta chromium\nPin: origin dl.google.com\nPin-Priority: 990\n' >> "$TREE/etc/apt/preferences.d/google-chrome"
expect_fail "pin allow-listing more than stable fails gate" "more than google-chrome-stable" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/usr/local/bin/google-chrome-tl"
expect_fail "missing wrapper fails gate" "missing or not executable" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's|exec /usr/bin/google-chrome-stable|exec /usr/bin/chromium|' "$TREE/usr/local/bin/google-chrome-tl"
expect_fail "wrapper not wrapping chrome fails gate" "does not wrap" "$INST" --verify "$TREE"
plant "$TREE"

echo 'CHROME_FLAGS="$CHROME_FLAGS --no-sandbox"' >> "$TREE/etc/tesla-linux/google-chrome.conf"
expect_fail "--no-sandbox in flags fails gate" "sandbox" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/etc/tesla-linux/google-chrome.conf"
expect_fail "missing flags file fails gate" "flags file missing" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/etc/opt/chrome/policies/managed/tesla-linux.json"
expect_fail "missing policy fails gate" "policy missing" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/etc/apt/apt.conf.d/99tesla-linux-google-chrome"
expect_fail "missing x-www-browser guard fails gate" "guard" "$INST" --verify "$TREE"
plant "$TREE"

rm -f "$TREE/usr/share/applications/tesla-linux-google-chrome.desktop"
expect_fail "missing launcher fails gate" "desktop entry missing" "$INST" --verify "$TREE"
plant "$TREE"

sed -i 's|^Exec=.*|Exec=/usr/bin/google-chrome-stable %U|' "$TREE/usr/share/applications/tesla-linux-google-chrome.desktop"
expect_fail "launcher not running the wrapper fails gate" "does not run" "$INST" --verify "$TREE"
plant "$TREE"

TL_SKIP_GOOGLE_CHROME=1 "$INST" >"$OUT/skip.out" 2>&1 \
    && grep -q skipping "$OUT/skip.out" && pass "TL_SKIP_GOOGLE_CHROME=1 is a no-op" \
    || bad "TL_SKIP_GOOGLE_CHROME=1 did not skip ($(cat "$OUT/skip.out"))"
TL_SKIP_GOOGLE_CHROME=1 bash "$MAIN" --verify-google-chrome "$TREE/nonexistent" >/dev/null 2>&1 \
    && pass "main --verify-google-chrome honours the skip env" || bad "main verify ignores skip env"

# --- live checks (only on a Pi that has it installed) -----------------------
if [ -x /opt/google/chrome/chrome ] && [ -x /usr/local/bin/google-chrome-tl ]; then
    expect_ok "live: --verify" "$INST" --verify
    ver="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' /opt/google/chrome/WidevineCdm/manifest.json)"
    [ -n "$ver" ] && pass "live: bundled Widevine CDM $ver" || bad "live: no CDM version"
    if [ -e /usr/bin/firefox ]; then
        [ "$(readlink -f /etc/alternatives/x-www-browser)" = "$(readlink -f /usr/bin/firefox)" ] \
            && pass "live: Firefox is still x-www-browser" || bad "live: x-www-browser is not Firefox"
    fi
    if [ -n "${DISPLAY:-}" ] && [ -f "$PROBE/probe.py" ] && python3 -c 'import websockets' 2>/dev/null; then
        prof="$(mktemp -d /tmp/tl-gc-prof.XXXXXX)"
        if timeout 90 python3 "$PROBE/probe.py" --exe "/usr/bin/google-chrome-stable --ozone-platform=x11 --no-first-run --no-default-browser-check --password-store=basic" \
              --profile "$prof" --eme-only --components --json "$OUT/eme.json" >/dev/null 2>&1 \
           && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); e=d["eme"]; w=d["components_widevine"]; sys.exit(0 if e["SW_SECURE_CRYPTO"]=="ok" and e["default"]=="ok" and any(x[0].isdigit() and x!="0.0.0.0" for x in w) else 1)' "$OUT/eme.json"; then
            pass "live: Widevine in chrome://components has a real version and EME works"
        else
            bad "live: Google Chrome Widevine probe failed"
        fi
        rm -rf "$prof"
    else
        echo "SKIP: live Google Chrome EME probe (no DISPLAY / websockets / probe)"
    fi
fi

echo "---"
echo "passed=$n_pass failed=$n_fail"
exit "$fail"
