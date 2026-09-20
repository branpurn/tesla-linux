# Station mode: http://\<dhcp-ip\>/ connection refused

## Symptom
Pi reachable at a station DHCP address (e.g. `192.168.1.199`) but HTTP connection refused. Web UI works on `10.42.0.1` (AP) / `10.42.1.1` (factory eth).

## Do not bind 0.0.0.0
Product + `wan-verify` **FAIL** if nginx listens on `0.0.0.0` or bare `:80`. Bind concrete IPv4s only.

## Cause
`wait_station` returns on **association**; `cmd_nginx_bind` often runs **before DHCP** assigns the station IPv4, so the listen list omits that address.

## Fix
Apply `tl-src/patches/station-nginx-bind.patch` (or land the equivalent hunk into `tl-src/tesla-linux-wlan.sh`):

```bash
cd /path/to/tesla-linux
git apply tl-src/patches/station-nginx-bind.patch
# or: patch -p1 < tl-src/patches/station-nginx-bind.patch
bash -n tl-src/tesla-linux-wlan.sh
```

Adds `wait_station_ipv4` and calls it from `cmd_nginx_bind` / save-wlan / boot / maybe-ap.

## Live unblock (no rebuild)
```bash
sudo tesla-linux-wlan nginx-bind
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.1.199/
```
