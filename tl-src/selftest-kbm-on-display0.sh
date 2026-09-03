#!/usr/bin/env bash
# Fail-hard checks: HDMI, web capture, and USB KBM share XFCE on Xorg :0.
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
    if "$@" >/tmp/tl-display-ok.out 2>/tmp/tl-display-ok.err; then
        pass "$name"
    else
        bad "$name (exit $?) stderr=$(tr '\n' ' ' </tmp/tl-display-ok.err)"
    fi
}

expect_fail() {
    local name="$1" needle="$2"
    shift 2
    if "$@" >/tmp/tl-display-bad.out 2>/tmp/tl-display-bad.err; then
        bad "$name (expected fail, passed)"
    elif grep -q "$needle" /tmp/tl-display-bad.err; then
        pass "$name"
    else
        bad "$name (wrong error: $(tr '\n' ' ' </tmp/tl-display-bad.err))"
    fi
}

pkgs="$("$INSTALL" --print-packages)"
echo "$pkgs" | grep -q 'xserver-xorg-input-libinput' \
    && pass "PKGS includes libinput" || bad "PKGS missing libinput"
if echo "$pkgs" | grep -q 'xserver-xorg-video-dummy'; then
    bad "PKGS still includes dummy video"
else
    pass "PKGS excludes dummy video"
fi
if echo "$pkgs" | grep -q 'tmux'; then
    bad "PKGS still includes tmux"
else
    pass "PKGS excludes tmux"
fi
grep -q '^ExecStart=/usr/bin/Xorg :0 vt1 -keeptty -ac -noreset -nolisten tcp$' "$INSTALL" \
    && pass "Xorg :0 owns vt1" || bad "Xorg does not own vt1"
grep -q '^TTYPath=/dev/tty1$' "$INSTALL" \
    && pass "Xorg service binds HDMI tty1" || bad "Xorg service lacks TTYPath"
if grep -Eq '^ExecStart=/usr/bin/Xorg .*-(novtswitch|seat)' "$INSTALL"; then
    bad "Xorg still overrides VT switching or seat discovery"
else
    pass "Xorg uses normal VT switching and seat0 discovery"
fi
grep -q 'Driver[[:space:]]*"modesetting"' "$INSTALL" \
    && pass "vc4 modesetting is configured" || bad "modesetting driver missing"
grep -q 'PreferredMode".*"1920x1080"' "$INSTALL" \
    && pass "HDMI uses standard 1920x1080 timing" || bad "1080p PreferredMode missing"
grep -q 'video=HDMI-A-1:1920x1080@60D' "$INSTALL" \
    && pass "KMS forces HDMI0 to 1080p60" || bad "KMS HDMI0 1080p60 missing"
grep -q 'xrandr --fb 1088x832 --output HDMI-1 --mode 1920x1080 --scale-from 1088x832 --primary' "$INSTALL" \
    && pass "RandR scales logical 1088x832 to HDMI 1080p" || bad "RandR scaling missing"
grep -q 'MatchDriver[[:space:]]*"vc4"' "$INSTALL" \
    && pass "Xorg selects the vc4 DRM device" || bad "vc4 MatchDriver missing"
grep -q 'PrimaryGPU".*"true"' "$INSTALL" \
    && pass "vc4 is the primary Xorg GPU" || bad "vc4 is not primary"
if grep -q 'Option "GrabDevice"' "$INSTALL"; then
    bad "input still uses GrabDevice"
else
    pass "input no longer uses GrabDevice"
fi
if grep -q 'cat > /etc/udev/rules.d/60-tesla-linux-kbm-seat0.rules' "$INSTALL"; then
    bad "installer still writes custom KBM seat rule"
else
    pass "input uses standard seat0 udev discovery"
fi

TREE="$(mktemp -d /tmp/tl-display-tree.XXXXXX)"
cleanup() { rm -rf "$TREE"; }
trap cleanup EXIT

