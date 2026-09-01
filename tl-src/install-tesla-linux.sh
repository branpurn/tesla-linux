#!/usr/bin/env bash
# Tesla Linux — install the streaming stack as systemd services.
#
# Idempotent. Runs on a live Pi *and* inside the image-bake chroot (pass --no-start
# there, since systemd isn't running). Assumes packages are already installed
# (see PKGS below for the list the bake must apt-install).
set -euo pipefail

TL_USER="${TL_USER:-ubuntu}"
TL_UID="$(id -u "$TL_USER" 2>/dev/null || echo 1000)"
PREFIX=/opt/tesla-linux
START=1
[ "${1:-}" = "--no-start" ] && START=0

# Canonical package list — single source of truth for both the live box and the
# image bake. `install-tesla-linux.sh --print-packages` emits it for the chroot.
PKGS="xserver-xorg-core xserver-xorg-video-dummy xinit x11-utils x11-xserver-utils xinput \
gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
python3-gi python3-gst-1.0 python3-websockets python3-evdev \
xfce4 xfce4-terminal xfce4-panel xfdesktop4 xfwm4 xfce4-settings thunar dbus-x11 \
pipewire pipewire-pulse pipewire-audio wireplumber pulseaudio-utils gstreamer1.0-pipewire \
nginx openssl"

if [ "${1:-}" = "--print-packages" ]; then echo "$PKGS"; exit 0; fi

echo "==> installing to $PREFIX (user=$TL_USER uid=$TL_UID)"
install -d "$PREFIX" /etc/tesla-linux

# --- payload -----------------------------------------------------------------
for f in ta_display_backend.py ta_touch_backend.py ta_audio_backend.py; do
    [ -f "$(dirname "$0")/$f" ] && install -m755 "$(dirname "$0")/$f" "$PREFIX/$f"
done
install -d /var/www/tl
for f in desktop.html probe.html; do
    [ -f "$(dirname "$0")/$f" ] && install -m644 "$(dirname "$0")/$f" /var/www/tl/$f
done

# --- tunables (edit here, not in the units) ----------------------------------
if [ ! -f /etc/tesla-linux/tesla-linux.env ]; then
cat > /etc/tesla-linux/tesla-linux.env <<EOF
# Display captured and served
TA_DISPLAY=:0
# Bind backends to loopback — nginx terminates TLS and proxies /sockets/*
TA_BIND=127.0.0.1
# Encoder: auto (v4l2h264enc on Pi4 if /dev/video11 exists, else x264enc)
TA_ENCODER=
TA_BITRATE=8000
TA_FPS=30
# Remote display geometry used for touch coordinate mapping
TA_WIDTH=1920
TA_HEIGHT=1080
# Audio capture source (monitor of the virtual sink)
TA_AUDIO_SRC=tesla.monitor
XDG_RUNTIME_DIR=/run/user/$TL_UID
EOF
fi

# --- Xorg on the real display (Pi: pin to the vc4 KMS node, not the v3d node) --
install -d /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-vc4.conf <<'EOF'
Section "OutputClass"
    Identifier  "vc4"
    MatchDriver "vc4"
    Driver      "modesetting"
    Option      "PrimaryGPU" "true"
EndSection
EOF

# --- uinput (virtual touch device) -------------------------------------------
echo uinput > /etc/modules-load.d/uinput.conf
echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' \
    > /etc/udev/rules.d/99-uinput.rules
usermod -aG input "$TL_USER" 2>/dev/null || true

# --- PipeWire: always-present virtual sink so headless audio has a target -----
install -d /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/99-tesla-sink.conf <<'EOF'
context.objects = [
  { factory = adapter
    args = {
      factory.name          = support.null-audio-sink
      node.name             = "tesla"
      node.description      = "Tesla Linux Sink"
      media.class           = Audio/Sink
      audio.position        = [ FL FR ]
      monitor.channel-volumes = true
      node.pause-on-idle    = false
    }
  }
]
EOF
# make it the default sink (wireplumber otherwise prefers HDMI, which is silent headless)
install -d /etc/wireplumber/wireplumber.conf.d
cat > /etc/wireplumber/wireplumber.conf.d/99-tesla-default.conf <<'EOF'
wireplumber.settings = {
  device.routes.default-sink-volume = 1.0
}
EOF

