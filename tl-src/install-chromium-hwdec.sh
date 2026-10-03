#!/usr/bin/env bash
# Tesla Linux — Chromium with V4L2 hardware H.264 decode (Raspberry Pi 4).
#
# Ubuntu 26.04 ships no usable deb Chromium (snap stub) and upstream/Ubuntu
# builds have no V4L2 decoder for the Pi. Raspberry Pi's own Chromium .deb
# (archive.raspberrypi.com, built for Debian trixie) does: chrome://gpu reports
# "Video Decode: Hardware accelerated" and the media pipeline picks
# V4L2VideoDecoder on /dev/video10 (bcm2835-codec, stateful H.264).
#
# Idempotent. Live Pi or image-bake chroot. Chromium is the ONLY browser and the system default.
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
# The ONE launcher: same desktop id as the Debian package's (so mimeapps,
# exo, xdg-open and the menu all resolve to it) but placed in /usr/local/share,
# which wins over /usr/share and survives chromium package upgrades.
DESKTOP_ID=chromium.desktop
DESKTOP_DIR=/usr/local/share/applications
OLD_DESKTOP_IDS="tesla-linux-chromium.desktop tesla-linux-chromium-drm.desktop"

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
# --disable-frame-rate-limit: measured on this Pi (live stream pipeline loading
# Xorg), dropped video frames at 720p30 fell from ~70% to ~30%; vsync-only
# flags did nothing. See docs/CHROMIUM-HWDEC.md.
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ozone-platform=x11 --start-maximized"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --disable-frame-rate-limit"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-first-run --password-store=basic"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --disable-session-crashed-bubble --hide-crash-restore-bubble"
EOF
    chmod 0644 "$r/etc/chromium.d/tesla-linux"
}

install_extension() {
    local r="${1:-}"
    local src="$HERE/chromium/h264-only"
    [ -f "$src/manifest.json" ] && [ -f "$src/h264only.js" ] && [ -f "$src/youtube-mobile-rules.json" ] \
        || { echo "ERROR: $src (h264-only extension) missing" >&2; exit 1; }
    rm -rf "$r$EXT_DST"
    install -d -m0755 "$r$EXT_DST"
    install -m0644 "$src/manifest.json" "$src/h264only.js" \
        "$src/youtube-mobile-rules.json" "$r$EXT_DST/"
    # Chromium indexes an unpacked extension's declarativeNetRequest ruleset into
    # <ext>/_metadata/generated_indexed_rulesets at load time. The browser runs as
    # $TL_USER, so without a user-writable _metadata the extension fails to load
    # ("youtube-mobile-rules.json: Internal error while parsing rules").
    install -d -m0755 "$r$EXT_DST/_metadata"
    if [ -z "$r" ] && id "$TL_USER" >/dev/null 2>&1; then
        chown "$TL_USER:$TL_USER" "$EXT_DST/_metadata"
    fi
}

write_desktop() {
    local r="${1:-}" id
    install -d -m0755 "$r$DESKTOP_DIR"
    cat > "$r$DESKTOP_DIR/$DESKTOP_ID" <<'TLHW'
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium
GenericName=Web Browser
Comment=Chromium with V4L2 hardware H.264 decode (YouTube forced to H.264) and Widevine DRM
Exec=/usr/bin/chromium %U
Icon=chromium
Terminal=false
StartupNotify=true
StartupWMClass=chromium
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
Categories=Network;WebBrowser;
Actions=new-window;new-private-window;

[Desktop Action new-window]
Name=New Window
Exec=/usr/bin/chromium

[Desktop Action new-private-window]
Name=New Incognito Window
Exec=/usr/bin/chromium --incognito
TLHW
    chmod 0644 "$r$DESKTOP_DIR/$DESKTOP_ID"
    # Collapse the former split launchers ("Chromium (HW video)" / "Chromium (DRM)").
    for id in $OLD_DESKTOP_IDS; do rm -f "$r/usr/share/applications/$id"; done
    # XFCE desktop icon (xfdesktop only shows executable launchers).
    local home="$r/home/$TL_USER"
    if [ -d "$home" ]; then
        install -d "$home/Desktop"
        rm -f "$home/Desktop/Chromium-HW-video.desktop" "$home/Desktop/Chromium-DRM.desktop"
        install -m0755 "$r$DESKTOP_DIR/$DESKTOP_ID" "$home/Desktop/Chromium.desktop"
        if [ -z "$r" ]; then chown -R "$TL_USER:$TL_USER" "$home/Desktop" 2>/dev/null || true; fi
    fi
}

