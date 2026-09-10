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

# Canonical package list — single source of truth for both the live box and the
# image bake. `install-tesla-linux.sh --print-packages` emits it for the chroot.
# xserver-xorg-input-libinput is required so USB HID attaches to Xorg :0.
# python3-evdev is the uinput touch backend, not the Xorg HID driver.
# firefox is Mozilla apt .deb (packages.mozilla.org), not the Ubuntu snap stub.
# ristretto is the lightweight XFCE image viewer (piecemeal XFCE; not a desktop meta).
PKGS="xserver-xorg-core xserver-xorg-input-libinput \
xinit x11-utils x11-xserver-utils xinput \
gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
python3-gi python3-gst-1.0 python3-websockets python3-evdev \
xfce4 xfce4-terminal xfce4-panel xfdesktop4 xfwm4 xfce4-settings thunar ristretto dbus-x11 \
xarchiver thunar-archive-plugin 7zip unzip \
pipewire pipewire-pulse pipewire-audio wireplumber pulseaudio-utils gstreamer1.0-pipewire \
nginx openssl network-manager hostapd iw dnsmasq rfkill firefox"

MOZILLA_APT_KEY_URL=https://packages.mozilla.org/apt/repo-signing-key.gpg
MOZILLA_APT_FP=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3

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
    # Do not After= tesla-linux-wlan. HDMI is the XFCE Xorg session on vt1.
    cat > /etc/systemd/system/serial-getty@.service.d/tl-no-binds-to-dev.conf <<'EOF'
# qemu: udev may never activate dev-ttyAMA0.device / dev-ttyS0.device.
# Stock BindsTo=dev-%i.device then DEPEND-fails the getty. Empty BindsTo= clears it.
# Do not wait on tesla-linux-wlan. Do not put HDMI getty back on tty1.
[Unit]
BindsTo=
EOF
}

# HDMI and the web stream are the same Xorg :0 session on vt1.
# Getty stays masked so it cannot steal USB KBM.
# Do not Conflicts=getty@tty1 on xorg (getty is already masked).
ensure_graphical_vt1() {
    mkdir -p /etc/systemd/system/getty.target.wants /etc/systemd/logind.conf.d
    rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service \
          /etc/systemd/system/getty.target.wants/autovt@tty1.service \
          /etc/systemd/system/getty@tty1.service.d/autologin.conf
    ln -sfn /dev/null /etc/systemd/system/getty@tty1.service
    ln -sfn /dev/null /etc/systemd/system/autovt@tty1.service

    cat > /etc/systemd/logind.conf.d/tesla-linux-hdmi.conf <<'EOF'
# Xorg :0 owns tty1 and displays the same 1088x832 desktop captured for the web.
# NAutoVTs=0: no extra VTs. getty@tty1 stays masked.
# Appliance never sleeps: idle/lid/suspend keys must not take down :0 or USB KBM.
[Login]
NAutoVTs=0
ReserveVT=0
IdleAction=ignore
IdleActionSec=infinity
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKey=poweroff
IdleHint=no
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
        echo "ERROR: getty@tty1 still in getty.target.wants (login would replace XFCE)" >&2
        exit 1
    fi
    grep -q '^NAutoVTs=0$' /etc/systemd/logind.conf.d/tesla-linux-hdmi.conf \
        || { echo "ERROR: logind NAutoVTs=0 did not stick" >&2; exit 1; }
    grep -q '^ReserveVT=0$' /etc/systemd/logind.conf.d/tesla-linux-hdmi.conf \
        || { echo "ERROR: logind ReserveVT=0 did not stick" >&2; exit 1; }
    grep -q '^IdleAction=ignore$' /etc/systemd/logind.conf.d/tesla-linux-hdmi.conf \
        || { echo "ERROR: logind IdleAction=ignore did not stick" >&2; exit 1; }
}

# Give Pi HDMI0 a standard timing monitors accept. Xrandr scales the logical
# 1088x832 Tesla framebuffer onto this 1920x1080@60 physical signal.
ensure_hdmi_mode() {
    local cmdline="" candidate line
    for candidate in \
        /boot/firmware/current/cmdline.txt \
        /boot/firmware/cmdline.txt \
        /boot/cmdline.txt; do
        if [ -f "$candidate" ]; then
            cmdline="$candidate"
            break
        fi
    done
    [ -n "$cmdline" ] || {
        echo "ERROR: missing Pi cmdline.txt; cannot force HDMI0 to 1080p60" >&2
        exit 1
    }
    line="$(tr '\n' ' ' < "$cmdline")"
    line="$(printf '%s\n' "$line" \
        | sed -E 's/(^| )video=HDMI-A-1:[^ ]+//g; s/(^| )usbcore.autosuspend=[^ ]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
    printf '%s video=HDMI-A-1:1920x1080@60D usbcore.autosuspend=-1\n' "$line" > "$cmdline"
    grep -q 'video=HDMI-A-1:1920x1080@60D' "$cmdline" \
        || { echo "ERROR: HDMI0 kernel mode did not stick" >&2; exit 1; }
    grep -q 'usbcore.autosuspend=-1' "$cmdline" \
        || { echo "ERROR: usbcore.autosuspend=-1 did not stick" >&2; exit 1; }
}

