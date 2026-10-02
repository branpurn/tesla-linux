#!/usr/bin/env bash
# Tesla Linux — Widevine DRM for the Pi-archive Chromium (all launch paths).
#
# Widevine is a proprietary CDM (Google's, redistributed by Raspberry Pi in
# archive.raspberrypi.com as libwidevinecdm0). Raspberry Pi ships it for BOTH
# armhf and arm64 (same version, 4.10.2662.3); on this arm64 Pi 4 the arm64
# one loads in the existing 64-bit Chromium — no 32-bit userland needed (see
# docs/CHROMIUM-WIDEVINE.md for the evidence and why armhf was not installed).
#
# What this installs (Chromium is the single browser; EVERY launch path gets DRM):
#   * libwidevinecdm0 (arm64) from the Pi archive -> /opt/WidevineCdm, via its
#     own apt pin (only that package may come from archive.raspberrypi.com).
#   * /etc/chromium.d/tesla-linux-widevine — sourced by /usr/bin/chromium on
#     every start. Chromium finds the CDM through a per-profile hint file
#     (<profile>/WidevineCdm/latest-component-updated-widevine-cdm); this
#     snippet writes it into whichever profile is about to be used (default
#     ~/.config/chromium, or --user-data-dir), unless the profile already has a
#     working, newer component-updated CDM. So bare `chromium`, chromium.desktop,
#     xdg-open, x-www-browser and the Desktop icon all get Widevine + the
#     H.264 HW-decode flags/extension from /etc/chromium.d/tesla-linux.
#   * /usr/local/bin/chromium-drm — only a compatibility shim (-> /usr/bin/chromium).
#     The old separate "Chromium (DRM)" launcher/profile no longer exists.
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
FLAGS_FILE=/etc/chromium.d/tesla-linux-widevine
OLD_DESKTOP_IDS="tesla-linux-chromium-drm.desktop tesla-linux-chromium.desktop"
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

