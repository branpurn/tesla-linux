# JUMP — virtual XFCE display (HDMI slave clone)

Ubuntu Server + XFCE, Raspberry Pi **4 8 GB only**. No Xvfb. No AOSP. kiss stays **PRIVATE**.

## QA bounce (evidence only)

qemu vs `tesla-linux-20260901` on **main before this PR**: Xorg/XFCE came up, then `tesla-linux-desktop` restart loop; WLAN pickers timed out. Do **not** invent a second `/api/wlan`. Fix is dummy virtual `:0` + HDMI slave clone so XFCE/X stay up if HDMI is black; desktop restart must not take down xorg/display.

## Product

The Tesla-browser web console is the primary display: **1088x832**. XFCE runs on that virtual screen even if HDMI stays black after the Ubuntu splash.

HDMI 1 and HDMI 2 are **slave duplicates** of the same `:0` session (`xrandr --same-as`), not a second Screen or desktop.

Capture stays `ximagesrc` on `DISPLAY=:0` (`ta_display_backend.py` unchanged). Touch map is `TA_WIDTH=1088` / `TA_HEIGHT=832`.

## On the image

| Path | Role |
|---|---|
| `/etc/X11/xorg.conf.d/10-virtual.conf` | `Driver dummy`, Modes/Virtual **1088x832**, depth 24. Dummy is Screen 0 primary so X starts without HDMI. |
| `/etc/X11/xorg.conf.d/99-vc4.conf` | HDMI KMS (`modesetting` on vc4). Kept. Not a second Screen. |
| `/usr/local/sbin/tesla-linux-hdmi-clone` | After X is up: `DISPLAY=:0 xrandr --output HDMI-1` / `HDMI-A-1` `--auto --same-as DUMMY0` / `Dummy-0`; same for HDMI-2 / `HDMI-A-2`. Missing HDMI does not fail the unit. |
| `tesla-linux-xorg.service` | X on `:0` + `ExecStartPost` clone. No `After=` wlan. Missing HDMI does not fail the unit. |
| `tesla-linux-display.service` | `After=` / `Requires=` **xorg only** (not desktop). Desktop restart must not block or take down capture. |
| `tesla-linux-desktop.service` | XFCE on `:0`. No `BindsTo`/`PartOf` xorg or display. |
| `tesla-linux-wlan.service` | No `After=` xorg. AP must not wait on X. |

Do not invent Xvfb. `xserver-xorg-video-dummy` is already in `PKGS`.
