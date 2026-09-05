# AP setup chrome lock

`tl-src/index.html` → nginx index at `http://10.42.0.1/`. Designer owns these labels. No settings maze.

| Element | Copy |
|---|---|
| `<title>` | Tesla Linux |
| Heading | Wi-Fi |
| Helper | Join the same Wi-Fi network as the car |
| SSID control | Network |
| Password | Password (`type=password`, show/hide peek) |
| Primary | Join |
| Status | Scanning · Joining · Saved · Couldn't join |

- **Scanning** — on load while `GET /api/wlan` is in flight.
- **Joining** — on submit.
- **Saved** — HTTP 2xx, plus one-line helper: `Next boot joins that WLAN.`
- **Couldn't join** — 501 / error / timeout / empty SSID. A short HTTP/timeout hint may sit on the same status line.

Copy lock: never "the car's Wi-Fi" / "the car's WiFi". The car does not broadcast an SSID to join. Helper means the same Wi-Fi network as the car.

Footer stays `Desktop` · `Probe`. Dark KISS, one column. No AP-password editor. No fake SSIDs.

Wiring (Frontend): origin-relative `GET`/`POST` `/api/wlan`, 15s abort, 501 is a hard error. Typed SSID if scan is missing; dropdown only if `GET` returns a list.

Mode switch (Frontend): **Join** (station — helper above) vs **WAN rebroadcast** (plug ethernet; TeslaLinux AP stays up at 10.42.0.1/24; no Network/Password). Origin-relative `GET` `/api/mode` `{mode,ap,uplink,nat}` and `POST` `{mode}` → `{ok,mode}`. Missing/404 → station. GET skeleton is `uplink.kind: none` and `nat: false` until Infra — do not invent live ethernet/LTE chrome from that.
