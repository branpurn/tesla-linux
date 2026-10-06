#!/usr/bin/env bash
# Tesla Linux — bake a flashable Raspberry Pi image (Pi 4 8 GB only).
#
# Takes the stock Ubuntu Server arm64 Pi image, grows it, chroots in via
# qemu-aarch64 (binfmt), installs the streaming stack, rips out cloud-init,
# switches to NetworkManager, and repacks to .img.xz for Raspberry Pi Imager.
#
# Run on the build VM as root:   sudo ./build-image.sh
#
# Requires: qemu-user-static binfmt-support parted e2fsprogs xz-utils curl zerofree
#   (zerofree is optional: without it free space is zeroed with a slower dd-fill)
#
# ALLOW_BIG_IMAGE=1  keep going (exit 0) even if the .img.xz is over the
#                    GitHub release-asset budget (MAX_IMG_XZ_BYTES, 2,140,000,000).
set -euo pipefail

UBUNTU_REL="${UBUNTU_REL:-26.04}"
BASE_URL="https://cdimage.ubuntu.com/releases/${UBUNTU_REL}/release"
BASE_IMG="ubuntu-${UBUNTU_REL}-preinstalled-server-arm64+raspi.img"
WORK="${WORK:-$HOME/tl-build}"
SRC="${SRC:-$(cd "$(dirname "$0")" && pwd)}"          # install-tesla-linux.sh + backends + html
OUT="${OUT:-$WORK/out}"
STAMP="$(date +%Y%m%d)"
IMGNAME="tesla-linux-${STAMP}-pi.img"
GROW_GB="${GROW_GB:-4}"
MNT="$WORK/mnt"
# GitHub release assets must be < 2 GiB (2,147,483,648 B); keep headroom.
MAX_IMG_XZ_BYTES=2140000000

