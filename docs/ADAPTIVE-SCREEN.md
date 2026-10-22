# Fit: Adaptive (desktop.html)

The Fit button cycles **Fixed → Stretch → Adaptive** (persisted in `localStorage['tl.desktop.fit']`).

* **Fixed / Stretch** — X screen stays 1088x832; CSS letterbox or stretch.
* **Adaptive** — the page asks the Pi to resize the real X screen to the viewport in device
  pixels (`innerWidth/innerHeight × devicePixelRatio`, rounded to multiples of 8, clamped
  640x480..1920x1080). The stream is then 1:1 — no bars, no scaling. Resize / orientation /
  fullscreen changes are debounced 500 ms. Leaving Adaptive posts `{reset:true}` → 1088x832.

## Server side
* `POST /api/screen {w,h}` / `{reset:true}`, `GET /api/screen` → nginx (inherits the boot-PIN
  `auth_request`) → `ta_screen_api.py` on `127.0.0.1:9096` (`tesla-linux-screen-api.service`, root).
* Applies the two-step method on `:0` as `teslalinux`:
  `xrandr --fb 1920x1080 --output HDMI-1 --mode 1920x1080 --scale 1x1` then
  `xrandr --fb WxH --output HDMI-1 --mode 1920x1080 --scale-from WxH --primary`.
* Target persisted in `/run/tesla-linux/screen-size` (tmpfs → every boot starts at 1088x832).
  `tl-screen-guard` enforces that target (default 1088x832) and still fixes drift; both share
  `/run/tesla-linux/screen.lock` (flock) so they never interleave.
* `ta_display_backend.py` reads the state file at start; the API restarts
  `tesla-linux-display` after a change. desktop.html reconnects the video socket, rebuilds the
  WebCodecs decoder from the new SPS, and touch stays normalised to the canvas rect.
* Rate limit: one applied change per 3 s (`429` + `Retry-After`; the page retries).

Selftests: `tl-src/selftest-desktop-fit.sh` (runs `selftest-screen-api.sh`, dry-run API).