# Appliance never sleep/suspend/hibernate. File-level so bake chroot and live
# install both stick without a running systemd. USB autosuspend off keeps HID
# and :0 capture awake; do not touch seat0 / GrabDevice / KBM udev.
ensure_never_sleep() {
    local t
    mkdir -p /etc/systemd/system /etc/modprobe.d /etc/udev/rules.d \
             /etc/xdg/autostart \
             /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        ln -sfn /dev/null "/etc/systemd/system/$t"
    done

    cat > /etc/modprobe.d/tesla-linux-no-autosuspend.conf <<'EOF'
# Keep USB HID and the :0 capture path from runtime-PM idle disconnects.
options usbcore autosuspend=-1
EOF

    cat > /etc/udev/rules.d/50-tesla-linux-usb-power.rules <<'EOF'
# USB power stays on. Do not assign seats or match HID here (standard seat0).
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="pci", DRIVER=="xhci_hcd", TEST=="power/control", ATTR{power/control}="on"
EOF

    # Locked system defaults: XFCE must not idle-suspend or DPMS-blank :0.
    cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="inactivity-on-ac" type="uint" value="0" locked="true"/>
    <property name="inactivity-on-battery" type="uint" value="0" locked="true"/>
    <property name="lid-action-on-ac" type="uint" value="0" locked="true"/>
    <property name="lid-action-on-battery" type="uint" value="0" locked="true"/>
    <property name="sleep-button-action" type="uint" value="0" locked="true"/>
    <property name="hibernate-button-action" type="uint" value="0" locked="true"/>
    <property name="power-button-action" type="uint" value="0" locked="true"/>
    <property name="critical-power-action" type="uint" value="0" locked="true"/>
    <property name="dpms-enabled" type="bool" value="false" locked="true"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0" locked="true"/>
    <property name="dpms-on-ac-off" type="uint" value="0" locked="true"/>
    <property name="dpms-on-battery-sleep" type="uint" value="0" locked="true"/>
    <property name="dpms-on-battery-off" type="uint" value="0" locked="true"/>
    <property name="blank-on-ac" type="int" value="0" locked="true"/>
    <property name="blank-on-battery" type="int" value="0" locked="true"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false" locked="true"/>
    <property name="logind-handle-lid-switch" type="bool" value="false" locked="true"/>
    <property name="presentation-mode" type="bool" value="true" locked="true"/>
  </property>
</channel>
EOF

    cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="false" locked="true"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="false" locked="true"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="false" locked="true"/>
  </property>
</channel>
EOF

    local desk
    for desk in xfce4-power-manager.desktop xfce4-screensaver.desktop \
                xscreensaver.desktop light-locker.desktop; do
        cat > "/etc/xdg/autostart/$desk" <<'EOF'
[Desktop Entry]
Hidden=true
EOF
    done

    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        case "$(readlink "/etc/systemd/system/$t")" in
            /dev/null|dev/null) ;;
            *)
                echo "ERROR: $t is not masked" >&2
                exit 1
                ;;
        esac
    done
    grep -q 'autosuspend=-1' /etc/modprobe.d/tesla-linux-no-autosuspend.conf \
        || { echo "ERROR: usbcore autosuspend=-1 did not stick" >&2; exit 1; }
    grep -q 'ATTR{power/control}="on"' /etc/udev/rules.d/50-tesla-linux-usb-power.rules \
        || { echo "ERROR: USB power/control=on udev rule did not stick" >&2; exit 1; }
    if grep -Eiv '^[[:space:]]*#' /etc/udev/rules.d/50-tesla-linux-usb-power.rules \
        | grep -Eiq 'ID_SEAT|seat0|GrabDevice'; then
        echo "ERROR: USB power udev rule must not assign seats or GrabDevice" >&2
        exit 1
    fi
    grep -q 'name="inactivity-on-ac" type="uint" value="0"' \
        /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml \
        || { echo "ERROR: XFCE power-manager inactivity-on-ac is not 0" >&2; exit 1; }
    grep -q 'Hidden=true' /etc/xdg/autostart/xfce4-power-manager.desktop \
        || { echo "ERROR: xfce4-power-manager autostart is not Hidden" >&2; exit 1; }
}

# No background auto-patch. File-level so bake chroot and live install both
# stick without a running systemd. Manual `apt` / `apt-get` stay available.
ensure_no_unattended() {
    local u
    mkdir -p /etc/systemd/system /etc/apt/apt.conf.d \
             /etc/systemd/system/multi-user.target.wants \
             /etc/systemd/system/timers.target.wants
    for u in unattended-upgrades.service unattended-upgrades.timer \
             apt-daily.timer apt-daily.service \
             apt-daily-upgrade.timer apt-daily-upgrade.service; do
        ln -sfn /dev/null "/etc/systemd/system/$u"
        rm -f "/etc/systemd/system/multi-user.target.wants/$u" \
              "/etc/systemd/system/timers.target.wants/$u"
    done

    cat > /etc/apt/apt.conf.d/99tesla-linux-no-unattended <<'EOF'
// Tesla Linux appliance: no background auto-patch.
// Operators still run apt / apt-get by hand.
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

    for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
             apt-daily.service apt-daily-upgrade.service unattended-upgrades.timer; do
        case "$(readlink "/etc/systemd/system/$u")" in
            /dev/null|dev/null) ;;
            *)
                echo "ERROR: $u is not masked" >&2
                exit 1
                ;;
        esac
    done
    grep -q 'APT::Periodic::Unattended-Upgrade "0"' \
        /etc/apt/apt.conf.d/99tesla-linux-no-unattended \
        || { echo "ERROR: Unattended-Upgrade 0 did not stick" >&2; exit 1; }
    grep -q 'APT::Periodic::Update-Package-Lists "0"' \
        /etc/apt/apt.conf.d/99tesla-linux-no-unattended \
        || { echo "ERROR: Update-Package-Lists 0 did not stick" >&2; exit 1; }
}

