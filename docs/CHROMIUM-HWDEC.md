# Chromium with V4L2 hardware H.264 decode (Pi 4)

**Chromium** is the **only browser** on Tesla Linux and the system
default (a software-decoding browser managed only ≈144p YouTube on the Pi 4).
It decodes H.264 on the Pi 4's VideoCore decoder (`/dev/video10`, `bcm2835-codec`, V4L2 stateful).

## What is installed

`tl-src/install-chromium-hwdec.sh` (run by `install-tesla-linux.sh`, hence by
the image bake; `TL_SKIP_CHROMIUM=1` skips it). On a live Pi:

```
sudo ./tl-src/install-chromium-hwdec.sh      # idempotent
sudo ./tl-src/install-tesla-linux.sh --verify-chromium
./tl-src/selftest-chromium-hwdec.sh           # host-side gates
```

- **Package source:** Raspberry Pi's own `chromium` (154.x, Debian trixie
  build with the V4L2 decode patches) from `archive.raspberrypi.com`, via
  `/etc/apt/sources.list.d/raspberrypi-chromium.list` (`signed-by` keyring,
  key fingerprint `CF8A 1AF5 02A2 AA2D 763B AE7E 82B1 2992 7FA3 303E` checked
  at install). `/etc/apt/preferences.d/raspberrypi-chromium` pins the whole Pi
  archive to **-10**, except `chromium chromium-common chromium-sandbox
  chromium-l10n zenoty` (990) — the Pi archive's kernels, firmware
  etc. can never be pulled in.
- **Libraries:** all satisfied from Ubuntu 26.04 except `libjpeg62-turbo`
  (Ubuntu only has `libjpeg-turbo8`, different soname). The installer fetches
  the exact Debian trixie `libjpeg62-turbo_2.1.5-4_arm64.deb` and checks its
  sha256 (matches Debian's signed index). It coexists with `libjpeg-turbo8`.
  `zlib1g` gets the normal Ubuntu security bump as a dependency; the installer
  sets `NEEDRESTART_SUSPEND=1` so no service is restarted.
- **Not installed:** `rpi-chromium-mods` (forces `--force-renderer-accessibility`
  which costs CPU, a welcome tab and remote extensions).
- **Config (managed by the installer):**
  - `/etc/chromium/policies/managed/tesla-linux.json` — HW acceleration on,
    no default-browser nag, no metrics, no sign-in/sync, no background mode.
  - `/etc/chromium.d/tesla-linux` — sourced by the Debian wrapper
    `/usr/bin/chromium`: `--ozone-platform=x11 --start-maximized
    --disable-frame-rate-limit --no-first-run --password-store=basic
    --disable-session-crashed-bubble --hide-crash-restore-bubble`.
    (The wrapper itself adds `--use-angle=gles`; Pi's `default-flags` add
    `--enable-gpu-rasterization`.)
  - `/usr/share/chromium/extensions/tl-h264-only/` — tiny MV3 extension
    (`tl-src/chromium/h264-only`), auto-loaded by the wrapper. See below.
  - Launcher (the only one): `/usr/local/share/applications/chromium.desktop`
    (XFCE menu → Internet → "Chromium", `Exec=/usr/bin/chromium %U`) and, if
    `~teslalinux` exists, `~/Desktop/Chromium.desktop`. Every launch path also
    gets Widevine from `/etc/chromium.d/tesla-linux-widevine`
    ([`CHROMIUM-WIDEVINE.md`](CHROMIUM-WIDEVINE.md)). The old "Chromium (HW
    video)" / "Chromium (DRM)" launchers are removed on install.
- Audio needs nothing: Chromium plays to the default Pulse/PipeWire sink,
  which `tesla-linux` already sets to `tesla`. Window: maximized in the
  1088×832 screen.
- Chromium is the default browser: `x-www-browser` / `gnome-www-browser`
  (`update-alternatives`), `/etc/xdg/mimeapps.list` (http, https, html),
  XFCE preferred application `WebBrowser=chromium` (system + `~/.config/xfce4/helpers.rc`).
  Firefox and Google Chrome are not installed (an Oct 2026 comparison showed
  Chrome arm64 has no V4L2 decoder: ≈140% vs ≈52% CPU at 720p30).

## YouTube must be H.264

