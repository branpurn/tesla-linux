#!/usr/bin/env python3
"""Tesla Linux adaptive screen API (loopback, behind the nginx PIN gate).

GET  /api/screen          -> {"w","h","target"}  current X size + guard target
POST /api/screen {w,h}    -> resize :0 to WxH (8-aligned, clamped), persist the
                             target for tl-screen-guard, restart the encoder.
POST /api/screen {"reset":true} -> back to the default 1088x832.

State: /run/tesla-linux/screen-size ("WxH", tmpfs: every boot starts 1088x832).
Rate limit: one applied change per TA_SCREEN_MIN_S seconds (429 otherwise).
"""
import json, os, re, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("TA_BIND", "127.0.0.1")
PORT = int(os.environ.get("TA_SCREEN_PORT", "9096"))
USER = os.environ.get("TA_SCREEN_USER", "teslalinux")
OUT = os.environ.get("TA_SCREEN_OUTPUT", "HDMI-1")
STATE_DIR = os.environ.get("TA_SCREEN_STATE_DIR", "/run/tesla-linux")
STATE = os.path.join(STATE_DIR, "screen-size")
LOCK = os.path.join(STATE_DIR, "screen.lock")
MIN_S = float(os.environ.get("TA_SCREEN_MIN_S", "3"))
DEF_W, DEF_H = 1088, 832
MIN_W, MIN_H, MAX_W, MAX_H = 640, 480, 1920, 1080
DRY = os.environ.get("TA_SCREEN_DRY") == "1"   # selftest: no xrandr/systemctl

_mu = threading.Lock()
_last = 0.0


def clamp(w, h):
    w = int(round(float(w) / 8.0)) * 8
    h = int(round(float(h) / 8.0)) * 8
    return max(MIN_W, min(MAX_W, w)), max(MIN_H, min(MAX_H, h))


def read_target():
    try:
        m = re.fullmatch(r"(\d+)x(\d+)", open(STATE).read().strip())
        if m:
            return clamp(int(m.group(1)), int(m.group(2)))
    except OSError:
        pass
    return DEF_W, DEF_H


def write_target(w, h):
    os.makedirs(STATE_DIR, exist_ok=True)
    os.chmod(STATE_DIR, 0o755)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        f.write("%dx%d\n" % (w, h))
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATE)


def as_user(*cmd):
    return subprocess.run(["runuser", "-u", USER, "--", "env", "DISPLAY=:0"] + list(cmd),
                          capture_output=True, text=True, timeout=15)


def current():
    if DRY:
        return read_target()
    r = as_user("xdpyinfo")
    m = re.search(r"dimensions:\s+(\d+)x(\d+)", r.stdout or "")
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def apply(w, h):
    write_target(w, h)
    if DRY:
        return True
    # Same lock as tl-screen-guard so the two never interleave the two-step.
    open(LOCK, "a").close()
    os.chmod(LOCK, 0o666)
    script = ("exec 9>%s; flock -w 10 9; "
              "xrandr --fb 1920x1080 --output %s --mode 1920x1080 --scale 1x1; sleep 1; "
              "xrandr --fb %dx%d --output %s --mode 1920x1080 --scale-from %dx%d --primary"
              % (LOCK, OUT, w, h, OUT, w, h))
    as_user("sh", "-c", script)
    ok = current() == (w, h)
    # Encoder pins its geometry at start (reads STATE) -> restart to pick it up.
    subprocess.run(["systemctl", "restart", "--no-block", "tesla-linux-display.service"],
                   capture_output=True, timeout=15)
    return ok


class H(BaseHTTPRequestHandler):
    def _out(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, fmt, *a):
        print("screen-api: " + fmt % a, flush=True)

    def do_GET(self):
        if self.path.split("?")[0] != "/api/screen":
            return self._out(404, {"error": "not found"})
        w, h = current()
        tw, th = read_target()
        self._out(200, {"w": w, "h": h, "target": "%dx%d" % (tw, th)})

    def do_POST(self):
        global _last
        if self.path.split("?")[0] != "/api/screen":
            return self._out(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 1024:
                return self._out(413, {"error": "too large"})
            d = json.loads(self.rfile.read(n) or b"{}")
            if d.get("reset"):
                w, h = DEF_W, DEF_H
            else:
                w, h = clamp(d["w"], d["h"])
        except Exception:
            return self._out(400, {"error": "need {w,h} or {reset:true}"})
        with _mu:
            if (w, h) == read_target() and current() == (w, h):
                return self._out(200, {"w": w, "h": h, "changed": False})
            wait = MIN_S - (time.monotonic() - _last)
            if wait > 0:
                self.send_response(429)
                self.send_header("Retry-After", str(int(wait) + 1))
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            _last = time.monotonic()
            ok = apply(w, h)
        print("screen-api: applied %dx%d ok=%s" % (w, h, ok), flush=True)
        self._out(200 if ok else 500, {"w": w, "h": h, "changed": True, "ok": ok})


if __name__ == "__main__":
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
