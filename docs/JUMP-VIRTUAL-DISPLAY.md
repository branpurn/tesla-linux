# JUMP — virtual XFCE display (HDMI slave clone)

Ubuntu Server + XFCE, Raspberry Pi **4 8 GB only**. No Xvfb. No AOSP. kiss stays **PRIVATE**.

## QA bounce (evidence only)

qemu vs `tesla-linux-20260901` on **main before this PR**: Xorg/XFCE came up, then `tesla-linux-desktop` restart loop; WLAN pickers timed out. Do **not** invent a second `/api/wlan`. Fix is dummy virtual `:0` + HDMI slave clone so XFCE/X stay up if HDMI is black; desktop restart must not take down xorg/display.

Physical JUMP **2026.09.02**: HDMI showed getty, not XFCE. Cause: `getty@tty1` owned the console VT while Xorg was on **vt7** (`-novtswitch`). Product path is X on **vt1** (the HDMI VT) and `getty@tty1` masked.

## Product

The Tesla-browser web console is the primary display: **1088x832**. XFCE runs on that virtual screen even if HDMI stays black after the Ubuntu splash.

Appliance **autologin**: user **teslalinux** boots into XFCE on `DISPLAY=:0` via `tesla-linux-desktop.service`. No TTY login prompt on HDMI. Do not invent lightdm/gdm/sddm.

HDMI 1 and HDMI 2 are **slave duplicates** of the same `:0` session (`xrandr --same-as`), not a second Screen or desktop.

Capture stays `ximagesrc` on `DISPLAY=:0` (`ta_display_backend.py` unchanged). Touch map is `TA_WIDTH=1088` / `TA_HEIGHT=832`.

## On the image

| Path | Role |
|---|---|
| `/etc/X11/xorg.conf.d/10-virtual.conf` | `Driver dummy`, Modes/Virtual **1088x832**, depth 24. Dummy is Screen 0 primary so X starts without HDMI. `AutoAddDevices` **true**. |
| `/etc/X11/xorg.conf.d/40-tesla-linux-hid.conf` | InputClass `libinput` for keyboard / pointer / touchpad on `:0`. USB HID does not wait on HDMI clone. |
| `/etc/X11/xorg.conf.d/99-vc4.conf` | HDMI KMS (`modesetting` on vc4). Kept. Not a second Screen. |
| `/etc/udev/rules.d/99-tesla-linux-hid.rules` | `TAG+="seat"` for `ID_INPUT` keyboard / mouse / touchpad so they attach to seat0 / X `:0`. Does not change `99-uinput.rules`. |
| `/usr/local/sbin/tesla-linux-hdmi-clone` | After X is up: `DISPLAY=:0 xrandr --output HDMI-1` / `HDMI-A-1` `--auto --same-as DUMMY0` / `Dummy-0`; same for HDMI-2 / `HDMI-A-2`. Missing HDMI does not fail the unit. |
| `tesla-linux-xorg.service` | `Xorg :0 vt1 -ac -noreset -novtswitch` + `ExecStartPost` clone. `Conflicts=getty@tty1.service`. No `After=` wlan. Missing HDMI does not fail the unit. |
| `getty@tty1.service` | **Masked** (`/dev/null`). Not the HDMI product path. |
| `/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf` | `NAutoVTs=0` `ReserveVT=0` so logind does not keep tty1 for getty. |
| `serial-getty@ttyAMA0` / `ttyS0` / `ttyAMA1` | Infra qemu typed-login path. Kept. |
| `tesla-linux-display.service` | `After=` / `Requires=` **xorg only** (not desktop). Desktop restart must not block or take down capture. |
| `tesla-linux-desktop.service` | Autologin XFCE on `:0` as **teslalinux**. No `BindsTo`/`PartOf` xorg or display. |
| `tesla-linux-wlan.service` | No `After=` xorg. AP must not wait on X. |

Bake/install runs `install-tesla-linux.sh --verify-autologin` (and the same checks after `--no-start`). Missing autologin / getty-still-on-HDMI **fails the script** — no `|| true`.

Factory console / SSH: **teslalinux** / **teslalinux**. `ubuntu` is removed. HDMI product path is that same XFCE `:0` session (BACKEND-HOLE **closed**).

Do not invent Xvfb. `xserver-xorg-video-dummy` is already in `PKGS`. USB HID on `:0` needs `xserver-xorg-input-libinput` in `PKGS` (keep `xinput`). `teslalinux` stays in group `input`.
