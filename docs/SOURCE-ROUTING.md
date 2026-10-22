# Per-interface source policy routing

## Problem
Two uplinks can land on the same subnet: LTE USB `enxac0033aa9633` = 192.168.1.100/24
(gw 192.168.1.1, metric 101) and Wi-Fi station `wlan0` on Starlink = 192.168.1.48/24
(gw 192.168.1.1, metric 600). The main table sends every reply out the lowest-metric
link, so the car on Starlink got `ERR_CONNECTION_REFUSED` at 192.168.1.48.

## Fix
`tl-src/tesla-linux-srcroute.sh` is installed as
`/etc/NetworkManager/dispatcher.d/50-tesla-linux-srcroute` (plus
`/usr/local/sbin/tesla-linux-srcroute` for `sync` / `status`). On every NM event
(`up`, `down`, `dhcp4-change`, `dhcp6-change`, `connectivity-change`, `reapply`) it
reconciles **all** interfaces, so it also covers any Wi-Fi saved later:

- table `1000 + ifindex` = a copy of that interface's main-table routes (incl. default), IPv4 and IPv6
- rule `pref 1000 + ifindex: from <each global addr> lookup <table>`
- stale rules/tables (pref/table 1000–1999) are flushed first; down interfaces get none

Skipped: `lo`, `docker*`, `veth*`, `br-*`, `virbr*`, `tun*`, `tap*`, `wg*`, `tl-tunnel*`, `dummy*`.
Forwarded traffic (WAN masquerade, 198.18.0.1 DNAT, AP 10.42.0.1) is not matched:
the rules only match locally owned source addresses, and lookups with no route fall through to main.

`/etc/sysctl.d/99-tesla-linux-srcroute.conf`: `arp_ignore=1`, `arp_announce=2`, `rp_filter=2` (all + default).

## Verify
```
sudo tesla-linux-srcroute status
ip route get 192.168.1.50 from 192.168.1.48   # dev wlan0 table 10xx
ip route get 192.168.1.50 from 192.168.1.100  # dev enx… table 10xx
curl --interface wlan0 https://ifconfig.me
./tl-src/install-tesla-linux.sh --verify-srcroute [root]
sudo ./tl-src/selftest-srcroute.sh            # netns two-uplinks-one-subnet test as root
```
