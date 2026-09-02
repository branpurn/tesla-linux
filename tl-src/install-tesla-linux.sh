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
    mkdir -p /etc/systemd/system/getty.target.wants \
             /etc/systemd/system/serial-getty@.service.d
    local tty
    for tty in ttyAMA0 ttyS0 ttyAMA1; do
        ln -sfn "$unit_src" "/etc/systemd/system/getty.target.wants/serial-getty@${tty}.service"
    done
    # Stock serial-getty@.service BindsTo=dev-%i.device. qemu raspi4b often never
    # activates that udev unit → DEPEND-fail, no guest shell. Empty BindsTo= clears it.
    # Do not After= tesla-linux-wlan. HDMI getty@tty1 stays masked (not this unit).
    cat > /etc/systemd/system/serial-getty@.service.d/tl-no-binds-to-dev.conf <<'EOF'
# qemu: udev may never activate dev-ttyAMA0.device / dev-ttyS0.device.
# Stock BindsTo=dev-%i.device then DEPEND-fails the getty. Empty BindsTo= clears it.
# Do not wait on tesla-linux-wlan. Do not put HDMI getty back on tty1.
[Unit]
BindsTo=
EOF
}

# HDMI / tty1 is Xorg :0 + tesla-linux-desktop (teslalinux), not getty.
# Serial-getty on ttyAMA0/ttyS0/ttyAMA1 stays (qemu typed login).
# logind ReserveVT=1 would keep tty1 for getty — that is the JUMP HDMI-is-getty fail.
ensure_getty_not_on_hdmi() {
    mkdir -p /etc/systemd/system/getty.target.wants /etc/systemd/logind.conf.d
    rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service \
          /etc/systemd/system/getty.target.wants/autovt@tty1.service \
          /etc/systemd/system/getty@tty1.service.d/autologin.conf
    ln -sfn /dev/null /etc/systemd/system/getty@tty1.service
    ln -sfn /dev/null /etc/systemd/system/autovt@tty1.service
    cat > /etc/systemd/logind.conf.d/tesla-linux-hdmi.conf <<'EOF'
# HDMI VT is Xorg :0 / tesla-linux-desktop (teslalinux). Do not reserve tty1 for getty.
# Serial getty on ttyAMA0/ttyS0/ttyAMA1 is unchanged.
[Login]
NAutoVTs=0
ReserveVT=0
EOF
    local mask
    mask="$(readlink /etc/systemd/system/getty@tty1.service)"
    case "$mask" in
        /dev/null|dev/null) ;;
        *)
            echo "ERROR: getty@tty1 is not masked (readlink='$mask')" >&2
            exit 1
            ;;
    esac
    if [ -e /etc/systemd/system/getty.target.wants/getty@tty1.service ]; then
        echo "ERROR: getty@tty1 still in getty.target.wants" >&2
        exit 1
    fi
    grep -q '^NAutoVTs=0$' /etc/systemd/logind.conf.d/tesla-linux-hdmi.conf \
        || { echo "ERROR: logind NAutoVTs=0 did not stick" >&2; exit 1; }
    grep -q '^ReserveVT=0$' /etc/systemd/logind.conf.d/tesla-linux-hdmi.conf \
        || { echo "ERROR: logind ReserveVT=0 did not stick" >&2; exit 1; }
}

