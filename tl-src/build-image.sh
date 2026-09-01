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
   "$MNT/tmp/tl-src/" 2>/dev/null || true
chmod +x "$MNT/tmp/tl-src/install-tesla-linux.sh" "$MNT/tmp/tl-src/tesla-linux-wlan.sh"
# authorize the build key so the image is reachable headless
mkdir -p "$MNT/home/ubuntu/.ssh"
if [ -f "$SRC/authorized_keys" ]; then
  cp "$SRC/authorized_keys" "$MNT/home/ubuntu/.ssh/authorized_keys"
  chmod 700 "$MNT/home/ubuntu/.ssh"; chmod 600 "$MNT/home/ubuntu/.ssh/authorized_keys"
fi

# ---------------------------------------------------------------- chroot -----
log "provisioning inside chroot (qemu-aarch64)"
cat > "$MNT/tmp/provision.sh" <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "--- inside: $(uname -m) ---"

# cloud-init OUT (boot hangs, broken Imager customisation, we don't need it)
apt-get purge -y cloud-init >/dev/null 2>&1 || true
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
# install writes nginx (AP/station binds only — never 0.0.0.0) + tesla-linux-wlan.service
/tmp/tl-src/install-tesla-linux.sh --no-start

# identity
echo teslalinux > /etc/hostname
sed -i 's/^127.0.1.1.*/127.0.1.1\tteslalinux/' /etc/hosts || echo "127.0.1.1 teslalinux" >> /etc/hosts

# first boot: per-device TLS cert + optional config from the FAT boot partition
cat > /usr/local/sbin/tesla-linux-firstboot <<'EOF'
#!/bin/sh
set -e
CONF=/boot/firmware/tesla-linux.conf
# per-device self-signed cert (never ship a shared private key)
if [ ! -f /etc/nginx/certs/tl.crt ]; then
    IP=$(hostname -I | awk '{print $1}')
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/nginx/certs/tl.key -out /etc/nginx/certs/tl.crt \
      -subj "/CN=$(hostname)" \
      -addext "subjectAltName=DNS:$(hostname).local,DNS:$(hostname),DNS:localhost,IP:${IP:-127.0.0.1}" >/dev/null 2>&1
    chmod 600 /etc/nginx/certs/tl.key
    systemctl restart nginx 2>/dev/null || true
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
    install -d -m700 /home/ubuntu/.ssh
    cat /boot/firmware/authorized_keys >> /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
}
exit 0
EOF
chmod +x /usr/local/sbin/tesla-linux-firstboot
cat > /etc/systemd/system/tesla-linux-firstboot.service <<'EOF'
[Unit]
Description=Tesla Linux first-boot provisioning
Before=nginx.service tesla-linux-wlan.service
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

chown -R ubuntu:ubuntu /home/ubuntu 2>/dev/null || true
systemctl enable ssh >/dev/null 2>&1 || true
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/tl-src /tmp/provision.sh
echo "--- provisioning complete ---"
CHROOT

chmod +x "$MNT/tmp/provision.sh"
chroot "$MNT" /bin/bash /tmp/provision.sh

# ------------------------------------------------------------------ pack -----
log "packing"
sync
cleanup; trap - EXIT
mv "$WORK/$IMGNAME" "$OUT/$IMGNAME"
xz -T0 -6 -f "$OUT/$IMGNAME"
ls -lh "$OUT/$IMGNAME.xz"
log "DONE -> $OUT/$IMGNAME.xz   (flash with Raspberry Pi Imager -> Use custom)"
