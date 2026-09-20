# Station-mode nginx bind (DHCP race)

## Symptom (live 2026-09-20)

Pi joined home Wi‑Fi as station: DHCP **192.168.1.199**. Car browser → `http://192.168.1.199/` → **ERR_CONNECTION_REFUSED**. Host is up; nothing listening on that address.

## Cause

`wait_station` returns on **associate**. `cmd_nginx_bind` / `collect_bind_ips` often run **before** DHCP assigns an IPv4, so the listen list never includes `192.168.1.199`.

## Do **not** bind `0.0.0.0`

Product rule + `wan-verify` fail-hard if nginx listen includes `0.0.0.0` / world bind. Bind the **concrete** station DHCP IPv4 (and eth `10.42.1.1` / AP `10.42.0.1` as today).

## Fix (helper)

Add `wait_station_ipv4` (default `STATION_IP_WAIT_SEC=30`) and call it from `cmd_nginx_bind` when station-associated and not `wan_mode_on`. Same path covers save-wlan / boot / maybe-ap via existing `cmd_nginx_bind` calls.

## Live unblock (now)

On the Pi (HDMI / SSH when isolation allows):

```bash
sudo tesla-linux-wlan nginx-bind
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.1.199/
# expect 200 (or any non-refused HTTP)
ss -ltnp | grep ':80'
```

If still refused, check `ip -4 addr show` for the station address, then re-run `nginx-bind` after DHCP is present.