# Fail the bake/install if autologin XFCE / getty-not-on-HDMI did not stick.
# Optional prefix ($1) is an image root (host-side check of a mounted bake).
# No `|| true` — any miss exits 1.
verify_autologin_hdmi() {
    local r="${1:-}"
    local xorg="$r/etc/systemd/system/tesla-linux-xorg.service"
    local desk="$r/etc/systemd/system/tesla-linux-desktop.service"
    local wlan="$r/etc/systemd/system/tesla-linux-wlan.service"
    local clone="$r/usr/local/sbin/tesla-linux-hdmi-clone"
    local virt="$r/etc/X11/xorg.conf.d/10-virtual.conf"
    local vc4="$r/etc/X11/xorg.conf.d/99-vc4.conf"
    local getty_mask="$r/etc/systemd/system/getty@tty1.service"
    local logind="$r/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf"
    local rl mask

    [ -f "$xorg" ] || { echo "ERROR: missing tesla-linux-xorg.service" >&2; exit 1; }
    grep -q '^ExecStart=/usr/bin/Xorg :0 vt1 ' "$xorg" \
        || { echo "ERROR: tesla-linux-xorg is not Xorg :0 vt1 (HDMI VT)" >&2; exit 1; }
    if grep -q ' vt7 ' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still uses vt7 — HDMI would stay on getty" >&2
        exit 1
    fi
    grep -q '^Conflicts=getty@tty1.service$' "$xorg" \
        || { echo "ERROR: tesla-linux-xorg missing Conflicts=getty@tty1.service" >&2; exit 1; }
    if grep -Eiq '^After=.*tesla-linux-wlan|^Requires=.*tesla-linux-wlan' "$xorg"; then
        echo "ERROR: tesla-linux-xorg must not After/Requires wlan" >&2
        exit 1
    fi

    [ -f "$desk" ] || { echo "ERROR: missing tesla-linux-desktop.service" >&2; exit 1; }
    grep -q '^User=teslalinux$' "$desk" \
        || { echo "ERROR: tesla-linux-desktop User is not teslalinux" >&2; exit 1; }
    grep -q '^Environment=DISPLAY=:0$' "$desk" \
        || { echo "ERROR: tesla-linux-desktop is not DISPLAY=:0" >&2; exit 1; }
    grep -q 'xfce4-session' "$desk" \
        || { echo "ERROR: tesla-linux-desktop is not xfce4-session" >&2; exit 1; }
    if grep -Eq '^(BindsTo|PartOf)=' "$desk"; then
        echo "ERROR: tesla-linux-desktop must not BindsTo/PartOf xorg or display" >&2
        exit 1
    fi

    [ -L "$getty_mask" ] || { echo "ERROR: getty@tty1.service is not a mask symlink" >&2; exit 1; }
    mask="$(readlink "$getty_mask")"
    case "$mask" in
        /dev/null|dev/null) ;;
        *)
            echo "ERROR: getty@tty1 is not masked (readlink='$mask')" >&2
            exit 1
            ;;
    esac
    if [ -e "$r/etc/systemd/system/getty.target.wants/getty@tty1.service" ]; then
        echo "ERROR: getty@tty1 still in getty.target.wants" >&2
        exit 1
    fi
    [ -f "$logind" ] || { echo "ERROR: missing logind tesla-linux-hdmi.conf" >&2; exit 1; }
    grep -q '^NAutoVTs=0$' "$logind" \
        || { echo "ERROR: logind NAutoVTs is not 0" >&2; exit 1; }
    grep -q '^ReserveVT=0$' "$logind" \
        || { echo "ERROR: logind ReserveVT is not 0" >&2; exit 1; }

    [ -L "$r/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service" ] \
        || { echo "ERROR: serial-getty@ttyAMA0 not enabled" >&2; exit 1; }
    [ -L "$r/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" ] \
        || { echo "ERROR: serial-getty@ttyS0 not enabled" >&2; exit 1; }
    [ -L "$r/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA1.service" ] \
        || { echo "ERROR: serial-getty@ttyAMA1 not enabled" >&2; exit 1; }

    local serial_dropin="$r/etc/systemd/system/serial-getty@.service.d/tl-no-binds-to-dev.conf"
    [ -f "$serial_dropin" ] \
        || { echo "ERROR: missing serial-getty BindsTo drop-in" >&2; exit 1; }
    grep -q '^BindsTo=$' "$serial_dropin" \
        || { echo "ERROR: serial-getty drop-in does not clear BindsTo" >&2; exit 1; }
    if grep -Eq '^BindsTo=dev-' "$serial_dropin"; then
        echo "ERROR: serial-getty still BindsTo the device unit" >&2
        exit 1
    fi
    if grep -Eiq '^After=.*tesla-linux-wlan|^Requires=.*tesla-linux-wlan|^Wants=.*tesla-linux-wlan' "$serial_dropin"; then
        echo "ERROR: serial-getty drop-in must not wait on wlan" >&2
        exit 1
    fi
    local serial_override
    for serial_override in \
        "$r/etc/systemd/system/serial-getty@.service" \
        "$r/etc/systemd/system/serial-getty@ttyAMA0.service" \
        "$r/etc/systemd/system/serial-getty@ttyS0.service"; do
        if [ -f "$serial_override" ] && grep -Eq '^BindsTo=dev-' "$serial_override"; then
            echo "ERROR: serial-getty still BindsTo the device unit ($serial_override)" >&2
            exit 1
        fi
    done

    local wlan_bin="$r/usr/local/sbin/tesla-linux-wlan"
    [ -f "$wlan_bin" ] || { echo "ERROR: missing tesla-linux-wlan helper" >&2; exit 1; }
    if grep -Eq 'no Wi-Fi iface after .*fail so the unit can restart' "$wlan_bin"; then
        echo "ERROR: tesla-linux-wlan boot still fails the unit solely for missing wifi" >&2
        exit 1
    fi
    grep -q 'wait_wired_iface' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing wait_wired_iface" >&2; exit 1; }
    grep -q 'eth_static_bound' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing eth_static_bound" >&2; exit 1; }

    [ -x "$clone" ] || { echo "ERROR: tesla-linux-hdmi-clone missing or not executable" >&2; exit 1; }
    grep -q -- '--same-as' "$clone" \
        || { echo "ERROR: tesla-linux-hdmi-clone is not xrandr --same-as" >&2; exit 1; }
    [ -f "$virt" ] || { echo "ERROR: missing 10-virtual.conf" >&2; exit 1; }
    grep -q '1088x832' "$virt" \
        || { echo "ERROR: 10-virtual.conf is not 1088x832" >&2; exit 1; }
    grep -q 'Screen 0 "VirtualScreen"' "$virt" \
        || { echo "ERROR: dummy is not Screen 0" >&2; exit 1; }
    [ -f "$vc4" ] || { echo "ERROR: missing 99-vc4.conf" >&2; exit 1; }
    grep -q 'PrimaryGPU" "false"' "$vc4" \
        || { echo "ERROR: 99-vc4.conf must not be a second Screen / primary GPU" >&2; exit 1; }

    [ -f "$wlan" ] || { echo "ERROR: missing tesla-linux-wlan.service" >&2; exit 1; }
    if grep -Eiq '^After=.*tesla-linux-(xorg|desktop)|^Requires=.*tesla-linux-(xorg|desktop)' "$wlan"; then
        echo "ERROR: tesla-linux-wlan must not After/Requires xorg or desktop" >&2
        exit 1
    fi
    if grep -Eiq '^Before=.*nginx\.service' "$wlan"; then
        echo "ERROR: tesla-linux-wlan must not Before=nginx.service (deadlock with nginx After=wlan)" >&2
        exit 1
    fi
    if awk '/^reload_nginx\(\)/,/^}/' "$wlan_bin" | grep -Eq 'systemctl[[:space:]]+(restart|start)[[:space:]]+nginx'; then
        echo "ERROR: reload_nginx still systemctl restart/start nginx (deadlock with nginx After=wlan)" >&2
        exit 1
    fi

    [ -L "$r/etc/systemd/system/graphical.target.wants/tesla-linux-xorg.service" ] \
        || { echo "ERROR: tesla-linux-xorg not WantedBy graphical.target" >&2; exit 1; }
    [ -L "$r/etc/systemd/system/graphical.target.wants/tesla-linux-desktop.service" ] \
        || { echo "ERROR: tesla-linux-desktop not WantedBy graphical.target" >&2; exit 1; }

    [ -L "$r/etc/systemd/system/default.target" ] \
        || { echo "ERROR: default.target is not a symlink" >&2; exit 1; }
    rl="$(readlink "$r/etc/systemd/system/default.target")"
    case "$rl" in
        */graphical.target|graphical.target) ;;
        *)
            echo "ERROR: default.target is '$rl', not graphical.target" >&2
            exit 1
            ;;
    esac

    if [ -L "$r/etc/systemd/system/display-manager.service" ]; then
        echo "ERROR: display-manager.service is enabled; product is tesla-linux-desktop, not a DM" >&2
        exit 1
    fi
}

