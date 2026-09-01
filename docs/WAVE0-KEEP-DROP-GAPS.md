# WAVE 0 — KEEP / DROP / GAPS

Base: public `tesla-linux` `main` `bb698a102845f638a7c010901da0f9488f235cc9`.
This WAVE supersedes PR 1 (do not merge PR 1). Do not merge this PR either.

tesla-android-kiss stays **private**. Do not make kiss public. This tree does not import kiss.

Hardware lock: **Raspberry Pi 4 8 GB only**. Not Pi 5.
Desktop lock: **Ubuntu + XFCE**. Not Debian. Not LXDE.
No AOSP. No WebRTC. This PR does not bake a `.img`.

## KEEP — bake / stack

- Ubuntu Server **arm64 raspi** bake → `.img.xz` via `tl-src/build-image.sh` with `UBUNTU_REL=26.04`.
- `tl-src/install-tesla-linux.sh` (xfce4 in `PKGS`, `xfce4-session`)
- STACK backends on **loopback** `:9091` / `:9092` / `:9093` with **nginx TLS** proxy
  - `tl-src/ta_display_backend.py` — `ximagesrc` → H.264 Annex-B WS `:9091`, `v4l2h264enc` if `/dev/video11` else `x264enc`, `TA_BIND=127.0.0.1`
  - `tl-src/ta_touch_backend.py` — uinput, kiss beta JSON + normalized, WS `:9092`, loopback
  - `tl-src/ta_audio_backend.py` — PipeWire/`pulsesrc` S16LE PCM WS `:9093`, `tesla.monitor`, loopback
- `tl-src/authorized_keys` (public SSH key — import into the tree; do not reprint the key in PR text)

Operator bake (do not run in this PR):

```bash
sudo ./tl-src/build-image.sh
```

## KEEP — Tesla-browser client (Frontend; WAVE 0)

Imported verbatim from the zip. Origin-relative already in the zip (not hardcoded `device.teslaandroid.com`). HTTP vs HTTPS follows the page. Do not invent WebRTC. `desktop.html` does not use it. `probe.html` only reports `RTCPeerConnection`.

- `tl-src/desktop.html` — canvas + origin-relative WS (`ws`/`wss` from `location.protocol` + `location.host`). Title Tesla Linux. HUD.
  - `/sockets/display` — H264 Annex-B → WebCodecs `VideoDecoder` → canvas
  - `/sockets/touchscreen` — JSON pointer/touch
  - `/sockets/audio` — S16LE PCM → Web Audio
- `tl-src/probe.html` — diagnostic only: viewport CSS-px, WebCodecs, `isSecureContext`, WebSocket, MSE, AudioContext.

Serve these pages so a Tesla browser can open them while the Pi is a station on the Tesla WLAN (Ubuntu + XFCE). Binding/WLAN join is WAVE 1.

## DROP

- AOSP
- C-service HAL
- WebRTC (do not invent; `desktop.html` does not use it)
- Flutter / kiss beta maze
- Hardcoded `https`/`wss://device.teslaandroid.com`
- LXDE
- Debian as the bake distro
- Making kiss public
- Pi 5
- Merging PR 1
- WAVE 1 Wi-Fi setup GUI (do not build in WAVE 0)
- Baking a real `.img` in this PR

## GAPS / FLAG (do not invent)

Documented mismatches only. Do not close these here.

- **FLAG-TLS.** This STACK uses nginx TLS. Kiss in-car path after prune was HTTP-only. Flag only.
- **FLAG-AUDIO.** This STACK audio is **raw PCM** (S16LE). Kiss audio path was **FLAC / fMP4**. Flag only.
- **FLAG-MJPEG.** `desktop.html` has no MJPEG fallback. WebCodecs needs a secure context; HTTP Tesla-browser is KEEP-to-verify. kiss MJPEG default is not in this zip.
- **FLAG-AP-GUI / WAVE 1 (later, not this PR):** WLAN, setup AP, web GUI on AP (pick/save WLAN; bind AP LAN, not loopback-only, never `0.0.0.0` to the world). Tesla-browser stream page is `desktop.html` and is **WAVE 0 KEEP**.

## Import status

| Date | State |
|---|---|
| 2026-09-01 | PR opened with inventory + README bake pointer. |
| 2026-09-01 | Zip `tl-src/` imported: `build-image.sh`, `install-tesla-linux.sh`, `ta_display_backend.py`, `ta_touch_backend.py`, `ta_audio_backend.py`, `desktop.html`, `probe.html`, `authorized_keys`. Header lock: Pi 4 8 GB only. Frontend KEEP/DROP/GAPS included. |
