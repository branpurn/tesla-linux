# WAN rebroadcast — AP stays up + ethernet or LTE NAT

Operator-facing primary in-car path is this mode (LTE WAN + TeslaLinux AP at **10.42.0.1**) — see [README.md](../README.md). Station-on-same-WLAN is setup/alternate.

Alternate networking mode vs station-on-same-WLAN. Helper / install / systemd. Backend owns `/api/mode` (`ta_wlan_api.py`) and uplink.kind — this SHA does not edit Backend or `desktop.html`.

SSID **TeslaLinux** stays visible. Operators use documented **10.42.0.1** (AP) and **10.42.1.1** (factory ethernet). Factory **10.42.1.1** stays up during `wan-ap` so Pop SSH and TeslaLinux AP run concurrently — WAN DHCP/default-route is LTE (`enx…` / `cdc_ether` / `wwan*`) or a separate uplink, never by converting `tesla-linux-eth` to `ipv4.method=auto`. Do not guess a DHCP station IP. nginx never listens on `0.0.0.0` or the WAN DHCP address. AP DHCP is dnsmasq (authoritative, option 3+6, range `10.42.0.10`–`10.42.0.200`); `wan-ap` fails if hostapd is up without that lease server.

**No station+AP dual.** While `wan_rebroadcast` is on, `boot` / `maybe-ap` / `wan-ap` call `leave_station`: disconnect every infra association, disable saved-WLAN autoconnect, and refuse `kick_nm_station` / `wait_station` / `save-wlan` join. Tesla and other **AP clients** stay on TeslaLinux.

## Modes

| Mode | How selected | Helper path |
|---|---|---|
| **station** (default) | missing/corrupt `/etc/tesla-linux/mode.json`, or `{"mode":"station"}` | existing saved-WLAN station, else TeslaLinux AP |
| **wan_rebroadcast** | `{"mode":"wan_rebroadcast"}` in `/etc/tesla-linux/mode.json` (Backend `POST /api/mode`) | **leave station**; TeslaLinux AP stays up at **10.42.0.1/24** + DHCP; NAT `10.42.0.0/24` out ethernet **or** USB LTE once that uplink has a WAN IPv4 / default route |

`WAN_REBROADCAST=1` in `/etc/tesla-linux/ap.env` is an operator override. `wan-ap` also plants `/run/tesla-linux-wan` for this boot.

### LTE / WAN uplink detection (not locked to one stick)

Default known stick is **1286:4e3c** (`cdc_ether`, live name like `enxac0033aa9633`). A **new same-family stick** can present a different VID:PID, MAC (`enx…`), or driver (`qmi_wwan` / `rndis_host` / `cdc_mbim`). Configure in `/etc/tesla-linux/ap.env`:

| Variable | Purpose |
|---|---|
| `WAN_IFACE=` | Force NAT out this iface (preferred when you already know `enx…` / `wwan0`) |
| `LTE_USB_VID` / `LTE_USB_PID` | Single known stick (default `1286` / `4e3c`) |
| `LTE_USB_IDS=` | Comma list of `vid:pid` (lowercase hex) — use for same-family replacements |
| `LTE_WAIT_SEC=` | Wait for net iface after modeswitch (default `15`) |
| `LTE_DHCP_WAIT_SEC=` | Wait for WAN IPv4 on detected enx (default `30`; Health=no_ip) |
| `LTE_APN=` | Optional ModemManager APN for `mmcli --simple-connect` |
| `LTE_MODESWITCH=` | `1` (default) try usb_modeswitch when USB ID present but no net iface |

Helper also accepts any `cdc_ether` `enx*` and common modem drivers (`qmi_wwan`, `rndis_host`, `cdc_mbim`, …). If USB ID matches but no net iface appears, it tries `usb_modeswitch` (when installed) and waits. Ethernet WAN still works when the stick is absent. Helper **accepts** the iface when present — it does not invent a Backend uplink-pick API.

**Symptom:** Tesla stays on TeslaLinux but says **"The Internet is unreachable"** — AP+DHCP is up, but NAT was skipped because the modem has no WAN IPv4 / default route (or the stick was not recognized). Fix uplink first; do not bounce a green AP.

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

Flash **2026.09.09-cc4c060** stands until the next bake. Tip helper can be installed over SSH when parked.

**If TeslaLinux AP is already up at 10.42.0.1/24 and clients have leases: do not re-run `wan-off` / `wan-ap` / hostapd restarts / channel changes.** Those steps fight live GREEN. Verify only:

