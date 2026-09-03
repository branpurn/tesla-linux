# JUMP — virtual XFCE display (USB KBM on :0)

Ubuntu Server + XFCE, Raspberry Pi **4 8 GB only**. No Xvfb. No AOSP. kiss stays **PRIVATE**. HDMI XFCE is DESCPE this round.

## QA bounce (evidence only)

qemu vs `tesla-linux-20260901` on **main before this PR**: Xorg/XFCE came up, then `tesla-linux-desktop` restart loop; WLAN pickers timed out. Do **not** invent a second `/api/wlan`. Fix is dummy virtual `:0` + HDMI slave clone so XFCE/X stay up if HDMI is black; desktop restart must not take down xorg/display.

Physical JUMP **2026.09.02**: HDMI showed getty, not XFCE. Cause: `getty@tty1` owned the console VT while Xorg was on **vt7** (`-novtswitch`). That round moved X onto **vt1** and masked getty.

**This round (tmux MOTD + KBM):** product display is the Tesla-browser virtual `:0` session. USB keyboard/mouse must drive that XFCE. Writing the manage-from-SSH sentence to the HDMI TTY kept the kernel console foreground and stole HID — MOTD is **tmux** (SSH pane), not tty1. `getty@tty1` stays masked. Do not `Conflicts=getty@tty1`. HDMI clone is not assigned here.

## Product

The Tesla-browser web console is the primary display: **1088x832**. XFCE autologin (**teslalinux**) runs on that virtual screen (`DISPLAY=:0`).

A USB keyboard and mouse plugged into the Pi drive **that same** `:0` session — not a different VT, seat, or getty. Xorg runs on **vt1** (foreground console) and opens `/dev/input/event*` via **libinput** with **GrabDevice**. Do not write the SSH sentence to the HDMI TTY (that stole HID). Do not use the Xorg `kbd` driver (that binds to the active console VT).

HDMI is not a login. The manage-from-SSH sentence is a **tmux MOTD** (separate pane + `/etc/update-motd.d`). Do not invent lightdm/gdm/sddm. Do not invent Xvfb.

Capture stays `ximagesrc` on `DISPLAY=:0` (`ta_display_backend.py` unchanged). Touch map is `TA_WIDTH=1088` / `TA_HEIGHT=832`. `python3-evdev` is the uinput touch backend, not Xorg HID.

## On the image

| Path | Role |
|---|---|
| `/etc/X11/xorg.conf.d/10-virtual.conf` | `Driver dummy`, Modes/Virtual **1088x832**, depth 24. Dummy is Screen 0 primary so X starts without HDMI. `AutoAddDevices` / `AutoEnableDevices` so USB HID attaches to this server. |
| `/etc/X11/xorg.conf.d/20-tesla-linux-input.conf` | `Driver libinput` + `Option GrabDevice true` for keyboard / pointer / touchpad. |
| `/etc/udev/rules.d/60-tesla-linux-kbm-seat0.rules` | Tag USB HID `ID_SEAT=seat0` so Xorg `-seat seat0` gets the devices. Required for this Xorg path — not a second install stack. |
| `/etc/X11/xorg.conf.d/99-vc4.conf` | HDMI KMS (`modesetting` on vc4). Kept. Not a second Screen. Not changed this PR. |
| `tesla-linux-hdmi-clone` | **Not installed, not run.** HDMI XFCE is DESCPE. Xorg has no `ExecStartPost` clone. File may remain in the tree only. |
| `tesla-linux-xorg.service` | `Xorg :0 vt1 -seat seat0 -ac -noreset -novtswitch`. **No** `Conflicts=getty@tty1`. **No** `ExecStartPost` clone. No `After=` wlan. |
| `getty@tty1.service` | **Masked**. HDMI is not a login. |
| `/usr/local/sbin/tesla-linux-hdmi-banner` | tmux session `tl` (`/run/tesla-linux/tmux.sock`): MOTD pane + shell pane. Sentence: live WLAN IPv4 (station, or `10.42.0.1` in AP mode) or ethernet `10.42.1.1` as **teslalinux**. SSH `profile.d` attaches. |
| `/etc/systemd/logind.conf.d/tesla-linux-hdmi.conf` | `NAutoVTs=0` `ReserveVT=0` — do not reserve tty1 for a text overlay that would fight X on vt1. |
| `serial-getty@ttyAMA0` / `ttyS0` / `ttyAMA1` | Infra qemu typed-login path. Kept. |
| `tesla-linux-display.service` | `After=` / `Requires=` **xorg only** (not desktop). Desktop restart must not block or take down capture. |
| `tesla-linux-desktop.service` | Autologin XFCE on `:0` as **teslalinux**. No `BindsTo`/`PartOf` xorg or display. |
| `tesla-linux-wlan.service` | No `After=` xorg. AP must not wait on X. |

`PKGS` includes `xserver-xorg-input-libinput` (was missing — dummy `:0` had no HID driver).

Bake/install runs `install-tesla-linux.sh --verify-autologin` (and `--verify-kbm`). Missing autologin / KBM-on-:0 / X-still-on-vt1 **fails the script** — no `|| true`.

Factory console / SSH: **teslalinux** / **teslalinux**. `ubuntu` is removed.

Do not invent Xvfb. `xserver-xorg-video-dummy` stays in `PKGS`.
