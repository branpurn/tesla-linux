# WAVE 0 KEEP / DROP / GAPS

Supersedes PR #1 (`docs/KEEP-FROM-KISS.md`, Debian + LXDE keep-list). **Do not merge #1.**

One PR. Backend owns the streaming stack **in this PR** (do not open a second PR). kiss stays **PRIVATE**. No second repo.

Inventory is against zip `tl-src/` (import **verbatim** into `tl-src/`). Do not invent `ta_*.py`, units, or nginx config. Zip bytes land when the follow-up tarball arrives.

## Product lock

| Item | Lock |
|---|---|
| Board | Raspberry Pi **4 8 GB only** |
| Distro | **Ubuntu Server arm64 raspi** (`UBUNTU_REL` **26.04** KEEP) |
| Desktop | **XFCE** — zip `xfce4` PKGS KEEP, `xfce4-session` KEEP |
| Image | `build-image.sh` → `.img.xz` (do **not** bake a real `.img` in this PR) |

Not Debian. Not LXDE. Do not switch. Not Pi 5. Strip any “Pi 4 + Pi 5, one image” comments on import.

No AOSP. No WebRTC. No WAVE 1 AP in this PR.

## KEEP — bake path (import zip files verbatim)

| Zip path | Role |
|---|---|
| `build-image.sh` | Ubuntu Server arm64 raspi → `.img.xz`. `UBUNTU_REL` 26.04 KEEP. |
| `install-tesla-linux.sh` | systemd units for **xorg / desktop / display / touch / audio**. `xfce4-session` KEEP. |
| `authorized_keys` | **Public** SSH key file. Import the file. Do not reprint the key in PR text. |
| `desktop.html` | Import **as-is**. Frontend fills later. |

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

## DROP

- AOSP / C-service HAL
- WebRTC
- LXDE
- Debian as the bake distro
- Making kiss public
- **hostapd / setup AP** (WAVE 1, after this PR)
- Pi 5
- Baking a real `.img` in this PR

## GAPS / FLAG (document, do not invent)

| ID | Gap | Action |
|---|---|---|
| FLAG-TLS | This stack: nginx TLS + loopback WS. kiss after prune: HTTP-only. Tesla-browser TLS/HTTP behavior is **not** resolved here. | **FLAG** |
| FLAG-AUDIO | This stack: raw S16LE PCM on :9093. kiss: FLAC / fMP4. Decoder/latency match is **not** resolved here. | **FLAG** |

Do not invent a TLS policy, an audio transcoder, hostapd, or a Tesla-browser client in WAVE 0.

## WAVE 1 — after this PR

Name only. Do not implement here:

- WLAN station join
- hostapd / setup AP
- Web GUI on the AP
- Tesla-browser stream page / in-car path

## Import status

| Date | State |
|---|---|
| 2026-09-01 | Zip `tl-src/` not in the opening prompt. PR opened with inventory + README bake command. |
| 2026-09-01 | Backend follow-up: stack KEEP/DROP/GAPS landed. Zip bytes still absent — **not invented**. Awaiting verbatim `tl-src/` tarball (`ta_*.py`, `install-tesla-linux.sh`, nginx, units). |

## KEEP / DROP / GAPS — Frontend (Tesla-browser client)

Copywriter off. Frontend owns in-app strings.

### KEEP

- desktop.html: canvas + origin-relative WS (ws/wss from location.protocol + location.host). Sockets /sockets/display (H264 Annex-B → WebCodecs VideoDecoder → canvas), /sockets/touchscreen (JSON pointer/touch), /sockets/audio (S16LE PCM → Web Audio). HUD. Title Tesla Linux.
- probe.html: viewport CSS-px, WebCodecs, isSecureContext, WebSocket, MSE, AudioContext. Diagnostic only.
- Origin-relative already in zip (not hardcoded device.teslaandroid.com). HTTP vs HTTPS follows the page.
- Do not invent WebRTC. desktop.html does not use it. probe.html only reports RTCPeerConnection.

### DROP

- Flutter / kiss beta maze. Hardcoded https/wss://device.teslaandroid.com. WAVE 1 Wi-Fi setup GUI (do not build in WAVE 0).

### GAPS

- desktop.html has no MJPEG fallback. WebCodecs needs secure context; HTTP Tesla-browser KEEP-to-verify. kiss MJPEG default is not in this zip.
- WAVE 1 AP Wi-Fi setup GUI (pick/save WLAN, bind AP LAN not loopback-only / not 0.0.0.0 world) — document only.
- Serve these pages so Tesla browser can open them while Pi is a station on Tesla WLAN (Ubuntu+XFCE).

## KEEP — Tesla-browser client (Frontend; import zip files verbatim)

Frontend owns in-app strings. Copywriter off. Do not invent WebRTC.

| Zip path | Contract |
|---|---|
| `desktop.html` | canvas + origin-relative WS (`ws`/`wss` from `location.protocol` + `location.host`). `/sockets/display` (H264 Annex-B → WebCodecs VideoDecoder → canvas), `/sockets/touchscreen` (JSON pointer/touch), `/sockets/audio` (S16LE PCM → Web Audio). HUD. Title Tesla Linux. |
| `probe.html` | viewport CSS-px, WebCodecs, isSecureContext, WebSocket, MSE, AudioContext. Diagnostic only. |

Origin-relative already in the zip (not hardcoded `device.teslaandroid.com`). HTTP vs HTTPS follows the page. `desktop.html` does not use WebRTC. `probe.html` only reports `RTCPeerConnection`.

## DROP (Frontend)

- Flutter / kiss beta maze
- Hardcoded `https`/`wss://device.teslaandroid.com`
- WAVE 1 Wi-Fi setup GUI (do not build in WAVE 0)

## GAPS / FLAG (Frontend; document, do not invent)

| ID | Gap | Action |
|---|---|---|
| FLAG-MJPEG | `desktop.html` has no MJPEG fallback. WebCodecs needs a secure context; HTTP Tesla-browser KEEP-to-verify. kiss MJPEG default is not in this zip. | **FLAG** |
| FLAG-AP-GUI | WAVE 1 AP Wi-Fi setup GUI (pick/save WLAN, bind AP LAN not loopback-only / not 0.0.0.0 world). | **document only** |
| FLAG-STATION | Serve these pages so the Tesla browser can open them while the Pi is a station on Tesla WLAN (Ubuntu+XFCE). | **WAVE 1** |

## Import status (update)

Zip scripts + html (`build-image.sh`, `install-tesla-linux.sh`, `desktop.html`, `probe.html`, `authorized_keys`) imported. `ta_*.py` owned by Backend on this SHA.
