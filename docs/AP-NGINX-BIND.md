# Factory AP: http://10.42.0.1/desktop.html connection refused

## Symptom (live 2026-09-28)

Tesla on SSID **TeslaLinux** has uplink (DHCP + NAT OK) but
`http://10.42.0.1/desktop.html` → **ERR_CONNECTION_REFUSED**.

## Do not bind 0.0.0.0

Product + `wan-verify` **FAIL** world bind. Bind concrete `10.42.0.1` (and
factory eth / station IPv4s) only.

## Cause

1. Install seeds `/etc/nginx/tl-http-server.conf` as an empty placeholder
   (no `listen`).
2. `tesla-linux-wlan nginx-bind` must rewrite listens after `AP_ADDR` is on
   the wifi iface. Emitting `listen 10.42.0.1:80` before the address exists
   makes the nginx master fail to bind; `reload_nginx` intentionally never
   `systemctl start` nginx from inside the wlan oneshot (After=wlan deadlock).
3. Result: AP + dnsmasq + NAT look healthy while nginx stays failed/inactive
   with no (or stale) listen on `10.42.0.1:80`.

## Durable fix (this branch)

- `wait_ap_ipv4` before collect (mirror of station DHCP wait).
- `tesla-linux-wlan.service` `ExecStartPost=… nginx-bind`.
- nginx drop-in `ExecStartPre=… nginx-bind` + `Restart=on-failure`.
- `reload_nginx` may `systemctl start nginx` only when nginx is **failed**
  and wlan is already active (not during nginx ExecStartPre).

## Live unblock (no rebuild)

```bash
sudo tesla-linux-wlan nginx-bind
# if nginx still dead:
sudo systemctl reset-failed nginx
sudo systemctl start nginx
curl -sS -o /dev/null -w '%{http_code}\n' http://10.42.0.1/desktop.html
```
