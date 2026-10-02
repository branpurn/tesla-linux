# Xubuntu desktop on the Pi

The appliance desktop is **Xubuntu**: the full `xubuntu-desktop` metapackage
(Ubuntu 26.04 arm64) installed with its recommends, with the session still
started by `tesla-linux-desktop.service` (`dbus-launch xfce4-session` on Xorg
`:0`, autologin `teslalinux`). **Chromium stays the only browser** and the
default (`x-www-browser`, `xdg-settings`, `~/.config/xfce4/helpers.rc`).

## What you get

Greybird GTK theme, elementary-xfce icons, xubuntu-default-settings/artwork,
xubuntu-wallpapers (`/usr/share/xfce4/backdrops/xubuntu-wallpaper.png`
stays the locked default), Whisker menu on the top panel, Thunar (+ volman,
media tags), xfce4 goodies (screenshooter, taskmanager, clipman, notifyd ...),
mousepad, parole, gucharmap, catfish, nm-applet. Kept from the appliance setup:
DPI 130, panel 34 px, cursor size 32, natural scrolling (Xorg conf), single
Chromium launcher, screen 1088x832 (screen guard).

## What is deliberately NOT installed — `apt` pin

`/etc/apt/preferences.d/tesla-linux-xubuntu-exclude.pref` (priority -1, source:
`install-tesla-linux.sh --print-apt-pins`) keeps the metapackage's recommends
that Brandon does not want out of the system:

| Pinned out | Why |
| --- | --- |
| `firefox*`, `thunderbird*` | Ubuntu's debs are snap launchers: they download snaps; Chromium is the only browser |
| `libreoffice*`, `gimp*`, `rhythmbox*`, `hexchat*` | heavy apps, not needed |
| `gdm3`, `gnome-shell`, `mutter*` | a second display manager / compositor |
| `cloud-init*` | boot hangs, recreates the `ubuntu` user |
| `cups*`, `cups-browsed`, `hplip*`, `system-config-printer*`, `sane-utils`, `simple-scan`, `bluez-cups` | print/scan daemons |
| `openvpn`, `network-manager-openvpn*`, `network-manager-pptp*`, `pptp-linux` | VPN plugins |
| `speech-dispatcher*`, `espeak*`, `brltty*` | speech/braille daemons |
| `whoopsie*`, `apport-gtk`, `update-notifier`, `ubuntu-advantage-desktop-daemon` | telemetry / update nags |
| `xserver-xorg-legacy`, `xserver-xorg-video-*` | would swap the Xorg wrapper / auto-load other GPU drivers; Xorg is pinned to vc4 modesetting |

`xubuntu-desktop` hard-depends on `printer-driver-*`, `update-manager`,
`lightdm`, `alsa-utils`, ... so those cannot be pinned out (the install would
fail); they are handled below. Measured (Pi 4, 2026-10-02): the unpinned
metapackage is 817 packages / ~2.4 GB installed; with the pin 461 packages /
~1.2 GB installed, 340 MB download, about 1.4 GB more on `/` in total.

## Services / autostarts disabled after install

- **`lightdm.service` is masked** and `display-manager.service` removed
  (xubuntu-desktop depends on lightdm; a DM would fight `tesla-linux-xorg` for
  `:0`). The image build also runs the install under `policy-rc.d` so nothing
  starts during the bake. Do **not** unmask it.
- Masked: `bluetooth`, `blueman-mechanism`, `anacron` (+timer), `lpd`,
  `lm-sensors`, `plocate-updatedb.timer` (indexer).
- Autostarts hidden per user (`~/.config/autostart/*.desktop`, `Hidden=true`,
  also in `/etc/skel`): blueman, indicator-messages, ayatana-indicator-application,
  onboard, spice-vdagent, GNOME disk-utility notify, polkit-mate agent, im-launch,
  gnome-keyring-pkcs11, clipman, snap-userd. xfce4-power-manager,
  xfce4-screensaver and light-locker stay Hidden system-wide (never sleep/lock).
- Session defaults: drop-in
  `/etc/systemd/system/tesla-linux-desktop.service.d/xubuntu-defaults.conf`
  sets `XDG_CONFIG_DIRS=/etc/xdg/xdg-xubuntu:/etc/xdg` (what the stock Xubuntu
  session script does) so xubuntu-default-settings (Thunar actions, menus,
  panel templates) apply to our directly-started `xfce4-session`.

Measured on the live Pi (idle, car stream running, no browser open): used RAM
1081 -> ~1467 MB (+~390 MB, all XFCE/Xubuntu session processes: 517 -> 901 MB
RSS), CPU idle ~68% -> ~69% (unchanged; the capture stream dominates).

## Installer / image

- `install-tesla-linux.sh`: `PKGS` contains `xubuntu-desktop`;
  `ensure_xubuntu_de` writes the pin, masks the services above, writes the
  drop-in, hides the autostarts and seeds `/etc/skel` xsettings (Greybird,
  elementary-xfce-dark, DPI 130, cursor 32); `--print-apt-pins`,
  `--verify-xubuntu [root]`.
- `build-image.sh`: writes the pin **before** apt, installs the base packages
  with `--no-install-recommends`, then `xubuntu-desktop` WITH recommends (under
  `policy-rc.d`), then runs `--verify-xubuntu` in the chroot and on the mounted
  image.
- `selftest-xubuntu-desktop.sh` (55 checks) + `selftest-xfce-wallpaper.sh`.

## Caveats

- **Restarting `tesla-linux-desktop` leaves the old session's processes
  running** (panel, xfdesktop, ... live in the PAM `session-N.scope`, not the
  unit cgroup), which gives duplicate panels / "notification area lost
  selection". After a restart, TERM the leftovers of the previous
  `session-N.scope` (never a decoding Chromium) or stop the unit first, TERM the
  old scope, then start it.
- Installing the metapackage regenerates the initramfs (plymouth theme) and the
  `/boot/firmware/new/` tryboot staging dir; `/boot/firmware/current/` (what
  boots) is untouched.
- `apt upgrade` will not pull the pinned-out packages back; do not delete the
  pin file.
