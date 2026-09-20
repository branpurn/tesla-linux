# Station mode: http://\<dhcp-ip\>/ connection refused

## Symptom
Pi reachable at a station DHCP address (e.g. `192.168.1.199`) but HTTP connection refused. Web UI works on `10.42.0.1` (AP) / `10.42.1.1` (factory eth).

## Do not bind 0.0.0.0
Product + `wan-verify` **FAIL** if nginx listens on `0.0.0.0` or bare `:80`. Bind concrete IPv4s only.

## Cause
`wait_station` returns on **association**; `cmd_nginx_bind` often runs **before DHCP** assigns the station IPv4, so the listen list omits that address.

## Land the helper (MCP cannot push ~78KB `tesla-linux-wlan.sh`)
From repo root on branch `fix/station-nginx-bind-ipv4`:

```bash
bash tl-src/patches/apply-station-nginx-wlan.sh
git add tl-src/tesla-linux-wlan.sh
git commit -m 'fix(wlan): wait for station DHCP IPv4 before nginx-bind'
git push
```

Or: `patch -p1 < tl-src/patches/station-nginx-bind-ipv4.patch` (fallback name: `station-nginx-bind.patch`).

## Live unblock (no rebuild)
```bash
sudo tesla-linux-wlan nginx-bind
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.1.199/
```
