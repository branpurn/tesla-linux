#!/usr/bin/env python3
"""Tesla Linux — loopback HTTP /api/wlan + /api/reboot + /api/mode.

Stdlib only. Binds TA_BIND (default 127.0.0.1) — never 0.0.0.0.
nginx on the AP/station LAN proxies origin-relative /api/wlan, /api/reboot,
and /api/mode here.

POST JSON {ssid, psk} kicks save-wlan in a background thread and returns 200
without waiting on WAIT_SEC. GET /api/wlan returns {ssids:[...]} (empty on scan fail).
POST /api/reboot kicks a real system reboot in a background thread and returns 200.

GET|POST /api/mode persists WAN-rebroadcast intent then kicks tesla-linux-wlan
wan-ap / wan-off in a background thread (200 after persist+kick-started).
Default mode is station. GET still reports nat:false and uplink none until
Infra status is readable without dual-writing the helper.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BIND = os.environ.get("TA_BIND") or "127.0.0.1"
PORT = int(os.environ.get("TA_WLAN_PORT") or "9094")
WLAN = os.environ.get("TA_WLAN_BIN") or "/usr/local/sbin/tesla-linux-wlan"
NMCLI = os.environ.get("TA_NMCLI") or "nmcli"
# Optional override for tests; default is systemctl reboot then /sbin/reboot.
REBOOT_BIN = os.environ.get("TA_REBOOT_BIN") or ""
BODY_MAX = 8192
# Persist WAN-rebroadcast intent. Override in tests; default is on-image.
MODE_FILE = os.environ.get("TA_MODE_FILE") or "/etc/tesla-linux/mode.json"
# Factory AP lock until a later lock moves it. Skeleton does not probe hostapd.
AP_SSID = os.environ.get("TA_AP_SSID") or "TeslaLinux"
AP_ADDR = os.environ.get("TA_AP_ADDR") or "10.42.0.1/24"
MODES = ("station", "wan_rebroadcast")
DEFAULT_MODE = "station"
# Primary helper names (not aliases wan-rebroadcast / wan-up / wan-down).
MODE_KICK = {"wan_rebroadcast": "wan-ap", "station": "wan-off"}
_MODE_LOCK = threading.Lock()

if BIND in ("0.0.0.0", "::", "*", "[::]"):
    raise SystemExit("ta_wlan_api: TA_BIND must be loopback, not %s" % BIND)


def _norm_path(raw):
    p = urlparse(raw).path or "/"
    if p.endswith("/") and p != "/":
        p = p.rstrip("/")
    return p


def _is_wlan_path(path):
    return path in ("/api/wlan", "/")


def _is_reboot_path(path):
    return path == "/api/reboot"


def _is_mode_path(path):
    return path == "/api/mode"


def _read_mode():
    """Persisted intent, else station. Corrupt/missing file is station."""
    try:
        with open(MODE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and data.get("mode") in MODES:
            return data["mode"]
    except (OSError, ValueError, json.JSONDecodeError):
        pass
    return DEFAULT_MODE


def _write_mode(mode):
    directory = os.path.dirname(MODE_FILE) or "."
    os.makedirs(directory, exist_ok=True)
    tmp = MODE_FILE + ".tmp"
    body = json.dumps({"mode": mode}, separators=(",", ":")) + "\n"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(body)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, MODE_FILE)


def _mode_status():
    with _MODE_LOCK:
        mode = _read_mode()
    return {
        "mode": mode,
        "ap": {"up": True, "ssid": AP_SSID, "addr": AP_ADDR},
        "uplink": {"kind": "none", "iface": None, "addr": None},
        "nat": False,
    }

def _ssid_ok(ssid):
    if not isinstance(ssid, str):
        return False
    if "\n" in ssid or "\r" in ssid:
        return False
    return 1 <= len(ssid) <= 32


def _psk_ok(psk):
    if psk is None:
        return True
    if not isinstance(psk, str):
        return False
    if "\n" in psk or "\r" in psk:
        return False
    return psk == "" or 8 <= len(psk) <= 63


def _scan_ssids():
    try:
        out = subprocess.run(
            [NMCLI, "-t", "-f", "SSID", "device", "wifi", "list"],
            capture_output=True, text=True, timeout=8, check=False,
        )
        if out.returncode != 0:
            return []
        seen, ssids = set(), []
        for line in out.stdout.splitlines():
            ssid = line.replace("\\:", ":").replace("\\\\", "\\").strip()
            if not ssid or ssid in seen:
                continue
            seen.add(ssid)
            ssids.append(ssid)
        return ssids
    except (OSError, subprocess.SubprocessError):
        return []


def _kick_save(ssid, psk):
    cmd = [WLAN, "save-wlan", ssid]
    if psk:
        cmd.append(psk)

    def run():
        try:
            subprocess.run(cmd, check=False, timeout=120)
        except (OSError, subprocess.SubprocessError):
            pass

    threading.Thread(target=run, name="save-wlan", daemon=True).start()


def _kick_reboot():
    """Kick a real Pi reboot after the HTTP response can flush."""

    def run():
        time.sleep(0.3)
        cmds = []
        if REBOOT_BIN:
            cmds.append([REBOOT_BIN])
        cmds.extend([["systemctl", "reboot"], ["/sbin/reboot"], ["/usr/sbin/reboot"]])
        for cmd in cmds:
            try:
                subprocess.run(cmd, check=False, timeout=30)
                return
            except (OSError, subprocess.SubprocessError):
                continue

    threading.Thread(target=run, name="reboot", daemon=True).start()


def _kick_wan(mode):
    """Kick wan-ap / wan-off after persist. Do not wait on NAT."""
    cmd = [WLAN, MODE_KICK[mode]]

    def run():
        try:
            out = subprocess.run(
                cmd, check=False, timeout=120, capture_output=True, text=True,
            )
            if out.returncode != 0:
                sys.stderr.write(
                    "ta_wlan_api: %s exited %s\n" % (" ".join(cmd), out.returncode)
                )
                if out.stderr:
                    sys.stderr.write(out.stderr if out.stderr.endswith("\n") else out.stderr + "\n")
        except (OSError, subprocess.SubprocessError) as exc:
            sys.stderr.write("ta_wlan_api: %s failed: %s\n" % (" ".join(cmd), exc))

    threading.Thread(target=run, name="wan-mode", daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("ta_wlan_api: " + (fmt % args) + "\n")

    def __getattr__(self, name):
        if name.startswith("do_"):
            return self._method_not_allowed
        raise AttributeError(name)

    def _drain_body(self):
        try:
            n = int(self.headers.get("Content-Length") or "0")
            if n > 0:
                self.rfile.read(min(n, BODY_MAX))
        except (ValueError, OSError):
            pass

    def _method_not_allowed(self):
        self._drain_body()
        path = _norm_path(self.path)
        allow = "POST" if _is_reboot_path(path) else "GET, POST"
        self._json(405, {"error": "method not allowed"}, extra={"Allow": allow})

    def _json(self, code, obj, extra=None):
        body = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = _norm_path(self.path)
        if _is_reboot_path(path):
            self._json(405, {"error": "method not allowed"}, extra={"Allow": "POST"})
            return
        if _is_mode_path(path):
            self._json(200, _mode_status())
            return
        if not _is_wlan_path(path):
            self._json(404, {"error": "not found"})
            return
        self._json(200, {"ssids": _scan_ssids()})

    def do_POST(self):
        path = _norm_path(self.path)
        if _is_reboot_path(path):
            self._drain_body()
            _kick_reboot()
            self._json(200, {"ok": True})
            return
        if _is_mode_path(path):
            self._post_mode()
            return
        if not _is_wlan_path(path):
            self._drain_body()
            self._json(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._json(400, {"error": "invalid Content-Length"})
            return
        if n <= 0 or n > BODY_MAX:
            self._json(400, {"error": "expected JSON {ssid, psk}"})
            return
        raw = self.rfile.read(n)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"error": "expected JSON {ssid, psk}"})
            return
        if not isinstance(data, dict):
            self._json(400, {"error": "expected JSON {ssid, psk}"})
            return
        if "ssid" not in data:
            self._json(400, {"error": "missing ssid"})
            return
        ssid = data.get("ssid")
        psk = data.get("psk", "")
        if not _ssid_ok(ssid):
            self._json(400, {"error": "ssid must be 1-32 chars with no newlines"})
            return
        if not _psk_ok(psk):
            self._json(400, {"error": "psk must be empty or 8-63 chars"})
            return
        _kick_save(ssid, psk or "")
        self._json(200, {"ok": True})

    def _post_mode(self):
        try:
            n = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._json(400, {"error": "invalid Content-Length"})
            return
        if n <= 0 or n > BODY_MAX:
            self._json(400, {"error": "expected JSON {mode}"})
            return
        raw = self.rfile.read(n)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"error": "expected JSON {mode}"})
            return
        if not isinstance(data, dict):
            self._json(400, {"error": "expected JSON {mode}"})
            return
        if "mode" not in data:
            self._json(400, {"error": "missing mode"})
            return
        mode = data.get("mode")
        if not isinstance(mode, str) or mode not in MODES:
            self._json(400, {"error": "mode must be station or wan_rebroadcast"})
            return
        try:
            with _MODE_LOCK:
                _write_mode(mode)
        except OSError:
            self._json(500, {"error": "could not persist mode"})
            return
        _kick_wan(mode)
        self._json(200, {"ok": True, "mode": mode})

def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    sys.stderr.write("ta_wlan_api: listen %s:%s\n" % (BIND, PORT))
    httpd.serve_forever()


def _selftest():
    """Contract checks. No hardware. Bind stays loopback."""
    import http.client
    import shutil
    import tempfile

    fail = 0

    def check(ok, msg):
        nonlocal fail
        if not ok:
            sys.stderr.write("FAIL: %s\n" % msg)
            fail += 1

    # TA_BIND=0.0.0.0 must refuse to start (import-time guard).
    env = os.environ.copy()
    env["TA_BIND"] = "0.0.0.0"
    env["TA_WLAN_PORT"] = "0"
    refuse = subprocess.run(
        [sys.executable, os.path.abspath(__file__)],
        env=env, capture_output=True, text=True, timeout=8,
    )
    check(refuse.returncode != 0, "TA_BIND=0.0.0.0 must exit non-zero")
    check("loopback" in (refuse.stderr or ""), "0.0.0.0 refusal mentions loopback")

    tmp = tempfile.mkdtemp(prefix="tl-mode-")
    mode_path = os.path.join(tmp, "mode.json")
    argv_log = os.path.join(tmp, "wlan-argv.log")
    wlan_bin = os.path.join(tmp, "wlan-bin")
    with open(wlan_bin, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\nprintf '%%s\\n' \"$*\" >> '%s'\nexit 0\n" % argv_log)
    os.chmod(wlan_bin, 0o755)

    def argv_lines():
        if not os.path.exists(argv_log):
            return []
        with open(argv_log, encoding="utf-8") as f:
            return [ln.strip() for ln in f if ln.strip()]

    def wait_argv(n, timeout=2.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            lines = argv_lines()
            if len(lines) >= n:
                return lines
            time.sleep(0.02)
        return argv_lines()

    global MODE_FILE, REBOOT_BIN, WLAN
    MODE_FILE = mode_path
    REBOOT_BIN = "/bin/true"
    WLAN = wlan_bin

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    host, port = httpd.server_address
    thread = threading.Thread(target=httpd.serve_forever, name="selftest-httpd", daemon=True)
    thread.start()

    def req(method, path, body=None, headers=None):
        conn = http.client.HTTPConnection(host, port, timeout=5)
        hdrs = headers or {}
        payload = None
        if body is not None:
            payload = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
            hdrs = dict(hdrs)
            hdrs.setdefault("Content-Type", "application/json")
            hdrs["Content-Length"] = str(len(payload))
        conn.request(method, path, body=payload, headers=hdrs)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        try:
            obj = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            obj = None
        return resp.status, obj, raw, resp.getheader("Allow")

    try:
        status, obj, _, _ = req("GET", "/api/mode")
        check(status == 200, "GET /api/mode default status")
        check(obj == {
            "mode": "station",
            "ap": {"up": True, "ssid": "TeslaLinux", "addr": "10.42.0.1/24"},
            "uplink": {"kind": "none", "iface": None, "addr": None},
            "nat": False,
        }, "GET /api/mode default JSON")
        check(not os.path.exists(mode_path), "default station does not write mode.json")

        status, obj, _, _ = req("POST", "/api/mode", {"mode": "wan_rebroadcast"})
        check(status == 200, "POST wan_rebroadcast status")
        check(obj == {"ok": True, "mode": "wan_rebroadcast"}, "POST wan_rebroadcast JSON")
        with open(mode_path, encoding="utf-8") as f:
            persisted = json.load(f)
        check(persisted == {"mode": "wan_rebroadcast"}, "persist wan_rebroadcast")
        check(wait_argv(1) == ["wan-ap"], "POST wan_rebroadcast kicks wan-ap")

        status, obj, _, _ = req("GET", "/api/mode")
        check(status == 200, "GET after persist status")
        check(obj["mode"] == "wan_rebroadcast", "GET reports persisted mode")
        check(obj["ap"]["up"] is True and obj["ap"]["ssid"] == "TeslaLinux", "factory AP lock")
        check(obj["ap"]["addr"] == "10.42.0.1/24", "factory AP addr")
        check(obj["uplink"] == {"kind": "none", "iface": None, "addr": None}, "skeleton uplink none")
        check(obj["nat"] is False, "skeleton nat false")

        status, obj, _, _ = req("POST", "/api/mode", {"mode": "station"})
        check(status == 200 and obj == {"ok": True, "mode": "station"}, "POST station")
        status, obj, _, _ = req("GET", "/api/mode")
        check(obj["mode"] == "station", "GET after station persist")
        check(wait_argv(2) == ["wan-ap", "wan-off"], "POST station kicks wan-off")
        check(all(line in ("wan-ap", "wan-off") for line in argv_lines()), "primary names, not aliases")

        status, obj, _, _ = req("POST", "/api/mode", {"mode": "lte"})
        check(status == 400, "invalid mode 400")
        check(obj and "error" in obj, "invalid mode error")
        status, obj, _, _ = req("GET", "/api/mode")
        check(obj["mode"] == "station", "invalid POST does not change mode")
        time.sleep(0.1)
        check(argv_lines() == ["wan-ap", "wan-off"], "invalid POST does not kick")

        missing = os.path.join(tmp, "missing-wlan")
        WLAN = missing
        status, obj, _, _ = req("POST", "/api/mode", {"mode": "wan_rebroadcast"})
        check(status == 200 and obj == {"ok": True, "mode": "wan_rebroadcast"}, "missing helper still 200")
        with open(mode_path, encoding="utf-8") as f:
            check(json.load(f) == {"mode": "wan_rebroadcast"}, "persist when helper missing")

        sleeper = os.path.join(tmp, "wlan-sleep")
        with open(sleeper, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nsleep 3\nexit 0\n")
        os.chmod(sleeper, 0o755)
        WLAN = sleeper
        t0 = time.monotonic()
        status, obj, _, _ = req("POST", "/api/mode", {"mode": "station"})
        elapsed = time.monotonic() - t0
        check(status == 200 and obj == {"ok": True, "mode": "station"}, "slow helper still 200")
        check(elapsed < 1.0, "POST returns before helper finishes")
        WLAN = wlan_bin

        status, obj, _, _ = req("POST", "/api/mode", {"ssid": "x"})
        check(status == 400 and obj.get("error") == "missing mode", "missing mode")
        status, obj, _, _ = req("POST", "/api/mode", b"not-json")
        check(status == 400, "non-JSON POST 400")
        status, obj, _, allow = req("PUT", "/api/mode")
        check(status == 405 and allow == "GET, POST", "PUT /api/mode 405")

        status, obj, _, _ = req("GET", "/api/wlan")
        check(status == 200 and isinstance(obj, dict) and "ssids" in obj, "GET /api/wlan kept")
        status, obj, _, _ = req("POST", "/api/wlan", {"ssid": "DemoNet", "psk": "password1"})
        check(status == 200 and obj == {"ok": True}, "POST /api/wlan kept")
        status, obj, _, _ = req("POST", "/api/reboot", {})
        check(status == 200 and obj == {"ok": True}, "POST /api/reboot kept")
        status, obj, _, allow = req("GET", "/api/reboot")
        check(status == 405 and allow == "POST", "GET /api/reboot still 405")
        status, obj, _, _ = req("GET", "/api/nope")
        check(status == 404, "unknown path 404")
    finally:
        httpd.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)

    if fail:
        sys.stderr.write("ta_wlan_api selftest FAILED (%s)\n" % fail)
        return 1
    sys.stderr.write("ta_wlan_api selftest OK\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("--selftest", "selftest"):
        sys.exit(_selftest())
    main()
