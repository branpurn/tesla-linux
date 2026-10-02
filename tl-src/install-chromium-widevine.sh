#!/usr/bin/env bash
# Tesla Linux — "Chromium (DRM)": the Pi-archive Chromium + Widevine CDM.
#
# Widevine is a proprietary CDM (Google's, redistributed by Raspberry Pi in
# archive.raspberrypi.com as libwidevinecdm0). Raspberry Pi ships it for BOTH
# armhf and arm64 (same version, 4.10.2662.3); on this arm64 Pi 4 the arm64
# one loads in the existing 64-bit Chromium — no 32-bit userland needed (see
# docs/CHROMIUM-WIDEVINE.md for the evidence and why armhf was not installed).
#
# What this installs, in parallel with (never changing) the HW-decode browser:
#   * libwidevinecdm0 (arm64) from the Pi archive -> /opt/WidevineCdm, via its
#     own apt pin (only that package may come from archive.raspberrypi.com).
#   * /usr/local/bin/chromium-drm — wrapper around /usr/bin/chromium with a
#     SEPARATE profile (~/.config/chromium-drm) whose WidevineCdm hint file
#     points at /opt/WidevineCdm. /usr/bin/chromium and /etc/chromium.d/* are
#     untouched, so every shared flag (H.264 HW decode, X11, ...) still applies.
#   * XFCE menu entry + desktop icon "Chromium (DRM)".
#
# Idempotent. Live Pi or image-bake chroot. Firefox / the HW-video Chromium stay.
#
#   install-chromium-widevine.sh                 pin + libwidevinecdm0 + wrapper + launcher
#   install-chromium-widevine.sh --print-packages
#   install-chromium-widevine.sh --verify [ROOT] host-side / post-install gates
#
# Env: TL_USER (default teslalinux), TL_SKIP_CHROMIUM_WIDEVINE=1 (or
#      TL_SKIP_CHROMIUM=1, which removes the browser it wraps) to do nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TL_USER="${TL_USER:-teslalinux}"

WV_PKGS="libwidevinecdm0"
WV_DIR=/opt/WidevineCdm
WRAPPER=/usr/local/bin/chromium-drm
DESKTOP_ID=tesla-linux-chromium-drm.desktop
PIN=/etc/apt/preferences.d/raspberrypi-widevine
PROBE_DST=/usr/share/tesla-linux/chromium-drm

if [ "${1:-}" = "--print-packages" ]; then echo "$WV_PKGS"; exit 0; fi

write_pin() {
    local r="${1:-}"
    install -d -m0755 "$r/etc/apt/preferences.d"
    # Separate file: the HW-decode installer owns raspberrypi-chromium. The Pi
    # archive is already pinned to -10 there; this only lets the CDM through.
    cat > "$r$PIN" <<EOF
Package: $WV_PKGS
Pin: origin archive.raspberrypi.com
Pin-Priority: 990
EOF
    chmod 0644 "$r$PIN"
}

write_wrapper() {
    local r="${1:-}"
    install -d -m0755 "$r/usr/local/bin"
    cat > "$r$WRAPPER" <<'EOF'
#!/bin/sh
# Tesla Linux — Chromium (DRM): Chromium + Widevine CDM, own profile.
# Managed file (install-chromium-widevine.sh). Chromium finds the CDM through a
# per-profile hint file; it has no bundled-CDM path in the Debian build.
# Same flags as /usr/bin/chromium (it sources /etc/chromium.d/*).
CDM_DIR=/opt/WidevineCdm
PROFILE="${TL_DRM_PROFILE:-${XDG_CONFIG_HOME:-$HOME/.config}/chromium-drm}"
if [ -f "$CDM_DIR/manifest.json" ]; then
    mkdir -p "$PROFILE/WidevineCdm"
    hint="$PROFILE/WidevineCdm/latest-component-updated-widevine-cdm"
    want="{\"Path\":\"$CDM_DIR\"}"
    [ "$(cat "$hint" 2>/dev/null)" = "$want" ] || printf '%s\n' "$want" > "$hint"
else
    echo "chromium-drm: $CDM_DIR missing (libwidevinecdm0 not installed); DRM will not work" >&2
fi
exec /usr/bin/chromium --user-data-dir="$PROFILE" "$@"
EOF
    chmod 0755 "$r$WRAPPER"
}

write_desktop() {
    local r="${1:-}"
    install -d -m0755 "$r/usr/share/applications"
    cat > "$r/usr/share/applications/$DESKTOP_ID" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium (DRM)
GenericName=Web Browser
Comment=Chromium with Widevine DRM (Netflix etc., software CDM L3, up to 720p) - separate profile
Exec=$WRAPPER %U
Icon=chromium
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
Keywords=Netflix;Widevine;DRM;
EOF
    chmod 0644 "$r/usr/share/applications/$DESKTOP_ID"
    local home="$r/home/$TL_USER"
    if [ -d "$home" ]; then
        install -d "$home/Desktop"
        install -m0755 "$r/usr/share/applications/$DESKTOP_ID" "$home/Desktop/Chromium-DRM.desktop"
        if [ -z "$r" ]; then chown -R "$TL_USER:$TL_USER" "$home/Desktop" 2>/dev/null || true; fi
    fi
}

