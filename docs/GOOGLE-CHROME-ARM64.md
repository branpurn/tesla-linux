# Google Chrome (ARM64) on the Pi 4 — "Google Chrome (DRM)"

Google now publishes an official Chrome for Linux **arm64** (apt repo
`dl.google.com/linux/chrome/deb`, `google-chrome-stable` 154.0.8037.97, 134 MB
deb / 440 MB installed) with a bundled native aarch64 Widevine CDM. This adds it
**next to** the Raspberry Pi-archive Chromium ([`CHROMIUM-HWDEC.md`](CHROMIUM-HWDEC.md)),
the Widevine-enabled "Chromium (DRM)" ([`CHROMIUM-WIDEVINE.md`](CHROMIUM-WIDEVINE.md)) and
Firefox. Nothing was removed.

## Short answer

| | Pi-archive Chromium 154 | Google Chrome 154 (arm64) |
| --- | --- | --- |
| Widevine CDM | 4.10.2662.3 (Oct 2023, `libwidevinecdm0`, hint file) | **4.10.3112.0**, bundled, found automatically; `chrome://components` shows the real version |
| EME (`com.widevine.alpha`) | default + `SW_SECURE_CRYPTO` ok; `SW_SECURE_DECODE`/`HW_SECURE_ALL` no (L3) | identical |
| **HW video decode** | **yes** — `V4L2VideoDecoder`, `/dev/video10` held by the gpu process | **no** — `FFmpegVideoDecoder`; V4L2 *decoder* isn't compiled in (only V4L2 camera capture); `--enable-features=AcceleratedVideoDecodeLinux*` changes nothing |
| DRM video decode | software, in the CDM (`DecryptingVideoDecoder`) | same |
| Clear 720p30 H.264 CPU | ~52% of one core | ~140–147% (96% in one run with `--disable-frame-rate-limit`) |

**Recommendation: keep the Pi-archive Chromium as the everyday browser** (it is the
only one with HW decode) and treat Google Chrome as optional — useful only if a
service refuses the 2023 CDM. A newer CDM does not make DRM playback cheaper
(CPU/dropped-frame numbers below are the same within noise), and Chrome costs
~0.5 GB of an 8 GB card.

## What is installed

`tl-src/install-google-chrome-arm64.sh` (run by `install-tesla-linux.sh`, hence
by the image bake; `TL_SKIP_GOOGLE_CHROME=1` skips it; it refuses to start with
< 900 MB free, `TL_GC_MIN_FREE_MB`). On a live Pi:

```
sudo ./tl-src/install-google-chrome-arm64.sh      # idempotent
sudo ./tl-src/install-tesla-linux.sh --verify-google-chrome
./tl-src/selftest-google-chrome-arm64.sh           # 36 plant gates (+4 live on a Pi with DISPLAY)
```

- **apt:** `/etc/apt/keyrings/google-chrome.asc` (fingerprint
  `EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796` checked), `google-chrome.sources`
  (deb822, `Architectures: arm64`, `Signed-By`), `/etc/apt/preferences.d/google-chrome`
  pinning the whole Google repo to -10 except `google-chrome-stable` (990) —
  beta/unstable/canary can't come in. Google's postinst also (re)writes an
  equivalent `.sources`; `/etc/default/google-chrome` is pre-seeded so it doesn't add a second one.
- **Default browser guard:** the postinst registers Chrome as `x-www-browser`
  (priority 200 > Firefox 100) — that happened on the first manual install and was
  reverted. The installer removes the registration and ships
  `/etc/apt/apt.conf.d/99tesla-linux-google-chrome` (`DPkg::Post-Invoke`) so
  upgrades can't flip it again. Firefox remains the default.
- **Launcher:** `/usr/local/bin/google-chrome-tl` → `/usr/bin/google-chrome-stable`
  with `/etc/tesla-linux/google-chrome.conf` flags (`--ozone-platform=x11
  --start-maximized --disable-frame-rate-limit --no-first-run --no-default-browser-check
  --password-store=basic ...`; no `--no-sandbox`). Menu entry and Desktop icon
  **"Google Chrome (DRM)"**; profile `~/.config/google-chrome`. Widevine needs no wiring.
- **Policy:** `/etc/opt/chrome/policies/managed/tesla-linux.json` (HW accel on, no
  default-browser nag, no metrics/sign-in/sync/background mode) plus a
  force-installed copy of the `tl-h264-only` extension (below).
- **h264-only for Chrome:** branded Chrome ≥ 137 ignores `--load-extension`, and
  without the extension YouTube serves Chrome **AV1** (software dav1d). So
  `tl-src/chromium/h264-only/pack-crx3.py` builds a signed CRX3 (key in
  `/etc/tesla-linux/chrome-h264only.pem`) + `updates.xml` into
  `/usr/share/tesla-linux/chrome-ext/`, and the policy force-installs it via
  `ExtensionInstallForcelist` (`file://` update URL — tested: after the first
  launch `MediaSource.isTypeSupported` answers false for VP9/AV1, YouTube serves
  `avc1`). `TL_GC_H264ONLY=0` disables it. Note it takes effect after the first
  start of a new profile.
- Untouched: `/etc/chromium.d/*`, the Pi Chromium policy/pins, `chromium-drm`.

Disk: 2.8 GB free → 2.3 GB right after the install (134 MB deb + 440 MB
installed); the installer deletes the cached deb and `apt-get clean` on the Pi
brought it back to **2.6 GB free** (≈ 0.2 GB net, i.e. Chrome ≈ 0.5 GB minus the
~0.3 GB apt cache that was freed).

## Evidence (Pi 4, 2026-10-02, loaded: car stream + user browsers, load avg 5–11)

