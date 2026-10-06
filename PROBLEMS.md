# Running problem list (build 2026.09.28-e9c0772, Pi at 10.42.1.1 via eth)
| # | Problem | Status |
|---|---------|--------|
| 1 | nginx never starts: `exec 9>$LOCK; flock 9` leaked fd 9 to hostapd/dnsmasq | FIXED (`9>&-` on daemon launch), verified live + after reboot |
| 2 | LTE modem got no IPv4 | resolved by #1 (192.168.1.100, internet OK via modem) |
| 3 | Pi clock wrong | resolved by #1 (NTP synced once WAN up) |
| 4 | WAN rebroadcast (NAT for AP clients) | rule present after fix; needs verify from a real wifi client |
| 5 | Security caveats: default password, root SSH, shared host keys, ufw off | open (later) |

## Added 2026-10-06
- Image too big for a GitHub release: last `.img.xz` was 3.2 GB (limit 2 GiB) because deleted package downloads leave old data in free blocks. Zeroing free space by hand gave ~1.93 GiB (2,074,426,664 B). FIXED in `build-image.sh`: apt/log/tmp cleanup in the chroot, then `zerofree` on the root (dd-fill fallback) and dd-fill on boot, build's own loop partitions only. A post-pack check fails over 2,140,000,000 B unless `ALLOW_BIG_IMAGE=1`. Still headroom-thin; watch the size on the next build.

## Added 2026-10-02
- Car browser will not connect to 10.42.0.1; workaround: http://198.18.0.1/desktop.html via nft DNAT (tl-src/tesla-linux-alias.{service,nft}; install to /etc/systemd/system and /etc/tesla-linux-alias.nft, enable).
- desktop.html: status HUD and bottom bar are overlays so the stream fills the car viewport (804x638 CSS px).
- Screen once ended up 617x641 (xrandr transform changed); reset with the xrandr line in tesla-linux-desktop.service. Cause unknown; watch for recurrence.
- DPI set to 130 via xfconf (Xft/DPI), panel 34px, to compensate for ~0.74 browser scaling. New homes get DPI 130 / cursor 32 / Greybird / elementary-xfce-dark from `/etc/skel` (`ensure_xubuntu_de`); panel 34px is still live-only (not in the image build).
- Optional remote access: tools/remote-access.sh (bore tunnel, key-only SSH).