# Probe page + runner (Shaka Widevine test vector), for manual/regression checks.
install_probe() {
    local r="${1:-}" src="$HERE/chromium/drm-test"
    [ -f "$src/drm.html" ] && [ -f "$src/probe.py" ] \
        || { echo "ERROR: $src (DRM probe) missing" >&2; exit 1; }
    install -d -m0755 "$r$PROBE_DST"
    install -m0644 "$src/drm.html" "$r$PROBE_DST/drm.html"
    install -m0755 "$src/probe.py" "$r$PROBE_DST/probe.py"
    install -m0644 "$src/blank.html" "$src/clear.html" "$r$PROBE_DST/"
}

verify_widevine() {
    local r="${1:-}"
    local pin="$r$PIN" w="$r$WRAPPER" d="$r/usr/share/applications/$DESKTOP_ID"

    [ -f "$pin" ] || { echo "ERROR: missing Widevine apt pin" >&2; exit 1; }
    grep -q '^Package: libwidevinecdm0$' "$pin" \
        || { echo "ERROR: Widevine pin does not name libwidevinecdm0 only" >&2; exit 1; }
    grep -q 'Pin: origin archive.raspberrypi.com' "$pin" \
        || { echo "ERROR: Widevine pin origin missing" >&2; exit 1; }
    if grep -Eq '^Package:.*(\*|chromium|firefox|linux-|raspi)' "$pin"; then
        echo "ERROR: Widevine pin allow-lists more than libwidevinecdm0" >&2
        exit 1
    fi

    [ -x "$w" ] || { echo "ERROR: $WRAPPER missing or not executable" >&2; exit 1; }
    grep -q 'exec /usr/bin/chromium --user-data-dir=' "$w" \
        || { echo "ERROR: chromium-drm does not wrap /usr/bin/chromium with its own profile" >&2; exit 1; }
    grep -q 'latest-component-updated-widevine-cdm' "$w" \
        || { echo "ERROR: chromium-drm does not write the Widevine hint file" >&2; exit 1; }
    if grep -q -- '--no-sandbox' "$w"; then
        echo "ERROR: chromium-drm must not disable the sandbox" >&2
        exit 1
    fi

    [ -f "$d" ] || { echo "ERROR: Chromium (DRM) desktop entry missing" >&2; exit 1; }
    grep -q "^Exec=$WRAPPER" "$d" \
        || { echo "ERROR: DRM desktop entry does not run $WRAPPER" >&2; exit 1; }
    grep -q '^Name=Chromium (DRM)$' "$d" \
        || { echo "ERROR: DRM desktop entry name" >&2; exit 1; }

    [ -f "$r$PROBE_DST/drm.html" ] && [ -x "$r$PROBE_DST/probe.py" ] \
        || { echo "ERROR: DRM probe not installed" >&2; exit 1; }

    # CDM payload (a plant root has no apt-installed files; only check a real tree).
    if [ -z "$r" ]; then
        [ -f "$WV_DIR/manifest.json" ] \
            || { echo "ERROR: $WV_DIR/manifest.json missing (libwidevinecdm0)" >&2; exit 1; }
        [ -s "$WV_DIR/_platform_specific/linux_arm64/libwidevinecdm.so" ] \
            || { echo "ERROR: Widevine arm64 CDM library missing" >&2; exit 1; }
        [ "$(head -c4 "$WV_DIR/_platform_specific/linux_arm64/libwidevinecdm.so" | tail -c3)" = "ELF" ] \
            || { echo "ERROR: Widevine CDM library is not an ELF" >&2; exit 1; }
        [ -e /usr/bin/chromium ] || { echo "ERROR: /usr/bin/chromium missing (install-chromium-hwdec.sh)" >&2; exit 1; }
        case "$(readlink -f /etc/alternatives/x-www-browser 2>/dev/null || true)" in
            *chromium*) echo "ERROR: x-www-browser switched to chromium" >&2; exit 1 ;;
        esac
    fi
}

if [ "${1:-}" = "--verify" ]; then
    verify_widevine "${2:-}"
    exit 0
fi

if [ "${TL_SKIP_CHROMIUM_WIDEVINE:-0}" = "1" ] || [ "${TL_SKIP_CHROMIUM:-0}" = "1" ]; then
    echo "TL_SKIP_CHROMIUM_WIDEVINE/TL_SKIP_CHROMIUM=1: skipping Chromium (DRM) install"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo $0)" >&2
    exit 1
fi

arch="$(dpkg --print-architecture)"
[ "$arch" = "arm64" ] || { echo "ERROR: Chromium (DRM) build is arm64-only (this is $arch)" >&2; exit 1; }
[ -e /usr/bin/chromium ] || { echo "ERROR: /usr/bin/chromium missing - run install-chromium-hwdec.sh first" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
# Key + sources.list.d + the -10 pin for the Pi archive: owned by the HW-decode installer.
bash "$HERE/install-chromium-hwdec.sh" --ensure-apt
write_pin ""
apt-get update -q
NEEDRESTART_SUSPEND=1 apt-get install -y -q --no-install-recommends $WV_PKGS
# The pin must actually have selected the Pi archive build (not a stale/other origin).
apt-cache policy libwidevinecdm0 | grep -q 'archive.raspberrypi.com' \
    || { echo "ERROR: libwidevinecdm0 is not available from the Pi archive" >&2; exit 1; }
write_wrapper ""
write_desktop ""
install_probe ""
verify_widevine ""
echo "==> Chromium (DRM) installed: Widevine $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' $WV_DIR/manifest.json), launch: $WRAPPER"
