# Keep from kiss — Team 1 (2026-09-01)

Source: tesla-android-kiss master `57ad40f` (POSTMORTEM / EXECUTION / README only).
Product: Pi 4 8 GB, Debian + LXDE. Not Android. KISS. Braindead-simple flash-and-launch.

## Product SUCCESS lock (chairman 2026-09-01)
Get the Pi on the SAME WLAN as the Tesla, then STREAM the Linux desktop (Debian + LXDE) to the car's web browser.
In-car path: station-mode on the Tesla WLAN → operator opens the stream URL in the Tesla browser → sees/hears the LXDE desktop.
Setup AP is the fallback when no saved WLAN — not the in-car path.

## How kiss got a desktop into the Tesla browser (verified)
Kiss in-car path was **SoftAP, not station**: the Pi is the AP; the car joins that LAN; the Tesla browser loads a web UI **served from the Pi** and receives screen+audio over that LAN (README / POSTMORTEM).
HTTP-only after prune (EXECUTION): lighttpd port 80, `/` → `/beta/`. Frontend is origin-relative (`window.location`), not hardcoded `wss://device.teslaandroid.com`. Hostname `device.teslaandroid.com` is **local SoftAP DNS** (dnsmasq), not upstream DNS.
Frontend KEEP-to-verify: vanilla-JS `beta/` with MJPEG default renderer plus h264-webcodecs / h264-broadway+avc.wasm. EXECUTION: over plain HTTP, WebCodecs/SharedArrayBuffer are unavailable — MJPEG default is unaffected.
lighttpd reverse-proxies `/sockets/{display,audio,touchscreen}` and `/stream` (MJPEG HTTP) and `/api`. Those backends were Android C services (virtual-display, audio-relay, …). Do not port those as Android HALs.
No Tesla-browser **bookmark requiring SSID TeslaAndroid** is proven in POSTMORTEM/EXECUTION/README. Hostname is `device.teslaandroid.com`, not an SSID. Fallback AP SSID is therefore **TeslaLinux**.
Do not invent WebRTC. Kiss docs used here do not describe WebRTC.

## What ports to Debian + LXDE (idea only — do not implement here)
- Capture/stream the **LXDE desktop** into an HTTP page the Tesla browser can open (MJPEG HTTP and/or same-origin WS, origin-relative). Not SurfaceFlinger, not AOSP C HALs.
- One origin on the Pi (HTTP only), bind the **in-car stream** so the car browser can load it while the Pi is a **station on the Tesla WLAN**.
- Tesla-browser quirks KEEP-to-verify: HTTP-only, origin-relative URLs, MJPEG default (EXECUTION). POSTMORTEM: keep beta frontend Tesla-browser quirks (except already-done origin-relative + GPS-off); do not casually drop them. EXECUTION: those quirks are load-bearing. If audio is kept, POSTMORTEM latency list includes 40 ms audio fragments. POSTMORTEM/EXECUTION/README do not name a user-gesture audio requirement — do not invent one.
- Latency tricks KEEP-to-verify if a capture path exists on Debian: DMA-BUF, stale-frame drop, 40 ms audio fragments, IDR-on-connect (POSTMORTEM). Do not invent a new encoder stack in this doc.
- BCM2711 HW H.264 (`/dev/video11`, port `m2m.c` not rewrite) is KEEP-if-useful on Debian (POSTMORTEM Pi 4 pivot). If unused, MJPEG remains the documented Tesla-browser default.
- Pi 4 8 GB / 5 V·3 A (~15 W Tesla USB-C) KEEP (POSTMORTEM).
- RPi Imager / flash path KEEP as the operator install idea (README/POSTMORTEM harness), retargeted at a Debian+LXDE image — do not implement here.

## Setup AP fallback (not in-car)
If no saved WLAN or join fails: raise AP SSID **TeslaLinux**. Documented operator default passphrase lives in this file only (plain default, not a secret): `teslalinux`.
Web GUI on that AP to pick/save Wi-Fi; next boot station-mode to that network. Bind the setup GUI to the **AP LAN only**, never `0.0.0.0` to the world. Port the idea with Debian NetworkManager/hostapd — do not port AOSP SoftAP/connman. SoftAP from kiss is leftover as this fallback only.

## DROP
AOSP; GloDroid / Raspberry Vanilla lunch; C services as Android HALs; GApps; CarPlay/AutoKit; Flutter; GPS/HTTPS (shelved in kiss); 12–16 h AOSP compile; OTA/ih8sn/Jelly/iOS tethering.

## WAVE 1 (name only — do not implement)
Boot LXDE on Pi 4 8 GB **and** this WLAN+browser stream path. Do not ship a desktop that cannot open in the Tesla browser.