plant() {
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/etc/systemd/system/getty.target.wants" \
             "$t/etc/systemd/system/graphical.target.wants" \
             "$t/etc/systemd/system/multi-user.target.wants" \
             "$t/etc/systemd/system/serial-getty@.service.d" \
             "$t/etc/systemd/logind.conf.d" \
             "$t/etc/X11/xorg.conf.d" \
             "$t/usr/lib/systemd/system" \
             "$t/usr/lib/xorg/modules/input" \
             "$t/usr/local/sbin" \
             "$t/usr/bin"
    : > "$t/usr/lib/systemd/system/getty@.service"
    : > "$t/usr/lib/xorg/modules/input/libinput_drv.so"
    : > "$t/usr/bin/Xorg"
    ln -sfn /usr/lib/systemd/system/graphical.target "$t/etc/systemd/system/default.target"
    ln -sfn /dev/null "$t/etc/systemd/system/getty@tty1.service"
    ln -sfn /dev/null "$t/etc/systemd/system/autovt@tty1.service"
    for tty in ttyAMA0 ttyS0 ttyAMA1; do
        ln -sfn /usr/lib/systemd/system/getty@.service \
            "$t/etc/systemd/system/getty.target.wants/serial-getty@${tty}.service"
    done
    ln -sfn /etc/systemd/system/tesla-linux-xorg.service \
        "$t/etc/systemd/system/graphical.target.wants/tesla-linux-xorg.service"
    ln -sfn /etc/systemd/system/tesla-linux-desktop.service \
        "$t/etc/systemd/system/graphical.target.wants/tesla-linux-desktop.service"

    cat > "$t/etc/systemd/system/tesla-linux-xorg.service" <<'EOF'
[Unit]
After=systemd-user-sessions.service systemd-udevd.service systemd-logind.service
Before=tesla-linux-desktop.service
[Service]
ExecStart=/usr/bin/Xorg :0 vt1 -keeptty -ac -noreset -nolisten tcp
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
[Install]
WantedBy=graphical.target
EOF
    cat > "$t/etc/systemd/system/tesla-linux-desktop.service" <<'EOF'
[Unit]
After=tesla-linux-xorg.service
Requires=tesla-linux-xorg.service
[Service]
User=teslalinux
Environment=DISPLAY=:0
ExecStartPre=/bin/sh -c 'DISPLAY=:0 xrandr --fb 1088x832 --output HDMI-1 --mode 1920x1080 --scale-from 1088x832 --primary'
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/xfce4-session
[Install]
WantedBy=graphical.target
EOF
    cat > "$t/etc/systemd/system/tesla-linux-wlan.service" <<'EOF'
[Unit]
Description=Tesla Linux WLAN
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tesla-linux-wlan boot
EOF
    cat > "$t/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf" <<'EOF'
[Login]
NAutoVTs=0
ReserveVT=0
EOF
    cat > "$t/etc/systemd/system/serial-getty@.service.d/tl-no-binds-to-dev.conf" <<'EOF'
[Unit]
BindsTo=
EOF
    cat > "$t/etc/X11/xorg.conf.d/10-tesla-linux-display.conf" <<'EOF'
Section "OutputClass"
    Identifier "TeslaLinuxVC4"
    MatchDriver "vc4"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
EndSection
Section "Monitor"
    Identifier "TeslaLinuxHDMI"
    Option "PreferredMode" "1920x1080"
EndSection
EOF
    cat > "$t/etc/X11/xorg.conf.d/20-tesla-linux-input.conf" <<'EOF'
Section "InputClass"
    Identifier "TeslaLinux keyboard"
    MatchIsKeyboard "on"
    Driver "libinput"
EndSection
Section "InputClass"
    Identifier "TeslaLinux pointer"
    MatchIsPointer "on"
    Driver "libinput"
EndSection
EOF
    cp "$HERE/tesla-linux-wlan.sh" "$t/usr/local/sbin/tesla-linux-wlan"
    chmod +x "$t/usr/local/sbin/tesla-linux-wlan"
}

plant "$TREE"
expect_ok "verify-kbm good unified tree" "$INSTALL" --verify-kbm "$TREE"
expect_ok "verify-autologin good unified tree" "$INSTALL" --verify-autologin "$TREE"

sed -i 's/Driver "modesetting"/Driver "dummy"/' \
    "$TREE/etc/X11/xorg.conf.d/10-tesla-linux-display.conf"
expect_fail "dummy screen fails gate" "modesetting" "$INSTALL" --verify-kbm "$TREE"
plant "$TREE"

sed -i 's/ :0 vt1 / :0 vt7 /' "$TREE/etc/systemd/system/tesla-linux-xorg.service"
expect_fail "Xorg vt7 fails gate" "vt1" "$INSTALL" --verify-kbm "$TREE"
plant "$TREE"

sed -i 's/ -keeptty/ -novtswitch/' "$TREE/etc/systemd/system/tesla-linux-xorg.service"
expect_fail "novtswitch fails gate" "novtswitch" "$INSTALL" --verify-kbm "$TREE"
plant "$TREE"

sed -i '/Driver "libinput"/a\\    Option "GrabDevice" "true"' \
    "$TREE/etc/X11/xorg.conf.d/20-tesla-linux-input.conf"
expect_fail "GrabDevice fails gate" "GrabDevice" "$INSTALL" --verify-kbm "$TREE"
plant "$TREE"

rm -f "$TREE/etc/systemd/system/getty@tty1.service"
ln -sfn /usr/lib/systemd/system/getty@.service \
    "$TREE/etc/systemd/system/getty.target.wants/getty@tty1.service"
expect_fail "unmasked getty fails gate" "unmasked" "$INSTALL" --verify-kbm "$TREE"
plant "$TREE"

rm -f "$TREE/usr/lib/xorg/modules/input/libinput_drv.so"
expect_fail "missing libinput driver fails gate" "libinput_drv.so" \
    "$INSTALL" --verify-kbm "$TREE"

echo
echo "selftest-kbm-on-display0: $n_pass passed, $n_fail failed"
exit "$fail"
