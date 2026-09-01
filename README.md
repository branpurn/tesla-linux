# tesla-linux

Tesla-Linux — Ubuntu Server + XFCE on Raspberry Pi 4 (8 GB). KISS replacement for tesla-android-kiss.

## Bake

```bash
sudo ./tl-src/build-image.sh
```

Ubuntu Server arm64 raspi → `.img.xz` (`UBUNTU_REL` 26.04). Pi 4 8 GB only.

## WLAN (WAVE 1)

Preferred: Pi is a station on a saved Tesla (or other) WLAN (NetworkManager autoconnect).

Pre-seed when flashing — `/boot/firmware/tesla-linux.conf` on the FAT partition:

```
WIFI_SSID=YourTeslaWLAN
WIFI_PSK=yourpsk
```

Fallback when no saved WLAN / associate fails: **hostapd** AP SSID **TeslaLinux**, WPA2-PSK password **teslalinux** (documented factory default; operators change it later). Do not invent a second SSID.

Web GUI on that AP: `http://10.42.0.1/` (`desktop.html`) and `http://10.42.0.1/probe.html` — reachable by other devices on the Pi WLAN. Bind is AP LAN (and station IP when associated), not loopback-only, not `0.0.0.0` world.

Factory AP password is also in `/etc/tesla-linux/ap.env` on the image.

Frontend owns the pick/save Wi-Fi GUI on this SHA (do not invent a settings maze here). Backend bounces autoconnect (`tesla-linux-wlan save-wlan`) on this SHA.

See [docs/WAVE1-WLAN.md](docs/WAVE1-WLAN.md). WAVE 0 KEEP / DROP / GAPS: [docs/WAVE0-KEEP-DROP-GAPS.md](docs/WAVE0-KEEP-DROP-GAPS.md).
