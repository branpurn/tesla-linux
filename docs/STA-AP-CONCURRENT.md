# Concurrent Wi-Fi station + TeslaLinux AP

The Pi joins a saved Wi-Fi (WAN) on `wlan0` under NetworkManager **and always** broadcasts
`TeslaLinux` (10.42.0.1/24, dnsmasq DHCP) from hostapd on a virtual iface `uap0`
(`iw dev wlan0 interface add uap0 type __ap`, locally-administered MAC, NM-unmanaged via
`/etc/NetworkManager/conf.d/90-tesla-linux-uap0.conf`).

brcmfmac combo: `managed<=1, AP<=1, #channels<=1` → the AP **follows the station channel**.
If the station rejoins on a different channel, hostapd is restarted on it (brief AP blip; car re-associates).

| Case | Behavior |
|---|---|
| Saved Wi-Fi in range | wlan0 station + uap0 AP on the station channel. Wi-Fi WAN route-metric 50 (preferred), LTE 101 fallback. |
| LTE only / no saved Wi-Fi | **Solo**: wlan0 NM-unmanaged + link down (no station, no background scanning); AP keeps running on uap0 (last channel, else `AP_CHANNEL=6`). |
| Station drops | AP is untouched. NM gets `WAIT_SEC` to reconnect; otherwise solo. |
| Station returns | `tesla-linux-wlan-rejoin.timer` (30 s) runs `rejoin-probe`: solo → one scan every `REJOIN_SCAN_SEC` (120 s); a saved SSID in range → rejoin, realign AP channel. Associated → realign channel if it changed. |

NAT: `ip saddr 10.42.0.0/24 oifname != "uap0" masquerade` — uplink-agnostic, so Wi-Fi WAN ↔ LTE
failover needs no rewrite. LTE and `tl-tunnel` are never touched; srcroute (PR #73) keeps
replies on their ingress uplink. 198.18.0.1 DNAT (`tesla-linux-alias.nft`) matches `{ wlan0, uap0 }`.

Knobs (`/etc/tesla-linux/ap.env`): `AP_CONCURRENT=1` (0 = legacy AP on wlan0, no station),
`AP_VIF`, `AP_CHANNEL`, `WIFI_WAN_PREFER`, `WIFI_WAN_METRIC`, `REJOIN_SCAN_SEC`.
`wan_rebroadcast` mode still leaves the station (see WAN-REBROADCAST.md).

Commands: `tesla-linux-wlan ap-sync` (reconcile now), `tesla-linux-wlan rejoin-probe`.

Verify:
```
iw dev                                   # uap0 type AP + wlan0 managed, same channel
hostapd_cli -p /run/hostapd -i uap0 status | grep ^state   # ENABLED (channel= may be stale on brcmfmac; trust iw)
ip route | grep default                  # wlan0 metric 50, LTE metric 101
./tl-src/selftest-sta-ap-concurrent.sh
```
