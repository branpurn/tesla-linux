# Chromium (DRM): Widevine on the Pi 4 (Netflix and friends)

Goal: DRM streaming (Netflix, Prime, Disney+ ...) on the Tesla Linux Pi 4 (8 GB,
Ubuntu 26.04 **arm64** userland, kernel 7.0.0-1009-raspi) **without** disturbing
the HW-decode Chromium from [`CHROMIUM-HWDEC.md`](CHROMIUM-HWDEC.md).

## Result in one paragraph

A 32-bit (armhf) Chromium is **not needed**. The premise "Google ships Widevine
for ARM Linux only as 32-bit" is out of date for what Raspberry Pi
redistributes: `archive.raspberrypi.com` (trixie) carries `libwidevinecdm0` for
**both armhf and arm64, same version 4.10.2662.3**. The arm64 CDM loads in the
existing 64-bit Chromium 154: `requestMediaKeySystemAccess('com.widevine.alpha')`
succeeds and an encrypted H.264 DASH stream (license fetched, CDM decrypting)
plays at 480p / 720p / 1080p with a non-black picture. So the shipped solution
is a second launcher, **"Chromium (DRM)"**, on the same browser binary with its
own profile and the arm64 CDM. DRM video is decoded **in software by the
Widevine L3 CDM**, not by V4L2 — HW decode only applies to clear (non-DRM)
H.264, which that launcher still does.

## What is installed

`tl-src/install-chromium-widevine.sh` (run by `install-tesla-linux.sh` and so by
the image bake; `TL_SKIP_CHROMIUM_WIDEVINE=1` — or `TL_SKIP_CHROMIUM=1`, which
removes the browser it wraps — skips it). On a live Pi:

```
sudo ./tl-src/install-chromium-widevine.sh        # idempotent
sudo ./tl-src/install-tesla-linux.sh --verify-chromium-widevine
./tl-src/selftest-chromium-widevine.sh             # plant gates (+ live EME probe on a Pi with DISPLAY)
```

