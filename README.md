# tesla-linux

Tesla-Linux — Ubuntu Server + XFCE on Raspberry Pi 4 (8 GB). KISS replacement for tesla-android-kiss.

Console login **teslalinux** / **teslalinux** (factory).

## Bake

```bash
sudo ./tl-src/build-image.sh
```

Ubuntu Server arm64 raspi → `.img.xz` (`UBUNTU_REL` 26.04). Pi 4 8 GB only.

Flash the same `tesla-linux-20260901-pi.img.xz` with Raspberry Pi Imager → **Use custom** onto an SD card **or** a USB stick/SSD. Do not invent a second image or a bake flag. Do not rebake.

### USB or SD (Pi 4)

Operator-side. Image is not USB-hostile (`root=LABEL=writable`, `LABEL=` fstab). Gap is EEPROM / power / HDMI.

- **EEPROM USB MSD:** Raspberry Pi Imager → Choose OS → Misc utility images → Bootloader → USB boot. Write to a spare SD. Power the Pi 4 with that SD (no USB OS yet). Success = rapid green ACT blink and HDMI green screen (~10s). Power off, remove the recovery SD, then boot the tesla-linux USB stick. Official docs: [boot EEPROM](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#boot-eeprom). `BOOT_ORDER` USB-then-SD is `0xf14` (read right-to-left). Default empty EEPROM is `0xf41` (SD then USB).
- **USB3 power:** official 5V 3A PSU. If red PWR flickers or the USB SSD/stick hangs at solid green, use a USB 2.0 port or a powered hub. Do not invent a second image.
- **HDMI:** use HDMI0 (micro-HDMI nearest USB-C). Ubuntu KMS has no firmware splash — black until the kernel starts is expected. teslalinux **autologin** XFCE on a **1088x832 virtual** display (`:0`). USB keyboard/mouse drive that same session. HDMI TTY is a **pinned SSH banner** (live WLAN IPv4 or `10.42.0.1` in AP mode, ethernet `10.42.1.1`, user **teslalinux**) — not a login; `getty@tty1` stays masked. Web console is the product path. See [docs/JUMP-VIRTUAL-DISPLAY.md](docs/JUMP-VIRTUAL-DISPLAY.md).

## WLAN (WAVE 1)

### Ethernet

Cable to the Pi ethernet jack. Pi is static **10.42.1.1/24** (not DHCP; not the TeslaLinux AP **10.42.0.1/24**). Peer may need **10.42.1.2/24**. Open `http://10.42.1.1/`. Also `http://teslalinux.local/` if avahi is up.

Preferred: Pi is a station on a saved Tesla (or other) WLAN (NetworkManager autoconnect).

Pre-seed when flashing — `/boot/firmware/tesla-linux.conf` on the FAT partition:

```
WIFI_SSID=YourTeslaWLAN
WIFI_PSK=yourpsk
```

Fallback when no saved WLAN / associate fails: **hostapd** AP SSID **TeslaLinux**, WPA2-PSK password **teslalinux** (documented factory default; operators change it later). Do not invent a second SSID.

Web GUI: `http://10.42.0.1/` on the TeslaLinux AP (pick/save station WLAN), `http://10.42.1.1/` on the ethernet static, plus the station IP when associated. Same paths: `/`, `/desktop.html`, `/probe.html`. Bind is those IPv4s only — not loopback-only, not `0.0.0.0`.

Factory AP password is also in `/etc/tesla-linux/ap.env` on the image.

Frontend picker is `tl-src/index.html` (POST origin-relative `/api/wlan`). Backend bounces autoconnect (`tesla-linux-wlan save-wlan`) on this SHA.

See [docs/WAVE1-WLAN.md](docs/WAVE1-WLAN.md). WAVE 0 KEEP / DROP / GAPS: [docs/WAVE0-KEEP-DROP-GAPS.md](docs/WAVE0-KEEP-DROP-GAPS.md).
