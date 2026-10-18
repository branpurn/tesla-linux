#!/usr/bin/env bash
# Host-side plantable gates for the Xubuntu desktop: xubuntu-desktop meta in
# PKGS, the apt pin that keeps every other browser / mail / office / DM /
# cloud-init out, lightdm masked, Chromium the only browser, build-image wiring.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/install-tesla-linux.sh"
BUILD="$HERE/build-image.sh"
n_pass=0
n_fail=0
pass() { echo "PASS: $*"; n_pass=$((n_pass + 1)); }
bad()  { echo "FAIL: $*"; n_fail=$((n_fail + 1)); }

expect_ok() {
    local name="$1"; shift
    if "$@" >/tmp/tl-xu.out 2>/tmp/tl-xu.err; then pass "$name"
    else bad "$name (stderr: $(tr '\n' ' ' </tmp/tl-xu.err))"; fi
}
expect_fail() {
    local name="$1" needle="$2"; shift 2
    if "$@" >/tmp/tl-xu.out 2>/tmp/tl-xu.err; then bad "$name (expected fail, passed)"
    elif grep -q "$needle" /tmp/tl-xu.err; then pass "$name"
    else bad "$name (wrong error: $(tr '\n' ' ' </tmp/tl-xu.err))"; fi
}

bash -n "$INSTALL" && pass "install-tesla-linux.sh parses" || bad "install syntax"
bash -n "$BUILD" && pass "build-image.sh parses" || bad "build-image syntax"

pkgs="$("$INSTALL" --print-packages)"
for want in xubuntu-desktop xubuntu-wallpapers xserver-xorg-input-libinput network-manager nginx; do
    echo "$pkgs" | grep -qw "$want" && pass "PKGS has $want" || bad "PKGS missing $want"
done
for no in firefox thunderbird epiphany-browser midori falkon chromium-browser snapd lightdm gdm3 cloud-init libreoffice gimp; do
    echo "$pkgs" | grep -qw "$no" && bad "PKGS lists $no" || pass "PKGS has no $no"
done

pins="$("$INSTALL" --print-apt-pins)"
for want in 'firefox\*' 'thunderbird\*' gdm3 cloud-init 'libreoffice\*' 'gimp\*' 'cups\*' xserver-xorg-legacy; do
    grep -Eq "^Package:.*(^|[[:space:]])$want([[:space:]]|\$)" <<<"$pins" \
        && pass "pin excludes ${want//\\/}" || bad "pin does not exclude ${want//\\/}"
done
grep -q '^Pin: release \*$' <<<"$pins" && grep -q '^Pin-Priority: -1$' <<<"$pins" \
    && pass "pin is release * / -1" || bad "pin priority"
# xubuntu-desktop HARD-depends on these: pinning them out makes the metapackage uninstallable.
for hard in alsa-utils lightdm lightdm-gtk-greeter xubuntu-default-settings xubuntu-artwork \
            update-manager 'printer-driver-\*' zenity xfce4-notifyd greybird-gtk-theme; do
    grep -Eq "^Package:.*(^|[[:space:]])$hard([[:space:]]|\$)" <<<"$pins" \
        && bad "pin excludes hard dependency ${hard//\\/}" || pass "pin leaves hard dep ${hard//\\/} installable"
done

grep -q -- '--print-apt-pins' "$BUILD" && pass "build-image writes the pin before apt" || bad "build-image missing pin"
awk '/print-apt-pins/{p=NR} /Keep-Downloaded-Packages=false xubuntu-desktop/{i=NR} END{exit !(p && i && p<i)}' "$BUILD" \
    && pass "pin is written before the xubuntu-desktop install" || bad "pin ordering in build-image"
grep -q 'apt-get install -y -q --no-install-recommends \$BASE_PKGS' "$BUILD" \
    && pass "base packages keep --no-install-recommends" || bad "base install flags"
grep -Eq 'apt-get install -y -q .*xubuntu-desktop$|xubuntu-desktop$' "$BUILD" \
    && ! grep -E 'no-install-recommends.*xubuntu-desktop' "$BUILD" | grep -vq '^#' \
    && pass "xubuntu-desktop installed WITH recommends" || bad "xubuntu-desktop must install with recommends"
grep -q 'policy-rc.d' "$BUILD" && pass "services not started during bake install" || bad "policy-rc.d missing"
grep -q -- '--verify-xubuntu' "$BUILD" && pass "build-image runs --verify-xubuntu" || bad "build-image verify missing"
# Image size: the desktop pushes the .img.xz near GitHub's 2 GiB asset limit, so the
# bake must clean apt/logs/tmp, zero free space on its own loop partitions, and gate size.
grep -q 'rm -f /var/cache/apt/archives/\*.deb' "$BUILD" && grep -q 'rm -rf /var/lib/apt/lists/\*' "$BUILD" \
    && pass "chroot drops apt archives + lists" || bad "chroot apt cleanup missing"
