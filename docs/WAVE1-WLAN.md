# WAVE 1 — WLAN station else TeslaLinux AP

vs `1cb7c04`. Ubuntu Server + XFCE, Raspberry Pi **4 8 GB only**. No AOSP. No Pi 5. No WebRTC. kiss stays **PRIVATE**.

## Product path

1. **Preferred:** Pi is a NetworkManager **station** on a saved Tesla (or other) WLAN. Autoconnect.
2. **Fallback** when no saved WLAN / associate fails: **hostapd** AP (not nmcli-only hotspot).
   - SSID: **TeslaLinux** (TeslaAndroid-like). Do not invent a second SSID.
   - WPA2-PSK factory default password: **teslalinux**
   - AP LAN: **10.42.0.1/24** (DHCP `10.42.0.10`–`10.42.0.200`)
3. Web GUI on that AP: `/var/www/tl/index.html` at `http://10.42.0.1/` (pick/save station WLAN). Stream remains `/var/www/tl/desktop.html`. `probe.html` unchanged. Reachable by **other devices** on the Pi WLAN.
   - Not loopback-only. Not `0.0.0.0` to the world.
   - Bind HTTP to the AP LAN address and, when associated, to the WLAN station address.
   - FLAG-TLS (WAVE 0): do not invent a new TLS policy. HTTP on the AP LAN is acceptable so a Tesla browser can open the GUI without a cert maze.

Factory password **teslalinux** is a documented operator default, not a secret. Operators change it later (`/etc/tesla-linux/ap.env`). Frontend may add that to the picker later.

## Pre-seed a saved WLAN when flashing

Keep `/boot/firmware/tesla-linux.conf` on the FAT boot partition:

```
WIFI_SSID=YourTeslaWLAN
WIFI_PSK=yourpsk
```

First-boot still creates the NM infra profile (`connection.autoconnect yes`). `tesla-linux-wlan.service` then waits ~20s for association; if that fails, the TeslaLinux AP comes up.

## On the image

| Path | Role |
|---|---|
| `/etc/tesla-linux/ap.env` | Factory `AP_SSID=TeslaLinux`, `AP_PSK=teslalinux`, `AP_ADDR=10.42.0.1` |
| `/usr/local/sbin/tesla-linux-wlan` | `boot` / `ap-up` / `ap-down` / `nginx-bind` / `save-wlan` |
| `tesla-linux-wlan.service` | `After=NetworkManager.service`; oneshot `boot` |
| hostapd + dnsmasq | AP + DHCP (stock `hostapd.service` / `dnsmasq.service` stay disabled) |

Connect a client to **TeslaLinux** / **teslalinux**, then open `http://10.42.0.1/` (pick/save station WLAN). Stream page stays `http://10.42.0.1/desktop.html`. Probe: `http://10.42.0.1/probe.html`.

## Frontend picker (this SHA)

`tl-src/index.html` → `/var/www/tl/index.html` (nginx `index`). Operator on the AP LAN saves a **station** SSID+PSK.

- Origin-relative `GET`/`POST` `/api/wlan` (same `location.host` as the page). HTTP-only. No WebRTC. No OAuth.
- `POST` JSON `{ssid, psk}` — `psk` may be empty. Show a hard error on HTTP 501 instead of hanging.
- `GET` is optional: if Backend later returns a scan list, the page fills a dropdown; a typed SSID is enough if there is no scan.
- Do not rewrite `desktop.html` / `probe.html` for a settings maze. Do not reprint the factory AP PSK here.

## BACKEND-HOLE (this SHA)

Stack glue / autoconnect bounce on **this SHA**. Do not open a second PR.

```
# save infra profile, tear down AP, NM associate, rebind nginx
tesla-linux-wlan save-wlan <ssid> [psk]
```

nginx `location /api/wlan` currently returns **501** — Backend replaces that with the handler that calls `save-wlan` / `boot`. Backends stay `TA_BIND=127.0.0.1` behind nginx. Do not rewrite `ta_*.py`.

## Packages

`install-tesla-linux.sh --print-packages` includes `hostapd iw dnsmasq rfkill` in addition to the WAVE 0 stack. Bake already installs NetworkManager as the netplan renderer.
