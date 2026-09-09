#!/usr/bin/env python3
"""HTTP mock of /sockets/* + Chrome CDP: broadway without VideoDecoder, webcodecs with it."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_accept(key: str) -> str:
    raw = hashlib.sha1((key + GUID).encode("utf-8")).digest()
    import base64
    return base64.b64encode(raw).decode("ascii")


def ws_frame(opcode: int, payload: bytes, mask: bool = False) -> bytes:
    header = [0x80 | opcode]
    n = len(payload)
    key = b""
    if mask:
        key = os.urandom(4)
        payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", n))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", n))
        return bytes(header) + key + payload
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header.extend(struct.pack("!H", n))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", n))
    return bytes(header) + payload


def ws_read_frame(sock: socket.socket) -> tuple[int, bytes] | None:
    hdr = sock.recv(2)
    if len(hdr) < 2:
        return None
    opcode = hdr[0] & 0x0F
    masked = hdr[1] & 0x80
    n = hdr[1] & 0x7F
    if n == 126:
        n = struct.unpack("!H", sock.recv(2))[0]
    elif n == 127:
        n = struct.unpack("!Q", sock.recv(8))[0]
    key = sock.recv(4) if masked else b""
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    if masked:
        data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
    return opcode, data


def split_annexb(buf: bytes) -> list[bytes]:
    starts: list[int] = []
    i = 0
    while i + 3 < len(buf):
        if buf[i] == 0 and buf[i + 1] == 0 and buf[i + 2] == 0 and buf[i + 3] == 1:
            starts.append(i)
            i += 4
            continue
        if buf[i] == 0 and buf[i + 1] == 0 and buf[i + 2] == 1:
            starts.append(i)
            i += 3
            continue
        i += 1
    units = []
    for idx, s in enumerate(starts):
        e = starts[idx + 1] if idx + 1 < len(starts) else len(buf)
        if e > s:
            units.append(buf[s:e])
    return units or [buf]


def nal_type(unit: bytes) -> int:
    off = 0
    if len(unit) >= 4 and unit[0:4] == b"\x00\x00\x00\x01":
        off = 4
    elif len(unit) >= 3 and unit[0:3] == b"\x00\x00\x01":
        off = 3
    if off >= len(unit):
        return -1
    return unit[off] & 0x1F


def access_units(buf: bytes) -> list[bytes]:
    """Group NAL units into AUs: config (7/8) together; VCL starts a new AU."""
    aus: list[bytes] = []
    cur = bytearray()
    for u in split_annexb(buf):
        t = nal_type(u)
        if t in (7, 8, 6):
            if cur and nal_type(bytes(cur)) in (1, 5):
                aus.append(bytes(cur))
                cur = bytearray()
            cur.extend(u)
            continue
        if t in (1, 5):
            if cur and nal_type(bytes(cur)) in (1, 5):
                aus.append(bytes(cur))
                cur = bytearray()
            cur.extend(u)
            aus.append(bytes(cur))
            cur = bytearray()
            continue
        cur.extend(u)
    if cur:
        aus.append(bytes(cur))
    return aus


def make_h264(path: str) -> None:
    cmd = [
        "ffmpeg", "-y", "-f", "lavfi",
        "-i", "color=c=red:s=320x240:r=10:d=2",
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-profile:v", "baseline", "-level", "3.0",
        "-bf", "0", "-coder", "0", "-g", "5", "-keyint_min", "5",
        "-x264-params", "cabac=0:bframes=0:weightp=0:repeat-headers=1",
        "-an", "-f", "h264", path,
    ]
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class DisplayHub:
    def __init__(self, aus: list[bytes]):
        self.aus = aus
        self.clients: list[socket.socket] = []
        self.lock = threading.Lock()
        self.stop = False

    def add(self, sock: socket.socket) -> None:
        with self.lock:
            self.clients.append(sock)

    def drop(self, sock: socket.socket) -> None:
        with self.lock:
            if sock in self.clients:
                self.clients.remove(sock)
        try:
            sock.close()
        except OSError:
            pass

    def pump(self) -> None:
        i = 0
        while not self.stop:
            if not self.clients:
                time.sleep(0.05)
                continue
            au = self.aus[i % len(self.aus)]
            i += 1
            dead = []
            with self.lock:
                cl = list(self.clients)
            for s in cl:
                try:
                    s.sendall(ws_frame(0x2, au))
                except OSError:
                    dead.append(s)
            for s in dead:
                self.drop(s)
            time.sleep(0.08)


def make_handler(www: str, hub: DisplayHub):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            if self.headers.get("Upgrade", "").lower() == "websocket":
                self._ws()
                return
            path = self.path.split("?", 1)[0]
            if path == "/":
                path = "/desktop.html"
            fs = os.path.normpath(os.path.join(www, path.lstrip("/")))
            if not fs.startswith(os.path.abspath(www)) or not os.path.isfile(fs):
                self.send_error(404)
                return
            ctype = "application/octet-stream"
            if fs.endswith(".html"):
                ctype = "text/html; charset=utf-8"
            elif fs.endswith(".js"):
                ctype = "application/javascript"
            elif fs.endswith(".wasm"):
                ctype = "application/wasm"
            data = open(fs, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _ws(self):
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                self.send_error(400)
                return
            path = self.path.split("?", 1)[0]
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", ws_accept(key))
            self.end_headers()
            sock = self.connection
            if path.endswith("/display"):
                hub.add(sock)
                try:
                    while True:
                        fr = ws_read_frame(sock)
                        if fr is None:
                            break
                finally:
                    hub.drop(sock)
                return
            # touch / audio: accept and idle
            try:
                while ws_read_frame(sock) is not None:
                    pass
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass

    return H


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Cdp:
    def __init__(self, url: str):
        self.sock = self._connect(url)
        self.buf = b""
        self.n = 0

    def _connect(self, url: str) -> socket.socket:
        # ws://127.0.0.1:port/devtools/page/ID
        assert url.startswith("ws://")
        rest = url[5:]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        port = int(port or 80)
        path = "/" + path
        sock = socket.create_connection((host, port), timeout=15)
        key = "dGhlIHNhbXBsZSBub25jZQ=="
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {hostport}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        sock.sendall(req.encode())
        hdr = b""
        while b"\r\n\r\n" not in hdr:
            chunk = sock.recv(4096)
            if not chunk:
                raise RuntimeError("CDP handshake closed")
            hdr += chunk
        if b" 101 " not in hdr.split(b"\r\n", 1)[0]:
            raise RuntimeError("CDP handshake failed: " + hdr[:200].decode("latin1"))
        leftover = hdr.split(b"\r\n\r\n", 1)[1]
        self.buf = leftover
        sock.settimeout(15)
        return sock

    def send(self, method: str, params=None):
        self.n += 1
        msg = {"id": self.n, "method": method, "params": params or {}}
        self.sock.sendall(ws_frame(0x1, json.dumps(msg).encode(), mask=True))
        return self.n

    def recv(self) -> dict:
        while True:
            if len(self.buf) >= 2:
                opcode = self.buf[0] & 0x0F
                masked = self.buf[1] & 0x80
                n = self.buf[1] & 0x7F
                hdr = 2
                if n == 126:
                    if len(self.buf) < 4:
                        self.buf += self.sock.recv(4096)
                        continue
                    n = struct.unpack("!H", self.buf[2:4])[0]
                    hdr = 4
                elif n == 127:
                    if len(self.buf) < 10:
                        self.buf += self.sock.recv(4096)
                        continue
                    n = struct.unpack("!Q", self.buf[2:10])[0]
                    hdr = 10
                mlen = 4 if masked else 0
                need = hdr + mlen + n
                if len(self.buf) < need:
                    self.buf += self.sock.recv(need - len(self.buf) + 4096)
                    continue
                payload = self.buf[hdr + mlen : need]
                if masked:
                    key = self.buf[hdr : hdr + 4]
                    payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
                self.buf = self.buf[need:]
                if opcode == 0x1:
                    return json.loads(payload.decode())
                if opcode == 0x8:
                    raise RuntimeError("CDP closed")
                continue
            more = self.sock.recv(4096)
            if not more:
                raise RuntimeError("CDP eof")
            self.buf += more

    def call(self, method: str, params=None, timeout=20.0) -> dict:
        mid = self.send(method, params)
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.recv()
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result") or {}
        raise TimeoutError(method)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def chrome_bin() -> str:
    for p in ("/usr/local/bin/google-chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"):
        if os.path.isfile(p):
            return p
    raise SystemExit("no chrome")


def wait_json(url: str, tries=50):
    last = None
    for _ in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                return json.load(r)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            last = e
            time.sleep(0.1)
    raise RuntimeError(f"cdp not up: {last}")


def run_case(page_url: str, cdp_port: int, chrome: str, user_data: str, expect_kind: str, strip_wc: bool) -> None:
    args = [
        chrome, "--headless=new", "--no-sandbox", "--disable-gpu",
        "--disable-dev-shm-usage", f"--remote-debugging-port={cdp_port}",
        f"--user-data-dir={user_data}", "--remote-allow-origins=*",
        "about:blank",
    ]
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ver = wait_json(f"http://127.0.0.1:{cdp_port}/json/version")
        ws = ver.get("webSocketDebuggerUrl")
        if not ws:
            tabs = wait_json(f"http://127.0.0.1:{cdp_port}/json/list")
            ws = tabs[0]["webSocketDebuggerUrl"]
        cdp = Cdp(ws)
        cdp.call("Page.enable")
        cdp.call("Runtime.enable")
        if strip_wc:
            cdp.call(
                "Page.addScriptToEvaluateOnNewDocument",
                {"source": "delete window.VideoDecoder; delete window.EncodedVideoChunk;"},
            )
        cdp.call("Page.navigate", {"url": page_url})
        hud = ""
        err = ""
        saw = False
        for _ in range(80):
            time.sleep(0.25)
            r = cdp.call(
                "Runtime.evaluate",
                {
                    "expression": (
                        "({hud: (document.getElementById('hud')||{}).textContent||'', "
                        "hasWC: ('VideoDecoder' in window), "
                        "el: !!(document.getElementById('c')&&document.getElementById('feed')"
                        "&&document.getElementById('reboot')&&document.getElementById('hide'))})"
                    ),
                    "returnByValue": True,
                },
            )
            val = (r.get("result") or {}).get("value") or {}
            hud = val.get("hud") or ""
            if "setup failed" in hud or "decoder error" in hud:
                err = hud
                break
            if (
                val.get("el")
                and expect_kind in hud
                and "frames" in hud
                and "NO WebCodecs" not in hud
            ):
                print(f"  {expect_kind}: hud={hud!r} hasWC={val.get('hasWC')}")
                saw = True
                break
        cdp.close()
        if not saw:
            raise SystemExit(f"{expect_kind} failed hud={hud!r} err={err!r}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def main() -> None:
    tmp = tempfile.mkdtemp(prefix="tl-broadway-")
    try:
        h264 = os.path.join(tmp, "clip.h264")
        make_h264(h264)
        aus = access_units(open(h264, "rb").read())
        if len(aus) < 2:
            raise SystemExit(f"too few AUs: {len(aus)}")
        types = {nal_type(u) for u in split_annexb(open(h264, "rb").read())}
        if 7 not in types or 5 not in types:
            raise SystemExit(f"fixture missing SPS/IDR types={types}")

        www = os.path.join(tmp, "www")
        os.makedirs(www)
        shutil.copy(os.path.join(HERE, "desktop.html"), os.path.join(www, "desktop.html"))
        shutil.copy(os.path.join(HERE, "probe.html"), os.path.join(www, "probe.html"))
        shutil.copytree(os.path.join(HERE, "broadway"), os.path.join(www, "broadway"))
        shutil.copy(os.path.join(HERE, "broadway", "avc.wasm"), os.path.join(www, "avc.wasm"))

        hub = DisplayHub(aus)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(www, hub))
        port = httpd.server_address[1]
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        threading.Thread(target=hub.pump, daemon=True).start()

        chrome = chrome_bin()
        page = f"http://127.0.0.1:{port}/desktop.html"
        print(f"serving {page} aus={len(aus)}")

        # Broadway: strip VideoDecoder (HTTP Tesla-browser / insecure context).
        run_case(page, free_port(), chrome, os.path.join(tmp, "c1"), "broadway", True)
        # WebCodecs: localhost is a secure context; VideoDecoder stays.
        run_case(page, free_port(), chrome, os.path.join(tmp, "c2"), "webcodecs", False)

        # probe must still render
        html = urllib.request.urlopen(f"http://127.0.0.1:{port}/probe.html", timeout=5).read().decode()
        if "desktop Broadway fallback" not in html:
            raise SystemExit("probe note missing from served html")
        print("probe.html served with broadway note")
        hub.stop = True
        httpd.shutdown()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
