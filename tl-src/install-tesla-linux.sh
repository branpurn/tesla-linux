#!/usr/bin/env bash
# Tesla Linux — install the streaming stack as systemd services.
#
# Idempotent. Runs on a live Pi *and* inside the image-bake chroot (pass --no-start
# there, since systemd isn't running). Assumes packages are already installed
# (see PKGS below for the list the bake must apt-install).
set -euo pipefail

TL_USER="${TL_USER:-teslalinux}"
PREFIX=/opt/tesla-linux
START=1
[ "${1:-}" = "--no-start" ] && START=0

# Factory console user (documented like AP PSK teslalinux). chpasswd must stick.
# Fail the bake/install if the password is not written — no `|| true`.
ensure_factory_user() {
    if ! id teslalinux >/dev/null 2>&1; then
        useradd -m -s /bin/bash teslalinux
    fi
    local g
    for g in sudo video audio render input; do
        getent group "$g" >/dev/null || groupadd "$g"
    done
    usermod -aG sudo,video,audio,render,input teslalinux
    if ! echo 'teslalinux:teslalinux' | chpasswd; then
        echo "ERROR: chpasswd teslalinux:teslalinux failed" >&2
        exit 1
    fi
    local hash
    hash="$(getent shadow teslalinux | cut -d: -f2)"
    case "$hash" in
        ''|'*'|'!'|'!*'|'!!')
            echo "ERROR: teslalinux password not set in shadow" >&2
            exit 1
            ;;
    esac
}

# chroot-safe: systemctl set-default is a no-op without a running systemd.
set_graphical_default() {
    local gt=""
    for p in /usr/lib/systemd/system/graphical.target /lib/systemd/system/graphical.target; do
        if [ -e "$p" ]; then
            gt="$p"
            break
        fi
    done
    if [ -z "$gt" ]; then
        echo "ERROR: graphical.target unit not found" >&2
        exit 1
    fi
    ln -sfn "$gt" /etc/systemd/system/default.target
    local rl
    rl="$(readlink /etc/systemd/system/default.target)"
    case "$rl" in
        */graphical.target|graphical.target) ;;
        *)
            echo "ERROR: default.target readlink is '$rl', not graphical.target" >&2
            exit 1
            ;;
    esac
}