- **CDM:** `libwidevinecdm0` (arm64, 7.5 MB deb, 10.4 MB installed) from the Pi
  archive into `/opt/WidevineCdm`. Own pin file
  `/etc/apt/preferences.d/raspberrypi-widevine` lets exactly that one package
  through (the Pi archive is otherwise at -10 from `raspberrypi-chromium`, so
  kernels/firefox/firmware still can't come in; verified with `apt-cache
  policy` and by the install pulling no other package).
- **Wrapper:** `/usr/local/bin/chromium-drm` → `exec /usr/bin/chromium
  --user-data-dir=~/.config/chromium-drm "$@"`. Debian's chromium has no
  bundled-CDM path; Chromium finds the CDM through a per-profile hint file
  `<profile>/WidevineCdm/latest-component-updated-widevine-cdm` =
  `{"Path":"/opt/WidevineCdm"}` (needs `manifest.json` +
  `_platform_specific/linux_arm64/libwidevinecdm.so`, both in the package). The
  wrapper (re)writes that file on each launch. No `--no-sandbox`, no
  `--widevine-path` (the Debian build has no such switch).
- **Flags:** because it execs `/usr/bin/chromium`, every flag in
  `/etc/chromium.d/*` (X11, `--disable-frame-rate-limit`, h264-only extension,
  whatever the black-video fix changes) applies unchanged. The installer writes
  **none** of `/etc/chromium.d/*`, the managed policy, or the chromium pin.
- **Launcher:** XFCE menu → Internet → **Chromium (DRM)**
  (`/usr/share/applications/tesla-linux-chromium-drm.desktop`) and
  `~/Desktop/Chromium-DRM.desktop`. Command line: `chromium-drm`. Separate
  profile means a separate Netflix login/cookies from the HW-video Chromium.
- **Probe:** `/usr/share/tesla-linux/chromium-drm/{probe.py,drm.html,clear.html,blank.html}`
  (source: `tl-src/chromium/drm-test/`) — what produced the numbers below:

```
python3 /usr/share/tesla-linux/chromium-drm/probe.py --exe /usr/local/bin/chromium-drm \
    --own-profile --profile /tmp/p --components --eme-only          # EME + chrome://components
TL_DRM_PROFILE=/tmp/p python3 .../probe.py --exe /usr/local/bin/chromium-drm --own-profile \
    --profile /tmp/p --page '{HTTP}/drm.html#h=720' --seconds 40     # DRM playback
TL_PROBE_SHOT=/tmp/shot.png ...                                     # + X screenshot (gst ximagesrc)
```

Disk: **2.8 GB free before and after** (`df /`); the whole feature is ~10 MB for
the CDM plus ~70 KB of scripts.

## Evidence (Pi 4, 2026-10-02, Chromium 154.0.8037.57, loaded system)

Everything below ran while the real car stream pipeline (display backend +
encoder + Xorg) and the user's own browsers were running (load average 5–8), so
absolute CPU/dropped numbers are pessimistic.

| Check | Result |
| --- | --- |
| `chrome://components` | "Widevine Content Decryption Module" listed; version shows `0.0.0.0` because a hinted CDM isn't a component-updater install — real CDM version is **4.10.2662.3** (`/opt/WidevineCdm/manifest.json`, host/interface version 10) |
| `requestMediaKeySystemAccess('com.widevine.alpha')` | **OK** for default and `SW_SECURE_CRYPTO` robustness; **NotSupported** for `SW_SECURE_DECODE` / `HW_SECURE_ALL` (= Widevine **L3 only**) |
| License + playback | Shaka Player 4.11 → public Axinom multi-DRM test vector (`TestVectors/v7-MultiDRM-SingleKey/Manifest_1080p.mpd`, H.264, 24 fps, license from `drm-widevine-licensing.axtest.net`): `keySystem=com.widevine.alpha`, `video.mediaKeys` set, time advances |
| Decoder for DRM video | `kVideoDecoderName = DecryptingVideoDecoder` (CDM decrypts **and decodes**, software), `kIsPlatformVideoDecoder=false`; `/dev/video10` **not** opened by any process |
| Decoder for clear H.264 in the same launcher | `V4L2VideoDecoder`, `kIsPlatformVideoDecoder=true`, `/dev/video10` held by the `--type=gpu-process` (720p30 clip: 51% of one core, 1280×720) |
| Not black | X screen grab (`gst-launch ximagesrc ! pngenc`) of each run: video area mean luma 113–129, <2% pixels < 16, 13k+ distinct colours; a burned-in frame counter in the test vector is legible in the screenshot |

DRM playback, Axinom H.264, 40 s windows, `--disable-frame-rate-limit` flags as
shipped:

| Rung | Frames / media time | Dropped | Browser CPU (sum, % of 1 core; 400 = all cores) | Verdict |
| --- | --- | --- | --- | --- |
| 480p (853×480) | 888 / 36.8 s (real time) | 37 (4%) | 182% | OK |
| 720p (1280×720) | 870 / 36.0 s | 224 (26%) | 201% | watchable, visibly drops under car-stream load |
| 1080p (1920×1080) | 765 / 31.6 s | 327 (43%) | 240% | not usable |

Earlier run with the cold-hinted 64-bit browser: 720p 593 frames / 25 s, 153
dropped, 206%. So: **480p is smooth, 720p marginal, 1080p unusable** while the
car stream runs; the V4L2 decoder cannot help because Widevine L3 decrypts and
decodes inside the CDM. (Netflix serves L3 clients at most 720p anyway.)

## Netflix: what is and isn't proven

- Proven: the same Widevine L3 key system Netflix uses is available and
  decrypts/plays H.264 DASH/CENC; EME robustness the CDM offers is the L3 set.
- **Not tested:** Netflix itself (needs an account). Expect: sign-in works in
  "Chromium (DRM)"; playback limited to **720p** (Widevine L3 — Netflix gives
  1080p only to L1 / certain platforms), H.264 only (the `tl-h264-only`
  extension hides VP9/AV1 from the player anyway), and at that rate the Pi
  can't hold 720p smooth under the car-stream load (see table) — pick the 480p/
  "data saver" cap in Netflix playback settings if it stutters. Netflix could
  also refuse the CDM for being old (4.10.2662.3 is from Oct 2023; Chrome on
  x86 gets newer CDMs from Google's component updater, which has no ARM-Linux
  build). If Netflix shows error `M7701`/`M7121`/"unsupported browser", that is
  the CDM/UA gate; there is no Pi-archive newer CDM to try.
- Other services that need L1 (Disney+/Prime in HD, Hulu) will fall back to SD
  or refuse.

## Why no 32-bit Chromium (what was checked)

- **armhf userland runs here:** `CONFIG_COMPAT=y`; the Ubuntu armhf `ld.so`
  (`libc6:armhf` 2.43, extracted, not installed) executes on this arm64 kernel
  (printed its version) — AArch32 EL0 works on the Cortex-A72.
- **Pi archive has everything for armhf:** `chromium`/`chromium-common`
  154.0.8037.92 armhf (109 MB deb, 210 MB installed, plus the whole armhf
  GTK3/Mesa/X/Pulse library closure from Ubuntu ports, which is a separate
  multiarch install not attempted) and `libwidevinecdm0` armhf **4.10.2662.3** —
  a different architecture build of the *same* CDM release as the arm64 one.
- **No gain:** same CDM version/capabilities (L3), same software decode in the
  CDM, and the same Pi V4L2 path would apply to clear video. A 32-bit browser
  is limited to a 3–4 GB address space and costs an estimated ~0.7–1 GB of the
  ~2.8 GB free plus a second apt architecture on a live system (`dpkg
  --add-architecture armhf`, Ubuntu *ports* sources restricted by `arch=`).
  I therefore did not install it. If a future CDM turns out to be armhf-only,
  this is the route: add armhf (`Architectures: arm64 armhf`, armhf from
  `ports.ubuntu.com/ubuntu-ports`, keep the Pi pin), install
  `chromium:armhf chromium-common:armhf libwidevinecdm0:armhf`, point a second
  wrapper at the armhf `/usr/lib/chromium/chromium` and `linux_arm`.

## Widevine licensing / redistribution

Widevine CDM is proprietary software owned by Google; it is **not** open source
and is not part of Chromium. This repo ships no CDM binary — the installer
fetches Raspberry Pi's redistributed `libwidevinecdm0` package from their apt
archive on the user's device, under the Widevine terms accompanying that
package (<https://www.widevine.com/>). Don't commit the `.so` or bake it into
public image artifacts without checking that those terms allow redistribution;
the image bake runs the installer in the chroot, i.e. fetches it at build time.
Using DRM streaming services on a Tesla Linux box is also subject to each
service's own terms. L3 is software DRM: the services cap its quality.

## Known limits

- L3 only; ≤720p for Netflix-class services; DRM video costs ~2 cores at 720p
  (CDM software decode) and drops frames while the car stream runs.
- No HW decode for DRM video; clear H.264 still gets V4L2.
- CDM is a 2023 build, no updater for ARM Linux; `chrome://components` shows
  version 0.0.0.0 for it.
- The hint file lives in the profile, so the **stock** "Chromium (HW video)"
  profile has no Widevine on purpose (untouched). To give another profile DRM,
  use `chromium-drm` or write the hint file there.
- No auto-updates (unattended upgrades are off): `sudo apt-get update && sudo
  apt-get install --only-upgrade libwidevinecdm0`.
