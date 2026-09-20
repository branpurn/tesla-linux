# Station-mode nginx bind (DHCP race)

## Symptom (live 2026-09-20)

Pi joined home Wi‑Fi as station: DHCP **192.168.1.199**. Car browser → `http://192.168.1.199/` → **ERR_CONNECTION_REFUSED**.

## Cause

`wait_station` returns on **associate**. `cmd_nginx_bind` often runs **before** DHCP → listen list misses the station IPv4.

## Do **not** bind `0.0.0.0`

`wan-verify` fails world bind. Bind the concrete station DHCP IPv4.

## Apply helper patch

```bash
cd /path/to/tesla-linux
patch -p1 < tl-src/patches/station-nginx-bind-ipv4.patch
sudo install -m 0755 tl-src/tesla-linux-wlan.sh /usr/local/bin/tesla-linux-wlan   # or your install path
sudo tesla-linux-wlan nginx-bind
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.1.199/
```

## Live unblock (no patch yet)

```bash
sudo tesla-linux-wlan nginx-bind
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.1.199/
```
