#!/usr/bin/env bash
# Host-side plantable gates: xubuntu-wallpapers + xfdesktop last-image default.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/install-tesla-linux.sh"
IMG=/usr/share/xfce4/backdrops/xubuntu-wallpaper.png
fail=0
n_pass=0
n_fail=0

pass() { echo "PASS: $*"; n_pass=$((n_pass + 1)); }
bad() { echo "FAIL: $*"; n_fail=$((n_fail + 1)); fail=1; }

expect_ok() {
    local name="$1"
    shift
    if "$@" >/tmp/tl-wp-ok.out 2>/tmp/tl-wp-ok.err; then
        pass "$name"
    else
        bad "$name (exit $?) stderr=$(tr '\n' ' ' </tmp/tl-wp-ok.err)"
    fi
}

expect_fail() {
    local name="$1" needle="$2"
    shift 2
    if "$@" >/tmp/tl-wp-bad.out 2>/tmp/tl-wp-bad.err; then
        bad "$name (expected fail, passed)"
    elif grep -q "$needle" /tmp/tl-wp-bad.err; then
        pass "$name"
    else
        bad "$name (wrong error: $(tr '\n' ' ' </tmp/tl-wp-bad.err))"
    fi
}

pkgs="$("$INSTALL" --print-packages)"
echo "$pkgs" | grep -qw 'xubuntu-wallpapers' \
    && pass "PKGS includes xubuntu-wallpapers" || bad "PKGS missing xubuntu-wallpapers"
if echo "$pkgs" | grep -qw 'xubuntu-desktop'; then
    bad "PKGS still includes xubuntu-desktop"
else
    pass "PKGS excludes xubuntu-desktop"
fi
if echo "$pkgs" | grep -qw 'xfce4-wallpapers'; then
    bad "PKGS substituted xfce4-wallpapers for xubuntu-wallpapers"
else
    pass "PKGS does not substitute xfce4-wallpapers"
fi
grep -q "$IMG" "$INSTALL" \
    && pass "install references $IMG" || bad "install missing $IMG"
grep -q 'name="monitorHDMI-1"' "$INSTALL" \
    && pass "install configures monitorHDMI-1" || bad "install missing monitorHDMI-1"
grep -q 'name="monitorVirtual-1"' "$INSTALL" \
    && pass "install configures monitorVirtual-1" || bad "install missing monitorVirtual-1"
grep -q 'name="image-style" type="int" value="5"' "$INSTALL" \
    && pass "install sets image-style 5" || bad "install missing image-style 5"
grep -q 'name="backdrop-cycle-enable" type="bool" value="false"' "$INSTALL" \
    && pass "install disables wallpaper cycle" || bad "install missing cycle off"

TREE="$(mktemp -d /tmp/tl-wp-tree.XXXXXX)"
cleanup() { rm -rf "$TREE"; }
trap cleanup EXIT

plant() {
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/etc/xdg/xfce4/xfconf/xfce-perchannel-xml" \
             "$t/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
    cat > "$t/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorHDMI-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$IMG" locked="true"/>
          <property name="image-style" type="int" value="5" locked="true"/>
          <property name="backdrop-cycle-enable" type="bool" value="false" locked="true"/>
        </property>
      </property>
      <property name="monitorVirtual-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$IMG" locked="true"/>
          <property name="image-style" type="int" value="5" locked="true"/>
          <property name="backdrop-cycle-enable" type="bool" value="false" locked="true"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
    cp "$t/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" \
       "$t/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
}

plant "$TREE"
expect_ok "verify-wallpaper good tree" "$INSTALL" --verify-wallpaper "$TREE"

rm -f "$TREE/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
expect_fail "missing xfce4-desktop.xml fails gate" "missing XFCE xfce4-desktop.xml" \
    "$INSTALL" --verify-wallpaper "$TREE"
plant "$TREE"

sed -i "s|$IMG|/tmp/missing.png|" \
    "$TREE/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
expect_fail "wrong wallpaper path fails gate" "does not reference" \
    "$INSTALL" --verify-wallpaper "$TREE"
plant "$TREE"

sed -i 's/monitorHDMI-1/monitorHDMI-2/' \
    "$TREE/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
expect_fail "missing HDMI-1 fails gate" "monitorHDMI-1" \
    "$INSTALL" --verify-wallpaper "$TREE"
plant "$TREE"

sed -i 's/value="5"/value="3"/' \
    "$TREE/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
expect_fail "image-style not zoom fails gate" "image-style is not 5" \
    "$INSTALL" --verify-wallpaper "$TREE"
plant "$TREE"

sed -i 's/value="false"/value="true"/' \
    "$TREE/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
expect_fail "cycle on fails gate" "backdrop cycle is not off" \
    "$INSTALL" --verify-wallpaper "$TREE"
plant "$TREE"

mkdir -p "$TREE/usr/share/xfce4/backdrops"
expect_fail "missing image after package files fails gate" "wallpaper image missing" \
    "$INSTALL" --verify-wallpaper "$TREE"
plant "$TREE"

mkdir -p "$TREE/usr/share/xfce4/backdrops"
: > "$TREE/usr/share/xfce4/backdrops/xubuntu-wallpaper.png"
expect_ok "verify-wallpaper with installed image" "$INSTALL" --verify-wallpaper "$TREE"

echo
echo "selftest-xfce-wallpaper: $n_pass passed, $n_fail failed"
exit "$fail"
