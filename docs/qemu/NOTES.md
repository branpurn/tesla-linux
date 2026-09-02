# Tesla Linux qemu harness (QA)

## Artifact
- xz (untouched): `/workspace/tesla-linux-flash/tesla-linux-20260901-pi.img.xz`
  sha256 `7fb25aa10675cccbeb1228fc06713a57bdbd8ac961af1aa32e09c3cb8b237993`
- raw work copy: `/workspace/tesla-linux-qemu/tesla-linux-20260901-pi.img` (resized to 16G for raspi4b SD power-of-two)

## Extracted boot assets
From FAT `current/`:
- `boot/vmlinuz` (gzip) → decompressed `boot/vmlinux` (ARM64 `ARMd`)
- `boot/initrd.img` (zstd)
- `boot/bcm2711-rpi-4-b.dtb`

## Run
```bash
./run-qemu.sh raspi4b   # preferred
./run-qemu.sh virt      # fallback
```

- Serial log: `serial.log` (also `serial.sock`)
- Monitor: `echo 'screendump "$ROOT/shots/x.ppm"' | socat - UNIX-CONNECT:"$ROOT/monitor.sock"`
- VNC: `127.0.0.1:5901`
- Host tap: `tesla0` at `10.42.0.254/24`

## QEMU facts (Debian 10.0.11)
- `-M raspi4b` present; RAM fixed at 2 GiB; SD size must be power of 2.
- DTB disables PCIe / GENET / rng200 / thermal → **no bcmgenet NIC**.
- `-nic model=help` empty on raspi4b; use `-device usb-net`.
- No Wi-Fi radio in qemu; product AP binds hostapd to a wireless iface only.
- Guest kernel has `mac80211_hwsim` module (can load at runtime without rewriting image).

## Product image notes (RO inspect)
- Services: `tesla-linux-wlan` (hostapd AP SSID TeslaLinux / PSK teslalinux @ 10.42.0.1), nginx picker `/var/www/tl/`.
- nginx listen rewritten to AP/station IPv4 only (never 0.0.0.0 / loopback-only).
- Pre-seed: `/boot/firmware/tesla-linux.conf` WIFI_SSID/WIFI_PSK.
- Default target: graphical; XFCE via `tesla-linux-desktop` (User=ubuntu).
- `/etc/cloud` absent in image at inspect time; cloud-init-base present — watch first-boot user creation.

## QA hwsim injection (work image only)
Work copy rootfs has `qa-hwsim.service` (WantedBy=multi-user) that only runs
`modprobe mac80211_hwsim radios=2` **before** product `tesla-linux-wlan.service`.
Product hostapd/NM path is unchanged. Not present in the release xz.