grep -q 'command -v zerofree' "$BUILD" && grep -q 'zerofree "\$ROOTDEV"' "$BUILD" \
    && grep -q 'dd if=/dev/zero of="\$mnt/.zero"' "$BUILD" \
    && pass "zerofree on root with dd-fill fallback" || bad "free-space zeroing missing"
awk '/^chroot "\$MNT" \/bin\/bash/{c=NR} /^assert_build_part "\$ROOTDEV" 2/{a=NR} /^ *zerofree "\$ROOTDEV"/{z=NR} /^xz -T0/{x=NR}
     END{exit !(c && a && z && x && c<a && a<z && z<x)}' "$BUILD" \
    && pass "zeroing runs after chroot, after the loop guard, before xz" || bad "zeroing order"
if grep -vE '^[[:space:]]*#' "$BUILD" | grep -Eq '/dev/(sd[a-z]|nvme|mmcblk|vd[a-z]|hd[a-z])'; then
    bad "build-image references a physical disk"
else pass "build-image never names a physical disk"; fi
grep -q '^MAX_IMG_XZ_BYTES=2140000000$' "$BUILD" && grep -q 'ALLOW_BIG_IMAGE:-0}" = 1' "$BUILD" \
    && awk '/^xz -T0/{x=NR} /-gt "\$MAX_IMG_XZ_BYTES"/{g=NR} END{exit !(x && g && x<g)}' "$BUILD" \
    && pass "post-pack size gate (2,140,000,000 B, ALLOW_BIG_IMAGE=1)" || bad "size gate missing"
grep -q 'Do not invent lightdm' "$INSTALL" && pass "desktop unit still forbids a DM" || bad "DM warning gone"

TREE="$(mktemp -d /tmp/tl-xu-tree.XXXXXX)"
trap 'rm -rf "$TREE"' EXIT
plant() {
    rm -rf "$TREE"
    mkdir -p "$TREE/etc/apt/preferences.d" "$TREE/etc/systemd/system/tesla-linux-desktop.service.d" "$TREE/var/lib/dpkg"
    "$INSTALL" --print-apt-pins > "$TREE/etc/apt/preferences.d/tesla-linux-xubuntu-exclude.pref"
    ln -s /dev/null "$TREE/etc/systemd/system/lightdm.service"
    printf '[Service]\nEnvironment=XDG_CONFIG_DIRS=/etc/xdg/xdg-xubuntu:/etc/xdg\n' \
        > "$TREE/etc/systemd/system/tesla-linux-desktop.service.d/xubuntu-defaults.conf"
    printf 'Package: chromium\nStatus: install ok installed\n\nPackage: xubuntu-desktop\nStatus: install ok installed\n' \
        > "$TREE/var/lib/dpkg/status"
}
plant
expect_ok "verify-xubuntu good tree" "$INSTALL" --verify-xubuntu "$TREE"

rm "$TREE/etc/apt/preferences.d/tesla-linux-xubuntu-exclude.pref"
expect_fail "missing pin fails" "missing apt pin" "$INSTALL" --verify-xubuntu "$TREE"
plant
sed -i 's/firefox\* //' "$TREE/etc/apt/preferences.d/tesla-linux-xubuntu-exclude.pref"
expect_fail "pin without firefox fails" "does not exclude firefox" "$INSTALL" --verify-xubuntu "$TREE"
plant
sed -i 's/^Pin-Priority: -1$/Pin-Priority: 500/' "$TREE/etc/apt/preferences.d/tesla-linux-xubuntu-exclude.pref"
expect_fail "pin priority not -1 fails" "priority is not -1" "$INSTALL" --verify-xubuntu "$TREE"
plant
rm "$TREE/etc/systemd/system/lightdm.service"
expect_fail "unmasked lightdm fails" "lightdm.service is not masked" "$INSTALL" --verify-xubuntu "$TREE"
plant
ln -s /lib/systemd/system/lightdm.service "$TREE/etc/systemd/system/display-manager.service"
expect_fail "display-manager alias fails" "display-manager.service exists" "$INSTALL" --verify-xubuntu "$TREE"
plant
rm "$TREE/etc/systemd/system/tesla-linux-desktop.service.d/xubuntu-defaults.conf"
expect_fail "missing XDG drop-in fails" "drop-in" "$INSTALL" --verify-xubuntu "$TREE"
plant
printf 'Package: firefox\nStatus: install ok installed\n' >> "$TREE/var/lib/dpkg/status"
expect_fail "installed firefox fails" "firefox is installed" "$INSTALL" --verify-xubuntu "$TREE"
plant
printf 'Package: thunderbird\nStatus: deinstall ok config-files\n' >> "$TREE/var/lib/dpkg/status"
expect_ok "removed (config-files) thunderbird is fine" "$INSTALL" --verify-xubuntu "$TREE"
plant
mkdir -p "$TREE/var/lib/snapd/snaps"; : > "$TREE/var/lib/snapd/snaps/firefox_1.snap"
expect_fail "firefox snap fails" "snap present" "$INSTALL" --verify-xubuntu "$TREE"

echo
echo "selftest-xubuntu-desktop: $n_pass passed, $n_fail failed"
[ "$n_fail" -eq 0 ]