# ubuntu/ubuntu is DOA. Purge cloud-init leftovers so it cannot recreate ubuntu.
purge_cloud_init_ubuntu() {
    apt-get purge -y cloud-init cloud-init-base cloud-guest-utils >/dev/null 2>&1 || true
    rm -rf /etc/cloud /var/lib/cloud
    rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf \
          /etc/ssh/sshd_config.d/*cloud-init* 2>/dev/null || true
    if id ubuntu >/dev/null 2>&1; then
        userdel -r ubuntu || userdel ubuntu
    fi
    rm -rf /home/ubuntu
    if id ubuntu >/dev/null 2>&1; then
        echo "ERROR: ubuntu user still present after userdel" >&2
        exit 1
    fi
}

# qemu-testable SSH: host keys must exist; password login for teslalinux.
ensure_sshd_qemu() {
    ssh-keygen -A
    if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        echo "ERROR: ssh host keys missing after ssh-keygen -A" >&2
        exit 1
    fi
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    fi
    install -d /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-tesla-linux.conf <<'EOF'
# qemu-testable factory SSH (teslalinux / teslalinux). Operators tighten later.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
EOF
    mkdir -p /etc/systemd/system/multi-user.target.wants
    for ssh_unit in /usr/lib/systemd/system/ssh.service /lib/systemd/system/ssh.service \
                    /usr/lib/systemd/system/sshd.service /lib/systemd/system/sshd.service; do
        if [ -f "$ssh_unit" ]; then
            ln -sfn "$ssh_unit" /etc/systemd/system/multi-user.target.wants/"$(basename "$ssh_unit")"
            break
        fi
    done
}

# Serial console getty for Ubuntu raspi + qemu raspi4b. Product path is XFCE :0, not getty.
# cmdline stays console=serial0,115200 console=tty1 — do not strip it.
ensure_serial_console() {
    local unit_src=""
    for p in /usr/lib/systemd/system/serial-getty@.service \
             /lib/systemd/system/serial-getty@.service; do
        if [ -f "$p" ]; then
            unit_src="$p"
            break
        fi
    done
    if [ -z "$unit_src" ]; then
        echo "ERROR: serial-getty@.service missing" >&2
        exit 1
    fi
    mkdir -p /etc/systemd/system/getty.target.wants
    local tty
    for tty in ttyAMA0 ttyS0 ttyAMA1; do
        ln -sfn "$unit_src" "/etc/systemd/system/getty.target.wants/serial-getty@${tty}.service"
    done
}

if [ "${1:-}" != "--print-packages" ]; then
    ensure_factory_user
    purge_cloud_init_ubuntu
    ensure_sshd_qemu
    ensure_serial_console
    set_graphical_default
fi
TL_UID=""

# Canonical package list — single source of truth for both the live box and the
# image bake. `install-tesla-linux.sh --print-packages` emits it for the chroot.
PKGS="xserver-xorg-core xserver-xorg-video-dummy xinit x11-utils x11-xserver-utils xinput \
gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
python3-gi python3-gst-1.0 python3-websockets python3-evdev \
xfce4 xfce4-terminal xfce4-panel xfdesktop4 xfwm4 xfce4-settings thunar dbus-x11 \
pipewire pipewire-pulse pipewire-audio wireplumber pulseaudio-utils gstreamer1.0-pipewire \
nginx openssl network-manager hostapd iw dnsmasq rfkill"

if [ "${1:-}" = "--print-packages" ]; then echo "$PKGS"; exit 0; fi
TL_UID="$(id -u "$TL_USER")"

echo "==> installing to $PREFIX (user=$TL_USER uid=$TL_UID)"
install -d "$PREFIX" /etc/tesla-linux /var/www/tl
HERE="$(cd "$(dirname "$0")" && pwd)"

# SSH authorized_keys for teslalinux (copy only — NEVER print the key).
if [ -f "$HERE/authorized_keys" ]; then
    install -d -m700 /home/teslalinux/.ssh
    install -m600 "$HERE/authorized_keys" /home/teslalinux/.ssh/authorized_keys
    chown -R teslalinux:teslalinux /home/teslalinux/.ssh
fi

# --- payload -----------------------------------------------------------------
for f in ta_display_backend.py ta_touch_backend.py ta_audio_backend.py; do
    [ -f "$HERE/$f" ] && install -m755 "$HERE/$f" "$PREFIX/$f"
done
for f in desktop.html probe.html index.html; do
    [ -f "$HERE/$f" ] && install -m644 "$HERE/$f" /var/www/tl/$f
done

# WAVE 1: factory AP env (SSID TeslaLinux / PSK teslalinux) + wlan helper/unit
if [ -f "$HERE/ap.env" ]; then
    install -m644 "$HERE/ap.env" /etc/tesla-linux/ap.env
else
    cat > /etc/tesla-linux/ap.env <<'EOF'
AP_SSID=TeslaLinux
AP_PSK=teslalinux
AP_ADDR=10.42.0.1
AP_PREFIX=24
AP_DHCP_START=10.42.0.10
AP_DHCP_END=10.42.0.200
ETH_ADDR=10.42.1.1
ETH_PREFIX=24
ETH_CONN=tesla-linux-eth
WAIT_SEC=20
IFACE_WAIT_SEC=60
EOF
fi
install -m755 "$HERE/tesla-linux-wlan.sh" /usr/local/sbin/tesla-linux-wlan
install -m755 "$HERE/tesla-linux-hdmi-clone" /usr/local/sbin/tesla-linux-hdmi-clone
install -m644 "$HERE/tesla-linux-wlan.service" /etc/systemd/system/tesla-linux-wlan.service
install -m755 "$HERE/ta_wlan_api.py" /usr/local/sbin/ta_wlan_api.py
install -m644 "$HERE/tesla-linux-wlan-api.service" /etc/systemd/system/tesla-linux-wlan-api.service

# NM dispatcher: wifi → maybe-ap (station else TeslaLinux AP); ethernet → nginx-bind
install -d /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/99-tesla-linux-wlan <<'EOF'
#!/bin/sh
# WAVE 1 — wifi: maybe-ap. ethernet/VM tap: nginx-bind only (not 0.0.0.0).
IFACE="$1"
ACTION="$2"
if [ -e "/sys/class/net/$IFACE/wireless" ]; then
    case "$ACTION" in
        up|connectivity-change|down)
            /usr/local/sbin/tesla-linux-wlan maybe-ap
            ;;
    esac
    exit 0
fi
# Wired eth0/end0/en* (or VM tap/bridge). Not lo/docker. Bind picker on that IPv4.
case "$IFACE" in
    lo|docker*|veth*|br-*|virbr*) exit 0 ;;
esac
[ -d "/sys/class/net/$IFACE" ] || exit 0
case "$ACTION" in
    up|connectivity-change)
        /usr/local/sbin/tesla-linux-wlan nginx-bind
        ;;
esac
exit 0
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/99-tesla-linux-wlan

# Wired ethernet: static 10.42.1.1/24 (not DHCP, not AP 10.42.0.1/24). NM owns it.
# shellcheck source=/dev/null
[ -f /etc/tesla-linux/ap.env ] && . /etc/tesla-linux/ap.env
ETH_ADDR="${ETH_ADDR:-10.42.1.1}"
ETH_PREFIX="${ETH_PREFIX:-24}"
ETH_CONN="${ETH_CONN:-tesla-linux-eth}"
install -d -m700 /etc/NetworkManager/system-connections /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-tesla-linux-eth.conf <<'EOF'
# Do not auto-create DHCP ethernet profiles; tesla-linux-eth is the wired connection.
[main]
no-auto-default=*
EOF
cat > /etc/NetworkManager/system-connections/${ETH_CONN}.nmconnection <<EOF
[connection]
id=$ETH_CONN
uuid=8e4c0b2a-1f42-4a11-9e01-104201010001
type=ethernet
autoconnect=true
autoconnect-priority=50

[ethernet]

[ipv4]
method=manual
address1=$ETH_ADDR/$ETH_PREFIX
never-default=true

[ipv6]
method=disabled
EOF
chmod 600 /etc/NetworkManager/system-connections/${ETH_CONN}.nmconnection

# stock hostapd/dnsmasq units stay off — tesla-linux-wlan starts them on demand
systemctl disable hostapd dnsmasq >/dev/null 2>&1 || true

# nginx: index.html (pick/save WLAN) + desktop.html / probe.html on AP/station/ethernet IPv4s only (never 0.0.0.0)
install -d /etc/nginx /etc/nginx/certs /etc/nginx/sites-available /etc/nginx/sites-enabled \
           /etc/systemd/system/nginx.service.d
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/tl-ws.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_set_header Host $host;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
proxy_buffering off;
EOF
cat > /etc/nginx/tl-locations.conf <<'EOF'
# WAVE 1: / is the station-WLAN picker (index.html). desktop.html stays the in-car stream.
# /api/wlan → loopback ta_wlan_api.py :9094 (save-wlan kick + nmcli scan). 501 gone.
root /var/www/tl;
index index.html;
location /sockets/display     { proxy_pass http://127.0.0.1:9091; include /etc/nginx/tl-ws.conf; }
location /sockets/touchscreen { proxy_pass http://127.0.0.1:9092; include /etc/nginx/tl-ws.conf; }
location /sockets/audio       { proxy_pass http://127.0.0.1:9093; include /etc/nginx/tl-ws.conf; }
location /api/wlan {
    proxy_pass http://127.0.0.1:9094;
    proxy_set_header Host $host;
    proxy_set_header Content-Type $http_content_type;
    client_max_body_size 8k;
}
EOF
# Placeholder until tesla-linux-wlan nginx-bind sees an AP/station/ethernet IPv4.
# No listen 80 / listen 0.0.0.0 — nginx stays down-bind until a WLAN/ethernet address exists.
echo "# no AP/station IPv4 yet; tesla-linux-wlan nginx-bind will rewrite" > /etc/nginx/tl-http-server.conf
echo "# no TLS binds yet" > /etc/nginx/tl-https-server.conf
cat > /etc/nginx/sites-available/tl <<'EOF'
# WAVE 1 binds: generated listen IPs in tl-http-server.conf / tl-https-server.conf.
# FLAG-TLS: HTTP on AP/station LAN is acceptable; do not invent a new TLS policy.
include /etc/nginx/tl-http-server.conf;
include /etc/nginx/tl-https-server.conf;
EOF
ln -sf /etc/nginx/sites-available/tl /etc/nginx/sites-enabled/tl
cat > /etc/systemd/system/nginx.service.d/tl-after-wlan.conf <<'EOF'
[Unit]
After=tesla-linux-wlan.service tesla-linux-wlan-api.service tesla-linux-firstboot.service
Wants=tesla-linux-wlan.service tesla-linux-wlan-api.service
EOF

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
# Remote display geometry used for touch coordinate mapping (Tesla-browser 1088x832)
TA_WIDTH=1088
TA_HEIGHT=832
# Audio capture source (monitor of the virtual sink)
TA_AUDIO_SRC=tesla.monitor
XDG_RUNTIME_DIR=/run/user/$TL_UID
EOF
fi
# Tesla-browser web-console geometry — pin even on re-install
if [ -f /etc/tesla-linux/tesla-linux.env ]; then
    sed -i 's/^TA_WIDTH=.*/TA_WIDTH=1088/' /etc/tesla-linux/tesla-linux.env
    sed -i 's/^TA_HEIGHT=.*/TA_HEIGHT=832/' /etc/tesla-linux/tesla-linux.env
    grep -q '^TA_WIDTH=' /etc/tesla-linux/tesla-linux.env || echo 'TA_WIDTH=1088' >> /etc/tesla-linux/tesla-linux.env
    grep -q '^TA_HEIGHT=' /etc/tesla-linux/tesla-linux.env || echo 'TA_HEIGHT=832' >> /etc/tesla-linux/tesla-linux.env
fi

# Virtual display (this SHA): dummy is Screen 0 primary so X starts without HDMI.
# Do not invent Xvfb. HDMI 1/2 are slave clones of that :0 session (--same-as dummy).
# --- Xorg: dummy 1088x832 (web console) + vc4 KMS for HDMI slave outputs ------
install -d /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-virtual.conf <<'EOF'
# Dummy is Screen 0 primary so X starts with no HDMI. Tesla-browser 1088x832.
Section "ServerFlags"
    Option "AllowEmptyInitialConfiguration" "true"
EndSection

Section "Device"
    Identifier "Virtual"
    Driver     "dummy"
    VideoRam   256000
EndSection

Section "Monitor"
    Identifier "VirtualMonitor"
    HorizSync   28.0-80.0
    VertRefresh 48.0-75.0
    Modeline "1088x832" 74.75 1088 1152 1264 1440 832 835 845 862 -hsync +vsync
EndSection

Section "Screen"
    Identifier "VirtualScreen"
    Device     "Virtual"
    Monitor    "VirtualMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1088x832"
        Virtual 1088 832
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier "TeslaLinux"
    Screen 0 "VirtualScreen"
EndSection
EOF
# Keep 99-vc4.conf for HDMI KMS (slave GPU / --same-as clone, not a second Screen).
cat > /etc/X11/xorg.conf.d/99-vc4.conf <<'EOF'
Section "OutputClass"
    Identifier  "vc4"
    MatchDriver "vc4"
    Driver      "modesetting"
    Option      "PrimaryGPU" "false"
EndSection
EOF

# --- uinput (virtual touch device) -------------------------------------------
echo uinput > /etc/modules-load.d/uinput.conf
echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' \
    > /etc/udev/rules.d/99-uinput.rules
usermod -aG input "$TL_USER"

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
Description=Tesla Linux — X server on virtual display (HDMI 1/2 slave clone)
After=systemd-user-sessions.service
Before=tesla-linux-desktop.service
# Do not After=tesla-linux-wlan — AP must not wait on X; X must not wait on AP.

[Service]
ExecStart=/usr/bin/Xorg :0 vt7 -ac -noreset -novtswitch
ExecStartPost=/usr/local/sbin/tesla-linux-hdmi-clone
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
# No BindsTo/PartOf xorg or display — desktop restart must not take down xorg/display.

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
# After xorg only — not desktop. A desktop restart loop must not block or take down capture.
After=tesla-linux-xorg.service
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

# --- boot into graphical.target (symlink — not systemctl set-default || true) -
loginctl enable-linger "$TL_USER" 2>/dev/null || true
set_graphical_default

# BACKEND-HOLE: autologin XFCE on :0 + HDMI 1/2 slave of that same session.
# Product path is tesla-linux-desktop on DISPLAY=:0, not getty on tty1/HDMI.
# Do not invent a second desktop. Do not treat getty as success.
# Backend lands autologin/XFCE/:0 on this branch.

mkdir -p /etc/systemd/system/graphical.target.wants /etc/systemd/system/multi-user.target.wants

enable_wlan_nginx() {
    systemctl enable tesla-linux-wlan.service tesla-linux-wlan-api.service nginx.service >/dev/null 2>&1 || true
    ln -sfn /etc/systemd/system/tesla-linux-wlan.service \
       /etc/systemd/system/multi-user.target.wants/tesla-linux-wlan.service
    ln -sfn /etc/systemd/system/tesla-linux-wlan-api.service \
       /etc/systemd/system/multi-user.target.wants/tesla-linux-wlan-api.service
}

if [ "$START" = "1" ]; then
    systemctl daemon-reload
    systemctl enable tesla-linux-xorg tesla-linux-desktop tesla-linux-display \
                     tesla-linux-touch tesla-linux-audio >/dev/null 2>&1
    enable_wlan_nginx
    /usr/local/sbin/tesla-linux-wlan eth-up >/dev/null 2>&1 || true
    echo "==> enabled. start with: systemctl start tesla-linux-xorg tesla-linux-desktop tesla-linux-display tesla-linux-touch tesla-linux-audio tesla-linux-wlan tesla-linux-wlan-api"
else
    # bake-time: enable via symlink since systemctl can't talk to a running systemd
    for u in xorg desktop display touch audio; do
        ln -sfn "/etc/systemd/system/tesla-linux-$u.service" \
           "/etc/systemd/system/graphical.target.wants/tesla-linux-$u.service"
    done
    enable_wlan_nginx
    echo "==> installed (chroot mode; units symlinked into graphical.target.wants + multi-user.target.wants)"
fi
