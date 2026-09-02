#!/usr/bin/env bash
# Tesla Linux — bake a flashable Raspberry Pi image (Pi 4 8 GB only).
#
# Takes the stock Ubuntu Server arm64 Pi image, grows it, chroots in via
# qemu-aarch64 (binfmt), installs the streaming stack, rips out cloud-init,
# switches to NetworkManager, and repacks to .img.xz for Raspberry Pi Imager.
#
# Run on the build VM as root:   sudo ./build-image.sh
#
# Requires: qemu-user-static binfmt-support parted e2fsprogs xz-utils curl
set -euo pipefail

UBUNTU_REL="${UBUNTU_REL:-26.04}"
BASE_URL="https://cdimage.ubuntu.com/releases/${UBUNTU_REL}/release"
BASE_IMG="ubuntu-${UBUNTU_REL}-preinstalled-server-arm64+raspi.img"
WORK="${WORK:-$HOME/tl-build}"
SRC="${SRC:-$HOME/tl-src}"          # install-tesla-linux.sh + backends + html
OUT="${OUT:-$WORK/out}"
STAMP="$(date +%Y%m%d)"
IMGNAME="tesla-linux-${STAMP}-pi.img"
GROW_GB="${GROW_GB:-4}"
MNT="$WORK/mnt"