# Ubuntu's archive firefox is a snap stub (fails offline / in-car). Prefer the
# Mozilla apt .deb so XFCE has a real /usr/bin/firefox + desktop entry.
firefox_is_snap_stub() {
    local bin="$1" target
    [ -e "$bin" ] || return 1
    target="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
    case "$target" in
        /snap/*|*/snap/*)
            return 0
            ;;
    esac
    if grep -Eiq 'snap[[:space:]]+run[[:space:]]+firefox|/snap/bin/firefox|ubuntu-browser-launcher' \
            "$bin" 2>/dev/null; then
        return 0
    fi
    return 1
}

ensure_firefox_deb_apt() {
    local key=/etc/apt/keyrings/packages.mozilla.org.asc
    local fp=""
    export DEBIAN_FRONTEND=noninteractive
    install -d -m0755 /etc/apt/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        apt-get install -y -q --no-install-recommends ca-certificates curl
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$MOZILLA_APT_KEY_URL" -o "$key"
    else
        wget -qO "$key" "$MOZILLA_APT_KEY_URL"
    fi
    chmod 644 "$key"
    if command -v gpg >/dev/null 2>&1; then
        fp="$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
        [ "$fp" = "$MOZILLA_APT_FP" ] \
            || { echo "ERROR: Mozilla apt key fingerprint mismatch" >&2; exit 1; }
    fi
    cat > /etc/apt/sources.list.d/mozilla.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF
    cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF
}

ensure_firefox_deb() {
    ensure_firefox_deb_apt
    if [ -e /usr/bin/firefox ] && ! firefox_is_snap_stub /usr/bin/firefox \
       && [ -f /usr/share/applications/firefox.desktop ]; then
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends firefox
}

# Host-side / live / bake: Mozilla apt Firefox .deb, XFCE desktop entry,
# not the Ubuntu snap stub. Optional prefix ($1) is an image / plant root.
verify_firefox() {
    local r="${1:-}"
    local bin desk list pin

    case "$PKGS" in
        *firefox*) ;;
        *)
            echo "ERROR: PKGS missing firefox" >&2
            exit 1
            ;;
    esac

    list="$r/etc/apt/sources.list.d/mozilla.list"
    [ -f "$list" ] || { echo "ERROR: missing Mozilla apt source" >&2; exit 1; }
    grep -q 'packages.mozilla.org' "$list" \
        || { echo "ERROR: mozilla.list is not packages.mozilla.org" >&2; exit 1; }

    pin="$r/etc/apt/preferences.d/mozilla"
    [ -f "$pin" ] || { echo "ERROR: missing Mozilla apt pin" >&2; exit 1; }
    grep -q 'Pin: origin packages.mozilla.org' "$pin" \
        || { echo "ERROR: Mozilla apt pin origin missing" >&2; exit 1; }
    grep -q 'Pin-Priority: 1000' "$pin" \
        || { echo "ERROR: Mozilla apt pin is not 1000" >&2; exit 1; }
    grep -q 'Pin: release o=Ubuntu' "$pin" \
        || { echo "ERROR: Ubuntu firefox snap stub is not pinned out" >&2; exit 1; }

    bin="$r/usr/bin/firefox"
    [ -e "$bin" ] || { echo "ERROR: firefox binary missing" >&2; exit 1; }
    if firefox_is_snap_stub "$bin"; then
        echo "ERROR: firefox is the Ubuntu snap stub" >&2
        exit 1
    fi

    desk="$r/usr/share/applications/firefox.desktop"
    [ -f "$desk" ] || { echo "ERROR: firefox desktop entry missing" >&2; exit 1; }
    grep -qi '^Exec=.*firefox' "$desk" \
        || { echo "ERROR: firefox.desktop has no Exec firefox" >&2; exit 1; }
}

# libinput_drv.so must exist on a real install (live / chroot / mounted bake).
# Fake verify roots may plant the file; skip only when Xorg itself is absent.
libinput_driver_present() {
    local r="${1:-}"
    local p g
    for p in \
        "$r/usr/lib/xorg/modules/input/libinput_drv.so" \
        "$r/usr/lib/aarch64-linux-gnu/xorg/modules/input/libinput_drv.so" \
        "$r/usr/lib/x86_64-linux-gnu/xorg/modules/input/libinput_drv.so"; do
        [ -f "$p" ] && return 0
    done
    for g in "$r"/usr/lib/*/xorg/modules/input/libinput_drv.so; do
        [ -f "$g" ] && return 0
    done
    return 1
}

# Fail the bake/install unless HDMI, web capture, and USB KBM share Xorg :0.
# Optional prefix ($1) is an image root (host-side check of a mounted bake).
# No `|| true` — any miss exits 1.
verify_kbm_on_display0() {
    local r="${1:-}"
    local xorg="$r/etc/systemd/system/tesla-linux-xorg.service"
    local display="$r/etc/X11/xorg.conf.d/10-tesla-linux-display.conf"
    local inp="$r/etc/X11/xorg.conf.d/20-tesla-linux-input.conf"
    local getty_mask="$r/etc/systemd/system/getty@tty1.service"
    local getty_wants="$r/etc/systemd/system/getty.target.wants/getty@tty1.service"

    case "$PKGS" in
        *xserver-xorg-input-libinput*) ;;
        *)
            echo "ERROR: PKGS missing xserver-xorg-input-libinput" >&2
            exit 1
            ;;
    esac

    [ -f "$xorg" ] || { echo "ERROR: missing tesla-linux-xorg.service" >&2; exit 1; }
    grep -q '^ExecStart=/usr/bin/Xorg :0 vt1 ' "$xorg" \
        || { echo "ERROR: tesla-linux-xorg is not Xorg :0 vt1 (HDMI and USB KBM need the console VT)" >&2; exit 1; }
    if grep -Eq '^ExecStart=/usr/bin/Xorg :0 vt7 ' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still on vt7 (HDMI would not show XFCE)" >&2
        exit 1
    fi
    if grep -q -- '-novtswitch' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still has -novtswitch (HDMI may stay on the kernel VT)" >&2
        exit 1
    fi
    if grep -q -- '-seat ' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still overrides the standard seat0 input path" >&2
        exit 1
    fi
    grep -q '^TTYPath=/dev/tty1$' "$xorg" \
        || { echo "ERROR: tesla-linux-xorg does not own /dev/tty1" >&2; exit 1; }
    if grep -Eq '^Conflicts=.*getty@tty1' "$xorg"; then
        echo "ERROR: tesla-linux-xorg must not Conflicts=getty@tty1" >&2
        exit 1
    fi
    if grep -Eq '^ExecStartPost=.*tesla-linux-hdmi-clone' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still ExecStartPost tesla-linux-hdmi-clone (HDMI XFCE is DESCPE)" >&2
        exit 1
    fi

    [ -L "$getty_mask" ] || { echo "ERROR: getty@tty1 is unmasked (not a mask symlink)" >&2; exit 1; }
    case "$(readlink "$getty_mask")" in
        /dev/null|dev/null) ;;
        *)
            echo "ERROR: getty@tty1 is unmasked; HDMI login would replace XFCE" >&2
            exit 1
            ;;
    esac
    if [ -e "$getty_wants" ]; then
        echo "ERROR: getty@tty1 still in getty.target.wants (login would replace XFCE)" >&2
        exit 1
    fi

    [ -f "$display" ] || { echo "ERROR: missing 10-tesla-linux-display.conf" >&2; exit 1; }
    grep -q 'Driver[[:space:]]*"modesetting"' "$display" \
        || { echo "ERROR: HDMI display is not using the vc4 modesetting driver" >&2; exit 1; }
    grep -q 'MatchDriver[[:space:]]*"vc4"' "$display" \
        || { echo "ERROR: HDMI display does not select the vc4 DRM device" >&2; exit 1; }
    grep -q 'PrimaryGPU".*"true"' "$display" \
        || { echo "ERROR: vc4 is not the primary Xorg GPU" >&2; exit 1; }
    grep -q 'PreferredMode".*"1920x1080"' "$display" \
        || { echo "ERROR: HDMI display is not standard 1920x1080" >&2; exit 1; }
    if grep -q 'Driver[[:space:]]*"dummy"' "$display" \
       || [ -e "$r/etc/X11/xorg.conf.d/10-virtual.conf" ]; then
        echo "ERROR: dummy Xorg screen still installed (HDMI and web would differ)" >&2
        exit 1
    fi

    [ -f "$inp" ] || { echo "ERROR: missing 20-tesla-linux-input.conf" >&2; exit 1; }
    grep -q 'Driver[[:space:]]*"libinput"' "$inp" \
        || { echo "ERROR: 20-tesla-linux-input.conf is not Driver libinput" >&2; exit 1; }
    if grep -q 'GrabDevice' "$inp"; then
        echo "ERROR: 20-tesla-linux-input.conf still uses nonstandard GrabDevice" >&2
        exit 1
    fi
    grep -q 'MatchIsKeyboard' "$inp" \
        || { echo "ERROR: 20-tesla-linux-input.conf missing MatchIsKeyboard" >&2; exit 1; }
    grep -q 'MatchIsPointer' "$inp" \
        || { echo "ERROR: 20-tesla-linux-input.conf missing MatchIsPointer" >&2; exit 1; }
    if grep -Eiq 'Driver[[:space:]]*"kbd"' "$inp" "$display"; then
        echo "ERROR: Xorg input uses Driver kbd (binds to the console VT)" >&2
        exit 1
    fi
    if [ -e "$r/etc/udev/rules.d/60-tesla-linux-kbm-seat0.rules" ]; then
        echo "ERROR: custom KBM seat rule still installed; use standard seat0 discovery" >&2
        exit 1
    fi

    # Require the driver when this looks like a real Xorg install (or a planted test file).
    if [ -e "$r/usr/bin/Xorg" ] || [ -d "$r/usr/lib/xorg" ] || [ -z "$r" ]; then
        libinput_driver_present "$r" \
            || { echo "ERROR: xserver-xorg-input-libinput did not stick (libinput_drv.so missing)" >&2; exit 1; }
    fi
}

