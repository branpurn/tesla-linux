#!/usr/bin/env bash
# Tesla Linux — "Google Chrome (DRM)": Google's official Chrome for Linux ARM64
# (dl.google.com apt repo) with its bundled native aarch64 Widevine CDM
# (/opt/google/chrome/WidevineCdm, newer than Raspberry Pi's libwidevinecdm0).
#
# Additive and parallel: the Pi-archive Chromium, "Chromium (DRM)" and Firefox are
# left alone, and Firefox stays x-www-browser (Google's postinst registers Chrome
# as x-www-browser at priority 200 — this installer undoes that and keeps it undone).
# Google Chrome has NO V4L2 hardware video decoder on this Pi (see
# docs/GOOGLE-CHROME-ARM64.md): clear H.264 is software-decoded.
#
# Idempotent. Live Pi or image-bake chroot.
#
#   install-google-chrome-arm64.sh                 apt key/source/pin + package + wrapper + launcher
#   install-google-chrome-arm64.sh --print-packages
#   install-google-chrome-arm64.sh --verify [ROOT] host-side / post-install gates
#
# Env: TL_USER (default teslalinux), TL_SKIP_GOOGLE_CHROME=1 to do nothing,
#      TL_GC_MIN_FREE_MB (default 900) minimum free space on / before installing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TL_USER="${TL_USER:-teslalinux}"

GC_PKGS="google-chrome-stable"
GC_KEY_URL=https://dl.google.com/linux/linux_signing_key.pub
GC_KEY_FP=EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796
GC_KEYRING=/etc/apt/keyrings/google-chrome.asc
GC_SOURCES=/etc/apt/sources.list.d/google-chrome.sources
GC_PIN=/etc/apt/preferences.d/google-chrome
GC_DEFAULTS=/etc/default/google-chrome
GC_HOOK=/etc/apt/apt.conf.d/99tesla-linux-google-chrome
GC_CONF=/etc/tesla-linux/google-chrome.conf
GC_WRAPPER=/usr/local/bin/google-chrome-tl
GC_POLICY=/etc/opt/chrome/policies/managed/tesla-linux.json
GC_EXT_DIR=/usr/share/tesla-linux/chrome-ext
GC_EXT_KEY=/etc/tesla-linux/chrome-h264only.pem
DESKTOP_ID=tesla-linux-google-chrome.desktop

if [ "${1:-}" = "--print-packages" ]; then echo "$GC_PKGS"; exit 0; fi

# Same repo/suite/format Google's own postinst writes, so a package upgrade
# rewriting this file changes nothing material (and never adds a second entry).
write_apt() {
    local r="${1:-}"
    install -d -m0755 "$r/etc/apt/sources.list.d" "$r/etc/apt/preferences.d" "$r/etc/default"
    cat > "$r$GC_SOURCES" <<EOF
Types: deb
URIs: https://dl.google.com/linux/chrome/deb/
Suites: stable
Components: main
Architectures: arm64
Signed-By: $GC_KEYRING
EOF
    chmod 0644 "$r$GC_SOURCES"
    # The whole Google repo is pinned out except the one package.
    cat > "$r$GC_PIN" <<EOF
Package: *
Pin: origin dl.google.com
Pin-Priority: -10

Package: $GC_PKGS
Pin: origin dl.google.com
Pin-Priority: 990
EOF
    chmod 0644 "$r$GC_PIN"
    # Tell Google's postinst/cron the repo is already configured (don't re-add it).
    if [ ! -e "$r$GC_DEFAULTS" ]; then
        printf 'repo_add_once="false"\nrepo_reenable_on_distupgrade="false"\n' > "$r$GC_DEFAULTS"
    fi
    # Google's postinst makes Chrome x-www-browser (prio 200 > firefox 100). Undo
    # after every dpkg run so upgrades can't flip the default browser.
    cat > "$r$GC_HOOK" <<'EOF'
// Tesla Linux: keep Firefox as x-www-browser when google-chrome-stable is (up)graded.
DPkg::Post-Invoke { "if [ -e /usr/bin/firefox ]; then update-alternatives --remove x-www-browser /usr/bin/google-chrome-stable >/dev/null 2>&1; update-alternatives --remove gnome-www-browser /usr/bin/google-chrome-stable >/dev/null 2>&1; fi; true"; };
EOF
    chmod 0644 "$r$GC_HOOK"
}

