# Widevine DRM in Chromium on the Pi 4 (Netflix and friends)

Goal: DRM streaming (Netflix, Prime, Disney+ ...) on the Tesla Linux Pi 4 (8 GB,
Ubuntu 26.04 **arm64** userland, kernel 7.0.0-1009-raspi) in the **same**
Chromium that does V4L2 HW H.264 decode ([`CHROMIUM-HWDEC.md`](CHROMIUM-HWDEC.md)).
There is one launcher, **"Chromium"**, and every way of starting Chromium
(bare `chromium`, `/usr/bin/chromium`, the menu/Desktop icon, panel "Web
Browser", `xdg-open`, `x-www-browser`/`gnome-www-browser`, the `chromium-drm`
compat shim) gets **both** HW decode and Widevine.

## Result in one paragraph

A 32-bit (armhf) Chromium is **not needed**. The premise "Google ships Widevine
for ARM Linux only as 32-bit" is out of date for what Raspberry Pi
redistributes: `archive.raspberrypi.com` (trixie) carries `libwidevinecdm0` for
**both armhf and arm64, same version 4.10.2662.3**. The arm64 CDM loads in the
existing 64-bit Chromium 154: `requestMediaKeySystemAccess('com.widevine.alpha')`
succeeds and an encrypted H.264 DASH stream (license fetched, CDM decrypting)
plays at 480p / 720p / 1080p with a non-black picture. So the shipped solution
is the arm64 CDM wired into every launch of the one Chromium (no separate DRM
launcher or profile any more). DRM video is decoded **in software by the
Widevine L3 CDM**, not by V4L2 — HW decode applies to clear (non-DRM) H.264,
which the same browser still does.

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
- **Flags snippet (the part that matters):** `/etc/chromium.d/tesla-linux-widevine`.
  `/usr/bin/chromium` sources `/etc/chromium.d/*` on every start, so any launch
  path passes through it. Debian's chromium has no bundled-CDM path; Chromium
  finds the CDM through a per-profile hint file
  `<profile>/WidevineCdm/latest-component-updated-widevine-cdm` =
  `{"Path":"/opt/WidevineCdm"}` (needs `manifest.json` +
  `_platform_specific/linux_arm64/libwidevinecdm.so`, both in the package). The
  snippet writes it into the profile about to be used (default
  `~/.config/chromium`, or the `--user-data-dir=` given), **unless that profile
  already has a working hint** — Chromium's component updater downloads newer
  `linux_arm64` Widevine builds into the profile (e.g. 4.10.3057.0) and
  rewrites the hint itself; the snippet never clobbers that. No `--no-sandbox`,
  no `--widevine-path` (the Debian build has no such switch).
- **HW decode:** unchanged, from `/etc/chromium.d/tesla-linux` (X11, V4L2 on by
  default in the Pi build, `--disable-frame-rate-limit`, tl-h264-only extension
  via `/etc/chromium.d/extensions`) and the managed policy. The Widevine
  installer touches none of those and does not change the chromium pin.
- **One launcher:** `/usr/local/share/applications/chromium.desktop`
  (Name=Chromium, `Exec=/usr/bin/chromium %U`; same desktop id as the package's,
  placed in `/usr/local/share` so it wins and survives package upgrades) and
  `~/Desktop/Chromium.desktop`. The former "Chromium (HW video)" and
  "Chromium (DRM)" launchers (and `Chromium-DRM.desktop` /
  `Chromium-HW-video.desktop` icons) are removed by the installers; the gates
  fail if they come back or if the launcher `Exec` is anything but plain
  `/usr/bin/chromium`.
- **`chromium-drm` shim:** `/usr/local/bin/chromium-drm` just `exec`s
  `/usr/bin/chromium` (honouring `TL_DRM_PROFILE` for throwaway test profiles),
  so old scripts keep working. It has no separate profile any more: Netflix/Prime
  logins live in the normal Chromium profile.
- **Probe:** `/usr/share/tesla-linux/chromium-drm/{probe.py,drm.html,clear.html,blank.html}`
  (source: `tl-src/chromium/drm-test/`) — what produced the numbers below:

