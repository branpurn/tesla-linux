#!/usr/bin/env bash
# Host-side plantable gates: Mozilla apt Firefox .deb (not the Ubuntu snap stub).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/install-tesla-linux.sh"
fail=0
n_pass=0
n_fail=0

pass() { echo "PASS: $*"; n_pass=$((n_pass + 1)); }
bad() { echo "FAIL: $*"; n_fail=$((n_fail + 1)); fail=1; }

expect_ok() {
    local name="$1"
    shift
    if "$@" >/tmp/tl-ff-ok.out 2>/tmp/tl-ff-ok.err; then
        pass "$name"
    else
        bad "$name (exit $?) stderr=$(tr '\n' ' ' </tmp/tl-ff-ok.err)"
    fi
}

expect_fail() {
    local name="$1" needle="$2"
    shift 2
    if "$@" >/tmp/tl-ff-bad.out 2>/tmp/tl-ff-bad.err; then
        bad "$name (expected fail, passed)"
    elif grep -q "$needle" /tmp/tl-ff-bad.err; then
        pass "$name"
    else
        bad "$name (wrong error: $(tr '\n' ' ' </tmp/tl-ff-bad.err))"
    fi
}

pkgs="$("$INSTALL" --print-packages)"
echo "$pkgs" | grep -q 'firefox' \
    && pass "PKGS includes firefox" || bad "PKGS missing firefox"
grep -q 'packages.mozilla.org' "$INSTALL" \
    && pass "install uses Mozilla apt" || bad "install missing packages.mozilla.org"
grep -q 'Pin-Priority: 1000' "$INSTALL" \
    && pass "install pins Mozilla apt at 1000" || bad "install missing Mozilla pin"
grep -q 'Pin: release o=Ubuntu' "$INSTALL" \
    && pass "install pins out Ubuntu firefox" || bad "install missing Ubuntu firefox pin"
if grep -Eq 'snap[[:space:]]+install[[:space:]]+firefox|apt-get[[:space:]]+install[[:space:]]+.*snapd' "$INSTALL"; then
    bad "install still pulls snap firefox"
else
    pass "install does not snap-install firefox"
fi

TREE="$(mktemp -d /tmp/tl-ff-tree.XXXXXX)"
cleanup() { rm -rf "$TREE"; }
trap cleanup EXIT

plant() {
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/etc/apt/sources.list.d" \
             "$t/etc/apt/preferences.d" \
             "$t/etc/apt/keyrings" \
             "$t/usr/bin" \
             "$t/usr/share/applications"
    cat > "$t/etc/apt/sources.list.d/mozilla.list" <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF
    cat > "$t/etc/apt/preferences.d/mozilla" <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF
    cat > "$t/usr/bin/firefox" <<'EOF'
#!/bin/sh
echo Mozilla Firefox
EOF
    chmod +x "$t/usr/bin/firefox"
    cat > "$t/usr/share/applications/firefox.desktop" <<'EOF'
[Desktop Entry]
Name=Firefox
Exec=firefox %u
Type=Application
Categories=Network;WebBrowser;
EOF
}

plant "$TREE"
expect_ok "verify-firefox good tree" "$INSTALL" --verify-firefox "$TREE"

rm -f "$TREE/usr/bin/firefox"
expect_fail "missing firefox binary fails gate" "firefox binary missing" \
    "$INSTALL" --verify-firefox "$TREE"
plant "$TREE"

cat > "$TREE/usr/bin/firefox" <<'EOF'
#!/bin/sh
exec snap run firefox "$@"
EOF
expect_fail "snap stub fails gate" "snap stub" \
    "$INSTALL" --verify-firefox "$TREE"
plant "$TREE"

rm -f "$TREE/usr/share/applications/firefox.desktop"
expect_fail "missing desktop entry fails gate" "desktop entry missing" \
    "$INSTALL" --verify-firefox "$TREE"
plant "$TREE"

rm -f "$TREE/etc/apt/sources.list.d/mozilla.list"
expect_fail "missing Mozilla apt source fails gate" "Mozilla apt source" \
    "$INSTALL" --verify-firefox "$TREE"
plant "$TREE"

sed -i '/Pin: release o=Ubuntu/d' "$TREE/etc/apt/preferences.d/mozilla"
expect_fail "Ubuntu firefox not pinned out fails gate" "snap stub is not pinned out" \
    "$INSTALL" --verify-firefox "$TREE"

echo
echo "selftest-firefox: $n_pass passed, $n_fail failed"
exit "$fail"