ensure_apt() {
    local tmp fp
    export DEBIAN_FRONTEND=noninteractive
    install -d -m0755 /etc/apt/keyrings
    if ! command -v curl >/dev/null 2>&1; then
        apt-get install -y -q --no-install-recommends ca-certificates curl
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        apt-get install -y -q --no-install-recommends gpg
    fi
    tmp="$(mktemp)"
    curl -fsSL "$GC_KEY_URL" -o "$tmp"
    fp="$(gpg --homedir "$(mktemp -d)" --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
    if [ "$fp" != "$GC_KEY_FP" ]; then
        rm -f "$tmp"
        echo "ERROR: Google Linux signing key fingerprint mismatch (got '$fp')" >&2
        exit 1
    fi
    install -m0644 "$tmp" "$GC_KEYRING"
    rm -f "$tmp"
    write_apt ""
}

# tl-h264-only (same extension the Pi Chromium loads) as a signed CRX served from a
# local update manifest and force-installed by policy: branded Chrome >= 137 ignores
# --load-extension. Without it YouTube serves AV1 (dav1d software decode) to Chrome,
# the most expensive codec for this CPU. TL_GC_H264ONLY=0 disables it.
install_h264_ext() {
    local r="${1:-}" src="$HERE/chromium/h264-only"
    [ "${TL_GC_H264ONLY:-1}" = "1" ] || return 0
    [ -f "$src/manifest.json" ] && [ -f "$src/h264only.js" ] && [ -f "$src/pack-crx3.py" ] \
        || { echo "ERROR: $src (h264-only extension + pack-crx3.py) missing" >&2; exit 1; }
    install -d -m0755 "$r$GC_EXT_DIR" "$r/etc/tesla-linux"
    python3 "$src/pack-crx3.py" "$src" "$r$GC_EXT_KEY" "$r$GC_EXT_DIR" \
        --base-url "file://$GC_EXT_DIR" > "$r$GC_EXT_DIR/extension-id"
    chmod 0644 "$r$GC_EXT_DIR"/h264only.crx "$r$GC_EXT_DIR"/updates.xml "$r$GC_EXT_DIR"/extension-id
}

write_policy() {
    local r="${1:-}" id="" force=""
    install -d -m0755 "$r/etc/opt/chrome/policies/managed"
    if [ -s "$r$GC_EXT_DIR/extension-id" ]; then
        id="$(cat "$r$GC_EXT_DIR/extension-id")"
        force=$',\n  "ExtensionInstallForcelist": ["'"$id"';file://'"$GC_EXT_DIR"'/updates.xml"]'
    fi
    cat > "$r$GC_POLICY" <<EOF
{
  "HardwareAccelerationModeEnabled": true,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "BackgroundModeEnabled": false,
  "PromotionalTabsEnabled": false$force
}
EOF
    chmod 0644 "$r$GC_POLICY"
}

# Sourced by the wrapper. Flags are measured, see docs/GOOGLE-CHROME-ARM64.md.
write_conf() {
    local r="${1:-}"
    install -d -m0755 "$r/etc/tesla-linux"
    cat > "$r$GC_CONF" <<'EOF'
# Tesla Linux — Google Chrome (DRM) flags (managed file, sourced by google-chrome-tl).
# Chrome picks ANGLE/GLES on the V3D GPU by itself (chrome://gpu). It has no V4L2
# video decoder, so there is no flag for HW decode. --disable-frame-rate-limit
# is the same presentation fix the Pi Chromium flags file uses.
CHROME_FLAGS="--ozone-platform=x11 --start-maximized --disable-frame-rate-limit"
CHROME_FLAGS="$CHROME_FLAGS --no-first-run --no-default-browser-check --password-store=basic"
CHROME_FLAGS="$CHROME_FLAGS --disable-session-crashed-bubble --hide-crash-restore-bubble"
EOF
    chmod 0644 "$r$GC_CONF"
}

write_wrapper() {
    local r="${1:-}"
    install -d -m0755 "$r/usr/local/bin"
    cat > "$r$GC_WRAPPER" <<'EOF'
#!/bin/sh
# Tesla Linux — Google Chrome (DRM): /usr/bin/google-chrome-stable + managed flags.
# Widevine is bundled (/opt/google/chrome/WidevineCdm) — nothing to wire up.
# Profile: ~/.config/google-chrome (Chrome's default).
CHROME_FLAGS=""
[ -r /etc/tesla-linux/google-chrome.conf ] && . /etc/tesla-linux/google-chrome.conf
exec /usr/bin/google-chrome-stable $CHROME_FLAGS "$@"
EOF
    chmod 0755 "$r$GC_WRAPPER"
}

