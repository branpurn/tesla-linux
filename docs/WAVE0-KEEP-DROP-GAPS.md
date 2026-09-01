# WAVE 0 — KEEP / DROP / GAPS

Base: public `tesla-linux` `main` `bb698a102845f638a7c010901da0f9488f235cc9`.
This WAVE supersedes PR 1 (do not merge PR 1). Do not merge this PR either.

tesla-android-kiss stays **private**. Do not make kiss public. This tree does not import kiss.

Hardware lock: **Raspberry Pi 4 8 GB only**. Not Pi 5.
Desktop lock: **Ubuntu + XFCE**. Not Debian. Not LXDE.
No AOSP. No WebRTC. This PR does not bake a `.img`.

## KEEP

- Ubuntu Server **arm64 raspi** bake → `.img.xz` via `tl-src/build-image.sh` with `UBUNTU_REL=26.04`.
- `tl-src/install-tesla-linux.sh`
- **xfce4** in `PKGS` (Ubuntu + XFCE locked)
- STACK backends on **loopback** `:9091` / `:9092` / `:9093` with **nginx TLS** proxy
  - `tl-src/ta_display_backend.py`
  - `tl-src/ta_touch_backend.py`
  - `tl-src/ta_audio_backend.py`
  - `tl-src/desktop.html`
  - `tl-src/probe.html`
- `tl-src/authorized_keys` (public SSH key — import into the tree; do not reprint the key in PR text)

## DROP

- AOSP
- C-service HAL
- WebRTC
- LXDE
- Making kiss public
- Pi 5
- Merging PR 1

## GAPS / FLAG (do not invent)

Documented mismatches only. Do not close these here.

- **TLS vs kiss HTTP-only.** This STACK uses nginx TLS. Kiss in-car path after prune was HTTP-only. Flag only.
- **Audio codec.** This STACK audio is **raw PCM**. Kiss audio path was **FLAC / fMP4**. Flag only.
- **WAVE 1 (later, not this PR):** WLAN, setup AP, web GUI on AP, Tesla-browser stream.

## Bake pointer (do not bake here)

Operator bake is `tl-src/build-image.sh` (`UBUNTU_REL=26.04`) → `.img.xz` for Pi 4 8 GB. Then `tl-src/install-tesla-linux.sh`. Files under `tl-src/` are imported when present; this WAVE does not run the bake.