```
python3 /usr/share/tesla-linux/chromium-drm/probe.py --exe /usr/bin/chromium \
    --profile /tmp/p --components --eme-only                         # EME + chrome://components
python3 .../probe.py --exe /usr/bin/chromium \
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
| `requestMediaKeySystemAccess('com.widevine.alpha')` | **OK** for default and `SW_SECURE_CRYPTO` robustness; **NotSupported** for `SW_SECURE_DECODE` / `HW_SECURE_ALL` (this was the packaged 2662.3 CDM in a throwaway profile; the component-updated 4.10.3057.0 in the real profile also accepts `SW_SECURE_DECODE`, see the Prime section — still Widevine **L3**) |
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
  Chromium; playback limited to **720p** (Widevine L3 — Netflix gives
  1080p only to L1 / certain platforms), H.264 only (the `tl-h264-only`
  extension hides VP9/AV1 from the player anyway), and at that rate the Pi
  can't hold 720p smooth under the car-stream load (see table) — pick the 480p/
  "data saver" cap in Netflix playback settings if it stutters. Netflix could
  also refuse the CDM for being old (the packaged 4.10.2662.3 is from Oct 2023;
  but Chromium's component updater does fetch newer `linux_arm64` CDMs into the
  profile, e.g. 4.10.3057.0, and those win). If Netflix shows error
  `M7701`/`M7121`/"unsupported browser", that is the CDM/UA gate.
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
- `/opt/WidevineCdm` is a 2023 build (4.10.2662.3), but Chromium's component
  updater does fetch newer `linux_arm64` builds into the profile (seen:
  4.10.3057.0, 2026-10-02) and those win; `chrome://components` shows 0.0.0.0
  for the hinted /opt CDM.
- Launching `/usr/lib/chromium/chromium` directly (bypassing `/usr/bin/chromium`)
  skips `/etc/chromium.d` — that is not a supported path. `chromium --temp-profile`
  also gets no Widevine hint (its profile is created after the snippet runs).
- **Never SIGKILL a Chromium that is decoding.** On 2026-10-02 killing several
  test Chromium instances mid-V4L2-decode triggered a kernel warning in
  `bcm2835_codec_release` ("stop_streaming … leaving buffer active"), after
  which `bcm2835_mmal_vchiq` timed out, further `gpu-process`es hung in
  uninterruptible sleep (`vc5_dumb_create`) and the load average went to 30+
  until reboot. Close test browsers gracefully (window close / CDP
  `Browser.close`) and let them exit before starting the next.
- No auto-updates (unattended upgrades are off): `sudo apt-get update && sudo
  apt-get install --only-upgrade libwidevinecdm0`.

## Amazon Prime Video on this Pi, incl. error 7031 (tested 2026-10-02)

**Summary: Prime plays** in the logged-in default profile
(`~teslalinux/.config/chromium`, normal `chromium` launch, `DISPLAY=:0`), in SD
only. Error **7031** (`amazon.com/dv/error/7031`, "Video Unavailable") appeared
**once**, on the first Play after a fresh Chromium launch, and did **not**
recur on retries (second Play, fresh navigation, full graceful close +
relaunch all played). Title tested: *Now You See Me: Now You Don't*
(`/gp/video/detail/B0FZLW2HCF`, ad-supported, Prime-included).

Measured while playing:

| Item | Result |
| --- | --- |
| Resolution | DRM stream 710x296 -> **960x400** (SD-class); the HD key comes back `output-restricted` (key statuses `usable, usable, output-restricted`) — Widevine **L3**, no HD |
| Decoder, ad preroll (clear) | `V4L2VideoDecoder` (hardware, `/dev/video10`) |
| Decoder, movie (DRM) | `DecryptingVideoDecoder` (CDM decrypts and decodes in software), `kIsPlatformVideoDecoder=false`; audio `FFmpegAudioDecoder` |
| CPU | about 166-197 % of one core |
| Dropped frames | about 7-9 % (195/2890 over 132 s; 141/1542 in a later run) |
| CDM actually in use | component-updated **4.10.3057.0** from `~/.config/chromium/WidevineCdm/` (downloaded 2026-10-02 13:40 UTC), **not** `/opt` 2662.3; it accepts `SW_SECURE_DECODE` (2662.3 did not) |
| Robustness negotiation | `HW_SECURE_ALL` / `HW_SECURE_CRYPTO` -> NotSupported; Amazon falls back to **`SW_SECURE_DECODE`** video + `SW_SECURE_CRYPTO` audio, which is granted |
| License path (playing runs) | `StartSession`, `GetWidevineLicense` and `UpdateSession` all HTTP 200 |

