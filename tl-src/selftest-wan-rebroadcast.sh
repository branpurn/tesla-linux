#!/usr/bin/env bash
# Host-side plantable WAN rebroadcast gates (like selftest-kbm-on-display0).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/install-tesla-linux.sh"
HELPER="$HERE/tesla-linux-wlan.sh"
fail=0
n_pass=0
n_fail=0

pass() { echo "PASS: $*"; n_pass=$((n_pass + 1)); }
bad() { echo "FAIL: $*"; n_fail=$((n_fail + 1)); fail=1; }

expect_ok() {
    local name="$1"
    shift
    if "$@" >/tmp/tl-wan-ok.out 2>/tmp/tl-wan-ok.err; then
        pass "$name"
    else
        bad "$name (exit $?) stderr=$(tr '\n' ' ' </tmp/tl-wan-ok.err)"
    fi
}

expect_fail() {
    local name="$1" needle="$2"
    shift 2
    if "$@" >/tmp/tl-wan-bad.out 2>/tmp/tl-wan-bad.err; then
        bad "$name (expected fail, passed)"
    elif grep -q "$needle" /tmp/tl-wan-bad.err; then
        pass "$name"
    else
        bad "$name (wrong error: $(tr '\n' ' ' </tmp/tl-wan-bad.err))"
    fi
}

grep -q 'wan-ap|wan-rebroadcast|wan-up' "$HELPER" && pass "helper exposes wan-ap/wan-rebroadcast" \
    || bad "helper missing wan-ap/wan-rebroadcast"
grep -q 'wan-off|wan-down' "$HELPER" && pass "helper exposes wan-off" \
    || bad "helper missing wan-off"
grep -q 'mode.json' "$HELPER" && pass "helper honors mode.json" \
    || bad "helper missing mode.json"
grep -Eq 'masquerade|MASQUERADE' "$HELPER" && pass "helper has NAT/masquerade" \
    || bad "helper missing masquerade"
if awk '/^write_nginx_servers\(\)/,/^}/' "$HELPER" | grep -Eq 'listen 0\.0\.0\.0|listen 80;|listen \[::\]'; then
    bad "write_nginx_servers would bind nginx to 0.0.0.0"
else
    pass "write_nginx_servers never listen 0.0.0.0"
fi

TREE="$(mktemp -d /tmp/tl-wan-tree.XXXXXX)"
cleanup() { rm -rf "$TREE"; }
trap cleanup EXIT

plant() {
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/usr/local/sbin" \
             "$t/etc/tesla-linux" \
             "$t/etc/nginx" \
             "$t/etc/systemd/system" \
             "$t/etc/NetworkManager/dispatcher.d"
    cp "$HELPER" "$t/usr/local/sbin/tesla-linux-wlan"
    chmod +x "$t/usr/local/sbin/tesla-linux-wlan"
    cat > "$t/etc/tesla-linux/ap.env" <<'EOF'
AP_SSID=TeslaLinux
AP_PSK=teslalinux
AP_ADDR=10.42.0.1
ETH_ADDR=10.42.1.1
WAN_REBROADCAST=0
EOF
    echo "# no AP/station IPv4 yet; tesla-linux-wlan nginx-bind will rewrite" \
        > "$t/etc/nginx/tl-http-server.conf"
    echo "# no TLS binds yet" > "$t/etc/nginx/tl-https-server.conf"
    cat > "$t/etc/systemd/system/tesla-linux-wlan.service" <<'EOF'
[Unit]
Description=Tesla Linux WLAN
After=NetworkManager.service tesla-linux-firstboot.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tesla-linux-wlan boot
EOF
}

plant "$TREE"
expect_ok "verify-wan good tree" "$INSTALL" --verify-wan "$TREE"
expect_ok "helper selftest" "$HELPER" selftest
expect_ok "helper wan-verify" env NGINX_HTTP="$TREE/etc/nginx/tl-http-server.conf" \
    "$HELPER" wan-verify "$TREE/etc/tesla-linux/ap.env"

echo '{"mode":"wan_rebroadcast"}' > "$TREE/etc/tesla-linux/mode.json"
expect_ok "verify-wan with mode.json wan_rebroadcast" "$INSTALL" --verify-wan "$TREE"

sed -i '/AP_ADDR=/d' "$TREE/etc/tesla-linux/ap.env"
expect_fail "missing AP factory addr fails gate" "AP factory addr" \
    "$INSTALL" --verify-wan "$TREE"
plant "$TREE"

echo '    listen 0.0.0.0:80;' > "$TREE/etc/nginx/tl-http-server.conf"
expect_fail "nginx 0.0.0.0 listen fails gate" "0.0.0.0" \
    "$INSTALL" --verify-wan "$TREE"
plant "$TREE"

echo '{"mode":"wan_rebroadcast"}' > "$TREE/etc/tesla-linux/mode.json"
sed -i '/masquerade\|MASQUERADE/d' "$TREE/usr/local/sbin/tesla-linux-wlan"
expect_fail "NAT helper missing when mode selected" "NAT/masquerade" \
    "$INSTALL" --verify-wan "$TREE"

echo
echo "selftest-wan-rebroadcast: $n_pass passed, $n_fail failed"
exit "$fail"
