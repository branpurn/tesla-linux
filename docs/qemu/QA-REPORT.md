# Tesla Linux — QEMU raspi4b QA Report (2026.09.01)

**Date:** 2026-09-01 (ET) / 2026-09-02 UTC  
**Artifact:** `tesla-linux-20260901-pi.img.xz`  
**sha256:** `7fb25aa10675cccbeb1228fc06713a57bdbd8ac961af1aa32e09c3cb8b237993`  
**Harness:** `/workspace/tesla-linux-qemu/` — `-M raspi4b`, VNC `:5901`, `serial.sock`, `monitor.sock`, tap `tesla0` (`10.42.0.254/24` + `10.42.1.2/24`)  
**Policy:** Do not kill · Do not flash · Stay on **2026.09.01** · **kiss PRIVATE** · **HOLD flash** until **6dbff3f** `img.xz` is named  
**Leftover rule:** XFCE restart-loop + picker timeout are **Backend virtual-display vs 6dbff3f** — **not** new leftovers. Do not invent leftovers for those.

---

## PASS / FAIL

| Check | Result | Notes |
|---|---|---|
| Boot to Ubuntu 26.04 on raspi4b TCG | **PASS** | `Welcome to Ubuntu 26.04 LTS`, hostname `teslalinux` |
| `multi-user.target` | **PASS** | Reached (MU prove run) |
| `tesla-linux-firstboot` | **PASS** | Finished OK (MU run; openssl TCG-slow on graphical run) |
| `tesla-linux-wlan` unit finishes | **PASS** *(vacuous)* | Finished OK with **no Wi-Fi iface** → boot path logs skip AP (`no Wi-Fi iface; nothing to do`). Expected on qemu without radio/hwsim. |
| hostapd AP `TeslaLinux` @ `10.42.0.1` | **FAIL** *(qemu env)* | No wireless iface in guest; AP not started. Not a product leftover — needs radio or runtime `mac80211_hwsim`. |
| nginx unit starts | **PASS** | `Started nginx.service` |
| nginx world listen / picker HTTP | **FAIL** *(qemu env)* | No AP/station IPv4 → nginx bind has nothing world-facing (`no AP/station IPv4 yet`). Host `curl http://10.42.0.1/` → no route. **Picker timeout folded into Backend virtual-display vs 6dbff3f — not a new leftover.** |
| XFCE desktop stable | **FAIL** *(qemu display)* | Graphical run: **92** desktop stops / **93** xorg starts (restart loop). Screendump `shots/xfce-now.png` is **not** wallpaper — solid near-black `RGB(1,1,1)` (Xorg black FB). **Folded into Backend virtual-display vs 6dbff3f — not a new leftover.** |
| `tesla-linux-xorg` | **FAIL** *(qemu display)* | Restarts with desktop; FB never shows XFCE. Same Backend bucket. |
| Guest shell via serial | **FAIL** / blocked | `systemd.debug-shell=ttyAMA1` → STDIN fail (`No such file or directory`). `serial-getty@ttyAMA1` DEPEND failed. Console shows systemd boot traffic only; no interactive serial login. tty1 getty shows `teslalinux login:` on VNC/screendump. |
| Guest `ip addr` / `nmcli` live | **FAIL** / blocked | No interactive guest shell; usb-net silent on tap (0 DHCP/ARP packets). |
| `systemctl status` wlan/nginx/xorg/desktop live | **PARTIAL** | Inferred from serial unit lines only (see evidence). No live `systemctl status` transcript. |
| `mac80211_hwsim` + wlan restart | **NOT RUN** | Module **present** in image (`…/wireless/virtual/mac80211_hwsim.ko.zst`). Could not `modprobe` / restart wlan without guest shell. **Did not rewrite product image.** |
| ssh | **FAIL** | `ssh.service` FAILED repeatedly. Image lacks `/etc/ssh/ssh_host_*` keys (RO inspect). `ssh.socket` listens; no L3 path to guest anyway. |
| `10.42.1.1` in **this** bake (2026.09.01) | **N/A — not-in-bake** | See `evidence/no-10.42.1.1.txt`. Zero hits in `/etc` + `/usr/local` on 2026.09.01 rootfs. Host probe of `10.42.1.1` fails (expected). |
| Flash | **HOLD** | HOLD until **6dbff3f** `img.xz` named. In-flight bake log: `/workspace/tl-bake/bake-6dbff3f.log` (work image `tesla-linux-20260902-pi.img` — **not** named/out as 6dbff3f xz yet). |
| kiss | **PRIVATE** | HOLD — do not make public. |