log(){ echo -e "\n\033[1;36m==> $*\033[0m"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$SRC/install-tesla-linux.sh" ] || die "missing $SRC/install-tesla-linux.sh"

mkdir -p "$WORK" "$OUT" "$MNT"

# ---------------------------------------------------------------- cleanup ----
LOOP=""
cleanup(){
  set +e
  mountpoint -q "$MNT/boot/firmware" && umount "$MNT/boot/firmware"
  for m in dev/pts dev proc sys run; do mountpoint -q "$MNT/$m" && umount -l "$MNT/$m"; done
  mountpoint -q "$MNT" && umount "$MNT"
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
  set -e
}
trap cleanup EXIT

# ------------------------------------------------------------ fetch base -----
log "fetching base image ($UBUNTU_REL)"
cd "$WORK"
if [ ! -f "$BASE_IMG" ]; then
  [ -f "$BASE_IMG.xz" ] || curl -fL --retry 3 -o "$BASE_IMG.xz" "$BASE_URL/$BASE_IMG.xz"
  xz -dk "$BASE_IMG.xz"
fi
cp --reflink=auto "$BASE_IMG" "$WORK/$IMGNAME"

# --------------------------------------------------------------- grow fs -----
log "growing image by ${GROW_GB}G"
truncate -s "+${GROW_GB}G" "$WORK/$IMGNAME"
LOOP=$(losetup --show -fP "$WORK/$IMGNAME")
parted -s "$LOOP" resizepart 2 100%
e2fsck -fy "${LOOP}p2" >/dev/null 2>&1 || true
resize2fs "${LOOP}p2" >/dev/null

# ----------------------------------------------------------------- mount -----
log "mounting"
mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "${LOOP}p1" "$MNT/boot/firmware"
for m in dev dev/pts proc sys run; do mount --bind "/$m" "$MNT/$m"; done
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

# --------------------------------------------------------------- payload -----
log "staging payload"
mkdir -p "$MNT/tmp/tl-src"
cp "$SRC"/install-tesla-linux.sh "$SRC"/ta_*.py "$SRC"/*.html \
   "$SRC"/tesla-linux-wlan.sh "$SRC"/tesla-linux-wlan.service \
   "$SRC"/tesla-linux-wlan-api.service "$SRC"/ap.env \
   "$SRC"/tesla-linux-hdmi-banner "$SRC"/tesla-linux-hdmi-banner.service \
   "$MNT/tmp/tl-src/" 2>/dev/null || true
# Stage authorized_keys for teslalinux (never print the key). Not ubuntu — ubuntu is DOA.
if [ -f "$SRC/authorized_keys" ]; then
  cp "$SRC/authorized_keys" "$MNT/tmp/tl-src/authorized_keys"
fi
chmod +x "$MNT/tmp/tl-src/install-tesla-linux.sh" "$MNT/tmp/tl-src/tesla-linux-wlan.sh" \
         "$MNT/tmp/tl-src/tesla-linux-hdmi-banner"
# HDMI clone is DESCPE — do not stage or install tesla-linux-hdmi-clone.

# ---------------------------------------------------------------- chroot -----
log "provisioning inside chroot (qemu-aarch64)"
cat > "$MNT/tmp/provision.sh" <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "--- inside: $(uname -m) ---"

# cloud-init OUT (boot hangs, broken Imager customisation, recreates ubuntu)
apt-get purge -y cloud-init cloud-init-base cloud-guest-utils >/dev/null 2>&1 || true
rm -rf /etc/cloud /var/lib/cloud
systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true

apt-get update -q
# NetworkManager IN (netplan/networkd out — NM is what the onboarding portal drives)
apt-get install -y -q --no-install-recommends network-manager avahi-daemon libnss-mdns

PKGS=$(/tmp/tl-src/install-tesla-linux.sh --print-packages)
echo "installing: $PKGS"
apt-get install -y -q --no-install-recommends $PKGS

# hand all interfaces to NetworkManager
rm -f /etc/netplan/*.yaml
cat > /etc/netplan/01-network-manager-all.yaml <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 600 /etc/netplan/01-network-manager-all.yaml
systemctl enable NetworkManager >/dev/null 2>&1 || true

# stack + units (chroot mode: no running systemd)
# install writes teslalinux/chpasswd, graphical.target symlink, ssh-keygen -A,
# serial-getty, nginx (AP/station/ethernet binds only — never 0.0.0.0) + wlan.
/tmp/tl-src/install-tesla-linux.sh --no-start
# Autologin XFCE / getty-not-on-HDMI — fail the chroot if it did not stick.
/tmp/tl-src/install-tesla-linux.sh --verify-autologin

# Fail the bake if factory login / default.target / ssh host keys did not stick.
id teslalinux >/dev/null
hash="$(getent shadow teslalinux | cut -d: -f2)"
case "$hash" in ''|'*'|'!'|'!*'|'!!') echo "ERROR: teslalinux password missing" >&2; exit 1;; esac
id ubuntu >/dev/null 2>&1 && { echo "ERROR: ubuntu user still present" >&2; exit 1; }
rl="$(readlink /etc/systemd/system/default.target)"
case "$rl" in */graphical.target|graphical.target) ;; *) echo "ERROR: default.target is $rl" >&2; exit 1;; esac
ls /etc/ssh/ssh_host_*_key >/dev/null
# cmdline stays console=serial0,115200 console=tty1 — do not rewrite it.

# identity — teslalinux.local via existing avahi-daemon (do not add a second mDNS stack)
echo teslalinux > /etc/hostname
sed -i 's/^127.0.1.1.*/127.0.1.1\tteslalinux/' /etc/hosts || echo "127.0.1.1 teslalinux" >> /etc/hosts
systemctl enable avahi-daemon >/dev/null 2>&1 || true

# first boot: per-device TLS cert + optional config from the FAT boot partition
cat > /usr/local/sbin/tesla-linux-firstboot <<'EOF'
#!/bin/sh
set -e
CONF=/boot/firmware/tesla-linux.conf
# Static ethernet 10.42.1.1/24 before cert SAN / nginx (hostname stays teslalinux).
/usr/local/sbin/tesla-linux-wlan eth-up >/dev/null 2>&1 || true
# per-device self-signed cert (never ship a shared private key)
if [ ! -f /etc/nginx/certs/tl.crt ]; then
    IP=$(hostname -I | awk '{print $1}')
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/nginx/certs/tl.key -out /etc/nginx/certs/tl.crt \
      -subj "/CN=$(hostname)" \
      -addext "subjectAltName=DNS:$(hostname).local,DNS:$(hostname),DNS:localhost,IP:${IP:-127.0.0.1}" >/dev/null 2>&1
    chmod 600 /etc/nginx/certs/tl.key
    # Never systemctl-start or systemctl-restart nginx from this oneshot —
    # Before=nginx plus restart deadlocks with nginx After=firstboot.
    # If nginx is already active, reload the new cert; if not, systemd
    # starts nginx after this unit (After=/Wants= firstboot+wlan).
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -t >/dev/null 2>&1 && nginx -s reload 2>/dev/null || true
    fi
