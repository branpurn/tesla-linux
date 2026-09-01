# WAVE 0 KEEP / DROP / GAPS

Supersedes PR #1 (`docs/KEEP-FROM-KISS.md`, Debian + LXDE keep-list). **Do not merge #1.**

One PR. Backend owns the streaming stack; Frontend owns the Tesla-browser client KEEP — both **in this PR** (do not open a second PR). kiss stays **PRIVATE**. No second repo. Do not touch tesla-android-kiss.

Inventory is against zip `tl-src/` (import **verbatim** into `tl-src/`). Do not invent `ta_*.py`, units, or nginx config. Zip html/scripts are imported. `ta_*.py` still pending — not invented.

## Product lock

| Item | Lock |
|---|---|
| Board | Raspberry Pi **4 8 GB only** |
| Distro | **Ubuntu Server arm64 raspi** (`UBUNTU_REL` **26.04** KEEP) |
| Desktop | **XFCE** — zip `xfce4` PKGS KEEP, `xfce4-session` KEEP |
| In-car path | Tesla WLAN → stream URL → XFCE desktop (`desktop.html`, **WAVE 0 KEEP**) |
| Image | `build-image.sh` → `.img.xz` (do **not** bake a real `.img` in this PR) |

Not Debian. Not LXDE. Do not switch. Not Pi 5. Strip any “Pi 4 + Pi 5, one image” comments on import.

No AOSP. No WebRTC. WAVE 1 AP / station path: [docs/WAVE1-WLAN.md](WAVE1-WLAN.md). Pick/save GUI is a **FRONTEND-HOLE** on that SHA (do not invent a settings maze here).

## KEEP — bake path (import zip files verbatim)

| Zip path | Role |
|---|---|
| `build-image.sh` | Ubuntu Server arm64 raspi → `.img.xz`. `UBUNTU_REL` 26.04 KEEP. |
| `install-tesla-linux.sh` | systemd units for **xorg / desktop / display / touch / audio**. `xfce4-session` KEEP. |
| `authorized_keys` | **Public** SSH key file. Import the file. Do not reprint the key in PR text. |
| `desktop.html` | Tesla-browser client (**WAVE 0 KEEP**). Canvas + origin-relative WebSocket (`ws`/`wss` from `location.protocol` + `location.host`). Title Tesla Linux. HUD. `/sockets/display` (H264 Annex-B → WebCodecs VideoDecoder → canvas), `/sockets/touchscreen` (JSON pointer/touch), `/sockets/audio` (S16LE PCM → Web Audio). Imported as-is from zip `tl-src/desktop.html`. |
| `probe.html` | Tesla-browser capability probe (**WAVE 0 KEEP**). Viewport CSS-px to match, WebCodecs, `isSecureContext`, WebSocket, MSE, AudioContext. Diagnostic. Imported as-is from zip `tl-src/probe.html`. |

Operator bake (after import):

```bash
sudo ./tl-src/build-image.sh
```

## KEEP — stack (Backend; import zip files verbatim; Backend bounces this SHA)

Loopback-only. `TA_BIND=127.0.0.1`. nginx TLS terminates and proxies `/sockets/*` to loopback.

| Zip path | Contract |
|---|---|
| `ta_display_backend.py` | `ximagesrc` → H.264 Annex-B WebSocket **:9091**. `v4l2h264enc` if `/dev/video11` else `x264enc`. SPS/PPS cache. Drop-oldest. |
| `ta_touch_backend.py` | uinput. kiss beta JSON + normalized. WebSocket **:9092**. Bind loopback. |
| `ta_audio_backend.py` | PipeWire/`pulsesrc` S16LE PCM WebSocket **:9093**. `tesla.monitor`. Bind loopback. |
| nginx site | `/sockets/display` → :9091, `/sockets/touchscreen` → :9092, `/sockets/audio` → :9093. |

## KEEP — Tesla-browser client (Frontend; WAVE 0, not WAVE 1)

One table. Origin-relative sockets are already in the zip (not hardcoded `https`/`wss://device.teslaandroid.com`). HTTP vs HTTPS follows the page. Do not invent WebRTC. `desktop.html` does not use it. `probe.html` only reports `RTCPeerConnection`.

| Zip path | Contract |
|---|---|
| `desktop.html` | Canvas + origin-relative WebSocket (`ws`/`wss` from `location.protocol` + `location.host`). Title Tesla Linux. HUD. `/sockets/display` (H264 Annex-B → WebCodecs VideoDecoder → canvas), `/sockets/touchscreen` (JSON pointer/touch), `/sockets/audio` (S16LE PCM → Web Audio). |
| `probe.html` | Viewport CSS-px to match, WebCodecs, `isSecureContext`, WebSocket, MSE, AudioContext. Diagnostic only. |

## DROP

- AOSP / C-service HAL
- WebRTC (do not invent; `desktop.html` does not use it)
- Flutter / kiss beta maze
- Hardcoded TLS host (`https`/`wss://device.teslaandroid.com`)
- LXDE
- Debian as the bake distro
- Making kiss public
- WAVE 1 pick/save **settings maze** (Frontend hole on WAVE 1 SHA — do not invent here)
- Pi 5
- Baking a real `.img` in this PR

## GAPS / FLAG (document, do not invent)

| ID | Gap | Action |
|---|---|---|
| FLAG-TLS | This stack: nginx TLS + loopback WS. kiss after prune: HTTP-only. Tesla-browser TLS/HTTP behavior is **not** resolved here. Do not invent a TLS policy. | **FLAG** |
| FLAG-AUDIO | This stack: raw S16LE PCM on :9093. kiss: FLAC / fMP4. Decoder/latency match is **not** resolved here. | **FLAG** |
| FLAG-MJPEG | `desktop.html` has no MJPEG fallback. WebCodecs needs a secure context; HTTP-only Tesla-browser is KEEP-to-verify. kiss MJPEG default is **not** in this zip. | **FLAG** |
| FLAG-AP-GUI | WAVE 1 AP + bind is in [WAVE1-WLAN.md](WAVE1-WLAN.md). Pick/save WLAN UI: **FRONTEND-HOLE** on that SHA. | **Frontend on WAVE 1 SHA** |

Do not invent a TLS policy or an audio transcoder here. hostapd AP is WAVE 1 ([WAVE1-WLAN.md](WAVE1-WLAN.md)). `desktop.html` **is** WAVE 0 KEEP.

## WAVE 1

Implemented on the WAVE 1 PR vs `1cb7c04`: saved-WLAN NM autoconnect else **hostapd** AP SSID **TeslaLinux** / password **teslalinux**, GUI on AP LAN. See [docs/WAVE1-WLAN.md](WAVE1-WLAN.md).

The Tesla-browser stream page / in-car path is **`desktop.html` and is WAVE 0 KEEP**. Frontend fills pick/save on the WAVE 1 SHA; Backend bounces autoconnect on that SHA.

## Import status

| Date | State |
|---|---|
| 2026-09-01 | Zip `tl-src/` not in the opening prompt. PR opened with inventory + README bake command. |
| 2026-09-01 | Backend follow-up: stack KEEP/DROP/GAPS landed. `ta_*.py` / nginx still **not invented**. |
| 2026-09-01 | Zip html/scripts imported into `tl-src/`: `build-image.sh`, `install-tesla-linux.sh`, `desktop.html`, `probe.html`, `authorized_keys`. Frontend KEEP/DROP/GAPS restomped (`probe.html` in KEEP; WAVE 1 list no longer names the stream page). `ta_*.py` still Backend-owned, not invented. |
