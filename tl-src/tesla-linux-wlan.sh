#!/usr/bin/env bash
# Tesla Linux WAVE 1 — saved-WLAN station else TeslaLinux hostapd AP.
# Alternate: WAN rebroadcast — AP stays up; ethernet WAN is NAT'd to AP clients.
#
# NetworkManager owns infrastructure (station) autoconnect.
# Fallback AP is hostapd + dnsmasq (not nmcli hotspot), SSID TeslaLinux.
# nginx listen is rewritten to the current AP / station / ethernet IPv4s only
# (never 0.0.0.0, never loopback-only). teslalinux.local is existing avahi.
# WAN mode never binds nginx to a DHCP WAN address — operators use 10.42.0.1
# (AP) and 10.42.1.1 (factory ethernet). Do not guess a station DHCP IP.
#
# FRONTEND-HOLE (this SHA): pick/save WLAN UI — do not invent a settings maze.
# HDMI and web capture share XFCE on Xorg :0. AP must not wait on X.
set -euo pipefail

AP_ENV="${AP_ENV:-/etc/tesla-linux/ap.env}"
# shellcheck source=/dev/null
[ -f "$AP_ENV" ] && . "$AP_ENV"

AP_SSID="${AP_SSID:-TeslaLinux}"
AP_PSK="${AP_PSK:-teslalinux}"
AP_IFACE="${AP_IFACE:-}"
AP_ADDR="${AP_ADDR:-10.42.0.1}"
AP_PREFIX="${AP_PREFIX:-24}"
AP_DHCP_START="${AP_DHCP_START:-10.42.0.10}"
AP_DHCP_END="${AP_DHCP_END:-10.42.0.200}"
ETH_ADDR="${ETH_ADDR:-10.42.1.1}"
ETH_PREFIX="${ETH_PREFIX:-24}"
ETH_CONN="${ETH_CONN:-tesla-linux-eth}"
WAIT_SEC="${WAIT_SEC:-20}"
# brcmfmac often appears after this oneshot first runs — wait, then fail so systemd restarts.
IFACE_WAIT_SEC="${IFACE_WAIT_SEC:-60}"
# Alternate mode: AP stays up; do not join a station WLAN. Ethernet WAN is NAT'd.
# Backend persist is /etc/tesla-linux/mode.json (POST /api/mode). Missing = station.
# wan-ap/wan-up also plants /run/tesla-linux-wan for this boot.
WAN_REBROADCAST="${WAN_REBROADCAST:-0}"
WAN_RUNTIME="${WAN_RUNTIME:-/run/tesla-linux-wan}"
MODE_FILE="${MODE_FILE:-/etc/tesla-linux/mode.json}"

HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/tesla-linux/hostapd.conf}"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/tesla-linux/dnsmasq-ap.conf}"
HOSTAPD_PID="${HOSTAPD_PID:-/run/tesla-linux-hostapd.pid}"
DNSMASQ_PID="${DNSMASQ_PID:-/run/tesla-linux-dnsmasq.pid}"
NGINX_HTTP="${NGINX_HTTP:-/etc/nginx/tl-http-server.conf}"
NGINX_HTTPS="${NGINX_HTTPS:-/etc/nginx/tl-https-server.conf}"
NGINX_LOCS="${NGINX_LOCS:-/etc/nginx/tl-locations.conf}"
LOCK="${LOCK:-/run/tesla-linux-wlan.lock}"

log() { echo "tesla-linux-wlan: $*" >&2; }

with_lock() {
    mkdir -p "$(dirname "$LOCK")"
    exec 9>"$LOCK"
    flock 9
}

