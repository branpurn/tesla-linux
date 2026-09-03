# Tesla Linux

Tool for baking a flashable Ubuntu Server 26.04 + XFCE image for Raspberry Pi 4 (8 GB only). 

Product path is the Tesla-browser web console (`desktop.html`), not HDMI XFCE.

## Components:

| File | Description |
| ------------------------- | ---------------------------------------------------------------------------- |
| `tl-src/build-image.sh` | Bakes Ubuntu Server arm64 raspi into `tesla-linux-YYYYMMDD-pi.img.xz` |
| `tl-src/install-tesla-linux.sh` | Installs the XFCE / Xorg / stream / WLAN stack inside the image chroot |
| `tl-src/desktop.html` | Tesla-browser console (in-car product path) |
| `tl-src/index.html` | Wi-Fi picker: join the same network as the car |
| `tl-src/probe.html` | Tesla-browser capability probe |
| `tl-src/tesla-linux-wlan.sh` | Station autoconnect, else hostapd AP; ethernet static |
| `tl-src/ta_*.py` | Display / touch / audio backends (loopback, nginx-proxied) |
| `docs/` | Virtual display, WLAN, and qemu notes |
| `README.md` | The document you are currently reading |

## Prerequisites:

- A Linux host to generate the image (`qemu-user-static`, `binfmt-support`, `parted`, `e2fsprogs`, `xz-utils`, `curl`)
- Internet connection capable of downloading the Ubuntu Server arm64 raspi image
- Raspberry Pi **4 (8 GB)** to boot the result
- An SD card **or** USB stick/SSD (same image either way)

## Usage:

- From the repo root, bake:

```
sudo ./tl-src/build-image.sh
```

- Flash `tesla-linux-YYYYMMDD-pi.img.xz` with Raspberry Pi Imager → **Use custom** onto an SD card or a USB stick
- Optional pre-seed on the FAT boot partition (`/boot/firmware/tesla-linux.conf`):

```
WIFI_SSID=YourTeslaWLAN
WIFI_PSK=yourpsk
```

- Boot the Pi 4 (8 GB)
- Factory user **teslalinux** / **teslalinux**
- Connect:
  - Preferred: Pi is a station on a saved Tesla (or other) WLAN
  - Fallback: hostapd AP SSID **TeslaLinux**, WPA2-PSK **teslalinux**, gateway **10.42.0.1**
  - Ethernet: Pi is static **10.42.1.1/24** (peer may need **10.42.1.2/24**)
- Open the console: `http://10.42.0.1/desktop.html` on the AP, `http://10.42.1.1/desktop.html` on ethernet, or the station IPv4 / `http://teslalinux.local/desktop.html` when associated. Same host also serves `/` (Wi-Fi picker) and `/probe.html`
- SSH as teslalinux attaches tmux session `tl` (`/run/tesla-linux/tmux.sock`): MOTD pane + shell pane

## Primary Tools:

- Tesla-browser `desktop.html` for the in-car XFCE console (1088x832 virtual `:0`)
- USB keyboard/mouse drive that same XFCE session (`Xorg :0 vt1`)
- `index.html` to pick/save a station WLAN from the TeslaLinux AP
- `hostapd` AP **TeslaLinux** / **teslalinux** at **10.42.0.1** when no saved station associates
- NetworkManager station autoconnect when a WLAN is saved
- nginx serving the console on AP / ethernet / station IPv4
- `tmux` SSH MOTD (live WLAN IPv4 or `10.42.0.1` in AP mode, ethernet `10.42.1.1`)
- Misc. from Ubuntu Server 26.04 + XFCE (standard GNU tools, etc.)

## What/Why?:

- Rapidly image a single-purpose Pi for Tesla-browser access to an XFCE desktop
- Ubuntu Server 26.04 + XFCE on Raspberry Pi 4 (8 GB only) for a KISS path off tesla-android-kiss
- Product is the Tesla-browser web console, not a HDMI login desktop
- Dummy virtual `:0` so XFCE stays up whether HDMI is present or black
- USB HID grabbed on that Xorg so a plugged keyboard/mouse drives the same session the car sees
- SSH MOTD lives in tmux (not tty1) so the kernel console does not steal HID from `:0`
- Saved station WLAN when possible; TeslaLinux AP only as fallback (K.I.S.S.)
- Same image flashes SD or USB (`root=LABEL=writable`)
- Factory defaults are documented operator defaults (`teslalinux` / AP **teslalinux**); change them later (`/etc/tesla-linux/ap.env`)

### Notes:

- Pi 4 USB boot may need EEPROM USB MSD first (Raspberry Pi Imager → Misc utility images → Bootloader → USB boot on a spare SD). Official 5V 3A PSU; USB 2.0 or a powered hub if a USB SSD hangs
- HDMI0 (micro-HDMI nearest USB-C) is not a login; `getty@tty1` is masked. Ubuntu KMS has no firmware splash — black until the kernel starts is expected
- Wired ethernet is static **10.42.1.1/24**, not DHCP, not the AP subnet **10.42.0.1/24**
- `http://teslalinux.local/` via existing avahi when mDNS is up