write_desktop() {
    local r="${1:-}"
    install -d -m0755 "$r/usr/share/applications"
    cat > "$r/usr/share/applications/$DESKTOP_ID" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome (DRM)
GenericName=Web Browser
Comment=Google Chrome (ARM64) with its bundled Widevine CDM (Netflix etc., L3); software video decode
Exec=$GC_WRAPPER %U
Icon=google-chrome
Terminal=false
StartupNotify=true
StartupWMClass=Google-chrome
Categories=Network;WebBrowser;
Keywords=Netflix;Widevine;DRM;Chrome;
EOF
    chmod 0644 "$r/usr/share/applications/$DESKTOP_ID"
    local home="$r/home/$TL_USER"
    if [ -d "$home" ]; then
        install -d "$home/Desktop"
        install -m0755 "$r/usr/share/applications/$DESKTOP_ID" "$home/Desktop/Google-Chrome-DRM.desktop"
        if [ -z "$r" ]; then chown -R "$TL_USER:$TL_USER" "$home/Desktop" 2>/dev/null || true; fi
    fi
}

# Google's postinst registers x-www-browser at priority 200; Firefox must stay default.
fix_alternatives() {
    [ -e /usr/bin/firefox ] || return 0
    update-alternatives --remove x-www-browser /usr/bin/google-chrome-stable >/dev/null 2>&1 || true
    update-alternatives --remove gnome-www-browser /usr/bin/google-chrome-stable >/dev/null 2>&1 || true
}

verify_google_chrome() {
    local r="${1:-}"
    local src="$r$GC_SOURCES" pin="$r$GC_PIN" w="$r$GC_WRAPPER" c="$r$GC_CONF" d="$r/usr/share/applications/$DESKTOP_ID"

    [ -f "$src" ] || { echo "ERROR: missing Google Chrome apt source" >&2; exit 1; }
    grep -q 'dl.google.com/linux/chrome' "$src" \
        || { echo "ERROR: Google Chrome apt source is not dl.google.com" >&2; exit 1; }
    grep -q '^Signed-By: ' "$src" \
        || { echo "ERROR: Google Chrome apt source is not Signed-By a keyring" >&2; exit 1; }
    grep -q '^Architectures: arm64$' "$src" \
        || { echo "ERROR: Google Chrome apt source is not arm64-only" >&2; exit 1; }

    [ -f "$pin" ] || { echo "ERROR: missing Google Chrome apt pin" >&2; exit 1; }
    grep -q 'Pin: origin dl.google.com' "$pin" \
        || { echo "ERROR: Google Chrome pin origin missing" >&2; exit 1; }
    grep -q '^Pin-Priority: -10$' "$pin" \
        || { echo "ERROR: Google repo is not pinned out by default" >&2; exit 1; }
    grep -Eq '^Package: google-chrome-stable$' "$pin" \
        || { echo "ERROR: google-chrome-stable is not allow-listed from the Google repo" >&2; exit 1; }
    if grep -Eq '^Package:.*(beta|unstable|canary|\*[^ ]|firefox|linux-|raspi|chromium)' "$pin"; then
        echo "ERROR: Google Chrome pin allow-lists more than google-chrome-stable" >&2
        exit 1
    fi

    [ -x "$w" ] || { echo "ERROR: $GC_WRAPPER missing or not executable" >&2; exit 1; }
    grep -q 'exec /usr/bin/google-chrome-stable' "$w" \
        || { echo "ERROR: google-chrome-tl does not wrap /usr/bin/google-chrome-stable" >&2; exit 1; }
    if grep -q -- '--no-sandbox' "$w" "$c" 2>/dev/null; then
        echo "ERROR: Google Chrome flags must not disable the sandbox" >&2
        exit 1
    fi
    [ -f "$c" ] || { echo "ERROR: Google Chrome flags file missing" >&2; exit 1; }
    grep -q -- '--ozone-platform=x11' "$c" \
        || { echo "ERROR: Google Chrome flags lack --ozone-platform=x11" >&2; exit 1; }

    [ -f "$r$GC_POLICY" ] || { echo "ERROR: Google Chrome managed policy missing" >&2; exit 1; }
    grep -q '"DefaultBrowserSettingEnabled": false' "$r$GC_POLICY" \
        || { echo "ERROR: Google Chrome policy lacks DefaultBrowserSettingEnabled=false" >&2; exit 1; }

    if grep -q ExtensionInstallForcelist "$r$GC_POLICY"; then
        grep -q "file://$GC_EXT_DIR/updates.xml" "$r$GC_POLICY" \
            || { echo "ERROR: h264-only force-install policy does not point at $GC_EXT_DIR/updates.xml" >&2; exit 1; }
        [ -s "$r$GC_EXT_DIR/h264only.crx" ] && [ -s "$r$GC_EXT_DIR/updates.xml" ] \
            || { echo "ERROR: h264-only CRX / update manifest missing in $GC_EXT_DIR" >&2; exit 1; }
        [ "$(head -c4 "$r$GC_EXT_DIR/h264only.crx")" = "Cr24" ] \
            || { echo "ERROR: h264only.crx is not a CRX" >&2; exit 1; }
    fi

    [ -f "$r$GC_HOOK" ] || { echo "ERROR: x-www-browser guard (apt hook) missing" >&2; exit 1; }

    [ -f "$d" ] || { echo "ERROR: Google Chrome (DRM) desktop entry missing" >&2; exit 1; }
    grep -q "^Exec=$GC_WRAPPER" "$d" \
        || { echo "ERROR: Google Chrome desktop entry does not run $GC_WRAPPER" >&2; exit 1; }
    grep -q '^Name=Google Chrome (DRM)$' "$d" \
        || { echo "ERROR: Google Chrome desktop entry name" >&2; exit 1; }

    # The package payload exists only on a real tree.
    if [ -z "$r" ]; then
        [ -s "$GC_KEYRING" ] || { echo "ERROR: Google apt keyring missing" >&2; exit 1; }
        [ -x /opt/google/chrome/chrome ] || { echo "ERROR: /opt/google/chrome/chrome missing" >&2; exit 1; }
        [ "$(dpkg-query -W -f='${Architecture}' google-chrome-stable 2>/dev/null)" = "arm64" ] \
            || { echo "ERROR: google-chrome-stable is not installed as arm64" >&2; exit 1; }
        [ -s /opt/google/chrome/WidevineCdm/_platform_specific/linux_arm64/libwidevinecdm.so ] \
            || { echo "ERROR: bundled Widevine arm64 CDM missing" >&2; exit 1; }
        grep -q '"version"' /opt/google/chrome/WidevineCdm/manifest.json \
            || { echo "ERROR: Widevine manifest has no version" >&2; exit 1; }
        if [ -e /usr/bin/firefox ]; then
            case "$(readlink -f /etc/alternatives/x-www-browser 2>/dev/null || true)" in
                *google-chrome*|*chromium*) echo "ERROR: x-www-browser switched away from Firefox" >&2; exit 1 ;;
            esac
        fi
    fi
}