log(){ echo -e "\n\033[1;36m==> $*\033[0m"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$SRC/install-tesla-linux.sh" ] || die "missing $SRC/install-tesla-linux.sh"

mkdir -p "$WORK" "$OUT" "$MNT"

# ---------------------------------------------------------------- cleanup ----
LOOP=""
unmount_all(){
  set +e
  mountpoint -q "$MNT/boot/firmware" && umount "$MNT/boot/firmware"
  for m in dev/pts dev proc sys run; do mountpoint -q "$MNT/$m" && umount -l "$MNT/$m"; done
  mountpoint -q "$MNT" && umount "$MNT"
  set -e
}
cleanup(){
  unmount_all
  set +e
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

# Docker Desktop / udev-less hosts: losetup -P may not emit ${LOOP}pN.
# Prefer ${LOOP}pN; fall back to kpartx /dev/mapper/loopNpN.
loop_part() {
  local loop="$1" n="$2" base
  base="$(basename "$loop")"
  if [ -b "${loop}p${n}" ]; then
    printf '%s\n' "${loop}p${n}"
    return 0
  fi
  if [ -b "/dev/mapper/${base}p${n}" ]; then
    printf '%s\n' "/dev/mapper/${base}p${n}"
    return 0
  fi
  return 1
}

ensure_loop_parts() {
  local loop="$1" i
  # Prefer native losetup -P partition nodes. Calling kpartx while those exist
  # makes resize2fs see "Device or resource busy" on ${loop}pN.
  if loop_part "$loop" 1 >/dev/null && loop_part "$loop" 2 >/dev/null; then
    return 0
  fi
  for i in $(seq 1 20); do
    partx -u "$loop" 2>/dev/null || true
    kpartx -u "$loop" 2>/dev/null || true
    kpartx -av "$loop" 2>/dev/null || true
    if loop_part "$loop" 1 >/dev/null && loop_part "$loop" 2 >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

# --------------------------------------------------------------- grow fs -----
log "growing image by ${GROW_GB}G"
truncate -s "+${GROW_GB}G" "$WORK/$IMGNAME"
LOOP=$(losetup --show -fP "$WORK/$IMGNAME")
parted -s "$LOOP" resizepart 2 100%
ensure_loop_parts "$LOOP" || die "loop partitions missing after losetup ($LOOP)"
ROOTDEV="$(loop_part "$LOOP" 2)"
BOOTDEV="$(loop_part "$LOOP" 1)"
e2fsck -fy "$ROOTDEV" >/dev/null 2>&1 || true
resize2fs "$ROOTDEV" >/dev/null

# ----------------------------------------------------------------- mount -----
log "mounting"
mount "$ROOTDEV" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "$BOOTDEV" "$MNT/boot/firmware"
for m in dev dev/pts proc sys run; do mount --bind "/$m" "$MNT/$m"; done
rm -f "$MNT/etc/resolv.conf"; cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || cp /etc/resolv.conf "$MNT/etc/resolv.conf"
# qemu-user chroot: binfmt F-flag uses the host binary; copy anyway for non-F.
if [ -x /usr/bin/qemu-aarch64-static ]; then
  mkdir -p "$MNT/usr/bin"
  cp -a /usr/bin/qemu-aarch64-static "$MNT/usr/bin/qemu-aarch64-static"
fi

# --------------------------------------------------------------- payload -----
log "staging payload"
mkdir -p "$MNT/tmp/tl-src"
cp "$SRC"/install-tesla-linux.sh "$SRC"/install-chromium-hwdec.sh "$SRC"/install-chromium-widevine.sh "$SRC"/ta_*.py "$SRC"/*.html \
   "$SRC"/tesla-linux-wlan.sh "$SRC"/tesla-linux-wlan.service \
   "$SRC"/tesla-linux-wlan-api.service "$SRC"/ap.env \
   "$SRC"/99-tesla-linux-lte.rules \
   "$SRC"/tesla-linux-lte-dhcp.service "$SRC"/tesla-linux-lte-dhcp.timer \
   "$SRC"/tesla-linux-alias.service "$SRC"/tesla-linux-alias.nft \
   "$SRC"/tl-screen-guard.sh "$SRC"/tesla-linux-screen-guard.service \
   "$MNT/tmp/tl-src/" 2>/dev/null || true
# Stage authorized_keys for teslalinux (never print the key). Not ubuntu — ubuntu is DOA.
if [ -f "$SRC/authorized_keys" ]; then
  cp "$SRC/authorized_keys" "$MNT/tmp/tl-src/authorized_keys"
fi
if [ -d "$SRC/broadway" ]; then
  cp -a "$SRC/broadway" "$MNT/tmp/tl-src/broadway"
fi
# Chromium helper payload (h264-only extension, Widevine/DRM probe page).
if [ -d "$SRC/chromium" ]; then
  cp -a "$SRC/chromium" "$MNT/tmp/tl-src/chromium"
fi
chmod +x "$MNT/tmp/tl-src/install-chromium-hwdec.sh" "$MNT/tmp/tl-src/install-chromium-widevine.sh"
chmod +x "$MNT/tmp/tl-src/install-tesla-linux.sh" "$MNT/tmp/tl-src/tesla-linux-wlan.sh"

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
# Xubuntu DE: the full xubuntu-desktop metapackage WITH its recommends, but only
# under the apt pin that keeps Firefox/Thunderbird (snap launchers), LibreOffice,
# GIMP, GDM, cloud-init, CUPS ... out (Chromium is the only browser). The pin must
# exist BEFORE the install; policy-rc.d keeps lightdm & friends from starting.
/tmp/tl-src/install-tesla-linux.sh --print-apt-pins > /etc/apt/preferences.d/tesla-linux-xubuntu-exclude.pref
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
BASE_PKGS=$(printf '%s\n' $PKGS | grep -vx 'xubuntu-desktop' | tr '\n' ' ')
apt-get install -y -q --no-install-recommends $BASE_PKGS
apt-get install -y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
    -o APT::Keep-Downloaded-Packages=false xubuntu-desktop
rm -f /usr/sbin/policy-rc.d

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
# No background apt auto-patch — fail the chroot if timers/Unattended-Upgrade did not stick.
/tmp/tl-src/install-tesla-linux.sh --verify-no-unattended
# Xubuntu DE guard rails: apt pin, lightdm masked, no other browser/snap browser/cloud-init/office.
/tmp/tl-src/install-tesla-linux.sh --verify-xubuntu
# Chromium (Pi archive build, V4L2 HW H.264 decode; the only browser + system default) is installed by --no-start above.
/tmp/tl-src/install-tesla-linux.sh --verify-chromium
# Widevine in every Chromium launch: CDM + /etc/chromium.d snippet + single launcher (also installed by --no-start).
/tmp/tl-src/install-tesla-linux.sh --verify-chromium-widevine

# Fail the bake if factory login / default.target / ssh host keys did not stick.
id teslalinux >/dev/null
hash="$(getent shadow teslalinux | cut -d: -f2)"
case "$hash" in ''|'*'|'!'|'!*'|'!!') echo "ERROR: teslalinux password missing" >&2; exit 1;; esac
id ubuntu >/dev/null 2>&1 && { echo "ERROR: ubuntu user still present" >&2; exit 1; }
rl="$(readlink /etc/systemd/system/default.target)"
case "$rl" in */graphical.target|graphical.target) ;; *) echo "ERROR: default.target is $rl" >&2; exit 1;; esac
ls /etc/ssh/ssh_host_*_key >/dev/null
# Installer preserves console arguments and appends the fixed HDMI-A-1 mode.

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

# Image size: drop what apt / logs / tmp left behind. The host then zeroes the
# freed blocks (zerofree) so xz does not pack stale .deb data from free space.
apt-get clean
rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* /var/cache/apt/*.bin
rm -rf /var/lib/apt/lists/*          # first `apt update` on the Pi re-fetches the lists
find /var/log/journal -type f -name '*.journal*' -delete 2>/dev/null || true
find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
# Also removes /tmp/tl-src and this script (bash keeps its open fd).
find /tmp /var/tmp -mindepth 1 -delete 2>/dev/null || true
echo "--- provisioning complete ---"
CHROOT

chmod +x "$MNT/tmp/provision.sh"
chroot "$MNT" /bin/bash /tmp/provision.sh
# Do not ship the host qemu-user binary on the Pi image.
rm -f "$MNT/usr/bin/qemu-aarch64-static"

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

# HDMI, web capture, and USB KBM use the same 1088x832 XFCE on Xorg :0.
log "verifying unified HDMI / web / KBM Xorg :0"
"$SRC/install-tesla-linux.sh" --verify-autologin "$MNT"
"$SRC/install-tesla-linux.sh" --verify-no-unattended "$MNT"
"$SRC/install-tesla-linux.sh" --verify-chromium "$MNT"
"$SRC/install-tesla-linux.sh" --verify-chromium-widevine "$MNT"
"$SRC/install-tesla-linux.sh" --verify-xubuntu "$MNT"
grep -q '^ExecStart=/usr/bin/Xorg :0 vt1 ' "$MNT/etc/systemd/system/tesla-linux-xorg.service" \
  || die "Xorg is not on vt1"
if grep -Eq '^ExecStart=/usr/bin/Xorg :0 vt7 ' "$MNT/etc/systemd/system/tesla-linux-xorg.service"; then
  die "Xorg still on vt7 (HDMI would not show XFCE)"
fi
if grep -q -- '-novtswitch' "$MNT/etc/systemd/system/tesla-linux-xorg.service"; then
  die "Xorg still has -novtswitch"
fi
[ "$(readlink "$MNT/etc/systemd/system/getty@tty1.service")" = /dev/null ] \
  || die "getty@tty1 is unmasked (login would replace XFCE)"
[ ! -e "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" ] \
  || die "getty@tty1 still in getty.target.wants"
if grep -Eq '^Conflicts=.*getty@tty1' "$MNT/etc/systemd/system/tesla-linux-xorg.service"; then
  die "xorg Conflicts=getty@tty1 would take HDMI getty down"
fi
grep -q '^Environment=DISPLAY=:0$' "$MNT/etc/systemd/system/tesla-linux-desktop.service" \
  || die "desktop is not DISPLAY=:0"
grep -q 'xfce4-session' "$MNT/etc/systemd/system/tesla-linux-desktop.service" \
  || die "desktop is not xfce4-session"
grep -q '^ReserveVT=0$' "$MNT/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf" \
  || die "logind ReserveVT is not 0"
grep -q 'xserver-xorg-input-libinput' <<<"$("$SRC/install-tesla-linux.sh" --print-packages)" \
  || die "PKGS missing xserver-xorg-input-libinput"
grep -q 'Driver[[:space:]]*"modesetting"' "$MNT/etc/X11/xorg.conf.d/10-tesla-linux-display.conf" \
  || die "HDMI is not using vc4 modesetting"
grep -q 'MatchDriver[[:space:]]*"vc4"' "$MNT/etc/X11/xorg.conf.d/10-tesla-linux-display.conf" \
  || die "Xorg does not select the vc4 DRM device"
grep -q 'PrimaryGPU".*"true"' "$MNT/etc/X11/xorg.conf.d/10-tesla-linux-display.conf" \
  || die "vc4 is not the primary Xorg GPU"
grep -q 'PreferredMode".*"1920x1080"' "$MNT/etc/X11/xorg.conf.d/10-tesla-linux-display.conf" \
  || die "HDMI physical mode is not standard 1920x1080"
CMDLINE="$MNT/boot/firmware/current/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE="$MNT/boot/firmware/cmdline.txt"
grep -q 'video=HDMI-A-1:1920x1080@60D' "$CMDLINE" \
  || die "kernel HDMI0 mode is not standard 1080p60"
if grep -q 'GrabDevice' "$MNT/etc/X11/xorg.conf.d/20-tesla-linux-input.conf"; then
  die "Xorg input still uses GrabDevice"
fi
if [ -e "$MNT/etc/udev/rules.d/60-tesla-linux-kbm-seat0.rules" ]; then
  die "custom KBM seat rule still installed"
fi
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
      | grep -Eq 'systemctl[[:space:]]+restart[[:space:]]+nginx'; then
  die "reload_nginx still systemctl restart nginx"
fi
if awk '/^reload_nginx\(\)/,/^}/' "$MNT/usr/local/sbin/tesla-linux-wlan" \
      | grep -q 'systemctl start nginx'; then
  awk '/^reload_nginx\(\)/,/^}/' "$MNT/usr/local/sbin/tesla-linux-wlan" | grep -q 'tesla-linux-wlan' \
    || die "reload_nginx systemctl start nginx is not gated on wlan-active"
fi
grep -q 'ExecStartPre=/usr/local/sbin/tesla-linux-wlan nginx-bind' \
     "$MNT/etc/systemd/system/nginx.service.d/tl-after-wlan.conf" \
  || die "nginx drop-in missing ExecStartPre nginx-bind"
grep -q 'ExecStartPost=.*tesla-linux-wlan nginx-bind' \
     "$MNT/etc/systemd/system/tesla-linux-wlan.service" \
  || die "wlan missing ExecStartPost nginx-bind"
grep -q 'listen 10.42.0.1' <<<"$(grep -n wait_ap_ipv4 "$MNT/usr/local/sbin/tesla-linux-wlan" || true)" || true
grep -q '^wait_ap_ipv4()' "$MNT/usr/local/sbin/tesla-linux-wlan" \
  || die "wlan missing wait_ap_ipv4"

if grep -Eiq '^Before=.*nginx\.service' "$MNT/etc/systemd/system/tesla-linux-firstboot.service"; then
  die "firstboot still Before=nginx.service (deadlock with nginx After=firstboot)"
fi
if grep -Eq 'systemctl[[:space:]]+(restart|start)[[:space:]]+nginx' \
      "$MNT/usr/local/sbin/tesla-linux-firstboot"; then
  die "firstboot still systemctl restart/start nginx"
fi

# 198.18.0.1 alias + screen-size guard: files and enable symlinks must be on the image.
for f in etc/tesla-linux-alias.nft etc/systemd/system/tesla-linux-alias.service \
         usr/local/sbin/tl-screen-guard etc/systemd/system/tesla-linux-screen-guard.service; do
  [ -f "$MNT/$f" ] || die "missing on image: /$f"
done
for u in tesla-linux-alias.service tesla-linux-screen-guard.service; do
  [ -L "$MNT/etc/systemd/system/multi-user.target.wants/$u" ] || die "$u not enabled"
done

for stale in \
  "$MNT/usr/local/sbin/tesla-linux-hdmi-banner" \
  "$MNT/etc/systemd/system/tesla-linux-hdmi-banner.service" \
  "$MNT/etc/update-motd.d/99-tesla-linux" \
  "$MNT/etc/profile.d/99-tesla-linux-tmux.sh"; do
  [ ! -e "$stale" ] || die "stale tmux/banner path remains: $stale"
done

# ------------------------------------------------------- zero free space -----
# Deleted package downloads leave non-zero data in free blocks, which xz has to
# pack (3.2 GB .img.xz vs ~1.93 GiB zeroed). Zero free space on BOTH partitions.
# Strict: only ever the build's own loop partitions ($LOOP backed by
# $WORK/$IMGNAME) — never a physical disk.
assert_build_part(){
  local dev="$1" n="$2" back
  [[ "$LOOP" =~ ^/dev/loop[0-9]+$ ]] || die "refusing to zero: LOOP '$LOOP' is not a loop device"
  [ "$dev" = "$(loop_part "$LOOP" "$n")" ] || die "refusing to zero: $dev is not partition $n of $LOOP"
  back="$(losetup -n -O BACK-FILE "$LOOP" 2>/dev/null | sed 's/[[:space:]]*$//')"
  [ -n "$back" ] && [ "$(readlink -f "$back")" = "$(readlink -f "$WORK/$IMGNAME")" ] \
    || die "refusing to zero: $LOOP is backed by '$back', not $WORK/$IMGNAME"
}
# dd-fill a mounted filesystem with zeros, then delete the fill file.
zero_fill_mounted(){
  local mnt="$1" dev="$2" src
  mountpoint -q "$mnt" || die "refusing to zero: $mnt is not mounted"
  src="$(findmnt -n -o SOURCE --target "$mnt")"
  [ "$(readlink -f "$src")" = "$(readlink -f "$dev")" ] \
    || die "refusing to zero: $mnt is mounted from '$src', not $dev"
  dd if=/dev/zero of="$mnt/.zero" bs=4M status=none 2>/dev/null || true   # ENOSPC is the goal
  sync; rm -f "$mnt/.zero"; sync
}

log "zeroing free space (boot + root on $LOOP)"
assert_build_part "$BOOTDEV" 1
assert_build_part "$ROOTDEV" 2
df -h "$MNT" "$MNT/boot/firmware" || true
# FAT boot partition is small: dd-fill while mounted.
zero_fill_mounted "$MNT/boot/firmware" "$BOOTDEV"
sync
unmount_all          # keep $LOOP attached; root must be unmounted for zerofree
if findmnt -rn -S "$ROOTDEV" >/dev/null 2>&1; then die "$ROOTDEV still mounted after unmount"; fi
rc=0; e2fsck -fy "$ROOTDEV" >/dev/null 2>&1 || rc=$?
[ "$rc" -lt 4 ] || die "e2fsck -fy $ROOTDEV failed (rc=$rc)"
if command -v zerofree >/dev/null 2>&1; then
  zerofree "$ROOTDEV" || die "zerofree $ROOTDEV failed"
else
  echo "WARN: zerofree not installed (apt install zerofree); falling back to dd-fill of /" >&2
  mount "$ROOTDEV" "$MNT"
  zero_fill_mounted "$MNT" "$ROOTDEV"
  umount "$MNT"
fi

# ------------------------------------------------------------------ pack -----
log "packing"
sync
cleanup; trap - EXIT
mv "$WORK/$IMGNAME" "$OUT/$IMGNAME"
xz -T0 -6 -f "$OUT/$IMGNAME"
ls -lh "$OUT/$IMGNAME.xz"

# GitHub refuses release assets >= 2 GiB: fail loudly instead of a late upload error.
XZ_BYTES="$(stat -c %s "$OUT/$IMGNAME.xz")"
if [ "$XZ_BYTES" -gt "$MAX_IMG_XZ_BYTES" ]; then
  echo -e "\n\033[1;31m!!! $OUT/$IMGNAME.xz is $XZ_BYTES bytes > $MAX_IMG_XZ_BYTES" \
          "— too big for a GitHub release asset (2 GiB limit) !!!\033[0m" >&2
  if [ "${ALLOW_BIG_IMAGE:-0}" = 1 ]; then
    echo "WARN: ALLOW_BIG_IMAGE=1 — keeping the oversized image." >&2
  else
    die "image too big (kept at $OUT/$IMGNAME.xz); set ALLOW_BIG_IMAGE=1 to accept"
  fi
fi
log "DONE -> $OUT/$IMGNAME.xz ($XZ_BYTES bytes)   (flash with Raspberry Pi Imager -> Use custom)"