# --verify-autologin [root] checks a live box or a mounted image. Do not run ensure_*.
if [ "${1:-}" = "--verify-autologin" ]; then
    verify_autologin_hdmi "${2:-}"
    exit 0
fi

if [ "${1:-}" != "--print-packages" ]; then
    ensure_factory_user
    purge_cloud_init_ubuntu
    ensure_sshd_qemu
    ensure_serial_console
    ensure_getty_not_on_hdmi
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
Conflicts=getty@tty1.service
# HDMI/console VT is vt1 (not vt7). getty@tty1 must not own it.
# X and AP stay independent. Do not wait on tesla-linux-wlan.

[Service]
# teslalinux session dir so xfce4-session has XDG_RUNTIME_DIR if linger is late.
ExecStartPre=/bin/sh -c 'install -d -m700 -o $TL_USER -g $TL_USER /run/user/$TL_UID'
ExecStart=/usr/bin/Xorg :0 vt1 -ac -noreset -novtswitch
ExecStartPost=/usr/local/sbin/tesla-linux-hdmi-clone
Restart=always
RestartSec=2
TimeoutStopSec=5

[Install]
WantedBy=graphical.target
EOF

cat > /etc/systemd/system/tesla-linux-desktop.service <<EOF
[Unit]
Description=Tesla Linux — XFCE session (autologin teslalinux on :0)
After=tesla-linux-xorg.service
Requires=tesla-linux-xorg.service
# No BindsTo/PartOf xorg or display — desktop restart must not take down xorg/display.
# This unit is the appliance autologin. Do not invent lightdm/gdm/sddm.

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
# Autologin XFCE on :0; HDMI 1/2 slave-clone that session. getty@tty1 must not own HDMI.
ensure_getty_not_on_hdmi