# --- systemd units ------------------------------------------------------------
cat > /etc/systemd/system/tesla-linux-xorg.service <<EOF
[Unit]
Description=Tesla Linux — X server on the HDMI display
After=systemd-user-sessions.service
Before=tesla-linux-desktop.service

[Service]
ExecStart=/usr/bin/Xorg :0 vt7 -ac -noreset -novtswitch
Restart=always
RestartSec=2
TimeoutStopSec=5

[Install]
WantedBy=graphical.target
EOF

cat > /etc/systemd/system/tesla-linux-desktop.service <<EOF
[Unit]
Description=Tesla Linux — XFCE session
After=tesla-linux-xorg.service
Requires=tesla-linux-xorg.service

[Service]
User=$TL_USER
PAMName=login
EnvironmentFile=/etc/tesla-linux/tesla-linux.env
Environment=DISPLAY=:0
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 30); do DISPLAY=:0 xdpyinfo >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/xfce4-session
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

cat > /etc/systemd/system/tesla-linux-display.service <<EOF
[Unit]
Description=Tesla Linux — screen capture/encode -> WebSocket
After=tesla-linux-desktop.service
Requires=tesla-linux-xorg.service

[Service]
User=$TL_USER
EnvironmentFile=/etc/tesla-linux/tesla-linux.env
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 30); do DISPLAY=\$TA_DISPLAY xdpyinfo >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/python3 $PREFIX/ta_display_backend.py
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

cat > /etc/systemd/system/tesla-linux-touch.service <<EOF
[Unit]
Description=Tesla Linux — WebSocket -> uinput pointer/touch
After=tesla-linux-xorg.service

[Service]
User=$TL_USER
SupplementaryGroups=input
EnvironmentFile=/etc/tesla-linux/tesla-linux.env
ExecStart=/usr/bin/python3 $PREFIX/ta_touch_backend.py
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

cat > /etc/systemd/system/tesla-linux-audio.service <<EOF
[Unit]
Description=Tesla Linux — desktop audio -> WebSocket
After=tesla-linux-desktop.service

[Service]
User=$TL_USER
EnvironmentFile=/etc/tesla-linux/tesla-linux.env
# wait for pipewire-pulse and make the virtual sink the default
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 30); do pactl info >/dev/null 2>&1 && break; sleep 1; done; pactl set-default-sink tesla 2>/dev/null || true'
ExecStart=/usr/bin/python3 $PREFIX/ta_audio_backend.py
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

# --- boot into graphical.target, and keep the user session alive --------------
loginctl enable-linger "$TL_USER" 2>/dev/null || true
systemctl set-default graphical.target >/dev/null 2>&1 || true

if [ "$START" = "1" ]; then
    systemctl daemon-reload
    systemctl enable tesla-linux-xorg tesla-linux-desktop tesla-linux-display \
                     tesla-linux-touch tesla-linux-audio >/dev/null 2>&1
    echo "==> enabled. start with: systemctl start tesla-linux-xorg tesla-linux-desktop tesla-linux-display tesla-linux-touch tesla-linux-audio"
else
    # bake-time: enable via symlink since systemctl can't talk to a running systemd
    for u in xorg desktop display touch audio; do
        ln -sf "/etc/systemd/system/tesla-linux-$u.service" \
           "/etc/systemd/system/graphical.target.wants/tesla-linux-$u.service" 2>/dev/null || true
    done
    echo "==> installed (chroot mode; units symlinked into graphical.target.wants)"
fi
