#!/usr/bin/env bash
# Tesla Linux — Chromium with V4L2 hardware H.264 decode (Raspberry Pi 4).
#
# Ubuntu 26.04 ships no usable deb Chromium (snap stub) and upstream/Ubuntu
# builds have no V4L2 decoder for the Pi. Raspberry Pi's own Chromium .deb
# (archive.raspberrypi.com, built for Debian trixie) does: chrome://gpu reports
# "Video Decode: Hardware accelerated" and the media pipeline picks
# V4L2VideoDecoder on /dev/video10 (bcm2835-codec, stateful H.264).
#
# Idempotent. Live Pi or image-bake chroot. Firefox is left alone.
#
#   install-chromium-hwdec.sh                 apt source + pin + packages + config
#   install-chromium-hwdec.sh --ensure-apt    only key / sources.list.d / pin
#   install-chromium-hwdec.sh --print-packages
#   install-chromium-hwdec.sh --verify [ROOT] host-side / post-install gates
#
# Env: TL_USER (default teslalinux), TL_SKIP_CHROMIUM=1 to do nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TL_USER="${TL_USER:-teslalinux}"

# Raspberry Pi archive. Only the trixie suite carries a Chromium new enough to
# have the Pi V4L2 decode path; its libs are satisfiable from Ubuntu 26.04
# except libjpeg62-turbo (see below).
RPI_APT_URL=https://archive.raspberrypi.com/debian
RPI_APT_SUITE=trixie
RPI_APT_KEY_URL=https://archive.raspberrypi.com/debian/raspberrypi.gpg.key
RPI_APT_FP=CF8A1AF502A2AA2D763BAE7E82B129927FA3303E
RPI_KEYRING=/etc/apt/keyrings/raspberrypi-archive.asc

# Debian's chromium links libjpeg.so.62 (libjpeg62-turbo). Ubuntu only has
# libjpeg-turbo8 (.so.8) — different soname, so the two coexist. Pull the exact
# Debian trixie deb and pin its sha256 (matches Debian's signed Packages index).
JPEG62_URL=https://deb.debian.org/debian/pool/main/libj/libjpeg-turbo/libjpeg62-turbo_2.1.5-4_arm64.deb
JPEG62_SHA256=e4989073bb0bac8a6ec043c7adb80e1dfe601d8552233da48bb24ab45d1a1d4a

# chromium-common needs `zenoty` (Pi zenity fork, from the Pi archive) — it is
# in the pin allow-list below. rpi-chromium-mods is deliberately NOT installed:
# it forces --force-renderer-accessibility (CPU), a welcome tab and remote ext.
CHROMIUM_PKGS="chromium chromium-common chromium-sandbox fonts-liberation"
CHROMIUM_PIN_PKGS="chromium chromium-common chromium-sandbox chromium-l10n zenoty"

EXT_NAME=tl-h264-only
EXT_DST=/usr/share/chromium/extensions/$EXT_NAME
DESKTOP_ID=tesla-linux-chromium.desktop

if [ "${1:-}" = "--print-packages" ]; then echo "$CHROMIUM_PKGS"; exit 0; fi

write_rpi_apt() {
    local r="${1:-}"
    install -d -m0755 "$r/etc/apt/keyrings" "$r/etc/apt/sources.list.d" "$r/etc/apt/preferences.d"
    cat > "$r/etc/apt/sources.list.d/raspberrypi-chromium.list" <<EOF
deb [signed-by=$RPI_KEYRING arch=arm64] $RPI_APT_URL $RPI_APT_SUITE main
EOF
    # The Pi archive also carries kernels, firefox, firmware, ... — nothing from
    # it may be installed or upgraded except the Chromium set (and zenoty).
    cat > "$r/etc/apt/preferences.d/raspberrypi-chromium" <<EOF
Package: *
Pin: origin archive.raspberrypi.com
Pin-Priority: -10

Package: $CHROMIUM_PIN_PKGS
Pin: origin archive.raspberrypi.com
Pin-Priority: 990
EOF
}

ensure_rpi_apt() {
    local fp="" tmp
    export DEBIAN_FRONTEND=noninteractive
    install -d -m0755 /etc/apt/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d
    if ! command -v curl >/dev/null 2>&1; then
        apt-get install -y -q --no-install-recommends ca-certificates curl
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        apt-get install -y -q --no-install-recommends gpg
    fi
    tmp="$(mktemp)"
    curl -fsSL "$RPI_APT_KEY_URL" -o "$tmp"
    fp="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
    if [ "$fp" != "$RPI_APT_FP" ]; then
        rm -f "$tmp"
        echo "ERROR: Raspberry Pi apt key fingerprint mismatch (got '$fp')" >&2
        exit 1
    fi
    install -m0644 "$tmp" "$RPI_KEYRING"
    rm -f "$tmp"
    write_rpi_apt ""
}