fi
# optional per-device config dropped on the FAT partition when flashing
if [ -f "$CONF" ]; then
    . "$CONF" 2>/dev/null || true
    [ -n "${HOSTNAME_SET:-}" ] && hostnamectl set-hostname "$HOSTNAME_SET"
    if [ -n "${WIFI_SSID:-}" ]; then
        nmcli con add type wifi con-name "$WIFI_SSID" ifname "*" ssid "$WIFI_SSID" \
            802-11-wireless.mode infrastructure \
            connection.autoconnect yes \
            connection.autoconnect-priority 10 2>/dev/null || true
        nmcli con modify "$WIFI_SSID" \
            802-11-wireless.mode infrastructure \
            connection.autoconnect yes \
            connection.autoconnect-priority 10 2>/dev/null || true
        [ -n "${WIFI_PSK:-}" ] && nmcli con modify "$WIFI_SSID" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PSK" 2>/dev/null || true
        nmcli con up "$WIFI_SSID" 2>/dev/null || true
    fi
fi
[ -f /boot/firmware/authorized_keys ] && {
    install -d -m700 /home/teslalinux/.ssh
    cat /boot/firmware/authorized_keys >> /home/teslalinux/.ssh/authorized_keys
    chmod 600 /home/teslalinux/.ssh/authorized_keys
    chown -R teslalinux:teslalinux /home/teslalinux/.ssh
}
exit 0
EOF
chmod +x /usr/local/sbin/tesla-linux-firstboot
cat > /etc/systemd/system/tesla-linux-firstboot.service <<'EOF'
[Unit]
Description=Tesla Linux first-boot provisioning
# nginx After=/Wants= firstboot+wlan (install drop-in) so it starts after the cert.
# Do not Before=nginx — a oneshot that systemctl-restarts nginx deadlocks.
# Keep Before=wlan so eth-up/cert happen before wlan boot.
Before=tesla-linux-wlan.service
Wants=NetworkManager.service
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tesla-linux-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/tesla-linux-firstboot.service \
       /etc/systemd/system/multi-user.target.wants/tesla-linux-firstboot.service

chown -R teslalinux:teslalinux /home/teslalinux
# ssh host keys + PasswordAuthentication: install-tesla-linux.sh (ssh-keygen -A).
systemctl enable ssh >/dev/null 2>&1 || true
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/tl-src /tmp/provision.sh
echo "--- provisioning complete ---"
CHROOT

chmod +x "$MNT/tmp/provision.sh"
chroot "$MNT" /bin/bash /tmp/provision.sh

# Image-on-disk gates (not paper). Fail the bake if any of these are missing.
log "verifying teslalinux / graphical.target / ssh / serial-getty on image"
grep -q '^teslalinux:' "$MNT/etc/passwd" || die "teslalinux missing from passwd"
if grep -q '^ubuntu:' "$MNT/etc/passwd"; then die "ubuntu still in passwd"; fi
_tlhash="$(awk -F: '$1=="teslalinux"{print $2}' "$MNT/etc/shadow")"
case "$_tlhash" in ''|'*'|'!'|'!*'|'!!') die "teslalinux password not set in shadow";; esac
unset _tlhash
_rl="$(readlink "$MNT/etc/systemd/system/default.target")"
case "$_rl" in */graphical.target|graphical.target) ;; *) die "default.target is $_rl";; esac
ls "$MNT/etc/ssh/ssh_host_"*_key >/dev/null || die "ssh host keys missing"
grep -q '^PasswordAuthentication yes$' "$MNT/etc/ssh/sshd_config.d/99-tesla-linux.conf" \
  || die "sshd PasswordAuthentication not yes"
