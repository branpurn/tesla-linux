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

- Serial: qemu `-serial` stdio (typeable). Log: `serial.log`. Login **teslalinux** / **teslalinux** (factory).
- Monitor: `echo 'screendump "$ROOT/shots/x.ppm"' | socat - UNIX-CONNECT:"$ROOT/monitor.sock"`
- VNC: `127.0.0.1:5901`
- Host tap: `tesla0` at `10.42.0.254/24`

## QEMU facts (Debian 10.0.11)
- `-M raspi4b` present; RAM fixed at 2 GiB; SD size must be power of 2.
- DTB disables PCIe / GENET / rng200 / thermal → **no bcmgenet NIC**.
- `-nic model=help` empty on raspi4b; use `-device usb-net`.
- No Wi-Fi radio in qemu; product AP binds hostapd to a wireless iface only. **No wlan0 expected.**
- QEMU picker path is ethernet: `usb-net` / `cdc_ether` → static **10.42.1.1/24**, nginx listen on that IPv4 (never 0.0.0.0). `tesla-linux-wlan` must not fail the oneshot when 10.42.1.1 is bound. nginx `After=`/`Wants=` wlan so CLEAN-boot starts nginx after listen files; wlan does not `Before=nginx` and does not systemctl-restart nginx from the oneshot.
- Serial getty `ttyAMA0` / `ttyS0`: drop-in clears `BindsTo=dev-%i.device` so a missing udev device is not DEPEND-fail. Do not wait on wlan. HDMI `getty@tty1` stays masked.
- Guest kernel has `mac80211_hwsim` module (can load at runtime without rewriting image).

## Product image notes (RO inspect)
- Services: `tesla-linux-wlan` (hostapd AP SSID TeslaLinux / PSK teslalinux @ 10.42.0.1), nginx picker `/var/www/tl/`.
- nginx listen rewritten to AP/station/ethernet IPv4 only (never 0.0.0.0 / loopback-only). QEMU path: **10.42.1.1** (no wlan0).
- Pre-seed: `/boot/firmware/tesla-linux.conf` WIFI_SSID/WIFI_PSK.
- Default target: `ln -sfn` graphical.target (verified `readlink`). XFCE via `tesla-linux-desktop` (User=teslalinux).
- Factory user teslalinux / teslalinux (`chpasswd`); `ubuntu` userdel'd. cloud-init purged.
- SSH: `ssh-keygen -A` in bake; `PasswordAuthentication yes`. `ssh teslalinux@guest` is the qemu path.
- Serial getty enabled on ttyAMA0 / ttyS0 / ttyAMA1. Drop-in clears `BindsTo=dev-%i.device`. cmdline keeps `console=serial0,115200 console=tty1`.
- HDMI / qemu VNC (tty1) is XFCE on `:0` (`Xorg vt1`), not `getty@tty1` (masked). Serial-getty remains the typed login path.

## QA hwsim injection (work image only)
Work copy rootfs has `qa-hwsim.service` (WantedBy=multi-user) that only runs
`modprobe mac80211_hwsim radios=2` **before** product `tesla-linux-wlan.service`.
Product hostapd/NM path is unchanged. Not present in the release xz.
