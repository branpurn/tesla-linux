# WAN rebroadcast — AP stays up + ethernet or LTE NAT

Alternate networking mode vs station-on-same-WLAN. Helper / install / systemd. Backend owns `/api/mode` (`ta_wlan_api.py`) and uplink.kind — this SHA does not edit Backend or `desktop.html`.

SSID **TeslaLinux** stays visible. Operators use documented **10.42.0.1** (AP) and **10.42.1.1** (factory ethernet). Do not guess a DHCP station IP. nginx never listens on `0.0.0.0` or the WAN DHCP address. AP DHCP is dnsmasq (authoritative, option 3+6, range `10.42.0.10`–`10.42.0.200`); `wan-ap` fails if hostapd is up without that lease server.

**No station+AP dual.** While `wan_rebroadcast` is on, `boot` / `maybe-ap` / `wan-ap` call `leave_station`: disconnect every infra association, disable saved-WLAN autoconnect, and refuse `kick_nm_station` / `wait_station` / `save-wlan` join. Tesla and other **AP clients** stay on TeslaLinux.

## Modes

| Mode | How selected | Helper path |
|---|---|---|
| **station** (default) | missing/corrupt `/etc/tesla-linux/mode.json`, or `{"mode":"station"}` | existing saved-WLAN station, else TeslaLinux AP |
| **wan_rebroadcast** | `{"mode":"wan_rebroadcast"}` in `/etc/tesla-linux/mode.json` (Backend `POST /api/mode`) | **leave station**; TeslaLinux AP stays up at **10.42.0.1/24** + DHCP; NAT `10.42.0.0/24` out ethernet **or** USB LTE (`1286:4e3c` `cdc_ether`, `enx…`) once that uplink has a WAN IPv4 / default route |

`WAN_REBROADCAST=1` in `/etc/tesla-linux/ap.env` is an operator override. `wan-ap` also plants `/run/tesla-linux-wan` for this boot.

USB LTE stick **1286:4e3c** (`cdc_ether`, live name like `enxac0033aa9633`) is an accepted WAN uplink. Ethernet WAN still works when the stick is absent. Helper **accepts** the iface when present — it does not invent a Backend uplink-pick API.

## Backend kick — exact helper names

API mode string is **`wan_rebroadcast`** (`GET|POST /api/mode`). Do not invent `wan` or `lte`. Helper CLI Backend should kick:

| `/api/mode` | Helper (exact argv) | Also accepted |
|---|---|---|
| `POST {mode:wan_rebroadcast}` | `tesla-linux-wlan wan-ap` | `wan-rebroadcast`, `wan-up` |
| `POST {mode:station}` | `tesla-linux-wlan wan-off` | `wan-down` |

```
# persist (Backend). Helper also reads this on boot / maybe-ap / ethernet-up.
echo '{"mode":"wan_rebroadcast"}' > /etc/tesla-linux/mode.json

# leave station, then AP-stays-up + NAT (preferred kick):
tesla-linux-wlan wan-ap
# same action:
tesla-linux-wlan wan-rebroadcast

# leave WAN; back to maybe-ap / station (preferred kick):
tesla-linux-wlan wan-off
```

## Live box (Pop SSH `teslalinux@10.42.1.1`) — do not fight a green AP

Flash **2026.09.09-cc4c060** stands until the next bake. This PR is tip-helper only.

**If TeslaLinux AP is already up at 10.42.0.1/24 and clients have leases: do not re-run `wan-off` / `wan-ap` / hostapd restarts / channel changes.** Those steps fight live GREEN. Verify only:

```
ssh teslalinux@10.42.1.1
# confirm AP + not station+AP dual
ip -4 addr show | grep 10.42.0.1
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
# wifi = TeslaLinux AP / unmanaged hostapd — not an infra SSID (Eero)
ss -ulpn | grep -E 'dnsmasq|:67' || true
cat /var/lib/misc/dnsmasq.leases 2>/dev/null || cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || true
# LTE NAT once enx… / cdc_ether 1286:4e3c has a WAN IPv4 or default route
lsusb | grep -i 1286 || true
ip -4 addr show | grep -E 'enx'
ip -4 route show default
sudo tesla-linux-wlan wan-verify
sudo nft list table ip tesla-linux-wan
# or: sudo iptables -t nat -S POSTROUTING | grep tesla-linux-wan
# from an AP client (only if you need a datapath check; do not bounce the AP):
# ping -c 3 10.42.0.1 && ping -c 3 1.1.1.1
```

Enter `wan_rebroadcast` only when the box is still on Eero/station (leave-station then `wan-ap`). Persist is Backend `mode.json` / `POST /api/mode` `{mode:wan_rebroadcast}` → `tesla-linux-wlan wan-ap`. Do not invent `lte`. Hostapd **channel stays the existing default (6 in helper)** — live operator ch11 is not a tip invent; do not bake a channel change.

```
# only if AP is down / still a station — not if live is GREEN
printf '%s\n' '{"mode":"wan_rebroadcast"}' | sudo tee /etc/tesla-linux/mode.json
sudo tesla-linux-wlan wan-ap
```

## Verify NAT (host / bake)

```
tesla-linux-wlan wan-verify
tesla-linux-wlan selftest
./tl-src/install-tesla-linux.sh --verify-wan
# live (after wan-ap and a WAN IPv4 on eth or enx…):
nft list table ip tesla-linux-wan
# or: iptables -t nat -S POSTROUTING | grep tesla-linux-wan
```

`wan-verify` / `--verify-wan` fail-hard if the factory AP addr is missing, nginx listen includes `0.0.0.0`, the NAT/masquerade helper is missing when the mode is selected, or LTE (`1286:4e3c` / `cdc_ether` / `leave_station`) helpers are missing.

## Station mode still works

Default remains station. With `mode.json` absent or `station`, `boot` / `maybe-ap` / `save-wlan` are unchanged: NetworkManager associates a saved infra WLAN when it can; otherwise TeslaLinux AP. `wan-off` removes NAT and restores factory ethernet static **10.42.1.1/24** (`never-default`).

## nginx binds

- WAN mode: **10.42.0.1** and factory **10.42.1.1** only (not the WAN DHCP IPv4 on eth or LTE).
- Station mode: existing AP / station / ethernet bind behavior (never `0.0.0.0`).
