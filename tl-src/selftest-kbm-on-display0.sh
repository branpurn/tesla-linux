#!/usr/bin/env bash
# Fail-hard checks: USB KBM attaches to XFCE :0; Xorg is off HDMI vt1.
# No `|| true` on the gate. Run from the repo: ./tl-src/selftest-kbm-on-display0.sh
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
    if "$@" >/tmp/tl-kbm-ok.out 2>/tmp/tl-kbm-ok.err; then
        pass "$name"
    else
        bad "$name (exit $?) stderr=$(tr '\n' ' ' </tmp/tl-kbm-ok.err)"
    fi
}

expect_fail() {
    local name="$1"
    local needle="$2"
    shift 2
    if "$@" >/tmp/tl-kbm-bad.out 2>/tmp/tl-kbm-bad.err; then
        bad "$name (expected fail, passed)"
    elif grep -q "$needle" /tmp/tl-kbm-bad.err; then
        pass "$name"
    else
        bad "$name (wrong error: $(tr '\n' ' ' </tmp/tl-kbm-bad.err))"
    fi
}

# --- script-source / PKGS ----------------------------------------------------
pkgs="$("$INSTALL" --print-packages)"
echo "$pkgs" | grep -q 'xserver-xorg-input-libinput' \
    && pass "PKGS includes xserver-xorg-input-libinput" \
    || bad "PKGS missing xserver-xorg-input-libinput"
echo "$pkgs" | grep -q 'xserver-xorg-video-dummy' \
    && pass "PKGS still has dummy" \
    || bad "PKGS dropped xserver-xorg-video-dummy"
echo "$pkgs" | grep -q 'python3-evdev' \
    && pass "PKGS still has python3-evdev (uinput touch, not Xorg HID)" \
    || bad "PKGS dropped python3-evdev"

echo "$pkgs" | grep -q 'tmux' \
    && pass "PKGS includes tmux" \
    || bad "PKGS missing tmux"
grep -q '^ExecStart=/usr/bin/Xorg :0 vt1 -seat seat0 -ac -noreset -novtswitch$' "$INSTALL" \
    && pass "Xorg unit is :0 vt1 -seat seat0" \
    || bad "Xorg ExecStart is not :0 vt1 -seat seat0"
if grep -Eq '^ExecStart=/usr/bin/Xorg :0 vt7 ' "$INSTALL"; then
    bad "install script still starts Xorg on vt7"
else
    pass "install script does not start Xorg on vt7"
fi
if grep -Eq '^Conflicts=getty@tty1' "$INSTALL"; then
    bad "install script still Conflicts=getty@tty1"
else
    pass "install script does not Conflicts=getty@tty1"
fi
if grep -q 'systemctl mask getty@tty1' "$INSTALL"; then
    pass "install remasks getty@tty1 (HDMI is not a login; MOTD is tmux)"
else
    bad "install script does not remask getty@tty1"
fi
grep -q 'GrabDevice' "$INSTALL" && pass "install writes GrabDevice" || bad "no GrabDevice"
grep -Eq 'Driver[[:space:]]+"libinput"' "$INSTALL" && pass "install writes Driver libinput" || bad "no libinput driver"
if grep -Eq '^[[:space:]]*Driver[[:space:]]+"kbd"' "$INSTALL"; then
    bad "install still uses Driver kbd"
else
    pass "install does not use Driver kbd"
fi
grep -q '60-tesla-linux-kbm-seat0.rules' "$INSTALL" && pass "install writes kbm udev rule" || bad "no kbm udev rule"
grep -q 'ensure_hdmi_getty_vt1' "$INSTALL" && pass "getty-on-vt1 helper present" || bad "missing ensure_hdmi_getty_vt1"

if grep -Eq '^ExecStartPost=.*tesla-linux-hdmi-clone' "$INSTALL"; then
    bad "install still ExecStartPost tesla-linux-hdmi-clone"
else
    pass "install does not ExecStartPost tesla-linux-hdmi-clone"
fi
if grep -q 'install -m755 .*tesla-linux-hdmi-clone' "$INSTALL"; then
    bad "install still installs tesla-linux-hdmi-clone"
else
    pass "install does not install tesla-linux-hdmi-clone"
fi
grep -q 'PrimaryGPU" "false"' "$INSTALL" && pass "99-vc4.conf still non-primary" || bad "99-vc4.conf changed role"