if [ "${1:-}" = "--verify" ]; then
    verify_google_chrome "${2:-}"
    exit 0
fi

if [ "${TL_SKIP_GOOGLE_CHROME:-0}" = "1" ]; then
    echo "TL_SKIP_GOOGLE_CHROME=1: skipping Google Chrome (ARM64) install"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo $0)" >&2
    exit 1
fi

arch="$(dpkg --print-architecture)"
[ "$arch" = "arm64" ] || { echo "ERROR: Google Chrome (ARM64) is arm64-only (this is $arch)" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
if ! dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null | grep -q 'ok installed'; then
    free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
    min="${TL_GC_MIN_FREE_MB:-900}"
    if [ "$free_mb" -lt "$min" ]; then
        echo "ERROR: only ${free_mb} MB free on /, Google Chrome needs ~${min} MB (134 MB download + 440 MB installed)." >&2
        echo "       Free space (apt-get clean; remove old logs) or set TL_SKIP_GOOGLE_CHROME=1." >&2
        exit 1
    fi
fi
ensure_apt
apt-get update -q
# NEEDRESTART_SUSPEND: no service restarts (sshd / tunnel / display) during a live install.
NEEDRESTART_SUSPEND=1 apt-get install -y -q --no-install-recommends $GC_PKGS
# The package must be the arm64 build from Google's repo (not some other origin).
apt-cache policy google-chrome-stable | grep -q 'dl.google.com' \
    || { echo "ERROR: google-chrome-stable is not from dl.google.com" >&2; exit 1; }
# Its postinst re-creates google-chrome.sources (equivalent) and changes x-www-browser.
write_apt ""
fix_alternatives
install_h264_ext ""
write_policy ""
write_conf ""
write_wrapper ""
write_desktop ""
# Drop the 134 MB .deb from the apt cache (disk is tight on the 8 GB card).
rm -f /var/cache/apt/archives/google-chrome-stable_*.deb
verify_google_chrome ""
echo "==> Google Chrome (DRM) installed: $(/opt/google/chrome/chrome --version 2>/dev/null | head -1), Widevine $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' /opt/google/chrome/WidevineCdm/manifest.json), launch: $GC_WRAPPER"