---

## Shot confirmation: `xfce-now.png`

| | |
|---|---|
| Path | `shots/xfce-now.png` |
| Size | 800×480 |
| Pixels | ~383984 × `RGB(1,1,1)`, 16 × `RGB(204,204,204)` |
| Verdict | **NOT desktop wallpaper.** Near-black Xorg/virtual-display framebuffer. Evidence: `evidence/xfce-now-pixels.txt`. |

Earlier console text was visible on `shots/boot-now2.png` (kernel/fb). After Xorg owns the display, dumps stay black even if VTs underneath change (`-novtswitch`).

---

## Runs observed

1. **Graphical prove (default target)** — preserved `evidence/serial-graphical-run.log`  
   - XFCE/xorg restart loop (counts above).  
   - firstboot long-running under TCG.  
   - ssh FAILED.  
   - VNC black / near-black dumps (`xfce-now.png`).

2. **Multi-user prove** (`systemd.unit=multi-user.target`, `debug-shell=ttyAMA1`) — serial captured during session; later truncated by concurrent harness restart  
   - firstboot **Finished**, wlan **Finished**, nginx **Started**, `multi-user.target` **Reached**.  
   - No desktop units (as intended).  
   - tty1 login prompt visible (`shots/mu-now.png` / `final-login.png`): `Ubuntu 26.04 LTS teslalinux tty1` / `teslalinux login:`.  
   - Serial interactive shell still unavailable (getty/debug-shell on ttyAMA1 broken).

VM left **running** (do not kill). Concurrent agents may restart harness; socks/VNC should remain the prove surface.

---

## Networking (host)

| Item | Value |
|---|---|
| tap | `tesla0` UP — `10.42.0.254/24`, `10.42.1.2/24` |
| Guest AP `10.42.0.1` | unreachable (no AP) |
| Guest eth static `10.42.1.1` | **not in 2026.09.01 bake** |
| usb-net | QEMU `usb-net` attached; **no** guest DHCP/ARP seen on tap during prove |
| `cdc_ether` / `mac80211_hwsim` | present in guest modules tree (RO inspect) |

---

## Folded (not new leftovers)

| Symptom | Bucket |
|---|---|
| XFCE restart-loop | **Backend virtual-display vs 6dbff3f** |
| Picker timeout / no HTTP picker | **Backend virtual-display vs 6dbff3f** (qemu: no AP IPv4 + black FB; same Backend track) |

Do **not** open separate leftover tickets for these on 2026.09.01.

---

## Notes for 6dbff3f (informational only — HOLD flash)

In-tree bake source under `/workspace/tl-bake/tl-src/` adds factory ethernet static **`10.42.1.1/24`** (`tesla-linux-wlan eth-up`, nginx bind on eth). That is **not** in the 2026.09.01 artifact under test. Flash remains **HOLD** until a **6dbff3f-named** `img.xz` exists in the release/out path.

---

## Evidence index

| Path | What |
|---|---|
| `evidence/no-10.42.1.1.txt` | RO inspect: 10.42.1.1 absent from 2026.09.01 bake |
| `evidence/xfce-now-pixels.txt` | Pixel proof xfce-now is not wallpaper |
| `evidence/serial-graphical-run.log` | Graphical restart-loop serial |
| `evidence/http-10.42.0.1.curl.txt` | Host curl fail to AP |
| `evidence/http-10.42.1.1.curl.txt` | Host curl fail to 10.42.1.1 |
| `shots/xfce-now.png` | Black FB (not wallpaper) |
| `shots/mu-now.png` / `final-login.png` | tty1 login prompt (MU run) |
| `shots/boot-now2.png` | Pre-Xorg console text |
| `NOTES.md` | Harness facts |

---

## Overall

**QEMU prove on 2026.09.01: PARTIAL.** Boot + firstboot + wlan unit + nginx unit OK on multi-user; AP/picker/desktop **not** demonstrable in this qemu environment. Desktop/picker symptoms stay under **Backend virtual-display vs 6dbff3f**. **No flash.** **kiss PRIVATE.** Leave VM running.

## Harness liveness at report write

`qemu-system-aarch64 -M raspi4b` relaunched after concurrent harness drop (this agent did not kill the prior VM). VNC `127.0.0.1:5901`, socks restored. **Left running.** No flash.
