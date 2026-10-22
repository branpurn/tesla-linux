# nginx / SSH: wildcard listen on every interface

**Policy (supersedes all earlier "do not bind 0.0.0.0" / per-IP bind notes):**
the web GUI (nginx 80/443) and SSH (22) must be reachable on **any network and
any interface** at whatever IP the Pi holds — TeslaLinux AP `10.42.0.1`,
factory ethernet `10.42.1.1`, any station DHCP address (e.g. Starlink Mini
Wi-Fi), and IPv6. No source filtering (`0.0.0.0/0` allowed).

- `tesla-linux-wlan nginx-bind` / `write_nginx_servers` always writes
  `listen 80; listen [::]:80;` and (with cert) `listen 443 ssl; listen [::]:443 ssl;`.
  The live IPv4 list is ignored; there is no per-IP regeneration.
- Installer seeds the same wildcard `tl-http-server.conf`; stock `default` site is removed.
- sshd: no `ListenAddress`; no `hosts.deny` sshd/ALL rule; no input firewall.

Gates (`install-tesla-linux.sh --verify-wan`, `tesla-linux-wlan wan-verify`,
`selftest-wan-rebroadcast.sh`, `tesla-linux-wlan selftest`) **FAIL** on any
IP-specific nginx listen (`listen A.B.C.D:port`, incl. `0.0.0.0:`) and on sshd
`ListenAddress`.