# Host-side / live / bake: sleep targets masked, logind idle ignore, XFCE
# power-manager will not suspend, USB autosuspend off. Optional prefix ($1).
verify_never_sleep() {
    local r="${1:-}"
    local t rl logind udev xfce desk display
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        [ -L "$r/etc/systemd/system/$t" ] \
            || { echo "ERROR: $t is unmasked (not a mask symlink)" >&2; exit 1; }
        rl="$(readlink "$r/etc/systemd/system/$t")"
        case "$rl" in
            /dev/null|dev/null) ;;
            *)
                echo "ERROR: $t is unmasked (readlink='$rl')" >&2
                exit 1
                ;;
        esac
    done

    logind="$r/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf"
    [ -f "$logind" ] || { echo "ERROR: missing logind tesla-linux-hdmi.conf" >&2; exit 1; }
    grep -q '^IdleAction=ignore$' "$logind" \
        || { echo "ERROR: logind IdleAction is not ignore" >&2; exit 1; }

    udev="$r/etc/udev/rules.d/50-tesla-linux-usb-power.rules"
    [ -f "$udev" ] || { echo "ERROR: missing USB power udev rule" >&2; exit 1; }
    grep -q 'ATTR{power/control}="on"' "$udev" \
        || { echo "ERROR: USB udev rule does not set power/control=on" >&2; exit 1; }
    if grep -Eiv '^[[:space:]]*#' "$udev" \
        | grep -Eiq 'ID_SEAT|60-tesla-linux-kbm-seat0|GrabDevice'; then
        echo "ERROR: USB power udev rule must not assign seats or GrabDevice" >&2
        exit 1
    fi
    [ -f "$r/etc/modprobe.d/tesla-linux-no-autosuspend.conf" ] \
        || { echo "ERROR: missing usbcore autosuspend modprobe" >&2; exit 1; }
    grep -q 'autosuspend=-1' "$r/etc/modprobe.d/tesla-linux-no-autosuspend.conf" \
        || { echo "ERROR: usbcore autosuspend is not -1" >&2; exit 1; }

    xfce="$r/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml"
    [ -f "$xfce" ] || { echo "ERROR: missing XFCE power-manager xfconf" >&2; exit 1; }
    grep -q 'name="inactivity-on-ac" type="uint" value="0"' "$xfce" \
        || { echo "ERROR: XFCE power-manager inactivity-on-ac is not 0" >&2; exit 1; }
    grep -q 'name="lid-action-on-ac" type="uint" value="0"' "$xfce" \
        || { echo "ERROR: XFCE power-manager lid-action-on-ac is not 0" >&2; exit 1; }
    grep -q 'name="dpms-enabled" type="bool" value="false"' "$xfce" \
        || { echo "ERROR: XFCE power-manager DPMS is not disabled" >&2; exit 1; }
    desk="$r/etc/xdg/autostart/xfce4-power-manager.desktop"
    [ -f "$desk" ] || { echo "ERROR: missing xfce4-power-manager autostart override" >&2; exit 1; }
    grep -q '^Hidden=true$' "$desk" \
        || { echo "ERROR: xfce4-power-manager autostart is not Hidden" >&2; exit 1; }

    display="$r/etc/X11/xorg.conf.d/10-tesla-linux-display.conf"
    if [ -f "$display" ]; then
        grep -q 'BlankTime".*"0"' "$display" \
            || { echo "ERROR: Xorg BlankTime is not 0 (:0 capture would idle-blank)" >&2; exit 1; }
    fi
    if [ -f "$r/etc/systemd/system/tesla-linux-desktop.service" ]; then
        grep -q 'xset -dpms s off s noblank' "$r/etc/systemd/system/tesla-linux-desktop.service" \
            || { echo "ERROR: desktop does not xset -dpms (capture would idle-blank)" >&2; exit 1; }
    fi
}