wifi_iface() {
    if [ -n "$AP_IFACE" ] && [ -e "/sys/class/net/$AP_IFACE" ]; then
        echo "$AP_IFACE"
        return 0
    fi
    local d n
    d="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}' || true)"
    if [ -n "$d" ]; then
        echo "$d"
        return 0
    fi
    for n in /sys/class/net/*/wireless; do
        [ -e "$n" ] || continue
        basename "$(dirname "$n")"
        return 0
    done
    return 1
}

# Wired / VM-virtio ethernet we may bind nginx to (eth0, end0, en*).
# Not lo, not docker/veth, not wifi. Type ARPHRD_ETHER=1.
is_wired_iface() {
    local n="$1"
    [ -n "$n" ] || return 1
    case "$n" in
        lo|docker*|veth*|br-*|virbr*|tun*|wg*) return 1 ;;
    esac
    [ -e "/sys/class/net/$n" ] || return 1
    [ -e "/sys/class/net/$n/wireless" ] && return 1
    [ "$(cat "/sys/class/net/$n/type" 2>/dev/null || echo 0)" = "1" ]
}

wired_ifaces() {
    local n
    for n in /sys/class/net/*; do
        [ -e "$n" ] || continue
        n="$(basename "$n")"
        is_wired_iface "$n" || continue
        printf '%s\n' "$n"
    done
}

# Primary jack / VM nic: eth0, then end0, then first en*.
primary_wired_iface() {
    local n
    for n in eth0 end0; do
        is_wired_iface "$n" && { printf '%s\n' "$n"; return 0; }
    done
    for n in /sys/class/net/en*; do
        [ -e "$n" ] || continue
        n="$(basename "$n")"
        is_wired_iface "$n" && { printf '%s\n' "$n"; return 0; }
    done
    n="$(wired_ifaces | head -n1)"
    [ -n "$n" ] && { printf '%s\n' "$n"; return 0; }
    return 1
}

wait_wifi_iface() {
    local i=0 iface
    while :; do
        if iface="$(wifi_iface)"; then
            printf '%s\n' "$iface"
            return 0
        fi
        [ "$i" -ge "$IFACE_WAIT_SEC" ] && break
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# usb-net / cdc_ether / virtio can appear after this oneshot first runs (qemu).
wait_wired_iface() {
    local i=0 iface
    while :; do
        if iface="$(primary_wired_iface)"; then
            printf '%s\n' "$iface"
            return 0
        fi
        [ "$i" -ge "$IFACE_WAIT_SEC" ] && break
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# True when factory ethernet static is on a wired iface (nginx-bind path without AP).
eth_static_bound() {
    local n
    is_bindable_ipv4 "$ETH_ADDR" || return 1
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        if iface_ipv4s "$n" | grep -qx "$ETH_ADDR"; then
            return 0
        fi
    done < <(wired_ifaces)
    return 1
}

# Backend persist: {"mode":"wan_rebroadcast"|"station"}. Missing/corrupt = station.
persisted_mode() {
    local f="${MODE_FILE:-/etc/tesla-linux/mode.json}"
    if [ -f "$f" ] && grep -Eq '"mode"[[:space:]]*:[[:space:]]*"wan_rebroadcast"' "$f"; then
        printf '%s\n' wan_rebroadcast
        return 0
    fi
    printf '%s\n' station
}

# AP-stays-up + NAT when mode.json is wan_rebroadcast, ap.env flag, or wan-ap runtime.
wan_mode_on() {
    case "${WAN_REBROADCAST:-0}" in
        1|yes|true|on|ON) return 0 ;;
    esac
    [ -f "$WAN_RUNTIME" ] && return 0
    [ "$(persisted_mode)" = wan_rebroadcast ]
}

# AP client subnet for NAT (factory 10.42.0.1/24 → 10.42.0.0/24).
ap_client_net() {
    printf '%s.0/%s\n' "${AP_ADDR%.*}" "${AP_PREFIX}"
}

have_nft() { command -v nft >/dev/null 2>&1; }
have_iptables() { command -v iptables >/dev/null 2>&1; }

set_ip_forward() {
    if [ -w /proc/sys/net/ipv4/ip_forward ]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
    else
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    fi
}

# Wired iface with a default route, else a non-factory bindable IPv4 (WAN DHCP).
wan_uplink_iface() {
    local n ip gw
    gw="$(ip -4 route show default 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
    if [ -n "$gw" ] && is_wired_iface "$gw"; then
        printf '%s\n' "$gw"
        return 0
    fi
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            [ "$ip" = "$ETH_ADDR" ] && continue
            [ "$ip" = "$AP_ADDR" ] && continue
            is_bindable_ipv4 "$ip" || continue
            printf '%s\n' "$n"
            return 0
        done < <(iface_ipv4s "$n")
    done < <(wired_ifaces)
    return 1
}

# Idempotent NAT: AP 10.42.0.0/24 masquerade out the wired WAN uplink.
# nftables table tesla-linux-wan if nft exists; else iptables. No LTE drivers.
apply_wan_nat() {
    local wan net
    net="$(ap_client_net)"
    if ! wan="$(wan_uplink_iface)"; then
        log "no wired WAN uplink yet; NAT not applied (factory $ETH_ADDR / AP $AP_ADDR still documented)"
        return 0
    fi
    set_ip_forward
    if have_nft; then
        nft delete table ip tesla-linux-wan >/dev/null 2>&1 || true
        nft -f - <<EOF
table ip tesla-linux-wan {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $net oifname "$wan" masquerade
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        ip saddr $net oifname "$wan" accept
        iifname "$wan" ip daddr $net ct state related,established accept
    }
}
EOF
        log "nft tesla-linux-wan masquerade $net -> $wan"
        return 0
    fi
    if have_iptables; then
        if ! iptables -t nat -C POSTROUTING -s "$net" -o "$wan" -m comment --comment tesla-linux-wan -j MASQUERADE 2>/dev/null; then
            iptables -t nat -A POSTROUTING -s "$net" -o "$wan" -m comment --comment tesla-linux-wan -j MASQUERADE
        fi
        if ! iptables -C FORWARD -s "$net" -o "$wan" -m comment --comment tesla-linux-wan -j ACCEPT 2>/dev/null; then
            iptables -A FORWARD -s "$net" -o "$wan" -m comment --comment tesla-linux-wan -j ACCEPT
        fi
        if ! iptables -C FORWARD -d "$net" -m state --state RELATED,ESTABLISHED -m comment --comment tesla-linux-wan -j ACCEPT 2>/dev/null; then
            iptables -A FORWARD -d "$net" -m state --state RELATED,ESTABLISHED -m comment --comment tesla-linux-wan -j ACCEPT
        fi
        log "iptables tesla-linux-wan MASQUERADE $net -> $wan"
        return 0
    fi
    log "nft/iptables missing; cannot NAT $net"
    return 1
}

remove_wan_nat() {
    if have_nft; then
        nft delete table ip tesla-linux-wan >/dev/null 2>&1 || true
    fi
    if have_iptables; then
        local spec
        while spec="$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -F tesla-linux-wan | head -n1)"; do
            [ -n "$spec" ] || break
            # shellcheck disable=SC2086
            iptables -t nat -D ${spec#-A } 2>/dev/null || break
        done
        while spec="$(iptables -S FORWARD 2>/dev/null | grep -F tesla-linux-wan | head -n1)"; do
            [ -n "$spec" ] || break
            # shellcheck disable=SC2086
            iptables -D ${spec#-A } 2>/dev/null || break
        done
    fi
    rm -f "$WAN_RUNTIME"
}

is_ap_conn() {
    local name="$1" mode
    [ -n "$name" ] || return 1
    [ "$name" = "$AP_SSID" ] && return 0
    mode="$(nmcli -g 802-11-wireless.mode connection show "$name" 2>/dev/null || true)"
    [ "$mode" = "ap" ]
}

# Print saved infrastructure Wi-Fi connection names (not the TeslaLinux AP).
saved_infra_names() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless" || $2=="wifi" {print $1}' \
        | while IFS= read -r n; do
            [ -n "$n" ] || continue
            is_ap_conn "$n" && continue
            printf '%s\n' "$n"
        done
}

has_saved_infra() {
    [ -n "$(saved_infra_names)" ]
}

# True when iface is associated to an infrastructure SSID (not our AP).
station_associated() {
    local iface="${1:-}"
    [ -n "$iface" ] || return 1
    if [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID" 2>/dev/null)" 2>/dev/null; then
        return 1
    fi
    local line state conn
    line="$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null \
        | awk -F: -v i="$iface" '$1==i && $2=="wifi" {print; exit}' || true)"
    state="$(printf '%s' "$line" | cut -d: -f3)"
    conn="$(printf '%s' "$line" | cut -d: -f4)"
    if [ "$state" = "connected" ] && [ -n "$conn" ] && ! is_ap_conn "$conn"; then
        return 0
    fi
    # Unmanaged / NM lag: iw "Connected to" means station, not our hostapd AP.
    if command -v iw >/dev/null 2>&1 \
        && iw dev "$iface" link 2>/dev/null | grep -q '^Connected'; then
        return 0
    fi
    return 1
}

kick_nm_station() {
    local iface="$1" n
    nmcli radio wifi on 2>/dev/null || true
    rfkill unblock wifi 2>/dev/null || true
    nmcli device set "$iface" managed yes 2>/dev/null || true
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        nmcli connection modify "$n" connection.autoconnect yes 2>/dev/null || true
    done < <(saved_infra_names)
    nmcli device connect "$iface" 2>/dev/null || true
}

wait_station() {
    local iface="$1" i
    kick_nm_station "$iface"
    i=0
    while [ "$i" -lt "$WAIT_SEC" ]; do
        if station_associated "$iface"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

hostapd_running() {
    [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID" 2>/dev/null)" 2>/dev/null
}

dnsmasq_running() {
    [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null
}

write_hostapd_conf() {
    local iface="$1"
    mkdir -p "$(dirname "$HOSTAPD_CONF")"
    cat > "$HOSTAPD_CONF" <<EOF
# Generated from $AP_ENV — SSID $AP_SSID (factory PSK in ap.env / docs).
interface=$iface
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PSK
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    chmod 600 "$HOSTAPD_CONF"
}

write_dnsmasq_conf() {
    local iface="$1"
    mkdir -p "$(dirname "$DNSMASQ_CONF")"
    cat > "$DNSMASQ_CONF" <<EOF
# AP DHCP only (no DNS — clients use http://$AP_ADDR/).
interface=$iface
bind-interfaces
except-interface=lo
listen-address=$AP_ADDR
port=0
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,12h
dhcp-option=3,$AP_ADDR
EOF
    if wan_mode_on; then
        cat >> "$DNSMASQ_CONF" <<EOF
# WAN rebroadcast: AP clients use public DNS (no guess-the-station-IP path).
dhcp-option=6,1.1.1.1,8.8.8.8
EOF
    fi
}

stop_pidfile() {
    local pidfile="$1" name="$2"
    if [ -f "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.2
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
    pkill -x "$name" 2>/dev/null || true
}

# IPv4s we may bind nginx to: never 0.0.0.0 / loopback / link-local.
is_bindable_ipv4() {
    local ip="$1"
    case "$ip" in
        ''|0.0.0.0|127.*|169.254.*) return 1 ;;
        *:*) return 1 ;;
        *.*.*.*) return 0 ;;
    esac
    return 1
}

# Args or stdin: candidate addresses (optional /prefix). Prints unique bindable IPv4s.
filter_addrs() {
    local a seen="|"
    if [ "$#" -gt 0 ]; then
        for a in "$@"; do
            a="${a%%/*}"
            a="${a%%[[:space:]]*}"
            is_bindable_ipv4 "$a" || continue
            case "$seen" in
                *"|$a|"*) continue ;;
            esac
            seen="${seen}${a}|"
            printf '%s\n' "$a"
        done
        return 0
    fi
    while IFS= read -r a; do
        a="${a%%/*}"
        a="${a%%[[:space:]]*}"
        is_bindable_ipv4 "$a" || continue
        case "$seen" in
            *"|$a|"*) continue ;;
        esac
        seen="${seen}${a}|"
        printf '%s\n' "$a"
    done
}

iface_ipv4s() {
    local iface="$1"
    [ -n "$iface" ] || return 0
    ip -4 -o addr show dev "$iface" 2>/dev/null \
        | awk '{print $4}' \
        | filter_addrs
}

collect_bind_ips() {
    local iface="${1:-}" n ip
    local seen="|"
    _emit_ip() {
        local a="$1"
        [ -n "$a" ] || return 0
        case "$seen" in *"|$a|"*) return 0 ;; esac
        seen="${seen}${a}|"
        printf '%s\n' "$a"
    }
    if [ -n "$iface" ]; then
        while IFS= read -r ip; do
            # WAN mode: never bind nginx to a station/WAN DHCP address on wifi.
            if wan_mode_on && [ "$ip" != "$AP_ADDR" ] && [ "$ip" != "$ETH_ADDR" ]; then
                continue
            fi
            _emit_ip "$ip"
        done < <(iface_ipv4s "$iface")
    fi
    # Wired eth0/end0/en* (and VM virtio) — picker/desktop on the same ethernet.
    # WAN mode: factory 10.42.1.1 only — do not bind the WAN DHCP IPv4.
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ "$n" = "$iface" ] && continue
        while IFS= read -r ip; do
            if wan_mode_on && [ "$ip" != "$ETH_ADDR" ]; then
                continue
            fi
            _emit_ip "$ip"
        done < <(iface_ipv4s "$n")
    done < <(wired_ifaces)
    if hostapd_running && is_bindable_ipv4 "$AP_ADDR"; then
        _emit_ip "$AP_ADDR"
    fi
    # Factory ethernet static (10.42.1.1) when assigned — never 0.0.0.0.
    if is_bindable_ipv4 "$ETH_ADDR"; then
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            if iface_ipv4s "$n" | grep -qx "$ETH_ADDR"; then
                _emit_ip "$ETH_ADDR"
                break
            fi
        done < <(wired_ifaces)
    fi
}

write_nginx_servers() {
    local ips="$1" ip
    mkdir -p "$(dirname "$NGINX_HTTP")"
    if [ -z "$ips" ]; then
        # No address yet — do not emit a listen (avoids 0.0.0.0 and a dead bind).
        echo "# no AP/station IPv4 yet; tesla-linux-wlan nginx-bind will rewrite" > "$NGINX_HTTP"
        echo "# no TLS binds yet" > "$NGINX_HTTPS"
        return 0
    fi
    {
        echo "server {"
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            echo "    listen ${ip}:80;"
        done <<< "$ips"
        echo "    server_name _;"
        echo "    include $NGINX_LOCS;"
        echo "}"
    } > "$NGINX_HTTP"
    if [ -f /etc/nginx/certs/tl.crt ] && [ -f /etc/nginx/certs/tl.key ]; then
        {
            echo "server {"
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                echo "    listen ${ip}:443 ssl;"
            done <<< "$ips"
            echo "    server_name _;"
            echo "    ssl_certificate     /etc/nginx/certs/tl.crt;"
            echo "    ssl_certificate_key /etc/nginx/certs/tl.key;"
            echo "    include $NGINX_LOCS;"
            echo "}"
        } > "$NGINX_HTTPS"
    else
        echo "# WAVE 0 cert not yet issued; HTTP on AP/station LAN is FLAG-TLS-acceptable" > "$NGINX_HTTPS"
    fi
}

reload_nginx() {
    # Listen files are already written. Never systemctl-start or systemctl-restart
    # nginx from this oneshot — that waits for nginx, nginx After=wlan waits here.
    # If nginx is not active yet, systemd starts it after this unit (After=/Wants=).
    if ! command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        return 0
    fi
    nginx -t >/dev/null 2>&1 && nginx -s reload 2>/dev/null || true
}

cmd_nginx_bind() {
    local iface ips
    iface="$(wifi_iface 2>/dev/null || true)"
    ips="$(collect_bind_ips "$iface" || true)"
    write_nginx_servers "$ips"
    if [ -n "$ips" ]; then
        log "nginx bind HTTP on: $(echo "$ips" | tr '\n' ' ')"
        reload_nginx
    else
        log "no AP/station/ethernet IPv4 yet; nginx not listening world"
    fi
}

cmd_ap_up() {
    local iface
    iface="$(wifi_iface)" || { log "no Wi-Fi iface; cannot start AP"; return 1; }
    if station_associated "$iface" && ! wan_mode_on; then
        log "station associated; not starting AP"
        cmd_nginx_bind
        return 0
    fi
    if hostapd_running; then
        log "hostapd already up on $AP_SSID"
        cmd_nginx_bind
        return 0
    fi

    log "starting hostapd AP SSID=$AP_SSID addr=$AP_ADDR (not nmcli hotspot)"
    nmcli device disconnect "$iface" 2>/dev/null || true
    nmcli device set "$iface" managed no 2>/dev/null || true
    rfkill unblock wifi 2>/dev/null || true
    ip link set "$iface" down 2>/dev/null || true
    ip addr flush dev "$iface" 2>/dev/null || true
    ip addr add "$AP_ADDR/$AP_PREFIX" dev "$iface"
    ip link set "$iface" up

    write_hostapd_conf "$iface"
    write_dnsmasq_conf "$iface"

    stop_pidfile "$HOSTAPD_PID" hostapd
    stop_pidfile "$DNSMASQ_PID" dnsmasq
    hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF"
    dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID"
    cmd_nginx_bind
}

cmd_ap_down() {
    local iface
    stop_pidfile "$HOSTAPD_PID" hostapd
    stop_pidfile "$DNSMASQ_PID" dnsmasq
    iface="$(wifi_iface 2>/dev/null || true)"
    if [ -n "$iface" ]; then
        ip addr flush dev "$iface" 2>/dev/null || true
        nmcli device set "$iface" managed yes 2>/dev/null || true
    fi
}

# Backend bounce: save infra WLAN, tear down AP, let NM associate, rebind nginx.
cmd_save_wlan() {
    local ssid="${1:-}" psk="${2:-}"
    [ -n "$ssid" ] || { log "usage: tesla-linux-wlan save-wlan <ssid> [psk]"; return 1; }
    local iface
    iface="$(wifi_iface 2>/dev/null || true)"
    cmd_ap_down
    if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$ssid"; then
        nmcli connection modify "$ssid" \
            802-11-wireless.ssid "$ssid" \
            802-11-wireless.mode infrastructure \
            connection.autoconnect yes \
            connection.autoconnect-priority 10
    else
        nmcli connection add type wifi con-name "$ssid" ifname "*" \
            ssid "$ssid" \
            802-11-wireless.mode infrastructure \
            connection.autoconnect yes \
            connection.autoconnect-priority 10
    fi
    if [ -n "$psk" ]; then
        nmcli connection modify "$ssid" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$psk"
    else
        nmcli connection modify "$ssid" wifi-sec.key-mgmt none 2>/dev/null || true
    fi
    if [ -n "$iface" ]; then
        nmcli device set "$iface" managed yes 2>/dev/null || true
        nmcli connection up "$ssid" ifname "$iface" 2>/dev/null \
            || nmcli device connect "$iface" 2>/dev/null \
            || true
        wait_station "$iface" || log "save-wlan: NM did not associate within ${WAIT_SEC}s"
    fi
    cmd_nginx_bind
}

# Factory static 10.42.1.1/24 on the primary wired iface. Not the AP subnet.
# WAN mode: keep that documented address and also allow DHCP default-route (WAN).
# Wait for delayed usb-net/cdc_ether/eth0/end0/en* — skip-if-none immediately is an operator hangup.
cmd_eth_up() {
    local iface name type ipv4_method=manual never_default=yes
    if ! iface="$(wait_wired_iface)"; then
        log "no wired iface after ${IFACE_WAIT_SEC}s; skip $ETH_CONN"
        return 0
    fi
    if wan_mode_on; then
        ipv4_method=auto
        never_default=no
        log "wired $iface -> factory $ETH_ADDR/$ETH_PREFIX + DHCP WAN ($ETH_CONN; operators use $ETH_ADDR / $AP_ADDR)"
    else
        log "wired $iface -> $ETH_ADDR/$ETH_PREFIX ($ETH_CONN, not DHCP, not $AP_ADDR/$AP_PREFIX)"
    fi
    if command -v nmcli >/dev/null 2>&1; then
        while IFS=: read -r name type; do
            [ -n "$name" ] || continue
            [ "$name" = "$ETH_CONN" ] && continue
            case "$type" in
                802-3-ethernet|ethernet)
                    nmcli connection modify "$name" connection.autoconnect no 2>/dev/null || true
                    ;;
            esac
        done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null || true)
        if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$ETH_CONN"; then
            nmcli connection modify "$ETH_CONN" \
                connection.interface-name "$iface" \
                connection.autoconnect yes \
                ipv4.method "$ipv4_method" \
                ipv4.addresses "$ETH_ADDR/$ETH_PREFIX" \
                ipv4.never-default "$never_default" \
                ipv6.method disabled 2>/dev/null || true
        else
            nmcli connection add type ethernet con-name "$ETH_CONN" ifname "$iface" \
                ipv4.method "$ipv4_method" ipv4.addresses "$ETH_ADDR/$ETH_PREFIX" \
                ipv4.never-default "$never_default" ipv6.method disabled \
                connection.autoconnect yes 2>/dev/null || true
        fi
        nmcli connection up "$ETH_CONN" ifname "$iface" 2>/dev/null || true
    fi
    if ! iface_ipv4s "$iface" | grep -qx "$ETH_ADDR"; then
        ip link set "$iface" up 2>/dev/null || true
        ip addr add "$ETH_ADDR/$ETH_PREFIX" dev "$iface" 2>/dev/null || true
    fi
}

# WAN rebroadcast: keep TeslaLinux AP up, do not join a station WLAN, NAT AP clients.
cmd_wan_up() {
    local iface
    mkdir -p "$(dirname "$WAN_RUNTIME")"
    : > "$WAN_RUNTIME"
    log "WAN rebroadcast: AP stays up; skip station join; NAT ${AP_ADDR%.*}.0/${AP_PREFIX} out ethernet WAN"
    cmd_eth_up
    iface="$(wifi_iface 2>/dev/null || true)"
    if [ -n "$iface" ]; then
        if station_associated "$iface"; then
            log "wan-up: leaving station so TeslaLinux AP can stay up"
            nmcli device disconnect "$iface" 2>/dev/null || true
        fi
        cmd_ap_up || log "wan-up: AP did not start"
        if hostapd_running && [ -n "$iface" ]; then
            write_dnsmasq_conf "$iface"
            if [ -f "$DNSMASQ_PID" ]; then
                kill -HUP "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null || true
            fi
        fi
    fi
    apply_wan_nat || log "wan-up: NAT helper missing or no uplink yet"
    cmd_nginx_bind
}

cmd_wan_down() {
    log "WAN rebroadcast off; restore factory ethernet static (station mode unchanged)"
    remove_wan_nat
    WAN_REBROADCAST=0
    cmd_eth_up
    cmd_nginx_bind
}

# Fail-hard: factory AP addr present, nginx not world-bind, NAT helper present when selected.
cmd_wan_verify() {
    local fail=0 helper apenv nginx_http mode_on=0
    helper="${WLAN_VERIFY_HELPER:-$0}"
    apenv="${1:-$AP_ENV}"
    nginx_http="${NGINX_HTTP}"
    if [ -f "$apenv" ]; then
        # shellcheck source=/dev/null
        . "$apenv"
        case "${WAN_REBROADCAST:-0}" in
            1|yes|true|on|ON) mode_on=1 ;;
        esac
    fi
    if ! is_bindable_ipv4 "${AP_ADDR:-}"; then
        echo "FAIL: AP factory addr missing or not bindable (${AP_ADDR:-unset})" >&2
        fail=1
    fi
    [ "${AP_ADDR:-}" = "10.42.0.1" ] || {
        echo "FAIL: AP factory addr is '${AP_ADDR:-unset}', expected 10.42.0.1" >&2
        fail=1
    }
    if [ -f "$nginx_http" ] && grep -Eq '0\.0\.0\.0|listen[[:space:]]+80;|listen[[:space:]]+\[::\]' "$nginx_http"; then
        echo "FAIL: nginx listen includes 0.0.0.0 / world bind ($nginx_http)" >&2
        fail=1
    fi
    if [ -f "$helper" ]; then
        grep -Eq 'masquerade|MASQUERADE' "$helper" \
            || { echo "FAIL: NAT/masquerade helper missing in $helper" >&2; fail=1; }
        grep -q 'apply_wan_nat' "$helper" \
            || { echo "FAIL: apply_wan_nat missing in $helper" >&2; fail=1; }
        if grep -Eq 'listen 0\.0\.0\.0' "$helper"; then
            echo "FAIL: helper would bind nginx to 0.0.0.0" >&2
            fail=1
        fi
    else
        echo "FAIL: wlan helper missing ($helper)" >&2
        fail=1
    fi
    if [ "$mode_on" = 1 ]; then
        if [ -f "$helper" ] && ! grep -Eq 'masquerade|MASQUERADE' "$helper"; then
            echo "FAIL: WAN_REBROADCAST selected but NAT/masquerade helper missing" >&2
            fail=1
        fi
    fi
    if [ "$fail" -eq 0 ]; then
        echo "tesla-linux-wlan wan-verify OK"
        return 0
    fi
    echo "tesla-linux-wlan wan-verify FAILED"
    return 1
}

cmd_boot() {
    local iface
    # Ethernet + nginx-bind first — do not wait on X/desktop. qemu has no wlan0.
    cmd_eth_up
    cmd_nginx_bind
    if wan_mode_on; then
        log "WAN rebroadcast mode (mode.json/ap.env); skip station join"
        cmd_wan_up
        if hostapd_running || eth_static_bound; then
            return 0
        fi
        log "WAN mode: neither AP nor wired $ETH_ADDR; fail so the unit can restart"
        return 1
    fi
    # station (or absent mode.json): drop leftover NAT from a previous wan_rebroadcast.
    remove_wan_nat
    if iface="$(wait_wifi_iface)"; then
        if has_saved_infra; then
            log "saved infra WLAN present; waiting ${WAIT_SEC}s for NM autoconnect"
            if wait_station "$iface"; then
                log "associated as station"
                cmd_nginx_bind
                return 0
            fi
            log "saved WLAN did not associate within ${WAIT_SEC}s"
        else
            log "no saved infra WLAN"
        fi
        if cmd_ap_up; then
            return 0
        fi
        log "AP did not start"
    else
        log "no Wi-Fi iface after ${IFACE_WAIT_SEC}s (eth GUI is the qemu path)"
    fi
    if eth_static_bound; then
        log "ethernet $ETH_ADDR bound; nginx-bind without AP (unit success)"
        cmd_nginx_bind
        return 0
    fi
    log "neither wired $ETH_ADDR nor wifi/AP; fail so the unit can restart"
    return 1
}

cmd_maybe_ap() {
    local iface
    if wan_mode_on; then
        cmd_wan_up
        return 0
    fi
    remove_wan_nat
    if hostapd_running; then
        cmd_nginx_bind
        return 0
    fi
    iface="$(wifi_iface 2>/dev/null || true)"
    [ -n "$iface" ] || return 0
    if station_associated "$iface"; then
        cmd_nginx_bind
        return 0
    fi
    if has_saved_infra; then
        if wait_station "$iface"; then
            cmd_nginx_bind
            return 0
        fi
    fi
    cmd_ap_up
}

cmd_selftest() {
    local fail=0 out dir
    out="$(filter_addrs 0.0.0.0 127.0.0.1 127.0.0.53 169.254.1.1 ::1 10.42.0.1 192.168.4.20 10.42.0.1/24)"
    echo "$out" | grep -qx '10.42.0.1' || { echo "FAIL: expected 10.42.0.1"; fail=1; }
    echo "$out" | grep -qx '192.168.4.20' || { echo "FAIL: expected 192.168.4.20"; fail=1; }
    echo "$out" | grep -Eq '0\.0\.0\.0|127\.|169\.254' && { echo "FAIL: filtered addrs leaked"; fail=1; }
    [ "$(echo "$out" | grep -c '10.42.0.1' || true)" = 1 ] || { echo "FAIL: unique 10.42.0.1"; fail=1; }
    is_bindable_ipv4 0.0.0.0 && { echo "FAIL: 0.0.0.0 bindable"; fail=1; }
    is_bindable_ipv4 10.42.0.1 || { echo "FAIL: AP addr not bindable"; fail=1; }
    is_bindable_ipv4 10.42.1.1 || { echo "FAIL: eth static not bindable"; fail=1; }

    dir="$(mktemp -d)"
    NGINX_HTTP="$dir/http.conf"
    NGINX_HTTPS="$dir/https.conf"
    NGINX_LOCS="$dir/locs.conf"
    write_nginx_servers $'10.42.0.1\n192.168.8.4'
    grep -q 'listen 10.42.0.1:80;' "$dir/http.conf" || { echo "FAIL: AP listen"; fail=1; }
    grep -q 'listen 192.168.8.4:80;' "$dir/http.conf" || { echo "FAIL: station listen"; fail=1; }
    grep -Eq '0\.0\.0\.0|listen 80;|listen \[::\]' "$dir/http.conf" && { echo "FAIL: world listen"; fail=1; }
    NGINX_HTTP="$dir/http2.conf"
    NGINX_HTTPS="$dir/https2.conf"
    write_nginx_servers ""
    grep -Eq 'listen ' "$dir/http2.conf" && { echo "FAIL: empty bind still listens"; fail=1; }

    HOSTAPD_CONF="$dir/hostapd.conf"
    write_hostapd_conf wlan0
    grep -q '^ssid=TeslaLinux$' "$dir/hostapd.conf" || { echo "FAIL: SSID TeslaLinux"; fail=1; }
    grep -q '^ignore_broadcast_ssid=0$' "$dir/hostapd.conf" || { echo "FAIL: hidden SSID"; fail=1; }
    grep -q '^wpa_passphrase=teslalinux$' "$dir/hostapd.conf" || { echo "FAIL: factory PSK"; fail=1; }

    is_wired_iface lo && { echo "FAIL: lo is wired"; fail=1; }
    is_wired_iface docker0 && { echo "FAIL: docker0 is wired"; fail=1; }
    is_wired_iface "" && { echo "FAIL: empty is wired"; fail=1; }
    if [ -e /sys/class/net/eth0 ]; then
        is_wired_iface eth0 || { echo "FAIL: eth0 should be wired"; fail=1; }
    fi

    # reload_nginx: inactive → no-op; active → nginx -t && nginx -s reload only.
    ng_log="$dir/nginx-invocations"
    : > "$ng_log"
    systemctl() {
        if [ "${1:-}" = is-active ] && [ "${2:-}" = --quiet ]; then
            [ "${MOCK_NGINX_ACTIVE:-0}" = 1 ]
            return $?
        fi
        echo "systemctl $*" >> "$ng_log"
        return 1
    }
    nginx() {
        echo "nginx $*" >> "$ng_log"
        return 0
    }
    MOCK_NGINX_ACTIVE=0
    reload_nginx || { echo "FAIL: reload_nginx inactive returned non-zero"; fail=1; }
    if grep -Eq 'restart|start | -s reload|reload nginx' "$ng_log"; then
        echo "FAIL: reload_nginx acted while nginx inactive"; fail=1
    fi
    MOCK_NGINX_ACTIVE=1
    : > "$ng_log"
    reload_nginx || { echo "FAIL: reload_nginx active returned non-zero"; fail=1; }
    grep -q -- '-t' "$ng_log" || { echo "FAIL: no nginx -t when active"; fail=1; }
    grep -q -- '-s reload' "$ng_log" || { echo "FAIL: no nginx -s reload when active"; fail=1; }
    if grep -E 'systemctl' "$ng_log"; then
        echo "FAIL: reload_nginx used systemctl start/restart"; fail=1
    fi
    unset -f systemctl nginx
    unset MOCK_NGINX_ACTIVE

    reload_nginx() { return 0; }
    wifi_iface() { return 1; }
    IFACE_WAIT_SEC=0
    if wait_wifi_iface >/dev/null; then
        echo "FAIL: wait_wifi_iface succeeded with no iface"; fail=1
    fi
    primary_wired_iface() { return 1; }
    if wait_wired_iface >/dev/null; then
        echo "FAIL: wait_wired_iface succeeded with no iface"; fail=1
    fi
    if ! cmd_eth_up; then
        echo "FAIL: eth-up after wait timeout should skip (0)"; fail=1
    fi
    primary_wired_iface() { printf '%s\n' usb0; }
    out="$(wait_wired_iface)"
    [ "$out" = usb0 ] || { echo "FAIL: wait_wired_iface usb0"; fail=1; }
    if cmd_ap_up; then
        echo "FAIL: ap-up without iface returned 0"; fail=1
    fi
    wait_wifi_iface() { return 1; }
    wait_wired_iface() { return 1; }
    primary_wired_iface() { return 1; }
    wired_ifaces() { return 0; }
    NGINX_HTTP="$dir/boot-none-http.conf"
    NGINX_HTTPS="$dir/boot-none-https.conf"
    if cmd_boot; then
        echo "FAIL: boot without wired/wifi returned 0"; fail=1
    fi

    # No wifi / no hostapd: 10.42.1.1 bound → unit success + nginx listen (not 0.0.0.0).
    cmd_eth_up() { return 0; }
    wait_wifi_iface() { return 1; }
    wifi_iface() { return 1; }
    wired_ifaces() { printf '%s\n' eth0; }
    iface_ipv4s() {
        case "$1" in
            wlan0) printf '%s\n' 10.8.0.4 ;;
            eth0) printf '%s\n' 10.42.1.1 ;;
            *) ;;
        esac
    }
    hostapd_running() { return 1; }
    ETH_ADDR=10.42.1.1
    NGINX_HTTP="$dir/boot-eth-http.conf"
    NGINX_HTTPS="$dir/boot-eth-https.conf"
    if ! cmd_boot; then
        echo "FAIL: boot with 10.42.1.1 and no wifi must return 0"; fail=1
    fi
    grep -q 'listen 10.42.1.1:80;' "$dir/boot-eth-http.conf" || { echo "FAIL: nginx-bind missing 10.42.1.1 without AP"; fail=1; }
    grep -Eq '0\.0\.0\.0|listen 80;|listen \[::\]' "$dir/boot-eth-http.conf" && { echo "FAIL: world listen after eth-only boot"; fail=1; }
    out="$(collect_bind_ips "")"
    echo "$out" | grep -qx '10.42.1.1' || { echo "FAIL: eth static in collect without AP"; fail=1; }
    echo "$out" | grep -qx '10.42.0.1' && { echo "FAIL: AP ip without hostapd"; fail=1; }

    hostapd_running() { return 0; }
    out="$(collect_bind_ips wlan0)"
    echo "$out" | grep -qx '10.8.0.4' || { echo "FAIL: station ip in collect"; fail=1; }
    echo "$out" | grep -qx '10.42.1.1' || { echo "FAIL: eth static in collect"; fail=1; }
    echo "$out" | grep -qx '10.42.0.1' || { echo "FAIL: AP ip in collect"; fail=1; }
    echo "$out" | grep -Eq '0\.0\.0\.0|127\.|169\.254' && { echo "FAIL: collect leaked"; fail=1; }
    NGINX_HTTP="$dir/http.conf"
    NGINX_HTTPS="$dir/https.conf"
    write_nginx_servers "$(printf '%s\n' 10.42.0.1 10.42.1.1)"
    grep -q 'listen 10.42.1.1:80;' "$dir/http.conf" || { echo "FAIL: eth listen"; fail=1; }
    grep -Eq '0\.0\.0\.0|listen 80;|listen \[::\]' "$dir/http.conf" && { echo "FAIL: world listen after eth"; fail=1; }

    # WAN rebroadcast skeleton: factory net, nginx not world, NAT helper, skip station.
    [ "$(ap_client_net)" = "10.42.0.0/24" ] || { echo "FAIL: ap_client_net"; fail=1; }
    WAN_REBROADCAST=0
    WAN_RUNTIME="$dir/no-wan-runtime"
    wan_mode_on && { echo "FAIL: wan_mode_on default"; fail=1; }
    WAN_REBROADCAST=1
    wan_mode_on || { echo "FAIL: wan_mode_on flag"; fail=1; }
    WAN_REBROADCAST=0
    : > "$dir/wan-runtime"
    WAN_RUNTIME="$dir/wan-runtime"
    wan_mode_on || { echo "FAIL: wan_mode_on runtime"; fail=1; }
    WAN_RUNTIME="$dir/absent-wan"
    wan_mode_on && { echo "FAIL: wan_mode_on still set"; fail=1; }
    MODE_FILE="$dir/mode.json"
    echo '{"mode":"station"}' > "$MODE_FILE"
    wan_mode_on && { echo "FAIL: mode.json station enabled WAN"; fail=1; }
    echo '{"mode":"wan_rebroadcast"}' > "$MODE_FILE"
    wan_mode_on || { echo "FAIL: mode.json wan_rebroadcast did not enable WAN"; fail=1; }
    [ "$(persisted_mode)" = wan_rebroadcast ] || { echo "FAIL: persisted_mode wan_rebroadcast"; fail=1; }
    echo 'not-json' > "$MODE_FILE"
    wan_mode_on && { echo "FAIL: corrupt mode.json enabled WAN"; fail=1; }
    [ "$(persisted_mode)" = station ] || { echo "FAIL: corrupt mode.json not station"; fail=1; }
    rm -f "$MODE_FILE"
    [ "$(persisted_mode)" = station ] || { echo "FAIL: missing mode.json not station"; fail=1; }

    WAN_REBROADCAST=1
    wired_ifaces() { printf '%s\n' eth0; }
    iface_ipv4s() {
        case "$1" in
            wlan0) printf '%s\n' 10.42.0.1 ;;
            eth0) printf '%s\n' 10.42.1.1 203.0.113.8 ;;
            *) ;;
        esac
    }
    hostapd_running() { return 0; }
    out="$(collect_bind_ips wlan0)"
    echo "$out" | grep -qx '10.42.0.1' || { echo "FAIL: WAN collect missing AP"; fail=1; }
    echo "$out" | grep -qx '10.42.1.1' || { echo "FAIL: WAN collect missing factory eth"; fail=1; }
    echo "$out" | grep -qx '203.0.113.8' && { echo "FAIL: WAN collect bound WAN DHCP"; fail=1; }
    echo "$out" | grep -Eq '0\.0\.0\.0|127\.|169\.254' && { echo "FAIL: WAN collect leaked"; fail=1; }
    NGINX_HTTP="$dir/wan-http.conf"
    NGINX_HTTPS="$dir/wan-https.conf"
    write_nginx_servers "$(collect_bind_ips wlan0)"
    grep -q 'listen 10.42.0.1:80;' "$dir/wan-http.conf" || { echo "FAIL: WAN nginx AP listen"; fail=1; }
    grep -q 'listen 10.42.1.1:80;' "$dir/wan-http.conf" || { echo "FAIL: WAN nginx factory eth listen"; fail=1; }
    grep -q '203.0.113.8' "$dir/wan-http.conf" && { echo "FAIL: WAN nginx WAN DHCP listen"; fail=1; }
    grep -Eq '0\.0\.0\.0|listen 80;|listen \[::\]' "$dir/wan-http.conf" && { echo "FAIL: WAN world listen"; fail=1; }

    DNSMASQ_CONF="$dir/dnsmasq-wan.conf"
    write_dnsmasq_conf wlan0
    grep -q 'dhcp-option=3,10.42.0.1' "$dir/dnsmasq-wan.conf" || { echo "FAIL: WAN dnsmasq gateway"; fail=1; }
    grep -q 'dhcp-option=6,1.1.1.1,8.8.8.8' "$dir/dnsmasq-wan.conf" || { echo "FAIL: WAN dnsmasq DNS"; fail=1; }
    WAN_REBROADCAST=0
    DNSMASQ_CONF="$dir/dnsmasq-ap.conf"
    write_dnsmasq_conf wlan0
    grep -q 'dhcp-option=6,' "$dir/dnsmasq-ap.conf" && { echo "FAIL: station-fallback dnsmasq got WAN DNS"; fail=1; }

    nft_log="$dir/nft.log"
    : > "$nft_log"
    have_nft() { return 0; }
    have_iptables() { return 1; }
    wan_uplink_iface() { printf '%s\n' eth0; }
    nft() {
        echo "nft $*" >> "$nft_log"
        if [ "${1:-}" = "-f" ]; then
            cat >> "$nft_log"
        fi
        return 0
    }
    set_ip_forward() { return 0; }
    apply_wan_nat || { echo "FAIL: apply_wan_nat nft"; fail=1; }
    grep -q 'tesla-linux-wan' "$nft_log" || { echo "FAIL: nft table tesla-linux-wan"; fail=1; }
    grep -qi 'masquerade' "$nft_log" || { echo "FAIL: nft masquerade"; fail=1; }
    have_nft() { return 1; }
    have_iptables() { return 0; }
    ipt_log="$dir/ipt.log"
    : > "$ipt_log"
    iptables() {
        echo "iptables $*" >> "$ipt_log"
        # -C (check) misses until we add; first -C fails so -A runs.
        case "${1:-}${2:-}" in
            -tnat) [ "${3:-}" = "-C" ] && return 1; return 0 ;;
        esac
        [ "${1:-}" = "-C" ] && return 1
        return 0
    }
    apply_wan_nat || { echo "FAIL: apply_wan_nat iptables"; fail=1; }
    grep -q 'MASQUERADE' "$ipt_log" || { echo "FAIL: iptables MASQUERADE"; fail=1; }

    WAN_REBROADCAST=1
    WAN_RUNTIME="$dir/boot-wan-runtime"
    rm -f "$WAN_RUNTIME"
    boot_log="$dir/boot-wan.log"
    : > "$boot_log"
    cmd_eth_up() { echo eth-up >> "$boot_log"; return 0; }
    cmd_nginx_bind() { echo nginx-bind >> "$boot_log"; return 0; }
    cmd_ap_up() { echo ap-up >> "$boot_log"; return 0; }
    apply_wan_nat() { echo nat >> "$boot_log"; return 0; }
    wait_station() { echo FAIL-station-wait >> "$boot_log"; return 1; }
    has_saved_infra() { echo FAIL-saved-infra >> "$boot_log"; return 0; }
    wait_wifi_iface() { printf '%s\n' wlan0; }
    wifi_iface() { printf '%s\n' wlan0; }
    station_associated() { return 1; }
    hostapd_running() { return 0; }
    eth_static_bound() { return 0; }
    if ! cmd_boot; then
        echo "FAIL: WAN boot returned non-zero"; fail=1
    fi
    grep -q 'ap-up' "$boot_log" || { echo "FAIL: WAN boot did not start AP"; fail=1; }
    grep -q 'nat' "$boot_log" || { echo "FAIL: WAN boot did not apply NAT"; fail=1; }
    grep -q 'FAIL-station-wait' "$boot_log" && { echo "FAIL: WAN boot waited on station"; fail=1; }
    grep -q 'FAIL-saved-infra' "$boot_log" && { echo "FAIL: WAN boot probed saved infra"; fail=1; }
    [ -f "$WAN_RUNTIME" ] || { echo "FAIL: wan-up did not plant runtime marker"; fail=1; }

    WAN_REBROADCAST=0
    WAN_RUNTIME="$dir/maybe-wan-runtime"
    : > "$WAN_RUNTIME"
    : > "$boot_log"
    if ! cmd_maybe_ap; then
        echo "FAIL: maybe-ap WAN returned non-zero"; fail=1
    fi
    grep -q 'FAIL-station-wait' "$boot_log" && { echo "FAIL: maybe-ap WAN waited on station"; fail=1; }
    grep -q 'ap-up' "$boot_log" || { echo "FAIL: maybe-ap WAN did not keep AP path"; fail=1; }

    # Backend persist file selects the path (do not edit ta_wlan_api.py).
    WAN_REBROADCAST=0
    WAN_RUNTIME="$dir/mode-boot-runtime"
    rm -f "$WAN_RUNTIME"
    MODE_FILE="$dir/mode.json"
    echo '{"mode":"wan_rebroadcast"}' > "$MODE_FILE"
    : > "$boot_log"
    if ! cmd_boot; then
        echo "FAIL: mode.json wan_rebroadcast boot returned non-zero"; fail=1
    fi
    grep -q 'ap-up' "$boot_log" || { echo "FAIL: mode.json boot did not start AP"; fail=1; }
    grep -q 'nat' "$boot_log" || { echo "FAIL: mode.json boot did not apply NAT"; fail=1; }
    grep -q 'FAIL-station-wait' "$boot_log" && { echo "FAIL: mode.json boot waited on station"; fail=1; }
    echo '{"mode":"station"}' > "$MODE_FILE"
    rm -f "$WAN_RUNTIME"
    : > "$boot_log"
    remove_wan_nat() { echo wan-off >> "$boot_log"; }
    wait_wifi_iface() { return 1; }
    eth_static_bound() { return 0; }
    if ! cmd_boot; then
        echo "FAIL: mode.json station boot returned non-zero"; fail=1
    fi
    grep -q 'wan-off' "$boot_log" || { echo "FAIL: station mode.json did not leave NAT"; fail=1; }
    grep -q 'FAIL-station-wait' "$boot_log" && { echo "FAIL: station boot probed saved infra wait"; fail=1; }

    AP_ENV="$dir/ap.env"
    cat > "$dir/ap.env" <<'EOF'
AP_SSID=TeslaLinux
AP_PSK=teslalinux
AP_ADDR=10.42.0.1
ETH_ADDR=10.42.1.1
WAN_REBROADCAST=1
EOF
    NGINX_HTTP="$dir/wan-http.conf"
    WLAN_VERIFY_HELPER="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    [ -n "$WLAN_VERIFY_HELPER" ] || WLAN_VERIFY_HELPER="$0"
    if ! cmd_wan_verify "$dir/ap.env"; then
        echo "FAIL: wan-verify good tree"; fail=1
    fi
    echo '    listen 0.0.0.0:80;' > "$dir/wan-http.conf"
    if cmd_wan_verify "$dir/ap.env"; then
        echo "FAIL: wan-verify accepted 0.0.0.0 listen"; fail=1
    fi
    echo '    listen 10.42.0.1:80;' > "$dir/wan-http.conf"
    cat > "$dir/ap.env" <<'EOF'
AP_SSID=TeslaLinux
AP_PSK=teslalinux
ETH_ADDR=10.42.1.1
WAN_REBROADCAST=1
EOF
    AP_ADDR=""
    if cmd_wan_verify "$dir/ap.env"; then
        echo "FAIL: wan-verify accepted missing AP_ADDR"; fail=1
    fi
    AP_ADDR=10.42.0.1

    rm -rf "$dir"

    if [ "$fail" -eq 0 ]; then
        echo "tesla-linux-wlan selftest OK"
        return 0
    fi
    echo "tesla-linux-wlan selftest FAILED"
    return 1
}

usage() {
    cat <<EOF
usage: tesla-linux-wlan <boot|eth-up|ap-up|ap-down|nginx-bind|maybe-ap|save-wlan|wan-ap|wan-up|wan-off|wan-down|wan-verify|selftest>
  boot         eth-up + nginx-bind; wifi/AP if present; success if ${ETH_ADDR} bound or AP/station
               mode.json wan_rebroadcast (or WAN_REBROADCAST=1): skip station; AP + NAT
  eth-up       wait ~${IFACE_WAIT_SEC}s for wired iface; static ${ETH_ADDR}/${ETH_PREFIX} (no DHCP)
               WAN mode keeps ${ETH_ADDR} and allows DHCP default-route on the same jack
  ap-up        TeslaLinux hostapd AP + dnsmasq (never if station is up, unless WAN mode)
  ap-down      stop AP; return iface to NetworkManager
  nginx-bind   listen on current AP/station/ethernet IPv4s only (WAN: ${AP_ADDR} + ${ETH_ADDR} only)
  maybe-ap     dispatcher: station if possible, else AP (WAN mode: wan-ap)
  save-wlan    BACKEND bounce: save infra SSID/PSK, AP down, NM up
  wan-ap       AP stays up; skip station; NAT 10.42.0.0/24 out ethernet WAN (alias: wan-up)
  wan-up       same as wan-ap (Backend /api/mode wan_rebroadcast kick)
  wan-off      remove NAT; restore factory ethernet static (alias: wan-down)
  wan-down     same as wan-off (leave wan_rebroadcast; Backend persist stays mode.json)
  wan-verify   fail-hard: factory AP addr, no nginx 0.0.0.0, NAT helper when mode selected
  selftest     address-filter + WAN skeleton checks (no hardware)
EOF
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        boot|eth-up|ap-up|ap-down|nginx-bind|maybe-ap|save-wlan|wan-ap|wan-up|wan-off|wan-down)
            with_lock
            ;;
    esac
    case "$cmd" in
        boot) cmd_boot ;;
        eth-up) cmd_eth_up ;;
        ap-up) cmd_ap_up ;;
        ap-down) cmd_ap_down ;;
        nginx-bind) cmd_nginx_bind ;;
        maybe-ap) cmd_maybe_ap ;;
        save-wlan) cmd_save_wlan "${1:-}" "${2:-}" ;;
        wan-ap|wan-up) cmd_wan_up ;;
        wan-off|wan-down) cmd_wan_down ;;
        wan-verify) cmd_wan_verify "${1:-}" ;;
        selftest) cmd_selftest ;;
        -h|--help|help|'') usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

if [ "${TL_WLAN_SOURCED:-}" != 1 ]; then
    main "$@"
fi
