#!/bin/bash
# tesla-linux-srcroute — generic per-interface source-based policy routing.
# Installed as /etc/NetworkManager/dispatcher.d/50-tesla-linux-srcroute and
# /usr/local/sbin/tesla-linux-srcroute (run with "sync" for a manual reconcile).
#
# Why: two uplinks can share one subnet (LTE USB 192.168.1.100/24 and Starlink
# Wi-Fi 192.168.1.48/24, both gw 192.168.1.1). The main table then sends every
# reply out the lowest-metric link, so a client hitting the other IP gets
# ERR_CONNECTION_REFUSED / RSTs. For every interface with an address we keep
#   table  TL_BASE+ifindex : that interface's main-table routes (incl. default)
#   rule   pref TL_BASE+ifindex  from <addr> lookup <table>   (IPv4 + IPv6)
# so traffic sourced from an address always leaves the interface that owns it.
# Every event reconciles ALL interfaces (idempotent), so stale tables/rules from
# vanished interfaces or changed DHCP leases are removed. Forwarded/NAT traffic
# (WAN masquerade, 198.18.0.1 DNAT, AP 10.42.0.0/24) is untouched: rules match
# only locally-owned source addresses, and tables without a matching route fall
# through to main.
set -u
TL_BASE="${TL_SRCROUTE_BASE:-1000}"
TL_MAX=$((TL_BASE + 999))
LOG_TAG=tesla-linux-srcroute

skip_iface() {
    case "$1" in
        lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|tl-tunnel*|dummy*) return 0 ;;
    esac
    return 1
}

# Copy main-table routes of a dev into its table (strip volatile tokens).
fill_table() {
    local fam="$1" dev="$2" tbl="$3" line
    ip "$fam" route flush table "$tbl" 2>/dev/null
    ip "$fam" route show table main dev "$dev" 2>/dev/null | while read -r line; do
        [ -n "$line" ] || continue
        line=$(printf '%s\n' "$line" | sed -E 's/ expires [0-9]+sec//; s/ linkdown//; s/ (dead|onlink)//g')
        # shellcheck disable=SC2086
        ip "$fam" route replace $line dev "$dev" table "$tbl" 2>/dev/null \
            || logger -t "$LOG_TAG" "route skip $fam $dev: $line"
    done
}

clear_rules() {
    local fam="$1" pref
    ip "$fam" rule show | awk -F: -v lo="$TL_BASE" -v hi="$TL_MAX" '$1+0>=lo && $1+0<=hi {print $1+0}' \
        | sort -u | while read -r pref; do
            while ip "$fam" rule del pref "$pref" 2>/dev/null; do :; done
        done
}

clear_tables() {
    local fam="$1" t
    ip "$fam" route show table all 2>/dev/null | sed -n 's/.* table \([0-9]\+\).*/\1/p' | sort -u \
        | while read -r t; do
            [ "$t" -ge "$TL_BASE" ] && [ "$t" -le "$TL_MAX" ] && ip "$fam" route flush table "$t" 2>/dev/null
        done
}

sync_all() {
    local fam dev idx tbl addr
    for fam in -4 -6; do
        clear_rules "$fam"
        clear_tables "$fam"
        for d in /sys/class/net/*; do
            dev="${d##*/}"
            skip_iface "$dev" && continue
            [ "$(cat "$d/operstate" 2>/dev/null)" = "down" ] && continue
            idx=$(cat "$d/ifindex" 2>/dev/null) || continue
            tbl=$((TL_BASE + idx))
            [ "$tbl" -le "$TL_MAX" ] || continue
            if [ "$fam" = -4 ]; then
                addrs=$(ip -4 -o addr show dev "$dev" scope global | awk '{print $4}' | cut -d/ -f1)
            else
                addrs=$(ip -6 -o addr show dev "$dev" scope global | grep -v tentative | awk '{print $4}' | cut -d/ -f1)
            fi
            [ -n "$addrs" ] || continue
            fill_table "$fam" "$dev" "$tbl"
            for addr in $addrs; do
                ip "$fam" rule add from "$addr" lookup "$tbl" pref "$tbl" 2>/dev/null
            done
        done
    done
    ip route flush cache 2>/dev/null
    logger -t "$LOG_TAG" "synced (${1:-manual})"
}

case "${2:-}" in
    up|down|dhcp4-change|dhcp6-change|connectivity-change|reapply|pre-down|hostname|"")
        ;;
    *) exit 0 ;;
esac
case "${1:-sync}" in
    status)
        ip -4 rule; ip -6 rule
        for t in $(ip -4 rule | awk -v lo="$TL_BASE" -v hi="$TL_MAX" -F'lookup ' 'NF>1 && $2+0>=lo && $2+0<=hi {print $2+0}' | sort -u); do
            echo "== table $t"; ip -4 route show table "$t"; ip -6 route show table "$t"
        done ;;
    *) sync_all "${1:-sync} ${2:-}" ;;
esac
exit 0