# Host-side / live / bake: apt-daily + unattended-upgrades masked;
# Periodic Unattended-Upgrade is 0. Optional prefix ($1).
# Do not mask apt itself — operators still apt by hand.
verify_no_unattended() {
    local r="${1:-}"
    local u rl aptcfg
    for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
             apt-daily.service apt-daily-upgrade.service unattended-upgrades.timer; do
        [ -L "$r/etc/systemd/system/$u" ] \
            || { echo "ERROR: $u is unmasked (not a mask symlink)" >&2; exit 1; }
        rl="$(readlink "$r/etc/systemd/system/$u")"
        case "$rl" in
            /dev/null|dev/null) ;;
            *)
                echo "ERROR: $u is unmasked (readlink='$rl')" >&2
                exit 1
                ;;
        esac
        if [ -e "$r/etc/systemd/system/multi-user.target.wants/$u" ] \
           || [ -e "$r/etc/systemd/system/timers.target.wants/$u" ]; then
            echo "ERROR: $u still enabled in systemd wants" >&2
            exit 1
        fi
    done

    aptcfg="$r/etc/apt/apt.conf.d/99tesla-linux-no-unattended"
    [ -f "$aptcfg" ] || { echo "ERROR: missing 99tesla-linux-no-unattended" >&2; exit 1; }
    grep -q 'APT::Periodic::Unattended-Upgrade "0"' "$aptcfg" \
        || { echo "ERROR: Unattended-Upgrade is not 0" >&2; exit 1; }
    grep -q 'APT::Periodic::Update-Package-Lists "0"' "$aptcfg" \
        || { echo "ERROR: Update-Package-Lists is not 0" >&2; exit 1; }
    grep -q 'APT::Periodic::Download-Upgradeable-Packages "0"' "$aptcfg" \
        || { echo "ERROR: Download-Upgradeable-Packages is not 0" >&2; exit 1; }
    if grep -Eq 'APT::Periodic::Unattended-Upgrade[[:space:]]+"[1-9]' "$aptcfg"; then
        echo "ERROR: Unattended-Upgrade is still enabled" >&2
        exit 1
    fi

    if [ -L "$r/etc/systemd/system/apt.service" ]; then
        case "$(readlink "$r/etc/systemd/system/apt.service")" in
            /dev/null|dev/null)
                echo "ERROR: apt.service is masked (operators must still apt by hand)" >&2
                exit 1
                ;;
        esac
    fi
}

verify_autologin_hdmi() {
    local r="${1:-}"
    local xorg="$r/etc/systemd/system/tesla-linux-xorg.service"
    local desk="$r/etc/systemd/system/tesla-linux-desktop.service"
    local wlan="$r/etc/systemd/system/tesla-linux-wlan.service"
    local display="$r/etc/X11/xorg.conf.d/10-tesla-linux-display.conf"
    local getty_unit="$r/etc/systemd/system/getty@tty1.service"
    local getty_wants="$r/etc/systemd/system/getty.target.wants/getty@tty1.service"
    local logind="$r/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf"
    local rl

    [ -f "$xorg" ] || { echo "ERROR: missing tesla-linux-xorg.service" >&2; exit 1; }
    grep -q '^ExecStart=/usr/bin/Xorg :0 vt1 ' "$xorg" \
        || { echo "ERROR: tesla-linux-xorg is not Xorg :0 vt1 (HDMI and USB KBM need the console VT)" >&2; exit 1; }
    if grep -Eq '^ExecStart=/usr/bin/Xorg :0 vt7 ' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still on vt7 (HDMI would not show XFCE)" >&2
        exit 1
    fi
    if grep -q -- '-novtswitch' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still has -novtswitch" >&2
        exit 1
    fi
    if grep -Eq '^Conflicts=.*getty@tty1' "$xorg"; then
        echo "ERROR: tesla-linux-xorg Conflicts=getty@tty1 would take HDMI getty down" >&2
        exit 1
    fi
    if grep -Eq '^ExecStartPost=.*tesla-linux-hdmi-clone' "$xorg"; then
        echo "ERROR: tesla-linux-xorg still ExecStartPost tesla-linux-hdmi-clone (HDMI XFCE is DESCPE)" >&2
        exit 1
    fi
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
    grep -q 'xrandr --fb 1088x832 --output HDMI-1 --mode 1920x1080 --scale-from 1088x832 --primary' "$desk" \
        || { echo "ERROR: desktop does not scale logical 1088x832 to HDMI 1080p" >&2; exit 1; }
    if grep -Eq '^(BindsTo|PartOf)=' "$desk"; then
        echo "ERROR: tesla-linux-desktop must not BindsTo/PartOf xorg or display" >&2
        exit 1
    fi

    [ -L "$getty_unit" ] || { echo "ERROR: getty@tty1 is unmasked (not a mask symlink)" >&2; exit 1; }
    case "$(readlink "$getty_unit")" in
        /dev/null|dev/null) ;;
        *)
            echo "ERROR: getty@tty1 is unmasked; HDMI login would replace XFCE" >&2
            exit 1
            ;;
    esac
    if [ -e "$getty_wants" ]; then
        echo "ERROR: getty@tty1 still in getty.target.wants (login would replace XFCE)" >&2
        exit 1
    fi
    [ -f "$logind" ] || { echo "ERROR: missing logind tesla-linux-hdmi.conf" >&2; exit 1; }
    grep -q '^NAutoVTs=0$' "$logind" \
        || { echo "ERROR: logind NAutoVTs is not 0" >&2; exit 1; }
    grep -q '^ReserveVT=0$' "$logind" \
        || { echo "ERROR: logind ReserveVT is not 0 (Xorg vt1 must not fight a reserved getty VT)" >&2; exit 1; }
    grep -q '^IdleAction=ignore$' "$logind" \
        || { echo "ERROR: logind IdleAction is not ignore (appliance must not idle-sleep)" >&2; exit 1; }
    grep -q '^HandleLidSwitch=ignore$' "$logind" \
        || { echo "ERROR: logind HandleLidSwitch is not ignore" >&2; exit 1; }
    grep -q '^HandleSuspendKey=ignore$' "$logind" \
        || { echo "ERROR: logind HandleSuspendKey is not ignore" >&2; exit 1; }
    grep -q '^HandleHibernateKey=ignore$' "$logind" \
        || { echo "ERROR: logind HandleHibernateKey is not ignore" >&2; exit 1; }

    verify_never_sleep "$r"

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

    [ -f "$display" ] || { echo "ERROR: missing 10-tesla-linux-display.conf" >&2; exit 1; }
    grep -q 'PreferredMode".*"1920x1080"' "$display" \
        || { echo "ERROR: HDMI physical mode is not 1920x1080" >&2; exit 1; }
    grep -q 'Driver[[:space:]]*"modesetting"' "$display" \
        || { echo "ERROR: HDMI screen is not vc4/modesetting" >&2; exit 1; }
    grep -q 'PrimaryGPU".*"true"' "$display" \
        || { echo "ERROR: vc4 is not the primary Xorg GPU" >&2; exit 1; }

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

    verify_kbm_on_display0 "$r"
}

