# Running problem list (build 2026.09.28-e9c0772, Pi at 10.42.1.1 via eth)
| # | Problem | Status |
|---|---------|--------|
| 1 | nginx never starts: `exec 9>$LOCK; flock 9` leaked fd 9 to hostapd/dnsmasq | FIXED (`9>&-` on daemon launch), verified live + after reboot |
| 2 | LTE modem got no IPv4 | resolved by #1 (192.168.1.100, internet OK via modem) |
| 3 | Pi clock wrong | resolved by #1 (NTP synced once WAN up) |
| 4 | WAN rebroadcast (NAT for AP clients) | rule present after fix; needs verify from a real wifi client |
| 5 | Security caveats: default password, root SSH, shared host keys, ufw off | open (later) |

## Added 2026-10-02
- Car browser will not connect to 10.42.0.1; workaround: http://198.18.0.1/desktop.html via nft DNAT (tl-src/tesla-linux-alias.{service,nft}; install to /etc/systemd/system and /etc/tesla-linux-alias.nft, enable).
- desktop.html: status HUD and bottom bar are overlays so the stream fills the car viewport (804x638 CSS px).
- Screen once ended up 617x641 (xrandr transform changed); reset with the xrandr line in tesla-linux-desktop.service. Cause unknown; watch for recurrence.
- DPI set to 130 via xfconf (Xft/DPI), panel 34px, to compensate for ~0.74 browser scaling. Not yet in the image build.
- Optional remote access: tools/remote-access.sh (bore tunnel, key-only SSH).