YouTube serves VP9/AV1 by default; the Pi 4 has **no** VP9/AV1 hardware
decoder, so those fall to slow software decode. `tl-h264-only` runs in the
page's main world at `document_start` and answers "unsupported" for
VP8/VP9/AV1 from `MediaSource.isTypeSupported`, `canPlayType` and
`MediaCapabilities.decodingInfo`, so the player falls back to `avc1`. Same idea
as the h264ify extension, but local (no web store, MV3-safe). Verified:
`getStatsForNerds().codecs` = `avc1.4d4020 (298) / opus (251)` at 720p60 and
`avc1.64002a (299)` at 1080p60. H.264 on YouTube tops out at 1080p; 1440p/4K
are VP9/AV1-only, so they are not offered.

## YouTube mobile site (`youtube-mobile-rules.json`)

The *desktop* YouTube watch page is not decoder-bound on a Pi 4, it is
JS/compositor-bound: DOMContentLoaded 22-31 s, skeleton UI after ~40 s,
comments never load, renderer main thread 70-85 %, ~200 % CPU and 30-47 %
dropped frames even at 240-480p (uBlock Origin Lite, compositor tweaks,
frame-rate-limit, SW raster/decode: none of it helps). The **mobile site**
(`m.youtube.com` with a mobile User-Agent) is light: DCL 5-11 s,
`V4L2VideoDecoder`, 0 dropped frames at 480p/720p (68 early drops at 1080p).

`tl-h264-only` (version >= 1.1) therefore also ships a static
declarativeNetRequest rule set, `chromium/h264-only/youtube-mobile-rules.json`
(permission `declarativeNetRequest`; host permissions only
`*.youtube.com`, `*.googlevideo.com`, `*.ytimg.com`):

1. **Redirect** `http(s)://[www.]youtube.com/<path>?<query>` -> `https://m.youtube.com/<path>?<query>`,
   **main frame only**. Priority-4 `allow` rules (one `||youtube.com/<prefix>^`
   urlFilter each; a single big regex is silently dropped by Chrome's RE2
   memory limit) keep `/embed`, `/api`, `/youtubei`, `/s`, `/yt`, `/tv`,
   `/live_chat`, `/oauth*`, `/signin`, `/accounts`, `/redirect`, `/get_video`,
   `/videoplayback`, `/ptracking`, `/generate_204`, `/upload`, `/pagead` on the
   desktop host. `music.youtube.com`, `studio.youtube.com`, `accounts.youtube.com`
   and `tv.youtube.com` never match the redirect.
2. **Mobile `User-Agent`** (+ `sec-ch-ua-mobile: ?1`, `sec-ch-ua-platform: "Android"`)
   set on requests whose domain is `youtube.com`, `googlevideo.com` or
   `ytimg.com` (minus music/studio/tv/accounts). Nothing else is touched, so
   Prime Video and every other site keep the desktop UA and Widevine/DRM
   behaviour is unchanged.

Verified on the Pi 4 (clone of the real profile, remote debugging): a
`www.youtube.com/watch?v=...` link lands on `m.youtube.com/watch?...` (307, path and
query kept), `V4L2VideoDecoder`, 0 dropped frames after ~50 s at 480p (854x364)
and 720p (1280x546), DCL 4-7 s; `/embed/<id>` stays on www.youtube.com;
`music.youtube.com` and `amazon.com/gp/video` keep the desktop UA on every request.

Caveats: `navigator.userAgent` in the page still reports the desktop UA (DNR
only changes the network header; the m. site keys off the header and the
redirect, which is enough); the UA string is pinned to a Chrome/154 Pixel
string and should be bumped with Chromium majors; the m. layout is the phone UI;
embedded players on third-party sites use the desktop `/embed` page but their
sub-requests to youtube.com/googlevideo/ytimg carry the mobile UA.
Chromium writes the indexed ruleset of an unpacked extension to
`<ext>/_metadata/generated_indexed_rulesets`, and the browser runs as the desktop
user, so the installer creates `/usr/share/chromium/extensions/tl-h264-only/_metadata`
owned by `$TL_USER`; without that the extension fails to load with
"youtube-mobile-rules.json: Internal error while parsing rules" (`--verify` and the
selftest gate it).
Static rulesets are indexed per extension *version*: **bump the manifest
version whenever the rules change**. New versions are picked up on the next
Chromium start (close the browser gracefully; never SIGKILL a decoding
Chromium). To switch the feature off, set `"enabled": false` for the
`youtube_mobile` rule resource in `manifest.json` (or delete
`youtube-mobile-rules.json` from `/usr/share/chromium/extensions/tl-h264-only/`
*and* its manifest entry) and restart Chromium. `selftest-chromium-hwdec.sh`
gates the manifest permissions, host scope, redirect/allow/UA rules and the
version; `install-chromium-hwdec.sh --verify` fails if the rules file is missing.