```
ssh teslalinux@10.42.1.1
# confirm AP + not station+AP dual
ip -4 addr show | grep 10.42.0.1
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
# wifi = TeslaLinux AP / unmanaged hostapd — not an infra SSID (Eero)
ss -ulpn | grep -E 'dnsmasq|:67' || true
cat /var/lib/misc/dnsmasq.leases 2>/dev/null || cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || true
# LTE NAT once enx… / wwan* has a WAN IPv4 or default route
lsusb
ip -br link; ip -4 addr; ip -4 route show default
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

## Offline recovery — new same-model LTE stick (parked)

When a replacement USB LTE stick of the "same model" leaves the car on TeslaLinux with **Internet is unreachable**, run this on the Pi (SSH `teslalinux@10.42.1.1` via Pop, or HDMI console). **Do not restart hostapd** if AP clients already have leases — fix WAN/NAT only.

```
# 1) What did the stick become?
lsusb
ip -br link
ip -4 addr
ip -4 route show default
# note: VID:PID from lsusb, and the net iface (enx… / wwan0 / eth1)

# 2) If the iface exists but has no IPv4 / no default route:
sudo ip link set <IFACE> up
sudo nmcli device set <IFACE> managed yes
sudo nmcli device connect <IFACE> || true
# wait ~15s; re-check:
ip -4 addr show <IFACE>
ip -4 route show default

# 3) If USB shows the stick but NO net iface (mass-storage / wrong mode):
sudo apt-get install -y usb-modeswitch usb-modeswitch-data   # once
# try modeswitch for the VID:PID from lsusb (example 1286:4e3c):
sudo usb_modeswitch -v 0x1286 -p 0x4e3c -J || sudo usb_modeswitch -v 0x1286 -p 0x4e3c
# re-plug once if still missing, then:
ip -br link

# 4) Persist recognition for this stick (edit /etc/tesla-linux/ap.env):
#    WAN_IFACE=<IFACE>                         # strongest — pin NAT to this name
#    and/or LTE_USB_IDS=1286:4e3c,<newvid:pid> # accept additional USB IDs
sudo nano /etc/tesla-linux/ap.env

# 5) Re-apply NAT without bouncing AP (helper re-detects uplink):
sudo tesla-linux-wlan wan-ap
# expect log lines about LTE/WAN candidate + nft/iptables masquerade
sudo nft list table ip tesla-linux-wan
# or: sudo iptables -t nat -S POSTROUTING | grep tesla-linux-wan

# 6) From the car / a phone on TeslaLinux:
# ping 10.42.0.1 && ping 1.1.1.1
# DNS should be the AP (dnsmasq → 10.42.0.1)
```

If `lsusb` shows a **different** VID:PID than `1286:4e3c`, add it to `LTE_USB_IDS` (or set `WAN_IFACE=` once the net iface is known). Tip helper defaults still include `1286:4e3c` so existing sticks keep working.

Install this tip helper on the Pi (when parked) from the PR branch, or copy `tl-src/tesla-linux-wlan.sh` over `/usr/local/bin/tesla-linux-wlan` (path may vary — match your install) and re-run `wan-ap`.

## Verify NAT (host / bake)

```
tesla-linux-wlan wan-verify
tesla-linux-wlan selftest
./tl-src/install-tesla-linux.sh --verify-wan
# live (after wan-ap and a WAN IPv4 on eth or enx… / wwan*):
nft list table ip tesla-linux-wan
# or: iptables -t nat -S POSTROUTING | grep tesla-linux-wan
```

`wan-verify` / `--verify-wan` fail-hard if the factory AP addr is missing, nginx listen includes `0.0.0.0`, the NAT/masquerade helper is missing when the mode is selected, or LTE (`1286:4e3c` / `LTE_USB_IDS` / `WAN_IFACE` / `cdc_ether` / `leave_station`) helpers are missing.

## Station mode still works

Default remains station. With `mode.json` absent or `station`, `boot` / `maybe-ap` / `save-wlan` are unchanged: NetworkManager associates a saved infra WLAN when it can; otherwise TeslaLinux AP. `wan-off` removes NAT and restores factory ethernet static **10.42.1.1/24** (`never-default`).

## nginx binds

- WAN mode: **10.42.0.1** and factory **10.42.1.1** only (not the WAN DHCP IPv4 on eth or LTE).
- Station mode: existing AP / station / ethernet bind behavior (never `0.0.0.0`).