### The one 7031

- It happened ~46 s after clicking Play. `GetVodPlaybackResources` returned
  200 and the clear ad preroll played, but the DRM video element (mediaKeys
  attached) **never made a license request** (no `GetWidevineLicense` call at
  all): it failed **before the license step**, so it is not a license-server
  rejection and not a missing/old CDM.
- Many Amazon telemetry POSTs (atv-ps Clickstream/reportEvent,
  `unagi.amazon.com` events) fail with `net::ERR_BLOCKED_BY_CLIENT`. The
  profile has an ad-blocker extension (id `ddkjiahejlhfcafbddmgiahcphecmpfh`,
  believed to be uBlock Origin Lite) besides `tl-h264-only`. Web reports tie
  blocked Amazon telemetry to 7031, but playback worked later **with the
  blocker still active**, so this is a suspect, **not proven** to be the cause.
- Most likely: a transient first-session player/DRM initialisation failure.

### Other things checked (not the cause)

- **User agent:** `Mozilla/5.0 (X11; Linux x86_64) ... Chrome/154.0.0.0`
  (aarch64 is not exposed); no UA spoof needed.
- **Clock:** NTP synchronized (chrony), UTC.
- **Network:** T-Mobile US mobile egress (IPv6), no VPN/proxy; amazon.com
  storefront returns 200 with no robot check.

### Options

1. **Retry** after a 7031 (worked every time after the first).
2. If 7031 keeps showing up on first Play: allowlist `amazon.com`, `atv-ps`
   and `unagi` in the ad-blocker (or disable it for Prime) and see whether it
   stops. This changes the user's profile, so **only with the user's OK**.
3. HD is not available (L3). Google Chrome arm64 (removed; see below) is
   still L3 with the same decoder/DRM cost, so it would not help.
4. Do not sign out, clear amazon.com cookies, or kill a decoding Chromium to
   "fix" it (see the SIGKILL warning above).

## Why not Google Chrome (arm64)? — measured Oct 2026, then removed

Google Chrome 154 arm64 (Google apt repo) was installed and compared on the Pi 4,
then removed; Chromium is the single browser. Findings:

- **Widevine:** Chrome bundles **4.10.3112.0** vs **4.10.2662.3** from the Pi
  archive. Both are L3 only (`SW_SECURE_CRYPTO` ok; `SW_SECURE_DECODE` /
  `HW_SECURE_ALL` unsupported). The newer CDM is not cheaper to run.
- **No V4L2 video decoder in Chrome arm64:** clear 720p30 H.264 uses
  `FFmpegVideoDecoder` (no `/dev/video10`), ≈141–147% CPU and 36% dropped frames
  vs Chromium V4L2 ≈52% CPU and 15% dropped; `AcceleratedVideoDecodeLinux*`
  flags do nothing (the decoder code is not compiled in).
- **DRM (Axinom/Shaka, software CDM decode in both):** Chrome 480p 149%/25%
  dropped, 720p 189%/36%, 1080p 226%/36%; Chromium(DRM) 480p 182%/4%,
  720p 201–217%/18–26%, 1080p 240%/43%.
- Branded Chrome ≥137 ignores `--load-extension`, so keeping YouTube on H.264
  would need a signed CRX force-installed by policy; without it YouTube serves
  Chrome AV1 (dav1d, software).
- Disk: ≈0.5 GB for Chrome.

If a service ever rejects the 2023 CDM, revisit; until then Chromium is enough.