[ -L "$MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service" ] \
  || die "serial-getty@ttyAMA0 not enabled"
[ -L "$MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" ] \
  || die "serial-getty@ttyS0 not enabled"
[ -f "$MNT/etc/systemd/system/serial-getty@.service.d/tl-no-binds-to-dev.conf" ] \
  || die "serial-getty BindsTo drop-in missing"
grep -q '^BindsTo=$' "$MNT/etc/systemd/system/serial-getty@.service.d/tl-no-binds-to-dev.conf" \
  || die "serial-getty drop-in does not clear BindsTo"
if grep -Eq '^BindsTo=dev-' "$MNT/etc/systemd/system/serial-getty@.service.d/tl-no-binds-to-dev.conf"; then
  die "serial-getty still BindsTo the device unit"
fi
if grep -Eq 'no Wi-Fi iface after .*fail so the unit can restart' "$MNT/usr/local/sbin/tesla-linux-wlan"; then
  die "wlan boot still fails the unit solely for missing wifi"
fi
grep -q 'wait_wired_iface' "$MNT/usr/local/sbin/tesla-linux-wlan" \
  || die "wlan missing wait_wired_iface"
grep -q '^User=teslalinux$' "$MNT/etc/systemd/system/tesla-linux-desktop.service" \
  || die "tesla-linux-desktop User is not teslalinux"
[ -d "$MNT/home/teslalinux" ] || die "teslalinux home missing"
if [ -f "$SRC/authorized_keys" ]; then
  [ -f "$MNT/home/teslalinux/.ssh/authorized_keys" ] || die "teslalinux authorized_keys missing"
fi

# Autologin XFCE on :0; USB KBM on that session. HDMI vt1 is the pinned SSH banner.
log "verifying autologin XFCE / KBM-on-:0 / HDMI SSH banner"
"$SRC/install-tesla-linux.sh" --verify-autologin "$MNT"
grep -q '^ExecStart=/usr/bin/Xorg :0 vt7 ' "$MNT/etc/systemd/system/tesla-linux-xorg.service" \
  || die "Xorg is not on vt7"
if grep -Eq '^ExecStart=/usr/bin/Xorg :0 vt1 ' "$MNT/etc/systemd/system/tesla-linux-xorg.service"; then
  die "Xorg still occupies HDMI vt1"
fi
[ "$(readlink "$MNT/etc/systemd/system/getty@tty1.service")" = /dev/null ] \
  || die "getty@tty1 is unmasked (login would bury the SSH banner)"
[ ! -e "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" ] \
  || die "getty@tty1 still in getty.target.wants"
if grep -Eq '^Conflicts=.*getty@tty1' "$MNT/etc/systemd/system/tesla-linux-xorg.service"; then
  die "xorg Conflicts=getty@tty1 would take HDMI getty down"
fi
if grep -Eq '^ExecStartPost=.*tesla-linux-hdmi-clone' "$MNT/etc/systemd/system/tesla-linux-xorg.service"; then
  die "xorg still ExecStartPost tesla-linux-hdmi-clone"
fi
if [ -e "$MNT/usr/local/sbin/tesla-linux-hdmi-clone" ]; then
  die "tesla-linux-hdmi-clone still installed on image"
fi
grep -q '^Environment=DISPLAY=:0$' "$MNT/etc/systemd/system/tesla-linux-desktop.service" \
  || die "desktop is not DISPLAY=:0"
grep -q 'xfce4-session' "$MNT/etc/systemd/system/tesla-linux-desktop.service" \
  || die "desktop is not xfce4-session"
grep -q '^ReserveVT=1$' "$MNT/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf" \
  || die "logind ReserveVT is not 1"