# --- fake image root ---------------------------------------------------------
TREE="$(mktemp -d /tmp/tl-kbm-tree.XXXXXX)"
cleanup() { rm -rf "$TREE"; }
trap cleanup EXIT

plant() {
    local t="$1"
    mkdir -p "$t/etc/systemd/system/getty.target.wants" \
             "$t/etc/systemd/system/graphical.target.wants" \
             "$t/etc/systemd/system/multi-user.target.wants" \
             "$t/etc/systemd/system/serial-getty@.service.d" \
             "$t/etc/systemd/logind.conf.d" \
             "$t/etc/X11/xorg.conf.d" \
             "$t/etc/udev/rules.d" \
             "$t/etc/NetworkManager/dispatcher.d" \
             "$t/etc/update-motd.d" \
             "$t/etc/profile.d" \
             "$t/usr/lib/systemd/system" \
             "$t/usr/lib/xorg/modules/input" \
             "$t/usr/local/sbin" \
             "$t/usr/bin"
    : > "$t/usr/lib/systemd/system/getty@.service"
    : > "$t/usr/lib/xorg/modules/input/libinput_drv.so"
    : > "$t/usr/bin/Xorg"
    ln -sfn /usr/lib/systemd/system/graphical.target "$t/etc/systemd/system/default.target"
    # HDMI getty stays masked. SSH MOTD is tmux. Xorg :0 is vt1.
    ln -sfn /dev/null "$t/etc/systemd/system/getty@tty1.service"
    ln -sfn /dev/null "$t/etc/systemd/system/autovt@tty1.service"
    ln -sfn /usr/lib/systemd/system/serial-getty@.service \
        "$t/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service"
    ln -sfn /usr/lib/systemd/system/serial-getty@.service \
        "$t/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
    ln -sfn /usr/lib/systemd/system/serial-getty@.service \
        "$t/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA1.service"
    ln -sfn /etc/systemd/system/tesla-linux-xorg.service \
        "$t/etc/systemd/system/graphical.target.wants/tesla-linux-xorg.service"
    ln -sfn /etc/systemd/system/tesla-linux-desktop.service \
        "$t/etc/systemd/system/graphical.target.wants/tesla-linux-desktop.service"

    cat > "$t/etc/systemd/system/tesla-linux-xorg.service" <<'EOF'
[Unit]
Description=Tesla Linux — X server on virtual display
After=systemd-user-sessions.service systemd-udevd.service
Before=tesla-linux-desktop.service

[Service]
ExecStart=/usr/bin/Xorg :0 vt1 -seat seat0 -ac -noreset -novtswitch

[Install]
WantedBy=graphical.target
EOF
    cat > "$t/etc/systemd/system/tesla-linux-desktop.service" <<'EOF'
[Unit]
Description=Tesla Linux — XFCE session (autologin teslalinux on :0)
After=tesla-linux-xorg.service
Requires=tesla-linux-xorg.service

[Service]
User=teslalinux
Environment=DISPLAY=:0
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
    cat > "$t/etc/X11/xorg.conf.d/10-virtual.conf" <<'EOF'
Section "ServerFlags"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
    Option "DontVTSwitch" "true"
EndSection
Section "Screen"
    Identifier "VirtualScreen"
EndSection
Section "ServerLayout"
    Identifier "TeslaLinux"
    Screen 0 "VirtualScreen"
    Option "AutoAddDevices" "true"
EndSection
# 1088x832
EOF
    cat > "$t/etc/X11/xorg.conf.d/20-tesla-linux-input.conf" <<'EOF'
Section "InputClass"
    Identifier "TeslaLinux keyboard"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
    Option "GrabDevice" "true"
EndSection
Section "InputClass"
    Identifier "TeslaLinux pointer"
    MatchIsPointer "on"
    Driver "libinput"
    Option "GrabDevice" "true"
EndSection
EOF
    cat > "$t/etc/X11/xorg.conf.d/99-vc4.conf" <<'EOF'
Section "OutputClass"
    Identifier  "vc4"
    MatchDriver "vc4"
    Driver      "modesetting"
    Option      "PrimaryGPU" "false"
EndSection
EOF
    cat > "$t/etc/udev/rules.d/60-tesla-linux-kbm-seat0.rules" <<'EOF'
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", TAG+="seat", ENV{ID_SEAT}="seat0"
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_MOUSE}=="1", TAG+="seat", ENV{ID_SEAT}="seat0"
EOF
    cp "$HERE/tesla-linux-wlan.sh" "$t/usr/local/sbin/tesla-linux-wlan"
    chmod +x "$t/usr/local/sbin/tesla-linux-wlan"
    cp "$HERE/tesla-linux-hdmi-banner" "$t/usr/local/sbin/tesla-linux-hdmi-banner"
    chmod +x "$t/usr/local/sbin/tesla-linux-hdmi-banner"
    cp "$HERE/tesla-linux-hdmi-banner.service" "$t/etc/systemd/system/tesla-linux-hdmi-banner.service"
    ln -sfn /etc/systemd/system/tesla-linux-hdmi-banner.service \
        "$t/etc/systemd/system/multi-user.target.wants/tesla-linux-hdmi-banner.service"
    cat > "$t/etc/update-motd.d/99-tesla-linux" <<'EOF'
