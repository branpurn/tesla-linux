#!/usr/bin/env python3
"""Tesla Linux — loopback HTTP /api/wlan → tesla-linux-wlan save-wlan / nmcli scan.

Stdlib only. Binds TA_BIND (default 127.0.0.1) — never 0.0.0.0.
nginx on the AP/station LAN proxies origin-relative /api/wlan here.

POST JSON {ssid, psk} kicks save-wlan in a background thread and returns 200
without waiting on WAIT_SEC. GET returns {ssids:[...]} (empty list on scan fail).
"""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BIND = os.environ.get("TA_BIND") or "127.0.0.1"
PORT = int(os.environ.get("TA_WLAN_PORT") or "9094")
WLAN = os.environ.get("TA_WLAN_BIN") or "/usr/local/sbin/tesla-linux-wlan"
NMCLI = os.environ.get("TA_NMCLI") or "nmcli"
BODY_MAX = 8192

if BIND in ("0.0.0.0", "::", "*", "[::]"):
    raise SystemExit("ta_wlan_api: TA_BIND must be loopback, not %s" % BIND)


def _norm_path(raw):
    p = urlparse(raw).path or "/"
    if p.endswith("/") and p != "/":
        p = p.rstrip("/")
    return p


def _is_wlan_path(path):
    return path in ("/api/wlan", "/")


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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("ta_wlan_api: " + (fmt % args) + "\n")

    def __getattr__(self, name):
        if name.startswith("do_"):
            return self._method_not_allowed
        raise AttributeError(name)

    def _method_not_allowed(self):
        try:
            n = int(self.headers.get("Content-Length") or "0")
            if n > 0:
                self.rfile.read(min(n, BODY_MAX))
        except (ValueError, OSError):
            pass
        self._json(405, {"error": "method not allowed"}, extra={"Allow": "GET, POST"})

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

    def _reject_path(self):
        if not _is_wlan_path(_norm_path(self.path)):
            self._json(404, {"error": "not found"})
            return True
        return False

    def do_GET(self):
        if self._reject_path():
            return
        self._json(200, {"ssids": _scan_ssids()})

    def do_POST(self):
        if self._reject_path():
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


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    sys.stderr.write("ta_wlan_api: listen %s:%s\n" % (BIND, PORT))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