Same probe as before (`tl-src/chromium/drm-test/probe.py`, now with `--gpu`,
`--js`, `--report-js`).

**Widevine:** `/opt/google/chrome/WidevineCdm/manifest.json` = 4.10.3112.0
(`x-cdm-host-versions` 10,11; cenc+cbcs; vp8/vp9/avc1/av01), `chrome://components`
→ "Widevine Content Decryption Module 4.10.3112.0" (vs 0.0.0.0 shown for the
hinted 4.10.2662.3 in Chromium). `requestMediaKeySystemAccess`: default ok,
`SW_SECURE_CRYPTO` ok, `SW_SECURE_DECODE`/`HW_SECURE_ALL` NotSupported → **L3**.
`chrome://gpu`: ANGLE/GLES on V3D 4.2.14.0 (Mesa 26.0.3), "Video Decode: Hardware
accelerated" is generic — the actual decoder is FFmpeg.

**DRM playback** (Axinom multi-DRM test vector via Shaka, H.264 24 fps, license ok,
`mediaKeys` set, `DecryptingVideoDecoder`, `/dev/video10` not opened). 40 s windows:

| Rung | Chrome 4.10.3112.0: CPU / dropped | Chromium (DRM) 4.10.2662.3: CPU / dropped |
| --- | --- | --- |
| 480p | 149% / 25% | 182% / 4% |
| 720p | 189% / 36% (repeat 206% / 32%; `--disable-frame-rate-limit` 230% / 32%) | 201–217% / 18–26% |
| 1080p | 226% / 36% | 240% / 43% |

Not black (X grab, `gst ximagesrc`): video-area mean luma 106–136, ≤2% dark pixels.
CPU/dropped differ run to run with the system load; nothing here shows the newer
CDM being cheaper. Same conclusion as before: ≤ 480p comfortable, 720p marginal,
1080p unusable while the car stream runs; Netflix (L3) caps at 720p.

**Clear H.264 720p30 (looped test clip):**

| Browser/flags | Decoder | CPU | Dropped |
| --- | --- | --- | --- |
| Chromium (Pi) | V4L2VideoDecoder, `/dev/video10` | 52% | 15% |
| Chrome | FFmpegVideoDecoder | 141–147% | 36–37% |
| Chrome + `--disable-frame-rate-limit` | FFmpeg | 96% | 5% (single run) |
| Chrome + `AcceleratedVideoDecodeLinux,...GL,...ZeroCopyGL --ignore-gpu-blocklist` | FFmpeg (no effect) | 144% | 39% |
| Firefox 156 (earlier measurement, `CHROMIUM-HWDEC.md`) | software | ~148% | – |

At 720p30 under the car-stream load Chrome's software decode costs ~1.4–1.5 cores,
roughly the same as Firefox and 2.7× Chromium's HW decode; it works but leaves the
capture/encode pipeline much less headroom.

**YouTube** (Big Buck Bunny 60 fps, quality forced to 720p, ~35 s, window
800×520):

| Browser | Codec / decoder | CPU | Frames / dropped |
| --- | --- | --- | --- |
| Chromium (Pi, extension) | avc1 / V4L2VideoDecoder (`/dev/video10`) | 200% | 1782 / 1224 (69%); earlier runs 67–70% |
| Chromium + `--disable-frame-rate-limit --disable-gpu-vsync` | avc1 / V4L2 | 119% | run caught still at 240p (1280×720 request) – not comparable |
| Chrome, no extension | **av01 / dav1d** | 224% | 1221 / 846 (69%) — falls behind (≈1100 frames in 21 s) |
| Chrome + h264-only (policy CRX) | avc1 / FFmpeg | 202–228% | 1825–2125 / 67–69% |

Dropped frames are the same ~67–70% with HW and software decode: at 720p60 the
limit under this load is presentation (X/compositor + the car pipeline), not
decode — consistent with `CHROMIUM-HWDEC.md`. 720p60 on YouTube is not smooth in
either browser right now; 720p30/480p is the realistic target.

## The black YouTube pane — not reproduced as a clean bug, cause not found

- Real YouTube in the Pi Chromium (fresh profile, same wrapper flags): the picture
  is visible in the grabs (mean luma/colour content inside the player), and the
  user's own grab (`yt4_cr`) confirms rendering. I could not reproduce a persistent
  all-black pane.
- With the video paused I compared a canvas readback of the frame with the screen
  at the player rectangle (normalised cross-correlation): Chromium with
  `--disable-accelerated-video-decode` (0.96), `--disable-gpu-compositing` (0.95)
  and `--disable-gpu-vsync` (0.97) match at the expected position. For default
  flags the canvas readback of the V4L2 frame itself came back blank
  (`drawImage` of the HW frame), so that comparison was inconclusive; Chrome (SW
  decode) matched at 0.89 with a layout offset I attribute to window-frame
  geometry, not to a bug. Hypothesis only: the black/misplaced pane is tied to the
  V4L2 zero-copy frame path in Chromium (the only browser that has it), since
  Chrome never uses it. Flags that sidestep it at a CPU cost:
  `--disable-accelerated-video-decode`. Not verified as Brandon's exact failure.

## Netflix

Not tested (no account). Same expectations as `CHROMIUM-WIDEVINE.md`: Widevine L3,
≤ 720p, H.264. The newer CDM (3112 vs 2662) is the only reason to prefer Chrome
if Netflix/Prime rejects the old one.

## Licensing / notes

Chrome and its Widevine CDM are proprietary Google software under Google's terms
(<https://www.google.com/chrome/terms/>); nothing is committed to this repo, the
installer fetches them from Google's apt repo on the device (the bake does it in
the chroot). No auto-updates: `sudo apt-get update && sudo apt-get install
--only-upgrade google-chrome-stable` (Google's cron job only maintains the repo file).
