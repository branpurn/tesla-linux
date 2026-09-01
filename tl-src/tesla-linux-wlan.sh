#!/usr/bin/env bash
# Tesla Linux WAVE 1 — saved-WLAN station else TeslaLinux hostapd AP.
#
# NetworkManager owns infrastructure (station) autoconnect.
# Fallback AP is hostapd + dnsmasq (not nmcli hotspot), SSID TeslaLinux.
# nginx listen is rewritten to the current AP/station IPv4s only
# (never 0.0.0.0, never loopback-only).
#
# FRONTEND-HOLE (this SHA): pick/save WLAN UI — do not invent a settings maze.
# BACKEND-HOLE (this SHA): bounce glue is cmd save-wlan / boot; HTTP API TBD.
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
WAIT_SEC="${WAIT_SEC:-20}"

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
    local iface="${1:-}" ip
    local seen="|"
    if [ -n "$iface" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            case "$seen" in *"|$ip|"*) continue ;; esac
            seen="${seen}${ip}|"
            printf '%s\n' "$ip"
        done < <(iface_ipv4s "$iface")
    fi
    if hostapd_running && is_bindable_ipv4 "$AP_ADDR"; then
        case "$seen" in
            *"|$AP_ADDR|"*) ;;
            *) printf '%s\n' "$AP_ADDR" ;;
        esac
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
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && nginx -s reload 2>/dev/null && return 0
    fi
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
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
        log "no AP/station IPv4 yet; nginx not listening world"
    fi
}

cmd_ap_up() {
    local iface
    iface="$(wifi_iface)" || { log "no Wi-Fi iface; skip AP"; return 0; }
    if station_associated "$iface"; then
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

cmd_boot() {
    local iface
    if ! iface="$(wifi_iface)"; then
        log "no Wi-Fi iface; nothing to do"
        cmd_nginx_bind
        return 0
    fi
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
    cmd_ap_up
}

cmd_maybe_ap() {
    local iface
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
usage: tesla-linux-wlan <boot|ap-up|ap-down|nginx-bind|maybe-ap|save-wlan|selftest>
  boot         saved infra NM autoconnect (~${WAIT_SEC}s) else hostapd AP
  ap-up        TeslaLinux hostapd AP + dnsmasq (never if station is up)
  ap-down      stop AP; return iface to NetworkManager
  nginx-bind   listen on current AP/station IPv4s only
  maybe-ap     dispatcher: station if possible, else AP
  save-wlan    BACKEND bounce: save infra SSID/PSK, AP down, NM up
  selftest     address-filter checks (no hardware)
EOF
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        boot|ap-up|ap-down|nginx-bind|maybe-ap|save-wlan)
            with_lock
            ;;
    esac
    case "$cmd" in
        boot) cmd_boot ;;
        ap-up) cmd_ap_up ;;
        ap-down) cmd_ap_down ;;
        nginx-bind) cmd_nginx_bind ;;
        maybe-ap) cmd_maybe_ap ;;
        save-wlan) cmd_save_wlan "${1:-}" "${2:-}" ;;
        selftest) cmd_selftest ;;
        -h|--help|help|'') usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

if [ "${TL_WLAN_SOURCED:-}" != 1 ]; then
    main "$@"
fi
