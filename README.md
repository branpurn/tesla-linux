# Tesla Linux

Tool for baking a flashable Ubuntu Server 26.04 + XFCE image for Raspberry Pi 4 (8 GB only).

Product path is the Tesla-browser web console (`desktop.html`) at a stable known IP. HDMI may show a standard 1080p clone of the same XFCE session.

## Components:

| File | Description |
    10|| ------------------------- | ---------------------------------------------------------------------------- |
| `tl-src/build-image.sh` | Bakes Ubuntu Server arm64 raspi into `tesla-linux-YYYYMMDD-pi.img.xz` |
| `tl-src/install-tesla-linux.sh` | Installs the XFCE / Xorg / stream / WLAN stack inside the image chroot |
| `tl-src/desktop.html` | Tesla-browser console (in-car product path) |
| `tl-src/index.html` | Wi-Fi picker: WAN rebroadcast, or join the same Wi-Fi network as the car |
| `tl-src/probe.html` | Tesla-browser capability probe |
| `tl-src/tesla-linux-wlan.sh` | LTE/ethernet WAN + TeslaLinux AP; station alternate; ethernet static |
| `tl-src/ta_*.py` | Display / touch / audio backends (loopback, nginx-proxied) |
| `docs/` | Virtual display, WLAN, and qemu notes |
| `README.md` | The document you are currently reading |

## Prerequisites:

- A Linux host to generate the image (`qemu-user-static`, `binfmt-support`, `parted`, `e2fsprogs`, `xz-utils`, `curl`)
- Internet connection capable of downloading the Ubuntu Server arm64 raspi image
- Raspberry Pi **4 (8 GB)** to boot the result
- An SD card **or** USB stick/SSD (same image either way)

## Usage:

- Operators: flash GitHub Release **[2026.09.09-36ecc74](https://github.com/branpurn/tesla-linux/releases/tag/2026.09.09-36ecc74)** (`tesla-linux-20260910-pi.img.xz`) with Raspberry Pi Imager → **Use custom** onto an SD card or a USB stick. That is the proven image (tip **36ecc74**). `main` tip is ahead (ristretto, tumbler, archive stack, xubuntu-wallpapers) for the next bake.
- To bake from this tree instead:

```
sudo ./tl-src/build-image.sh
```

Then flash `tesla-linux-YYYYMMDD-pi.img.xz` the same way.

- Optional pre-seed on the FAT boot partition (`/boot/firmware/tesla-linux.conf`) if you will use station mode (same Wi-Fi network as the car):

```
WIFI_SSID=YourWLAN
WIFI_PSK=yourpsk
```

- Boot the Pi 4 (8 GB)
- Factory user **teslalinux** / **teslalinux**
- Connect:
  - **PRIMARY (in-car):** Plug a USB LTE modem into the Pi as WAN. TeslaLinux AP stays **10.42.0.1**. From the car, join SSID **TeslaLinux**, WPA2-PSK **teslalinux**. Always open `http://10.42.0.1/desktop.html`. On `/` choose **WAN rebroadcast** so the AP stays up and the modem is NAT’d. Do not join the LTE modem’s own hotspot or chase a DHCP lease.
  - Lab / debug: ethernet static **10.42.1.1/24** (peer often **10.42.1.2/24**) → `http://10.42.1.1/desktop.html`
  - Alternate (setup): saved station WLAN — the same Wi-Fi network as the car. Pick/save from `index.html` (**Join**) or pre-seed above. Console is that station IPv4 or `http://teslalinux.local/desktop.html` when associated.
- Same host also serves `/` (Wi-Fi picker) and `/probe.html`
- SSH as `teslalinux` opens a normal shell

## Primary Tools:

- Tesla-browser `desktop.html` is the product path (capture/stream **1088×832**). HDMI may be a standard 1080p clone of the same XFCE session (`Xorg :0`, vt1)
- USB keyboard/mouse drive that same visible and broadcast XFCE session
- USB LTE modem as WAN + `hostapd` AP **TeslaLinux** / **teslalinux** at **10.42.0.1** (WAN rebroadcast). In-car console is always that address — not a lease from the modem’s own hotspot
- `index.html` **WAN rebroadcast** keeps the AP up; **Join** picks/saves a station WLAN (the same Wi-Fi network as the car)
- NetworkManager station autoconnect when a WLAN is saved (setup / alternate)
- Ethernet **10.42.1.1/24** is lab/debug, not the in-car primary
- nginx serving the console on AP / ethernet / station IPv4
- Piecemeal XFCE (not `xubuntu-desktop`): Mozilla apt Firefox (`.deb` from `packages.mozilla.org`, not the Ubuntu snap stub); **ristretto** + **tumbler**; **xubuntu-wallpapers** default; **xarchiver** + **thunar-archive-plugin** + **unzip** + **7zip**
- Misc. from Ubuntu Server 26.04 + XFCE (standard GNU tools, etc.)

## What/Why?:

- Rapidly image a single-purpose Pi for Tesla-browser access to an XFCE desktop
- Ubuntu Server 26.04 + XFCE on Raspberry Pi 4 (8 GB only). Not Android / AOSP.
- In-car: LTE on the Pi as WAN, car on TeslaLinux AP at a stable **10.42.0.1** — never chase a modem-hotspot DHCP lease
- One vc4/modesetting Xorg screen: HDMI may clone 1080p; product is `desktop.html` at 1088×832
- Logical 1088x832 geometry matches the Tesla-browser canvas and touch mapping; HDMI scales it to monitor-compatible 1080p60
- Standard seat0/libinput discovery lets a directly connected keyboard and mouse drive that session
- Saved station WLAN + picker remain for joining the same Wi-Fi network as the car (setup / alternate)
- Same image flashes SD or USB (`root=LABEL=writable`)
- Factory defaults are documented operator defaults (`teslalinux` / AP **TeslaLinux** / **teslalinux** / **10.42.0.1**); change them later (`/etc/tesla-linux/ap.env`)

### Notes:

- Pi 4 USB boot may need EEPROM USB MSD first (Raspberry Pi Imager → Misc utility images → Bootloader → USB boot on a spare SD). Official 5V 3A PSU; USB 2.0 or a powered hub if a USB SSD hangs
- Use HDMI0 (micro-HDMI nearest USB-C). `getty@tty1` is masked because Xorg owns vt1. Ubuntu KMS has no firmware splash — black until the kernel starts is expected
- Appliance never sleeps: `sleep.target` / `suspend.target` / `hibernate.target` / `hybrid-sleep.target` are masked; logind `IdleAction=ignore` (lid/suspend keys ignored). XFCE power-manager idle/lid/DPMS sleep is locked off and its autostart is Hidden. USB autosuspend is off (`usbcore.autosuspend=-1` + udev `power/control=on`) so USB KBM and the `:0` capture stream stay awake. Physical power button still powers off.
- Appliance does not background-patch: `unattended-upgrades.service`, `apt-daily.timer`, and `apt-daily-upgrade.timer` are masked; `/etc/apt/apt.conf.d/99tesla-linux-no-unattended` sets `APT::Periodic::Unattended-Upgrade "0"`. Operators still run `apt` by hand.
- Wired ethernet is lab/debug static **10.42.1.1/24**, not DHCP, not the AP subnet **10.42.0.1/24**, not the in-car primary
- Joining the LTE modem’s own hotspot (Pi and car both as clients, then guessing the Pi’s DHCP IP) is not a supported path
- `http://teslalinux.local/` via existing avahi when mDNS is up
