#!/usr/bin/env python3
"""Tesla Linux — boot-PIN gate (loopback /api/pin/*).

Stdlib only. Binds TA_BIND (default 127.0.0.1) — never 0.0.0.0.

* PIN hash: PIN_FILE (default /etc/tesla-linux/pin.hash, root 0600), format
  ``pbkdf2_sha256$<iter>$<salt hex>$<hash hex>``. No file = gate disabled.
* Unlock state: STATE_DIR (default /run/tesla-linux, tmpfs) — resets every boot.
  The marker stores the kernel boot_id so a stale marker can never unlock.
* Entering the right PIN once unlocks the Pi for ALL clients until reboot.

Endpoints:
  GET  /api/pin/check   nginx auth_request: 204 open/unlocked, 401 locked
  GET  /api/pin/status  {set, locked, wait}
  POST /api/pin/unlock  {pin}            200 | 403 wrong | 429 backoff
  POST /api/pin/set     {current?, pin}  200 | 400 bad PIN | 403
  POST /api/pin/clear   {current}        200 | 403
Recovery: ``sudo rm /etc/tesla-linux/pin.hash`` (gate disabled immediately).
"""
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BIND = os.environ.get("TA_BIND") or "127.0.0.1"
PORT = int(os.environ.get("TA_PIN_PORT") or "9095")
PIN_FILE = os.environ.get("TA_PIN_FILE") or "/etc/tesla-linux/pin.hash"
STATE_DIR = os.environ.get("TA_PIN_STATE_DIR") or "/run/tesla-linux"
BOOT_ID_FILE = os.environ.get("TA_BOOT_ID_FILE") or "/proc/sys/kernel/random/boot_id"
ITER = int(os.environ.get("TA_PIN_ITER") or "200000")
FREE_FAILS = 5          # wrong attempts before backoff starts
BACKOFF_BASE = 30       # seconds, doubles per further failure
BACKOFF_MAX = 900
BODY_MAX = 1024
_LOCK = threading.Lock()

if BIND in ("0.0.0.0", "::", "*", "[::]"):
    raise SystemExit("ta_pin_api: TA_BIND must be loopback, not %s" % BIND)


def valid_pin(pin):
    return isinstance(pin, str) and pin.isascii() and pin.isdigit() and 4 <= len(pin) <= 8


def hash_pin(pin, iterations=None, salt=None):
    it = iterations or ITER
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt, it)
    return "pbkdf2_sha256$%d$%s$%s" % (it, salt.hex(), dk.hex())


def verify_pin(pin, stored):
    try:
        algo, it, salt, want = stored.strip().split("$")
        if algo != "pbkdf2_sha256":
            return False
        dk = hashlib.pbkdf2_hmac("sha256", str(pin).encode(), bytes.fromhex(salt), int(it))
        return hmac.compare_digest(dk.hex(), want)
    except Exception:
        return False


def read_hash():
    try:
        with open(PIN_FILE) as f:
            s = f.read().strip()
        return s or None
    except FileNotFoundError:
        return None
    except OSError:
        return "unreadable"  # fail closed: present but unreadable stays locked


def _atomic_write(path, data, mode=0o600):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def boot_id():
    try:
        with open(BOOT_ID_FILE) as f:
            return f.read().strip()
    except OSError:
        return "unknown"


def _unlock_path():
    return os.path.join(STATE_DIR, "pin-unlocked")


def _fail_path():
    return os.path.join(STATE_DIR, "pin-fail.json")


def is_unlocked():
    try:
        with open(_unlock_path()) as f:
            return f.read().strip() == boot_id()
    except OSError:
        return False


def set_unlocked():
    _atomic_write(_unlock_path(), boot_id() + "\n")


def gate_open():
    """True when requests may pass: no PIN set, or unlocked this boot."""
    return read_hash() is None or is_unlocked()


def _fails():
    try:
        with open(_fail_path()) as f:
            d = json.load(f)
        return int(d.get("count", 0)), float(d.get("until", 0))
    except Exception:
        return 0, 0.0


def wait_left(now=None):
    _, until = _fails()
    return max(0, int(round(until - (now or time.time()))))


def record_fail(now=None):
    now = now or time.time()
    count, _ = _fails()
    count += 1
    until = 0.0
    if count >= FREE_FAILS:
        until = now + min(BACKOFF_MAX, BACKOFF_BASE * (2 ** (count - FREE_FAILS)))
    _atomic_write(_fail_path(), json.dumps({"count": count, "until": until}))
    return count, until


def clear_fails():
    try:
        os.unlink(_fail_path())
    except FileNotFoundError:
        pass


def try_pin(pin):
    """Check a PIN against the stored hash with backoff. Returns (code, msg)."""
    stored = read_hash()
    if stored is None:
        return 200, "no PIN set"
    w = wait_left()
    if w > 0:
        return 429, "too many attempts; wait %ds" % w
    if verify_pin(pin, stored):
        clear_fails()
        return 200, "ok"
    count, until = record_fail()
    if until:
        return 403, "wrong PIN; wait %ds" % wait_left()
    return 403, "wrong PIN (%d left before delay)" % (FREE_FAILS - count)


def status():
    stored = read_hash()
    return {"set": stored is not None, "locked": not gate_open(), "wait": wait_left()}


class H(BaseHTTPRequestHandler):
    server_version = "ta_pin_api"

    def log_message(self, *a):
        pass

    def _send(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Cache-Control", "no-store")
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _path(self):
        return (urlparse(self.path).path or "/").rstrip("/") or "/"

    def _json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > BODY_MAX:
            return None
        try:
            d = json.loads(self.rfile.read(n) or b"{}")
            return d if isinstance(d, dict) else None
        except Exception:
            return None

    def do_GET(self):
        p = self._path()
        if p == "/api/pin/check":
            return self._send(204 if gate_open() else 401)
        if p == "/api/pin/status":
            return self._send(200, status())
        self._send(404, {"error": "not found"})

    def do_POST(self):
        p = self._path()
        d = self._json()
        if d is None:
            return self._send(400, {"error": "bad json"})
        with _LOCK:
            if p == "/api/pin/unlock":
                code, msg = try_pin(str(d.get("pin", "")))
                if code == 200:
                    set_unlocked()
                return self._send(code, {"ok": code == 200, "msg": msg, "wait": wait_left()})
            if p in ("/api/pin/set", "/api/pin/clear"):
                if not gate_open():
                    return self._send(403, {"ok": False, "msg": "locked"})
                if read_hash() is not None:
                    code, msg = try_pin(str(d.get("current", "")))
                    if code != 200:
                        return self._send(code, {"ok": False, "msg": "current PIN: " + msg})
                if p == "/api/pin/clear":
                    try:
                        os.unlink(PIN_FILE)
                    except FileNotFoundError:
                        pass
                    return self._send(200, {"ok": True, "msg": "PIN cleared"})
                new = d.get("pin")
                if not valid_pin(new):
                    return self._send(400, {"ok": False, "msg": "PIN must be 4-8 digits"})
                _atomic_write(PIN_FILE, hash_pin(new) + "\n")
                set_unlocked()  # the person who set it stays unlocked this boot
                return self._send(200, {"ok": True, "msg": "PIN set"})
        self._send(404, {"error": "not found"})


def main():
    srv = ThreadingHTTPServer((BIND, PORT), H)
    srv.daemon_threads = True
    srv.serve_forever()


if __name__ == "__main__":
    main()