## How HW decode was verified (Pi 4, Ubuntu 26.04, kernel 7.0.0-1009-raspi)

1. `chrome://gpu`: *Video Decode: Hardware accelerated*; GL = ANGLE/OpenGL ES
   on `V3D 4.2.14.0`, Mesa 26.0.3.
2. DevTools `Media` domain on a playing `<video>`:
   `kVideoDecoderName = V4L2VideoDecoder`, `kIsPlatformVideoDecoder = true`.
   With `--disable-accelerated-video-decode` that falls back to software.
3. `ls -l /proc/<pid>/fd` of the Chromium GPU process (`--type=gpu-process`)
   shows `/dev/video10` open while a video plays (also in every run below).
4. CPU of the browser process tree, same test file, same moment.

Quick manual check:

```
chromium --remote-debugging-port=9222 file:///path/test.html &
for p in $(pgrep -f 'type=gpu-process'); do ls -l /proc/$p/fd | grep video10; done
```

## Measurements

Local 720p30 / 1080p30 High-profile H.264 test clips (ffmpeg `testsrc2`, 60 s,
looped). **Measured while the real stream was running** (display backend
capturing/encoding for the car, Xorg, plus the user's own Firefox): the
machine was ~80% busy before the test window opened. CPU is the sum over the
browser's process tree for 20–30 s, in % of one core (400% = all four).

| Case | 720p30 | 1080p30 |
| --- | --- | --- |
| Chromium, V4L2 HW decode | **69%** (`/dev/video10` held by GPU process) | **80%** |
| Chromium, `--disable-accelerated-video-decode` | 107–109% | – |
| Firefox 156 (software decode, fresh profile) | 148% | 150% |

Dropped frames (Chromium `getVideoPlaybackQuality`, 720p30 clip, 20 s window):
~60–70% dropped with HW decode and default flags, ~56% with software decode
— i.e. the limit was **presentation**, not decode: with
`--disable-frame-rate-limit` HW decode dropped ~30% (166–226 of ~565), while
`--disable-gpu-vsync` alone did nothing and `--enable-zero-copy` / GPU-compositing
off did not help. The flag is therefore in the shipped flags file. A rAF probe
on a blank page ran at only ~11–25 fps under that load; the X server and the
capture pipeline are the bottleneck once decode is off the CPU.

YouTube (Big Buck Bunny 60 fps, H.264, quality forced, in-car-stream load):

| Quality | Frames in 20 s | Browser CPU | Verdict |
| --- | --- | --- | --- |
| 720p60 | 1119 (~56 fps), 0 dropped | 98% of one core | **smooth** |
| 1080p60 | 894 (~45 fps), 0 dropped | 106% | plays at ≈0.75× real time (rebuffers/stalls) |

Note the stream to the car is `TA_FPS=30` (`ta_display_backend.py`), so the
car never sees more than 30 fps whatever the browser plays.

## Known limits

- **Codecs:** hardware = H.264 only (the Pi 4's `/dev/video19` HEVC decoder is
  not used by Chromium here). VP8/VP9/AV1 are software and are hidden from
  players by the extension; sites that don't offer H.264 (4K YouTube) are
  unavailable or software-decoded.
- **Resolution:** 720p is the sweet spot. 1080p60 is above what the loaded
  system can present in real time. Use the YouTube gear menu → 720p (or
  "Auto" — it starts at 144p and ramps).
- **Load:** decode is cheap, but the Pi is already near saturation from the
  capture/encode pipeline (the V4L2 H.264 *encoder* shares the VideoCore with
  the decoder). Don't expect headroom with several heavy tabs open.
- **Memory:** Chromium is heavy (~0.7 GB on disk;
  ~0.5 GB RSS across browser+GPU+renderer with one video tab). 8 GB Pi: fine.
- **No auto-updates:** unattended upgrades are off in this image; Chromium
  security updates need a manual `sudo apt-get update && sudo apt-get install
  --only-upgrade chromium chromium-common chromium-sandbox`.
- **Pi archive suite:** the build is Debian *trixie*; the `libjpeg62-turbo`
  shim and library sonames are verified against Ubuntu 26.04 (`ldd` clean). A
  future Ubuntu bump of those libs could break the dependency solve — rerun
  `selftest`/`--verify-chromium` after upgrades.