write_flags() {
    local r="${1:-}"
    install -d -m0755 "$r/etc/chromium.d"
    cat > "$r$FLAGS_FILE" <<'TLWV'
# Tesla Linux — Widevine DRM for EVERY Chromium launch (managed file,
# install-chromium-widevine.sh). /usr/bin/chromium sources /etc/chromium.d/* on
# each start, so bare `chromium`, chromium.desktop, xdg-open, x-www-browser and
# the Desktop icon all pass through here. Chromium (Debian/Pi build) has no
# bundled-CDM path: it loads the CDM named by a per-profile hint file, so make
# sure the profile about to be used has one. A working component-updated CDM
# already in the profile (Chromium's updater fetches linux_arm64 builds) wins.
tl_cdm=/opt/WidevineCdm
if [ -f "$tl_cdm/manifest.json" ]; then
    tl_prof=
    for tl_a in $CHROMIUM_FLAGS "$@"; do
        case "$tl_a" in --user-data-dir=*) tl_prof="${tl_a#--user-data-dir=}" ;; esac
    done
    [ -n "$tl_prof" ] || tl_prof="${XDG_CONFIG_HOME:-$HOME/.config}/chromium"
    tl_hint="$tl_prof/WidevineCdm/latest-component-updated-widevine-cdm"
    tl_cur="$(sed -n 's/.*"Path" *: *"\([^"]*\)".*/\1/p' "$tl_hint" 2>/dev/null)"
    if [ -z "$tl_cur" ] || [ ! -f "$tl_cur/manifest.json" ]; then
        { mkdir -p "$tl_prof/WidevineCdm" && printf '{"Path":"%s"}\n' "$tl_cdm" > "$tl_hint"; } 2>/dev/null || true
    fi
    unset tl_prof tl_hint tl_cur tl_a
fi
unset tl_cdm
TLWV
    chmod 0644 "$r$FLAGS_FILE"
}

# Compatibility shim only: scripts/tools that still call chromium-drm get the
# same single browser (all launch paths already have Widevine). TL_DRM_PROFILE
# still selects a throwaway profile for the probe/selftests.
write_wrapper() {
    local r="${1:-}"
    install -d -m0755 "$r/usr/local/bin"
    cat > "$r$WRAPPER" <<'TLWV'
#!/bin/sh
# Tesla Linux — compatibility shim. Chromium is the single browser and every
# launch path (this one included) has HW H.264 decode + Widevine via
# /etc/chromium.d/tesla-linux and /etc/chromium.d/tesla-linux-widevine.
if [ -n "${TL_DRM_PROFILE:-}" ]; then
    exec /usr/bin/chromium --user-data-dir="$TL_DRM_PROFILE" "$@"
fi
exec /usr/bin/chromium "$@"
TLWV
    chmod 0755 "$r$WRAPPER"
}

# The former separate "Chromium (DRM)" launcher is gone (one "Chromium" launcher
# is written by install-chromium-hwdec.sh).
remove_split_launchers() {
    local r="${1:-}" id
    for id in $OLD_DESKTOP_IDS; do
        rm -f "$r/usr/share/applications/$id"
    done
    rm -f "$r/home/$TL_USER/Desktop/Chromium-DRM.desktop" "$r/home/$TL_USER/Desktop/Chromium-HW-video.desktop"
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
    local pin="$r$PIN" w="$r$WRAPPER" f="$r$FLAGS_FILE" id

    [ -f "$pin" ] || { echo "ERROR: missing Widevine apt pin" >&2; exit 1; }
    grep -q '^Package: libwidevinecdm0$' "$pin" \
        || { echo "ERROR: Widevine pin does not name libwidevinecdm0 only" >&2; exit 1; }
    grep -q 'Pin: origin archive.raspberrypi.com' "$pin" \
        || { echo "ERROR: Widevine pin origin missing" >&2; exit 1; }
    if grep -Eq '^Package:.*(\*|chromium|firefox|linux-|raspi)' "$pin"; then
        echo "ERROR: Widevine pin allow-lists more than libwidevinecdm0" >&2
        exit 1
    fi

    [ -f "$f" ] || { echo "ERROR: $FLAGS_FILE missing (bare chromium would have no Widevine)" >&2; exit 1; }
    grep -q 'latest-component-updated-widevine-cdm' "$f" \
        || { echo "ERROR: $FLAGS_FILE does not write the Widevine hint file" >&2; exit 1; }
    grep -q '/opt/WidevineCdm' "$f" \
        || { echo "ERROR: $FLAGS_FILE does not point at $WV_DIR" >&2; exit 1; }
    grep -q -- '--user-data-dir=' "$f" \
        || { echo "ERROR: $FLAGS_FILE ignores --user-data-dir (hint would miss the real profile)" >&2; exit 1; }
    if grep -Eq -- '--no-sandbox|--disable-gpu([[:space:]"]|$)' "$f"; then
        echo "ERROR: $FLAGS_FILE must not disable the sandbox / GPU" >&2
        exit 1
    fi

    [ -x "$w" ] || { echo "ERROR: $WRAPPER missing or not executable" >&2; exit 1; }
    grep -q 'exec /usr/bin/chromium' "$w" \
        || { echo "ERROR: chromium-drm shim does not exec /usr/bin/chromium" >&2; exit 1; }
    if grep -Eq -- '--no-sandbox|--user-data-dir="?[^$"]' "$w"; then
        echo "ERROR: chromium-drm shim must not disable the sandbox or force a separate profile" >&2
        exit 1
    fi
    for id in $OLD_DESKTOP_IDS; do
        [ ! -e "$r/usr/share/applications/$id" ] \
            || { echo "ERROR: split launcher $id still present (single Chromium launcher only)" >&2; exit 1; }
    done

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
    fi
}

if [ "${1:-}" = "--verify" ]; then
    verify_widevine "${2:-}"
    exit 0
fi

if [ "${TL_SKIP_CHROMIUM_WIDEVINE:-0}" = "1" ] || [ "${TL_SKIP_CHROMIUM:-0}" = "1" ]; then
    echo "TL_SKIP_CHROMIUM_WIDEVINE/TL_SKIP_CHROMIUM=1: skipping Chromium Widevine install"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo $0)" >&2
    exit 1
fi

arch="$(dpkg --print-architecture)"
[ "$arch" = "arm64" ] || { echo "ERROR: Widevine Chromium build is arm64-only (this is $arch)" >&2; exit 1; }
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
write_flags ""
write_wrapper ""
remove_split_launchers ""
install_probe ""
verify_widevine ""
echo "==> Chromium Widevine installed: $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' $WV_DIR/manifest.json) (every launch path, via $FLAGS_FILE)"
