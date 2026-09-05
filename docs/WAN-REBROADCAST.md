# WAN rebroadcast — AP stays up + ethernet NAT

Alternate networking mode vs station-on-same-WLAN. Skeleton only (helper / install / systemd). Backend owns `/api/mode` (`ta_wlan_api.py`); Frontend owns the picker. This SHA does not edit those.

SSID **TeslaLinux** stays visible. Operators use documented **10.42.0.1** (AP) and **10.42.1.1** (factory ethernet). Do not guess a DHCP station IP. nginx never listens on `0.0.0.0` or the WAN DHCP address.

## Modes

| Mode | How selected | Helper path |
|---|---|---|
| **station** (default) | missing/corrupt `/etc/tesla-linux/mode.json`, or `{"mode":"station"}` | existing saved-WLAN station, else TeslaLinux AP |
| **wan_rebroadcast** | `{"mode":"wan_rebroadcast"}` in `/etc/tesla-linux/mode.json` (Backend `POST /api/mode`) | do **not** join a station WLAN; TeslaLinux AP stays up at **10.42.0.1/24**; ethernet WAN is NAT'd to `10.42.0.0/24` |

`WAN_REBROADCAST=1` in `/etc/tesla-linux/ap.env` is an operator override. `wan-ap` also plants `/run/tesla-linux-wan` for this boot.

USB LTE dongles are out of scope. Ethernet uplink first.

## Enable

Backend persist (picker / `POST /api/mode`) writes the file; the helper applies NAT when that mode is selected:

```
# persist (Backend). Helper reads this on boot / maybe-ap / ethernet-up.
echo '{"mode":"wan_rebroadcast"}' > /etc/tesla-linux/mode.json

# or kick the helper now (both names are the same action):
tesla-linux-wlan wan-ap
tesla-linux-wlan wan-up
```

Leave mode (station-else-AP again). Both names are the same action:

```
tesla-linux-wlan wan-off
tesla-linux-wlan wan-down
# Backend persist for next boot:
echo '{"mode":"station"}' > /etc/tesla-linux/mode.json
```

## Verify NAT

```
tesla-linux-wlan wan-verify
tesla-linux-wlan selftest
./tl-src/install-tesla-linux.sh --verify-wan
# live (after wan-ap and a wired WAN default route):
nft list table ip tesla-linux-wan
# or: iptables -t nat -S POSTROUTING | grep tesla-linux-wan
```

`wan-verify` / `--verify-wan` fail-hard if the factory AP addr is missing, nginx listen includes `0.0.0.0`, or the NAT/masquerade helper is missing when the mode is selected.

## Station mode still works

Default remains station. With `mode.json` absent or `station`, `boot` / `maybe-ap` / `save-wlan` are unchanged: NetworkManager associates a saved infra WLAN when it can; otherwise TeslaLinux AP. `wan-off` removes NAT and restores factory ethernet static **10.42.1.1/24** (`never-default`).

## nginx binds

- WAN mode: **10.42.0.1** and factory **10.42.1.1** only (not the WAN DHCP IPv4).
- Station mode: existing AP / station / ethernet bind behavior (never `0.0.0.0`).
