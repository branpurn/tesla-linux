#!/usr/bin/env bash
# Hardware-free checks for concurrent station + TeslaLinux AP (uap0).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/tesla-linux-wlan.sh"
fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
export TL_WLAN_SOURCED=1 AP_ENV=/nonexistent HOSTAPD_CONF="$tmp/h.conf" \
    HOSTAPD_CTRL="$tmp/ctrl" NET_SYSFS="$tmp/net" STA_STATE="$tmp/sta"
. "$HELPER"
set +e

[ "$(freq_to_chan 2462)" = 11 ] && pass "2462 MHz -> ch11" || bad "freq 2462"
[ "$(freq_to_chan 2412.0)" = 1 ] && pass "2412.0 MHz -> ch1" || bad "freq 2412"
[ "$(freq_to_chan 5180)" = 36 ] && pass "5180 MHz -> ch36" || bad "freq 5180"
freq_to_chan 5955 >/dev/null && bad "6 GHz must be unsupported" || pass "6 GHz unsupported"

write_hostapd_conf uap0 11
grep -qx 'interface=uap0' "$tmp/h.conf" && grep -qx 'channel=11' "$tmp/h.conf" && grep -qx 'hw_mode=g' "$tmp/h.conf" \
    && pass "hostapd on uap0 follows station ch11 (g)" || bad "hostapd ch11 conf"
write_hostapd_conf uap0 36
grep -qx 'channel=36' "$tmp/h.conf" && grep -qx 'hw_mode=a' "$tmp/h.conf" && pass "5 GHz station -> hw_mode=a ch36" || bad "hostapd ch36"
write_hostapd_conf wlan0
grep -qx 'channel=6' "$tmp/h.conf" && pass "solo default channel 6" || bad "default channel"
grep -q "^ctrl_interface=" "$tmp/h.conf" && pass "hostapd ctrl_interface (status/channel query)" || bad "ctrl_interface"

mkdir -p "$tmp/net/wlan0"; echo d8:3a:dd:d8:a7:d0 > "$tmp/net/wlan0/address"
m="$(ap_vif_mac wlan0)"
[ "$m" = d2:3a:dd:d8:a7:d0 ] && pass "uap0 MAC locally administered, distinct ($m)" || bad "vif mac $m"

AP_VIF=uap0
grep -q 'oifname != "$apif" masquerade' "$HELPER" && pass "AP NAT masquerades out any uplink (LTE or Wi-Fi WAN)" || bad "AP NAT"
awk '/^station_associated\(\)/,/^}/' "$HELPER" | grep -q 'hostapd_conf_iface' \
    && pass "hostapd on uap0 does not hide the wlan0 station" || bad "station_associated vs vif"
awk '/^wifi_iface\(\)/,/^}/' "$HELPER" | grep -q 'AP_VIF' && pass "wifi_iface never returns the AP vif" || bad "wifi_iface vif"
grep -q 'iw dev "$sta" interface add "$AP_VIF" type __ap' "$HELPER" && pass "creates __ap vif" || bad "vif create"
grep -q 'uap0' "$HERE/tesla-linux-alias.nft" && grep -q 'wlan0' "$HERE/tesla-linux-alias.nft" \
    && pass "198.18.0.1 DNAT on uap0 + wlan0" || bad "alias nft iface"
grep -q 'unmanaged-devices=interface-name:uap0' "$HERE/90-tesla-linux-uap0.conf" && pass "NM never manages uap0" || bad "nm conf"
grep -q 'rejoin-probe' "$HERE/tesla-linux-wlan-rejoin.service" && grep -q 'OnUnitActiveSec=30' "$HERE/tesla-linux-wlan-rejoin.timer" \
    && grep -q "KillMode=process" "$HERE/tesla-linux-wlan-rejoin.service" && pass "rejoin timer (hostapd survives oneshot)" || bad "rejoin timer"
grep -q '\[ "$IFACE" = uap0 \] && exit 0' "$HERE/install-tesla-linux.sh" && pass "dispatcher ignores uap0" || bad "dispatcher uap0"
grep -q 'tesla-linux-wlan-rejoin.timer' "$HERE/build-image.sh" && pass "build-image stages rejoin timer" || bad "build-image staging"
awk '/^leave_station\(\)/,/^}/' "$HELPER" | grep -q 'enx\|lte' && bad "leave_station touches LTE" || pass "LTE never touched by leave_station"
awk '/^go_solo\(\)/,/^}/' "$HELPER" | grep -Eq 'enx|LTE_CONN|tl-tunnel' && bad "go_solo touches LTE/tunnel" || pass "go_solo only touches wlan station"

[ "$fail" -eq 0 ] && echo "selftest-sta-ap-concurrent OK" || echo "selftest-sta-ap-concurrent FAILED"
exit "$fail"
