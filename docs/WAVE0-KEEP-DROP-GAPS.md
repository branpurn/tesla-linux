# WAVE 0 KEEP / DROP / GAPS

Supersedes PR #1 (`docs/KEEP-FROM-KISS.md`, Debian + LXDE keep-list). **Do not merge #1.**

Inventory is against zip `tl-src/` (import into this repo as `tl-src/`). This landing opens with the inventory + bake command. Zip files land when the follow-up base64 gzip tarball arrives; do not invent them.

## Product lock

| Item | Lock |
|---|---|
| Board | Raspberry Pi **4 8 GB only** |
| Distro | **Ubuntu Server arm64 raspi** (`UBUNTU_REL` **26.04** KEEP) |
| Desktop | **XFCE** (zip `xfce4` PKGS KEEP) |
| Image | `build-image.sh` → `.img.xz` (do **not** bake a real `.img` in this PR) |

Not Debian. Not LXDE. Not Pi 5. Strip any “Pi 4 + Pi 5, one image” comments on import — do not expand to Pi 5.

kiss stays **PRIVATE**. No second repo. No AOSP. No WebRTC.

## KEEP — bake path (import zip files)

| Zip path | Role |
|---|---|
| `build-image.sh` | Ubuntu Server arm64 raspi → `.img.xz`. `UBUNTU_REL` 26.04 KEEP. |
| `install-tesla-linux.sh` | On-image / first-boot install of Tesla-Linux stack. |
| `authorized_keys` | **Public** SSH key file. Import the file. Do not reprint the key in PR text. |
| `desktop.html` | Import **as-is**. Frontend fills later. |

Operator bake (after import):

```bash
sudo ./tl-src/build-image.sh
```

## KEEP — stack (import zip files; Backend bounces this SHA)

Loopback-only backends. nginx TLS terminates and proxies `/sockets/*` to `127.0.0.1`. `TA_BIND=127.0.0.1`.

| Zip path | Contract |
|---|---|
| `ta_display_backend.py` | `ximagesrc` → H.264 Annex-B WebSocket **:9091**. `v4l2h264enc` if `/dev/video11` else `x264enc`. SPS/PPS cache. Drop-oldest. |
| `ta_touch_backend.py` | uinput. kiss beta JSON + normalized. WebSocket **:9092**. Bind loopback. |
| `ta_audio_backend.py` | PipeWire/`pulsesrc` S16LE PCM WebSocket **:9093**. `tesla.monitor`. Bind loopback. |
| nginx site | Proxy `/sockets/*` to those loopback ports. nginx TLS. |

## DROP

- AOSP / GloDroid / Raspberry Vanilla / C-service HAL
- WebRTC
- LXDE (PR #1 product line)
- Debian as the bake distro (PR #1 product line)
- Making kiss public / cloning kiss into this repo
- Pi 5 / “one image for Pi 4 + Pi 5”
- Baking a real `.img` in this PR

## GAPS / FLAG (document, do not invent)

| ID | Gap | Action |
|---|---|---|
| FLAG-TLS | This stack: nginx TLS + loopback WS. kiss after prune: HTTP-only (lighttpd :80, origin-relative). Tesla-browser TLS/HTTP behavior is **not** resolved here. | **FLAG** |
| FLAG-AUDIO | This stack: raw S16LE PCM on :9093. kiss: FLAC / fMP4 fragments. Decoder/latency match is **not** resolved here. | **FLAG** |

Do not invent a TLS policy, an audio transcoder, or a Tesla-browser client in WAVE 0.

## WAVE 1 — not this PR

Name only. Do not implement:

- WLAN station join
- Setup AP fallback
- Web GUI on the AP
- Tesla-browser stream page / in-car path

## Import status

| Date | State |
|---|---|
| 2026-09-01 | Zip `tl-src/` not in the opening prompt. PR opened with this file + README bake command. Awaiting follow-up base64 gzip tarball of `tl-src/`. |
