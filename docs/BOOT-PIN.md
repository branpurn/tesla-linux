# Boot-PIN gate (web GUI)

Mild hardening: an optional numeric PIN (4–8 digits) the web GUI asks for **once
per cold boot**. One correct entry unlocks the Pi for every client until the
next reboot. With no PIN set, the GUI behaves exactly as before.

## Using it
* **Settings:** open `http://10.42.0.1/` (Wi-Fi page) → **Security PIN**
  (expandable section above the footer). Set PIN, Change PIN (needs current PIN),
  Clear PIN (needs current PIN).
* **After a reboot** any page redirects to `/pin.html` — a big numeric keypad
  sized for the Tesla browser. Enter the PIN, press OK, you land on the page you asked for.
* **Wrong PINs:** 5 free attempts, then 30 s backoff doubling per further miss
  (max 15 min). Counter lives in `/run`, so a reboot also resets it.

## How it works
| Piece | Where |
|---|---|
| Hash (PBKDF2-SHA256, 200k iters, 16-byte salt) | `/etc/tesla-linux/pin.hash` (root 0600). Absent = gate off |
| Unlock marker (holds kernel `boot_id`) + fail counter | `/run/tesla-linux/` (tmpfs, wiped every boot) |
| API | `ta_pin_api.py` on `127.0.0.1:9095`, unit `tesla-linux-pin-api.service` |
| Enforcement | nginx `auth_request /_tl_pin_check` at server level in `/etc/nginx/tl-locations.conf` |

Every location (pages, `/api/wlan|reboot|mode|lte`, `/sockets/display|touchscreen|audio`,
`.wasm`/Broadway assets) inherits `auth_request`. Exempt: `/pin.html` and
`/api/pin/*` (the API itself refuses set/clear while locked). Locked responses:
HTML → `302 /pin.html?next=…`; `/api/*` and `/sockets/*` → `401`.

## Recovery (forgotten PIN)
```
ssh teslalinux@10.42.0.1
sudo rm /etc/tesla-linux/pin.hash
```
The gate opens immediately (no restart needed).

## Tests
`tl-src/selftest-pin-gate.sh` — hash/verify, unset = open, set/change/clear,
`/run` wipe re-locks, stale boot_id marker stays locked, backoff, installer and
build-image wiring. `build-image.sh` also fails if the image ships a `pin.hash`.