#!/bin/sh
/usr/local/sbin/tesla-linux-hdmi-banner once
EOF
    chmod +x "$t/etc/update-motd.d/99-tesla-linux"
    cat > "$t/etc/profile.d/99-tesla-linux-tmux.sh" <<'EOF'
exec tmux -S /run/tesla-linux/tmux.sock attach -t tl
EOF
    cat > "$t/etc/NetworkManager/dispatcher.d/99-tesla-linux-wlan" <<'EOF'
#!/bin/sh
/usr/local/sbin/tesla-linux-wlan maybe-ap
/usr/local/sbin/tesla-linux-hdmi-banner once >/dev/null 2>&1 || true
EOF
}

plant "$TREE"
expect_ok "verify-kbm good tree" "$INSTALL" --verify-kbm "$TREE"
expect_ok "verify-autologin good tree" "$INSTALL" --verify-autologin "$TREE"

# Negative: X back on vt7 (HID would stay on the kernel console)
sed -i 's/:0 vt1 /:0 vt7 /' "$TREE/etc/systemd/system/tesla-linux-xorg.service"
expect_fail "Xorg on vt7 fails gate" "vt1" "$INSTALL" --verify-kbm "$TREE"
sed -i 's/:0 vt7 /:0 vt1 /' "$TREE/etc/systemd/system/tesla-linux-xorg.service"

# Negative: Conflicts=getty
sed -i '/Before=tesla-linux-desktop.service/a Conflicts=getty@tty1.service' \
    "$TREE/etc/systemd/system/tesla-linux-xorg.service"
expect_fail "Conflicts=getty fails gate" "Conflicts" "$INSTALL" --verify-kbm "$TREE"
sed -i '/^Conflicts=getty@tty1.service$/d' "$TREE/etc/systemd/system/tesla-linux-xorg.service"

# Negative: HDMI clone hung off Xorg
sed -i '/^ExecStart=\/usr\/bin\/Xorg /a ExecStartPost=/usr/local/sbin/tesla-linux-hdmi-clone' \
    "$TREE/etc/systemd/system/tesla-linux-xorg.service"
expect_fail "ExecStartPost hdmi-clone fails gate" "hdmi-clone" "$INSTALL" --verify-kbm "$TREE"
sed -i '/^ExecStartPost=\/usr\/local\/sbin\/tesla-linux-hdmi-clone$/d' \
    "$TREE/etc/systemd/system/tesla-linux-xorg.service"

# Negative: getty unmasked (login would steal USB KBM)
rm -f "$TREE/etc/systemd/system/getty@tty1.service"
ln -sfn /usr/lib/systemd/system/getty@.service \
    "$TREE/etc/systemd/system/getty.target.wants/getty@tty1.service"
expect_fail "unmasked getty fails gate" "unmasked" "$INSTALL" --verify-kbm "$TREE"
rm -f "$TREE/etc/systemd/system/getty.target.wants/getty@tty1.service"
ln -sfn /dev/null "$TREE/etc/systemd/system/getty@tty1.service"

# Negative: no GrabDevice
sed -i '/GrabDevice/d' "$TREE/etc/X11/xorg.conf.d/20-tesla-linux-input.conf"
expect_fail "missing GrabDevice fails gate" "GrabDevice" "$INSTALL" --verify-kbm "$TREE"
# restore input conf
plant "$TREE"

# Negative: missing libinput driver on a tree that has Xorg
rm -f "$TREE/usr/lib/xorg/modules/input/libinput_drv.so"
expect_fail "missing libinput_drv.so fails gate" "libinput_drv.so" "$INSTALL" --verify-kbm "$TREE"

echo
echo "selftest-kbm-on-display0: $n_pass passed, $n_fail failed"
exit "$fail"