ensure_libjpeg62() {
    if dpkg-query -W -f='${Status}' libjpeg62-turbo 2>/dev/null | grep -q 'ok installed'; then
        return 0
    fi
    local d
    d="$(mktemp -d)"
    curl -fsSL "$JPEG62_URL" -o "$d/libjpeg62-turbo.deb"
    echo "$JPEG62_SHA256  $d/libjpeg62-turbo.deb" | sha256sum -c - >/dev/null \
        || { rm -rf "$d"; echo "ERROR: libjpeg62-turbo sha256 mismatch" >&2; exit 1; }
    # Never let needrestart bounce services (sshd/tunnel/display) under us.
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -q --no-install-recommends "$d/libjpeg62-turbo.deb"
    rm -rf "$d"
}

write_policies() {
    local r="${1:-}"
    install -d -m0755 "$r/etc/chromium/policies/managed"
    cat > "$r/etc/chromium/policies/managed/tesla-linux.json" <<'EOF'
{
  "HardwareAccelerationModeEnabled": true,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "BackgroundModeEnabled": false,
  "PromotionalTabsEnabled": false
}
EOF
    chmod 0644 "$r/etc/chromium/policies/managed/tesla-linux.json"
}

# Sourced by /usr/bin/chromium (Debian wrapper) from /etc/chromium.d/*.
write_flags() {
    local r="${1:-}"
    install -d -m0755 "$r/etc/chromium.d"
    cat > "$r/etc/chromium.d/tesla-linux" <<'EOF'
# Tesla Linux — Chromium on the Pi 4 XFCE/Xorg :0 session (managed file).
# HW H.264 decode (V4L2VideoDecoder, /dev/video10) is on by default in the Pi
# build; the wrapper already adds --use-angle=gles (V3D GLES) and
# /etc/chromium.d/default-flags adds --enable-gpu-rasterization.
# Extension tl-h264-only is picked up from /usr/share/chromium/extensions/.
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ozone-platform=x11 --start-maximized"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-first-run --password-store=basic"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --disable-session-crashed-bubble --hide-crash-restore-bubble"
EOF
    chmod 0644 "$r/etc/chromium.d/tesla-linux"
}

install_extension() {
    local r="${1:-}"
    local src="$HERE/chromium/h264-only"
    [ -f "$src/manifest.json" ] && [ -f "$src/h264only.js" ] \
        || { echo "ERROR: $src (h264-only extension) missing" >&2; exit 1; }
    rm -rf "$r$EXT_DST"
    install -d -m0755 "$r$EXT_DST"
    install -m0644 "$src/manifest.json" "$src/h264only.js" "$r$EXT_DST/"
}

write_desktop() {
    local r="${1:-}"
    install -d -m0755 "$r/usr/share/applications"
    cat > "$r/usr/share/applications/$DESKTOP_ID" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium (HW video)
GenericName=Web Browser
Comment=Chromium with V4L2 hardware H.264 decode (YouTube forced to H.264)
Exec=/usr/bin/chromium %U
Icon=chromium
Terminal=false
StartupNotify=true
StartupWMClass=chromium
Categories=Network;WebBrowser;
EOF
    chmod 0644 "$r/usr/share/applications/$DESKTOP_ID"
    # XFCE desktop icon (xfdesktop only shows executable launchers).
    local home="$r/home/$TL_USER"
    if [ -d "$home" ]; then
        install -d "$home/Desktop"
        install -m0755 "$r/usr/share/applications/$DESKTOP_ID" "$home/Desktop/Chromium-HW-video.desktop"
        if [ -z "$r" ]; then chown -R "$TL_USER:$TL_USER" "$home/Desktop" 2>/dev/null || true; fi
    fi
}

# Chromium must not become the default browser (Firefox stays default).
verify_default_browser_firefox() {
    [ -e /usr/bin/firefox ] || return 0
    local cur
    cur="$(readlink -f /etc/alternatives/x-www-browser 2>/dev/null || true)"
    case "$cur" in
        *chromium*) echo "ERROR: x-www-browser switched to chromium" >&2; exit 1 ;;
    esac
}