grep -q 'xserver-xorg-input-libinput' <<<"$("$SRC/install-tesla-linux.sh" --print-packages)" \
  || die "PKGS missing xserver-xorg-input-libinput"
grep -q 'GrabDevice' "$MNT/etc/X11/xorg.conf.d/20-tesla-linux-input.conf" \
  || die "Xorg input missing GrabDevice"
if [ ! -f "$MNT/usr/lib/xorg/modules/input/libinput_drv.so" ] \
   && ! ls "$MNT"/usr/lib/*/xorg/modules/input/libinput_drv.so >/dev/null 2>&1; then
  die "libinput_drv.so missing on image"
fi
if grep -Eiq '^After=.*tesla-linux-(xorg|desktop)|^Requires=.*tesla-linux-(xorg|desktop)' \
      "$MNT/etc/systemd/system/tesla-linux-wlan.service"; then
  die "wlan After/Requires xorg or desktop"
fi
if grep -Eiq '^Before=.*nginx\.service' "$MNT/etc/systemd/system/tesla-linux-wlan.service"; then
  die "wlan still Before=nginx.service (deadlock with nginx After=wlan)"
fi
if awk '/^reload_nginx\(\)/,/^}/' "$MNT/usr/local/sbin/tesla-linux-wlan" \
      | grep -Eq 'systemctl[[:space:]]+(restart|start)[[:space:]]+nginx'; then
  die "reload_nginx still systemctl restart nginx"
fi
if grep -Eiq '^Before=.*nginx\.service' "$MNT/etc/systemd/system/tesla-linux-firstboot.service"; then
  die "firstboot still Before=nginx.service (deadlock with nginx After=firstboot)"
fi
if grep -Eq 'systemctl[[:space:]]+(restart|start)[[:space:]]+nginx' \
      "$MNT/usr/local/sbin/tesla-linux-firstboot"; then
  die "firstboot still systemctl restart/start nginx"
fi

# Pinned HDMI SSH banner. Fail if missing or does not name 10.42.1.1 / teslalinux.
log "verifying HDMI SSH banner"
[ -x "$MNT/usr/local/sbin/tesla-linux-hdmi-banner" ] \
  || die "tesla-linux-hdmi-banner missing or not executable"
grep -q '10.42.1.1' "$MNT/usr/local/sbin/tesla-linux-hdmi-banner" \
  || die "hdmi-banner does not mention 10.42.1.1"
grep -q 'teslalinux' "$MNT/usr/local/sbin/tesla-linux-hdmi-banner" \
  || die "hdmi-banner does not mention teslalinux"
[ -f "$MNT/etc/systemd/system/tesla-linux-hdmi-banner.service" ] \
  || die "tesla-linux-hdmi-banner.service missing"
[ -L "$MNT/etc/systemd/system/multi-user.target.wants/tesla-linux-hdmi-banner.service" ] \
  || die "tesla-linux-hdmi-banner not WantedBy multi-user.target"
if grep -Eiq '^PAMName=|^TTYPath=' "$MNT/etc/systemd/system/tesla-linux-hdmi-banner.service"; then
  die "hdmi-banner unit must not take a TTY login seat"
fi
if grep -Eiq '^Before=.*nginx\.service' "$MNT/etc/systemd/system/tesla-linux-hdmi-banner.service"; then
  die "hdmi-banner still Before=nginx.service"
fi
"$MNT/usr/local/sbin/tesla-linux-hdmi-banner" selftest \
  || die "hdmi-banner selftest failed"

# ------------------------------------------------------------------ pack -----
log "packing"
sync
cleanup; trap - EXIT
mv "$WORK/$IMGNAME" "$OUT/$IMGNAME"
xz -T0 -6 -f "$OUT/$IMGNAME"
ls -lh "$OUT/$IMGNAME.xz"
log "DONE -> $OUT/$IMGNAME.xz   (flash with Raspberry Pi Imager -> Use custom)"