mkdir -p /etc/systemd/system/graphical.target.wants /etc/systemd/system/multi-user.target.wants

enable_wlan_nginx() {
    systemctl enable tesla-linux-wlan.service tesla-linux-wlan-api.service nginx.service >/dev/null 2>&1 || true
    ln -sfn /etc/systemd/system/tesla-linux-wlan.service \
       /etc/systemd/system/multi-user.target.wants/tesla-linux-wlan.service
    ln -sfn /etc/systemd/system/tesla-linux-wlan-api.service \
       /etc/systemd/system/multi-user.target.wants/tesla-linux-wlan-api.service
}

# File-level enable so bake/chroot and live install both leave graphical.target.wants.
for u in xorg desktop display touch audio; do
    ln -sfn "/etc/systemd/system/tesla-linux-$u.service" \
       "/etc/systemd/system/graphical.target.wants/tesla-linux-$u.service"
done
enable_wlan_nginx

if [ "$START" = "1" ]; then
    systemctl daemon-reload
    systemctl stop getty@tty1.service
    systemctl mask getty@tty1.service autovt@tty1.service
    systemctl enable tesla-linux-xorg tesla-linux-desktop tesla-linux-display \
                     tesla-linux-touch tesla-linux-audio >/dev/null 2>&1
    /usr/local/sbin/tesla-linux-wlan eth-up >/dev/null 2>&1 || true
    echo "==> enabled. start with: systemctl start tesla-linux-xorg tesla-linux-desktop tesla-linux-display tesla-linux-touch tesla-linux-audio tesla-linux-wlan tesla-linux-wlan-api"
else
    echo "==> installed (chroot mode; units symlinked into graphical.target.wants + multi-user.target.wants)"
fi

# Fail the bake/install if autologin XFCE / getty-not-on-HDMI did not stick.
verify_autologin_hdmi