# Host-side plantable WAN rebroadcast skeleton (like --verify-kbm).
# Fail-hard: factory AP addr missing, nginx listen 0.0.0.0, NAT helper missing
# when WAN_REBROADCAST is selected. Optional prefix ($1) is an image / plant root.
verify_wan_rebroadcast() {
    local r="${1:-}"
    local wlan_bin apenv nginx_http nginx_https wlan_svc dispatcher src_helper
    src_helper="$(cd "$(dirname "$0")" && pwd)/tesla-linux-wlan.sh"

    if [ -n "$r" ]; then
        wlan_bin="$r/usr/local/sbin/tesla-linux-wlan"
        apenv="$r/etc/tesla-linux/ap.env"
        nginx_http="$r/etc/nginx/tl-http-server.conf"
        nginx_https="$r/etc/nginx/tl-https-server.conf"
        wlan_svc="$r/etc/systemd/system/tesla-linux-wlan.service"
        dispatcher="$r/etc/NetworkManager/dispatcher.d/99-tesla-linux-wlan"
    else
        wlan_bin="/usr/local/sbin/tesla-linux-wlan"
        [ -f "$wlan_bin" ] || wlan_bin="$src_helper"
        apenv="/etc/tesla-linux/ap.env"
        [ -f "$apenv" ] || apenv="$(cd "$(dirname "$0")" && pwd)/ap.env"
        nginx_http="/etc/nginx/tl-http-server.conf"
        nginx_https="/etc/nginx/tl-https-server.conf"
        wlan_svc="/etc/systemd/system/tesla-linux-wlan.service"
        [ -f "$wlan_svc" ] || wlan_svc="$(cd "$(dirname "$0")" && pwd)/tesla-linux-wlan.service"
        dispatcher="/etc/NetworkManager/dispatcher.d/99-tesla-linux-wlan"
    fi

    [ -f "$wlan_bin" ] || { echo "ERROR: missing tesla-linux-wlan helper ($wlan_bin)" >&2; exit 1; }
    [ -f "$apenv" ] || { echo "ERROR: missing ap.env ($apenv)" >&2; exit 1; }

    grep -q '^AP_ADDR=10.42.0.1' "$apenv" \
        || { echo "ERROR: AP factory addr missing (expected AP_ADDR=10.42.0.1)" >&2; exit 1; }
    grep -q '^ETH_ADDR=10.42.1.1' "$apenv" \
        || { echo "ERROR: ethernet factory addr missing (expected ETH_ADDR=10.42.1.1)" >&2; exit 1; }
    grep -q '^AP_SSID=TeslaLinux' "$apenv" \
        || { echo "ERROR: AP_SSID is not TeslaLinux" >&2; exit 1; }

    grep -q 'apply_wan_nat' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing apply_wan_nat" >&2; exit 1; }
    grep -Eq 'masquerade|MASQUERADE' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing NAT/masquerade helper" >&2; exit 1; }
    grep -q 'cmd_wan_up' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing wan-ap" >&2; exit 1; }
    grep -q 'wan-ap|wan-rebroadcast|wan-up' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing wan-ap / wan-rebroadcast" >&2; exit 1; }
    grep -q 'wan-off|wan-down' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing wan-off" >&2; exit 1; }
    grep -q 'mode.json' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan does not honor /etc/tesla-linux/mode.json" >&2; exit 1; }
    grep -q 'wan_mode_on' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing wan_mode_on" >&2; exit 1; }
    grep -q '1286:4e3c' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing LTE USB 1286:4e3c" >&2; exit 1; }
    grep -q 'cdc_ether' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing cdc_ether LTE uplink" >&2; exit 1; }
    grep -q 'ensure_lte_wan' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing ensure_lte_wan" >&2; exit 1; }
    grep -q 'leave_station' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing leave_station (WAN must not dual station+AP)" >&2; exit 1; }
    grep -q 'start_hostapd_ap' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing start_hostapd_ap (nl80211 settle)" >&2; exit 1; }
    grep -q 'managed no' "$wlan_bin" \
        || { echo "ERROR: tesla-linux-wlan missing NM managed no before hostapd" >&2; exit 1; }
    awk '/^write_hostapd_conf\(\)/,/^}/' "$wlan_bin" | grep -q '^channel=6$' \
        || { echo "ERROR: hostapd channel default must stay 6 (do not invent channel)" >&2; exit 1; }
    if awk '/^cmd_eth_up\(\)/,/^}/' "$wlan_bin" | grep -Eq 'ipv4_method=auto|ipv4\.method auto|never_default=no'; then
        echo "ERROR: cmd_eth_up converts factory eth to DHCP auto (wan-ap must keep 10.42.1.1)" >&2
        exit 1
    fi
    awk '/^cmd_eth_up\(\)/,/^}/' "$wlan_bin" | grep -q 'ipv4.method manual' \
        || { echo "ERROR: cmd_eth_up missing ipv4.method manual lock" >&2; exit 1; }
    awk '/^cmd_eth_up\(\)/,/^}/' "$wlan_bin" | grep -q 'ipv4.never-default yes' \
        || { echo "ERROR: cmd_eth_up missing never-default yes lock" >&2; exit 1; }
    grep -q 'ignore_broadcast_ssid=0' "$wlan_bin" \
        || { echo "ERROR: TeslaLinux SSID would be hidden" >&2; exit 1; }
    if awk '/^write_nginx_servers\(\)/,/^}/' "$wlan_bin" | grep -Eq 'listen 0\.0\.0\.0|listen 80;|listen \[::\]'; then
        echo "ERROR: tesla-linux-wlan write_nginx_servers would bind nginx to 0.0.0.0" >&2
        exit 1
    fi

    if grep -q '^WAN_REBROADCAST=1' "$apenv" \
       || { [ -f "${r}/etc/tesla-linux/mode.json" ] && grep -q 'wan_rebroadcast' "${r}/etc/tesla-linux/mode.json"; }; then
        grep -Eq 'masquerade|MASQUERADE' "$wlan_bin" \
            || { echo "ERROR: WAN mode selected but NAT/masquerade helper missing" >&2; exit 1; }
    fi

    if [ -f "$nginx_http" ] && grep -Eq '0\.0\.0\.0|listen[[:space:]]+80;|listen[[:space:]]+\[::\]' "$nginx_http"; then
        echo "ERROR: nginx listen includes 0.0.0.0 / world bind ($nginx_http)" >&2
        exit 1
    fi
    if [ -f "$nginx_https" ] && grep -Eq '0\.0\.0\.0|listen[[:space:]]+443' "$nginx_https"; then
        if grep -Eq '0\.0\.0\.0|listen[[:space:]]+443;|listen[[:space:]]+\[::\]' "$nginx_https"; then
            echo "ERROR: nginx TLS listen includes 0.0.0.0 / world bind ($nginx_https)" >&2
            exit 1
        fi
    fi

    if [ -f "$wlan_svc" ]; then
        if grep -Eiq '^Before=.*nginx\.service' "$wlan_svc"; then
            echo "ERROR: tesla-linux-wlan must not Before=nginx.service" >&2
            exit 1
        fi
        if grep -Eiq '^After=.*tesla-linux-(xorg|desktop)|^Requires=.*tesla-linux-(xorg|desktop)' "$wlan_svc"; then
            echo "ERROR: tesla-linux-wlan must not After/Requires xorg or desktop" >&2
            exit 1
        fi
    fi

    if [ -f "$dispatcher" ]; then
        grep -q 'tesla-linux-wlan' "$dispatcher" \
            || { echo "ERROR: NM dispatcher missing tesla-linux-wlan" >&2; exit 1; }
    fi
}

