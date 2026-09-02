# WAVE 1 — WLAN station else TeslaLinux AP

vs `1cb7c04`. Ubuntu Server + XFCE, Raspberry Pi **4 8 GB only**. No AOSP. No Pi 5. No WebRTC. kiss stays **PRIVATE**. Same `.img.xz` flashes SD or USB (Pi 4 USB boot: operator EEPROM).

## Product path

1. **Preferred:** Pi is a NetworkManager **station** on a saved Tesla (or other) WLAN. Autoconnect.
2. **Fallback** when no saved WLAN / associate fails: **hostapd** AP (not nmcli-only hotspot).
   - SSID: **TeslaLinux** (TeslaAndroid-like). Do not invent a second SSID.
   - WPA2-PSK factory default password: **teslalinux**
   - AP LAN: **10.42.0.1/24** (DHCP `10.42.0.10`–`10.42.0.200`)
3. Web GUI on that AP: `/var/www/tl/index.html` at `http://10.42.0.1/` (pick/save station WLAN). Stream remains `/var/www/tl/desktop.html`. `probe.html` unchanged. Also `http://10.42.1.1/` on the wired ethernet static (peer `10.42.1.2/24`) and `http://teslalinux.local/` (existing avahi; do not add a second mDNS stack). Station IP when associated.
   - Not loopback-only. Not `0.0.0.0` to the world.
   - Bind HTTP to AP **10.42.0.1**, ethernet static **10.42.1.1**, and the WLAN station IPv4 when associated.
   - FLAG-TLS (WAVE 0): do not invent a new TLS policy. HTTP on the AP LAN is acceptable so a Tesla browser can open the GUI without a cert maze.

Factory password **teslalinux** is a documented operator default, not a secret. Operators change it later (`/etc/tesla-linux/ap.env`). Frontend may add that to the picker later.

## Pre-seed a saved WLAN when flashing

Keep `/boot/firmware/tesla-linux.conf` on the FAT boot partition:

```
WIFI_SSID=YourTeslaWLAN
WIFI_PSK=yourpsk
```

First-boot still creates the NM infra profile (`connection.autoconnect yes`). `tesla-linux-wlan.service` waits ~60s for a wifi iface (brcmfmac race), then ~20s for association; if that fails, the TeslaLinux AP comes up. Oneshot `Restart=on-failure` — do not skip AP forever. AP does **not** wait on xorg/desktop.

## On the image

| Path | Role |
|---|---|
| `/etc/tesla-linux/ap.env` | Factory `AP_SSID=TeslaLinux`, `AP_PSK=teslalinux`, `AP_ADDR=10.42.0.1`, `ETH_ADDR=10.42.1.1` |
| `/etc/NetworkManager/system-connections/tesla-linux-eth.nmconnection` | Wired static **10.42.1.1/24** (no DHCP; not AP `10.42.0.1/24`) |
| `/usr/local/sbin/tesla-linux-wlan` | `boot` / `eth-up` / `ap-up` / `ap-down` / `nginx-bind` / `maybe-ap` / `save-wlan` |
| `/usr/local/sbin/ta_wlan_api.py` | loopback `127.0.0.1:9094` — GET scan + POST save-wlan kick |
| `tesla-linux-wlan.service` | `After=NetworkManager.service`; oneshot `boot`; `Restart=on-failure`; `WantedBy=multi-user.target` (not desktop/X). nginx `After=`/`Wants=` this unit; this unit does not `Before=nginx` |
| `tesla-linux-wlan-api.service` | `Type=simple`; `TA_BIND=127.0.0.1` |
| hostapd + dnsmasq | AP + DHCP (stock `hostapd.service` / `dnsmasq.service` stay disabled) |

Connect a client to **TeslaLinux** / **teslalinux**, then open `http://10.42.0.1/` (pick/save station WLAN). Stream page stays `http://10.42.0.1/desktop.html`. Probe: `http://10.42.0.1/probe.html`.

## Frontend picker (this SHA)

`tl-src/index.html` → `/var/www/tl/index.html` (nginx `index`). Operator on the AP LAN saves a **station** SSID+PSK.

Chrome lock (Designer): [design/ap-setup.md](../design/ap-setup.md) — title **Tesla Linux**; heading **Wi-Fi**; helper **Join the car's Wi-Fi**; labels **Network** / **Password**; button **Join**; status **Scanning · Joining · Saved · Couldn't join**.

- Origin-relative `GET`/`POST` `/api/wlan` (same `location.host` as the page). HTTP-only. No WebRTC. No OAuth.
- `POST` JSON `{ssid, psk}` — `psk` may be empty. Show a hard error on HTTP 501 instead of hanging.
- `GET` is optional: if Backend later returns a scan list, the page fills a dropdown; a typed SSID is enough if there is no scan.
- Do not rewrite `desktop.html` / `probe.html` for a settings maze. Do not reprint the factory AP PSK here.

## Backend `/api/wlan` (this SHA)

`tl-src/ta_wlan_api.py` listens on **`127.0.0.1:9094`** (never `0.0.0.0`). nginx `location /api/wlan` `proxy_pass`es there. **501 is gone.**

```
# save infra profile, tear down AP, NM associate, rebind nginx
tesla-linux-wlan save-wlan <ssid> [psk]
```

- `POST` JSON `{ssid, psk}` (`psk` may be empty) kicks `save-wlan` in a **background thread** and returns **HTTP 200 fast**. Picker fetch timeout is 15s — do not block the HTTP worker on `WAIT_SEC`.
- `GET` returns `{ssids:[...]}`. Scan failure is `200 {ssids:[]}`, not 501.
- Non-JSON POST or missing/invalid `ssid`: `400 {error:"..."}`.
- Display/touch/audio stay `TA_BIND=127.0.0.1`. Do not rewrite those `ta_*.py` files.

## Packages

`install-tesla-linux.sh --print-packages` includes `hostapd iw dnsmasq rfkill` in addition to the WAVE 0 stack. Bake already installs NetworkManager as the netplan renderer.
