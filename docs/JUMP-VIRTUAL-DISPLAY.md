# Unified HDMI + web XFCE display

Ubuntu Server + XFCE, Raspberry Pi **4 8 GB only**. No Xvfb, dummy screen, HDMI clone, display manager, or tmux MOTD.

## Product

There is one desktop: XFCE on `DISPLAY=:0`, hard-coded to **1088x832**.

- KMS forces HDMI0 with `video=HDMI-A-1:1088x832M@60D`.
- `MatchDriver "vc4"` selects the Pi DRM device as Xorg’s primary GPU, regardless of whether it enumerates as `card0` or `card1`.
- vc4/modesetting renders Xorg `:0` to HDMI0 (`HDMI-1` in Xrandr).
- `ta_display_backend.py` captures that same `DISPLAY=:0` for `desktop.html`.
- USB keyboards, mice, and touchpads use normal seat0/libinput discovery on that X server.
- Browser touch is injected into the same session by `ta_touch_backend.py`.

The directly connected display and the Tesla browser therefore show and control the same desktop.

## Why the old split was removed

The dummy Xorg screen gave the stream a framebuffer that HDMI could not display. The later TTY/tmux work did not change that: HDMI remained a separate console, and `-novtswitch` could leave that console active instead of Xorg.

The unified path removes:

- `xserver-xorg-video-dummy`
- `tesla-linux-hdmi-clone`
- `tesla-linux-hdmi-banner` and its systemd service
- the tmux MOTD/profile hook
- `-novtswitch` and explicit `-seat seat0`
- the custom `60-tesla-linux-kbm-seat0.rules`
- the libinput `GrabDevice` experiment

## On the image

| Path | Role |
|---|---|
| `/boot/firmware/current/cmdline.txt` | Ubuntu 26.04 boot cmdline; forces KMS HDMI0 (`HDMI-A-1`) to **1088x832** |
| `/etc/X11/xorg.conf.d/10-tesla-linux-display.conf` | Selects vc4 as the primary `modesetting` GPU; HDMI-1 preferred mode **1088x832** |
| `/etc/X11/xorg.conf.d/20-tesla-linux-input.conf` | Keyboard, pointer, and touchpad through `libinput` |
| `tesla-linux-xorg.service` | `Xorg :0 vt1 -keeptty`; owns `/dev/tty1` and switches to the graphical VT |
| `getty@tty1.service` | Masked so it cannot replace XFCE on HDMI |
| `tesla-linux-desktop.service` | Autologin XFCE on `:0` as **teslalinux** |
| `tesla-linux-display.service` | Captures `:0` for the web console |
| `tesla-linux-touch.service` | Maps browser input into the same 1088x832 session |

`TA_WIDTH=1088` and `TA_HEIGHT=832` remain the touch/canvas geometry.

Factory console/SSH credentials remain **teslalinux** / **teslalinux**. Serial gettys remain available for QEMU and recovery; HDMI is the XFCE desktop.