# --verify-autologin / --verify-kbm [root] checks a live box or a mounted image.
# Do not run ensure_*. KBM-on-:0 is part of the same fail-hard gate.
if [ "${1:-}" = "--verify-autologin" ] || [ "${1:-}" = "--verify-kbm" ]; then
    verify_autologin_hdmi "${2:-}"
    exit 0
fi

if [ "${1:-}" = "--verify-wan" ]; then
    verify_wan_rebroadcast "${2:-}"
    exit 0
fi

if [ "${1:-}" = "--verify-no-unattended" ]; then
    verify_no_unattended "${2:-}"
    exit 0
fi

if [ "${1:-}" = "--verify-firefox" ]; then
    verify_firefox "${2:-}"
    exit 0
fi

if [ "${1:-}" = "--ensure-firefox-apt" ]; then
    ensure_firefox_deb_apt
    exit 0
fi

if [ "${1:-}" = "--print-packages" ]; then echo "$PKGS"; exit 0; fi

ensure_factory_user
purge_cloud_init_ubuntu
ensure_sshd_qemu
ensure_serial_console
ensure_graphical_vt1
ensure_hdmi_mode
ensure_never_sleep
ensure_no_unattended
ensure_firefox_deb
set_graphical_default
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
# Broadway software H.264 (HTTP / no VideoDecoder). Worker loads avc.wasm
# next to Decoder.js; main-thread Decoder fetches /avc.wasm (page-relative).
if [ -d "$HERE/broadway" ]; then
    install -d /var/www/tl/broadway
    for f in Decoder.js Player.js YUVCanvas.js avc.wasm LICENSE AUTHORS NOTICE; do
        [ -f "$HERE/broadway/$f" ] && install -m644 "$HERE/broadway/$f" /var/www/tl/broadway/$f
    done
    [ -f "$HERE/broadway/avc.wasm" ] && install -m644 "$HERE/broadway/avc.wasm" /var/www/tl/avc.wasm
fi

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
WAN_REBROADCAST=0
EOF
fi
install -m755 "$HERE/tesla-linux-wlan.sh" /usr/local/sbin/tesla-linux-wlan
# Remove the old dummy/clone/tmux display experiments. HDMI is Xorg Screen 0.
rm -f /usr/local/sbin/tesla-linux-hdmi-clone \
      /usr/local/sbin/tesla-linux-hdmi-banner \
      /etc/systemd/system/tesla-linux-hdmi-banner.service \
      /etc/systemd/system/multi-user.target.wants/tesla-linux-hdmi-banner.service \
      /etc/update-motd.d/99-tesla-linux \
      /etc/profile.d/99-tesla-linux-tmux.sh
install -m644 "$HERE/tesla-linux-wlan.service" /etc/systemd/system/tesla-linux-wlan.service
install -m755 "$HERE/ta_wlan_api.py" /usr/local/sbin/ta_wlan_api.py
install -m644 "$HERE/tesla-linux-wlan-api.service" /etc/systemd/system/tesla-linux-wlan-api.service