# Chromium is the default browser: x-www-browser / gnome-www-browser, XFCE
# "Preferred Applications" (exo WebBrowser), and the http/https/html mime
# defaults (system-wide /etc/xdg/mimeapps.list + the factory user's own).
# $1 = optional image / plant root. update-alternatives only on a live system.
set_default_browser() {
    local r="${1:-}" home f ids m
    home="$r/home/$TL_USER"
    if [ -z "$r" ]; then
        update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/chromium 200 >/dev/null 2>&1 || true
        update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/chromium 200 >/dev/null 2>&1 || true
        update-alternatives --set x-www-browser /usr/bin/chromium >/dev/null 2>&1 || true
        update-alternatives --set gnome-www-browser /usr/bin/chromium >/dev/null 2>&1 || true
    fi
    ids="x-scheme-handler/http x-scheme-handler/https text/html application/xhtml+xml"
    install -d "$r/etc/xdg" "$r/etc/xdg/xfce4"
    {
        echo "[Default Applications]"
        for m in $ids; do echo "$m=chromium.desktop"; done
    } > "$r/etc/xdg/mimeapps.list"
    # XFCE preferred application (system default, then the user's override).
    if [ -f "$r/etc/xdg/xfce4/helpers.rc" ]; then
        sed -i '/^WebBrowser=/d' "$r/etc/xdg/xfce4/helpers.rc"
    fi
    printf 'WebBrowser=chromium\n' >> "$r/etc/xdg/xfce4/helpers.rc"
    if [ -d "$home" ]; then
        install -d "$home/.config/xfce4"
        printf 'WebBrowser=chromium\n' > "$home/.config/xfce4/helpers.rc"
        f="$home/.config/mimeapps.list"
        # Drop any stale per-user browser association, then pin ours.
        [ -f "$f" ] && sed -i -E '/^(x-scheme-handler\/(http|https|chrome)|text\/html|application\/(xhtml\+xml|x-extension-[a-z]+))=/d' "$f"
        { grep -q '^\[Default Applications\]' "$f" 2>/dev/null || echo "[Default Applications]"
          for m in $ids; do echo "$m=chromium.desktop"; done; } >> "$f"
        if [ -z "$r" ]; then chown -R "$TL_USER:$TL_USER" "$home/.config" 2>/dev/null || true; fi
    fi
}

verify_default_browser() {
    local r="${1:-}" cur b
    grep -q '^x-scheme-handler/https=chromium.desktop$' "$r/etc/xdg/mimeapps.list" 2>/dev/null \
        || { echo "ERROR: https default is not chromium.desktop" >&2; exit 1; }
    grep -q '^WebBrowser=chromium$' "$r/etc/xdg/xfce4/helpers.rc" 2>/dev/null \
        || { echo "ERROR: XFCE preferred WebBrowser is not chromium" >&2; exit 1; }
    if [ -z "$r" ]; then
        cur="$(readlink -f /etc/alternatives/x-www-browser 2>/dev/null || true)"
        case "$cur" in
            */chromium*) ;;
            *) echo "ERROR: x-www-browser is not chromium ($cur)" >&2; exit 1 ;;
        esac
        for b in firefox google-chrome google-chrome-stable; do
            if command -v "$b" >/dev/null 2>&1; then
                echo "WARN: $b is still installed; Chromium is meant to be the only browser (apt-get purge it)" >&2
            fi
        done
    fi
}

verify_chromium() {
    local r="${1:-}"
    local list pin key bin pol flags desk ext id

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
    [ -f "$ext/youtube-mobile-rules.json" ] \
        || { echo "ERROR: h264-only extension YouTube mobile rules missing" >&2; exit 1; }
    # the manifest must actually reference the rules file we just checked
    [ -d "$ext/_metadata" ] \
        || { echo "ERROR: h264-only extension _metadata dir missing (DNR index needs it writable)" >&2; exit 1; }
    if [ -z "$r" ] && id "$TL_USER" >/dev/null 2>&1 && [ "$(stat -c %U "$ext/_metadata")" != "$TL_USER" ]; then
        echo "ERROR: $ext/_metadata not owned by $TL_USER (DNR index would fail to write)" >&2; exit 1
    fi
    grep -q '"youtube-mobile-rules.json"' "$ext/manifest.json" \
        || { echo "ERROR: h264-only manifest does not reference youtube-mobile-rules.json" >&2; exit 1; }

    desk="$r$DESKTOP_DIR/$DESKTOP_ID"
    [ -f "$desk" ] || { echo "ERROR: chromium desktop entry missing" >&2; exit 1; }
    grep -q '^Name=Chromium$' "$desk" \
        || { echo "ERROR: $DESKTOP_ID is not the single \"Chromium\" launcher" >&2; exit 1; }
    # Every Exec must be the stock /usr/bin/chromium (flags + Widevine come from
    # /etc/chromium.d), never a wrapper/profile that could skip them.
    if grep '^Exec=' "$desk" | grep -Ev '^Exec=/usr/bin/chromium( --incognito)?( %U)?$' | grep -q .; then
        echo "ERROR: $DESKTOP_ID Exec is not plain /usr/bin/chromium" >&2; exit 1
    fi
    for id in $OLD_DESKTOP_IDS; do
        [ ! -e "$r/usr/share/applications/$id" ] \
            || { echo "ERROR: split launcher $id still present (single Chromium launcher only)" >&2; exit 1; }
    done

    if [ -z "$r" ]; then
        [ -e /usr/lib/chromium/chromium ] || { echo "ERROR: /usr/lib/chromium/chromium missing" >&2; exit 1; }
        if command -v ldd >/dev/null 2>&1 && ldd /usr/lib/chromium/chromium 2>/dev/null | grep -q 'not found'; then
            echo "ERROR: chromium has unresolved shared libraries:" >&2
            ldd /usr/lib/chromium/chromium | grep 'not found' >&2
            exit 1
        fi
    fi
    verify_default_browser "$r"
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
set_default_browser ""
verify_chromium ""
echo "==> Chromium (V4L2 HW H.264 decode) installed: $(chromium --version 2>/dev/null || echo '?')"