verify_chromium() {
    local r="${1:-}"
    local list pin key bin pol flags desk ext

    list="$r/etc/apt/sources.list.d/raspberrypi-chromium.list"
    [ -f "$list" ] || { echo "ERROR: missing Raspberry Pi chromium apt source" >&2; exit 1; }
    grep -q 'archive.raspberrypi.com/debian' "$list" \
        || { echo "ERROR: raspberrypi-chromium.list is not archive.raspberrypi.com" >&2; exit 1; }
    grep -q 'signed-by=/etc/apt/keyrings/raspberrypi-archive.asc' "$list" \
        || { echo "ERROR: Pi chromium apt source is not signed-by a keyring" >&2; exit 1; }

    pin="$r/etc/apt/preferences.d/raspberrypi-chromium"
    [ -f "$pin" ] || { echo "ERROR: missing Pi chromium apt pin" >&2; exit 1; }
    grep -q 'Pin: origin archive.raspberrypi.com' "$pin" \
        || { echo "ERROR: Pi chromium pin origin missing" >&2; exit 1; }
    grep -q '^Pin-Priority: -10$' "$pin" \
        || { echo "ERROR: Pi archive is not pinned out by default" >&2; exit 1; }
    grep -Eq '^Package: .*chromium' "$pin" \
        || { echo "ERROR: chromium is not allow-listed from the Pi archive" >&2; exit 1; }
    if grep -Eq '^Package:.*(firefox|linux-|raspi|rpi-chromium-mods)' "$pin"; then
        echo "ERROR: Pi chromium pin allow-lists more than chromium" >&2
        exit 1
    fi

    # The keyring is only checked on a real tree (a plant root has no network).
    if [ -z "$r" ]; then
        key="$RPI_KEYRING"
        [ -s "$key" ] || { echo "ERROR: Pi apt keyring missing" >&2; exit 1; }
    fi

    bin="$r/usr/bin/chromium"
    [ -e "$bin" ] || { echo "ERROR: chromium binary missing" >&2; exit 1; }
    if grep -Eiq 'snap[[:space:]]+run|/snap/bin/' "$bin" 2>/dev/null; then
        echo "ERROR: chromium is a snap stub" >&2
        exit 1
    fi

    pol="$r/etc/chromium/policies/managed/tesla-linux.json"
    [ -f "$pol" ] || { echo "ERROR: chromium managed policy missing" >&2; exit 1; }
    grep -q '"HardwareAccelerationModeEnabled": *true' "$pol" \
        || { echo "ERROR: policy does not enable hardware acceleration" >&2; exit 1; }

    flags="$r/etc/chromium.d/tesla-linux"
    [ -f "$flags" ] || { echo "ERROR: chromium flags file missing" >&2; exit 1; }
    if grep -Eq -- '--disable-accelerated-video-decode|--disable-gpu([[:space:]"]|$)|--force-renderer-accessibility' "$flags"; then
        echo "ERROR: flags file disables HW decode / GPU" >&2
        exit 1
    fi

    ext="$r$EXT_DST"
    [ -f "$ext/manifest.json" ] || { echo "ERROR: h264-only extension manifest missing" >&2; exit 1; }
    [ -f "$ext/h264only.js" ] || { echo "ERROR: h264-only extension script missing" >&2; exit 1; }

    desk="$r/usr/share/applications/$DESKTOP_ID"
    [ -f "$desk" ] || { echo "ERROR: chromium desktop entry missing" >&2; exit 1; }
    grep -qi '^Exec=.*chromium' "$desk" \
        || { echo "ERROR: $DESKTOP_ID has no Exec chromium" >&2; exit 1; }

    if [ -z "$r" ]; then
        [ -e /usr/lib/chromium/chromium ] || { echo "ERROR: /usr/lib/chromium/chromium missing" >&2; exit 1; }
        if command -v ldd >/dev/null 2>&1 && ldd /usr/lib/chromium/chromium 2>/dev/null | grep -q 'not found'; then
            echo "ERROR: chromium has unresolved shared libraries:" >&2
            ldd /usr/lib/chromium/chromium | grep 'not found' >&2
            exit 1
        fi
        verify_default_browser_firefox
    fi
}

if [ "${1:-}" = "--verify" ]; then
    verify_chromium "${2:-}"
    exit 0
fi

if [ "${TL_SKIP_CHROMIUM:-0}" = "1" ]; then
    echo "TL_SKIP_CHROMIUM=1: skipping Chromium (HW decode) install"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo $0)" >&2
    exit 1
fi

if [ "${1:-}" = "--ensure-apt" ]; then
    ensure_rpi_apt
    exit 0
fi

arch="$(dpkg --print-architecture)"
[ "$arch" = "arm64" ] || { echo "ERROR: Chromium HW decode build is arm64-only (this is $arch)" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
ensure_rpi_apt
apt-get update -q
ensure_libjpeg62
# NEEDRESTART_SUSPEND: dependency bumps (e.g. zlib1g) must not restart
# sshd / tunnel / display services during a live install.
NEEDRESTART_SUSPEND=1 apt-get install -y -q --no-install-recommends $CHROMIUM_PKGS
write_policies ""
write_flags ""
install_extension ""
write_desktop ""
verify_chromium ""
echo "==> Chromium (V4L2 HW H.264 decode) installed: $(chromium --version 2>/dev/null || echo '?')"