# NM dispatcher: wifi → maybe-ap (station else TeslaLinux AP); ethernet → nginx-bind
# WAN rebroadcast: ethernet/USB LTE up may bring a DHCP WAN — refresh wan-up (AP stays, NAT).
# wan-ap leaves station first — never station+AP dual.
install -d /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/99-tesla-linux-wlan <<'EOF'
#!/bin/sh
# WAVE 1 — wifi: maybe-ap. ethernet/VM tap: nginx-bind only (not 0.0.0.0).
# WAN mode: maybe-ap → wan-up; ethernet/USB LTE (enx*/cdc_ether) up refreshes NAT.
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
        if [ -f /run/tesla-linux-wan ] \
           || grep -q '^WAN_REBROADCAST=1' /etc/tesla-linux/ap.env 2>/dev/null \
           || grep -q 'wan_rebroadcast' /etc/tesla-linux/mode.json 2>/dev/null; then
            /usr/local/sbin/tesla-linux-wlan wan-ap
        fi
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
# /api/reboot → same loopback :9094 (system reboot kick; next boot joins saved WLAN).
# /api/mode → same loopback :9094 (WAN-rebroadcast intent; persist only).
# /api/lte → same loopback :9094 (GET stick health for the Frontend LTE pane).
root /var/www/tl;
index index.html;
location ~* \.wasm$ { default_type application/wasm; }
location /sockets/display     { proxy_pass http://127.0.0.1:9091; include /etc/nginx/tl-ws.conf; }
location /sockets/touchscreen { proxy_pass http://127.0.0.1:9092; include /etc/nginx/tl-ws.conf; }
location /sockets/audio       { proxy_pass http://127.0.0.1:9093; include /etc/nginx/tl-ws.conf; }
location /api/wlan {
    proxy_pass http://127.0.0.1:9094;
    proxy_set_header Host $host;
    proxy_set_header Content-Type $http_content_type;
    client_max_body_size 8k;
}
location /api/reboot {
    proxy_pass http://127.0.0.1:9094;
    proxy_set_header Host $host;
    client_max_body_size 1k;
}
location /api/mode {
    proxy_pass http://127.0.0.1:9094;
    proxy_set_header Host $host;
    proxy_set_header Content-Type $http_content_type;
    client_max_body_size 8k;
}
location /api/lte {
    proxy_pass http://127.0.0.1:9094;
    proxy_set_header Host $host;
    client_max_body_size 1k;
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

# One display: vc4 HDMI is the Xorg :0 screen captured by the web backend.
# HDMI uses standard 1080p60 timing; RandR scales the logical 1088x832 desktop.
install -d /etc/X11/xorg.conf.d
rm -f /etc/X11/xorg.conf.d/10-virtual.conf /etc/X11/xorg.conf.d/99-vc4.conf
cat > /etc/X11/xorg.conf.d/10-tesla-linux-display.conf <<'EOF'
Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "OutputClass"
    Identifier  "TeslaLinuxVC4"
    MatchDriver "vc4"
    Driver      "modesetting"
    Option      "PrimaryGPU" "true"
    Option      "Monitor-HDMI-1" "TeslaLinuxHDMI"
EndSection

Section "Monitor"
    Identifier  "TeslaLinuxHDMI"
    HorizSync   28.0-80.0
    VertRefresh 48.0-75.0
    Option "PreferredMode" "1920x1080"
EndSection

EOF
# USB HID follows normal seat0 discovery into the same visible Xorg :0.
# Do not force a custom udev seat and do not use the old GrabDevice experiment.
cat > /etc/X11/xorg.conf.d/20-tesla-linux-input.conf <<'EOF'
Section "InputClass"
    Identifier "TeslaLinux keyboard"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "TeslaLinux pointer"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "TeslaLinux touchpad"
    MatchIsTouchpad "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection
EOF

# --- uinput (virtual touch device) -------------------------------------------
echo uinput > /etc/modules-load.d/uinput.conf
echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' \
    > /etc/udev/rules.d/99-uinput.rules
usermod -aG input "$TL_USER"

rm -f /etc/udev/rules.d/60-tesla-linux-kbm-seat0.rules

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
Description=Tesla Linux — HDMI and web X server
After=systemd-user-sessions.service systemd-udevd.service systemd-logind.service
Before=tesla-linux-desktop.service
# HDMI, web capture, and USB KBM share Xorg :0 on vt1.
# getty@tty1 is masked; no dummy display, clone, tmux, or second seat.
# X and AP stay independent. Do not wait on tesla-linux-wlan.

[Service]
# teslalinux session dir so xfce4-session has XDG_RUNTIME_DIR if linger is late.
ExecStartPre=/bin/sh -c 'install -d -m700 -o $TL_USER -g $TL_USER /run/user/$TL_UID'
ExecStart=/usr/bin/Xorg :0 vt1 -keeptty -ac -noreset -nolisten tcp
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
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
ExecStartPre=/bin/sh -c 'DISPLAY=:0 xrandr --fb 1088x832 --output HDMI-1 --mode 1920x1080 --scale-from 1088x832 --primary'
ExecStartPre=/bin/sh -c 'DISPLAY=:0 xset -dpms s off s noblank'
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
# HDMI, web capture, and USB KBM share XFCE on Xorg :0 / vt1.
ensure_graphical_vt1
ensure_never_sleep
ensure_no_unattended

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
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    systemctl mask unattended-upgrades.service unattended-upgrades.timer \
                   apt-daily.timer apt-daily.service \
                   apt-daily-upgrade.timer apt-daily-upgrade.service
    systemctl enable tesla-linux-xorg tesla-linux-desktop tesla-linux-display \
                     tesla-linux-touch tesla-linux-audio >/dev/null 2>&1
    /usr/local/sbin/tesla-linux-wlan eth-up >/dev/null 2>&1 || true
    echo "==> enabled. start with: systemctl start tesla-linux-xorg tesla-linux-desktop tesla-linux-display tesla-linux-touch tesla-linux-audio tesla-linux-wlan tesla-linux-wlan-api"
else
    echo "==> installed (chroot mode; units symlinked into graphical.target.wants + multi-user.target.wants)"
fi

# Fail the bake/install if autologin XFCE / KBM-on-:0 did not stick.
verify_autologin_hdmi
# Fail the bake/install if WAN rebroadcast skeleton (AP factory / nginx / NAT) did not stick.
verify_wan_rebroadcast
# Fail the bake/install if background apt auto-patch is still enabled.
verify_no_unattended
# Fail the bake/install if Mozilla apt Firefox / XFCE desktop entry did not stick.
verify_firefox
