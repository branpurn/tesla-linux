#!/usr/bin/env python3
"""Host-side selftest for the boot-PIN gate (ta_pin_api.py + installer wiring)."""
import importlib.util, json, os, socket, sys, tempfile, threading, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="tl-pin-")
os.environ.update(TA_PIN_FILE=os.path.join(tmp, "etc/pin.hash"),
                  TA_PIN_STATE_DIR=os.path.join(tmp, "run"),
                  TA_BOOT_ID_FILE=os.path.join(tmp, "boot_id"), TA_PIN_ITER="1000")
open(os.environ["TA_BOOT_ID_FILE"], "w").write("boot-A\n")
spec = importlib.util.spec_from_file_location("pin", os.path.join(HERE, "ta_pin_api.py"))
pin = importlib.util.module_from_spec(spec); spec.loader.exec_module(pin)
fails = 0
def ok(name, cond):
    global fails
    print(("PASS: " if cond else "FAIL: ") + name)
    fails += 0 if cond else 1

# hash / verify
h = pin.hash_pin("1234")
ok("hash format", h.startswith("pbkdf2_sha256$1000$") and "1234" not in h)
ok("verify right", pin.verify_pin("1234", h))
ok("verify wrong", not pin.verify_pin("4321", h))
ok("salted", pin.hash_pin("1234") != h)
ok("verify garbage", not pin.verify_pin("1234", "nonsense"))
ok("valid_pin", pin.valid_pin("1234") and pin.valid_pin("12345678") and not pin.valid_pin("123")
   and not pin.valid_pin("123456789") and not pin.valid_pin("12a4") and not pin.valid_pin("١٢٣٤"))

srv = pin.ThreadingHTTPServer(("127.0.0.1", 0), pin.H)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
def req(path, body=None):
    r = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path),
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read(); return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read(); return e.code, (json.loads(raw) if raw else None)

# gate disabled when unset
ok("unset: check 204", req("/api/pin/check")[0] == 204)
ok("unset: status", req("/api/pin/status")[1] == {"set": False, "locked": False, "wait": 0})
ok("set rejects short", req("/api/pin/set", {"pin": "12"})[0] == 400)
ok("set 1234", req("/api/pin/set", {"pin": "1234"})[0] == 200)
st = os.stat(os.environ["TA_PIN_FILE"]).st_mode & 0o777
ok("pin.hash 0600", st == 0o600)
ok("setter stays unlocked", req("/api/pin/check")[0] == 204)
ok("change needs current", req("/api/pin/set", {"current": "0000", "pin": "5678"})[0] == 403)
ok("change with current", req("/api/pin/set", {"current": "1234", "pin": "5678"})[0] == 200)

# simulate reboot: /run wiped
import shutil; shutil.rmtree(os.environ["TA_PIN_STATE_DIR"])
ok("reboot: locked 401", req("/api/pin/check")[0] == 401)
ok("reboot: status locked", req("/api/pin/status")[1]["locked"] is True)
ok("locked: set forbidden", req("/api/pin/set", {"current": "5678", "pin": "1111"})[0] == 403)
ok("locked: clear forbidden", req("/api/pin/clear", {"current": "5678"})[0] == 403)
# stale marker from another boot never unlocks
os.makedirs(os.environ["TA_PIN_STATE_DIR"], exist_ok=True)
open(os.path.join(os.environ["TA_PIN_STATE_DIR"], "pin-unlocked"), "w").write("boot-OLD\n")
ok("stale boot_id marker stays locked", req("/api/pin/check")[0] == 401)

# wrong attempts + backoff
codes = [req("/api/pin/unlock", {"pin": "0000"})[0] for _ in range(5)]
ok("5 wrong = 403", codes == [403] * 5)
c, b = req("/api/pin/unlock", {"pin": "5678"})
ok("backoff blocks even right PIN (429)", c == 429 and b["wait"] > 0)
# expire backoff
fp = os.path.join(os.environ["TA_PIN_STATE_DIR"], "pin-fail.json")
d = json.load(open(fp)); d["until"] = time.time() - 1; json.dump(d, open(fp, "w"))
ok("after backoff right PIN unlocks", req("/api/pin/unlock", {"pin": "5678"})[0] == 200)
ok("unlocked: check 204 (global)", req("/api/pin/check")[0] == 204)
ok("fail counter cleared", not os.path.exists(fp))
ok("clear needs current", req("/api/pin/clear", {"current": "0000"})[0] == 403)
ok("clear with current", req("/api/pin/clear", {"current": "5678"})[0] == 200)
ok("cleared: file gone", not os.path.exists(os.environ["TA_PIN_FILE"]))
shutil.rmtree(os.environ["TA_PIN_STATE_DIR"])
ok("cleared+reboot: open", req("/api/pin/check")[0] == 204)
ok("bind guard", "0.0.0.0" in open(os.path.join(HERE, "ta_pin_api.py")).read())
srv.shutdown()

# installer / image wiring
inst = open(os.path.join(HERE, "install-tesla-linux.sh")).read()
for needle in ["auth_request /_tl_pin_check;", "location = /pin.html { auth_request off;",
               "location /api/pin/ {", "return 302 /pin.html?next=$request_uri;",
               "if ($uri ~ ^/(api|sockets)/) { return 401; }",
               "tesla-linux-pin-api.service nginx.service", "index.html pin.html",
               "multi-user.target.wants/tesla-linux-pin-api.service"]:
    ok("installer has " + needle, needle in inst)
locs = inst.split("cat > /etc/nginx/tl-locations.conf <<'EOF'")[1].split("\nEOF\n")[0]
ok("auth_request before all locations", locs.index("auth_request /_tl_pin_check;") < locs.index("\nlocation "))
ok("no other auth_request off", locs.count("auth_request off;") == 2)
ok("installer never writes pin.hash", "> /etc/tesla-linux/pin.hash" not in inst)
bi = open(os.path.join(HERE, "build-image.sh")).read()
ok("build-image stages pin unit", "tesla-linux-pin-api.service" in bi and "must not ship a pin.hash" in bi)
ok("index.html has PIN settings", 'id="pinbox"' in open(os.path.join(HERE, "index.html")).read())
print("pin-gate selftest: %s" % ("OK" if not fails else "%d FAIL" % fails))
sys.exit(1 if fails else 0)
