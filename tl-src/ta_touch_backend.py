#!/usr/bin/env python3
"""
Tesla Linux — touch/pointer input backend.

Receives pointer events over a WebSocket and injects them into the X session via
a virtual uinput absolute-pointing device (so it works with any X app, no XTEST).

Accepts two JSON shapes:
  * ours (resolution independent):  {"type":"down"|"move"|"up", "x":0..1, "y":0..1}
  * tesla-android beta client:      {"absMtPositionX":px, "absMtPositionY":py,
                                     "slotIndex":n, "trackingId":n|-1}
    (trackingId == -1 means lift; pixel coords are in remote-display space)

Env:
  TA_TOUCH_PORT  listen port          (default 9092)
  TA_BIND        bind address         (default 127.0.0.1)
  TA_WIDTH/TA_HEIGHT  remote display size for pixel->absolute mapping (default 1280x720)
"""
import asyncio, json, os
import websockets
from evdev import UInput, AbsInfo, ecodes as e

PORT   = int(os.environ.get("TA_TOUCH_PORT", "9092"))
BIND   = os.environ.get("TA_BIND", "127.0.0.1")
WIDTH  = int(os.environ.get("TA_WIDTH", "1280"))
HEIGHT = int(os.environ.get("TA_HEIGHT", "720"))
ABS_MAX = 32767

caps = {
    e.EV_KEY: [e.BTN_TOUCH, e.BTN_LEFT],
    e.EV_ABS: [
        (e.ABS_X, AbsInfo(value=0, min=0, max=ABS_MAX, fuzz=0, flat=0, resolution=0)),
        (e.ABS_Y, AbsInfo(value=0, min=0, max=ABS_MAX, fuzz=0, flat=0, resolution=0)),
    ],
}
ui = UInput(caps, name="tesla-linux-touch", version=1)
print("uinput device created: tesla-linux-touch (%dx%d -> 0..%d)" % (WIDTH, HEIGHT, ABS_MAX), flush=True)

down = False
stats = {"events": 0}


def to_abs(x, y, normalized):
    if normalized:
        nx, ny = float(x), float(y)
    else:
        nx, ny = float(x) / WIDTH, float(y) / HEIGHT
    nx = min(max(nx, 0.0), 1.0)
    ny = min(max(ny, 0.0), 1.0)
    return int(nx * ABS_MAX), int(ny * ABS_MAX)


def emit(ax, ay, press=None):
    """press: True=touch down, False=lift, None=move only."""
    global down
    ui.write(e.EV_ABS, e.ABS_X, ax)
    ui.write(e.EV_ABS, e.ABS_Y, ay)
    if press is True and not down:
        ui.write(e.EV_KEY, e.BTN_TOUCH, 1)
        ui.write(e.EV_KEY, e.BTN_LEFT, 1)
        down = True
    elif press is False and down:
        ui.write(e.EV_KEY, e.BTN_TOUCH, 0)
        ui.write(e.EV_KEY, e.BTN_LEFT, 0)
        down = False
    ui.syn()
    stats["events"] += 1


def handle(msg):
    d = json.loads(msg)
    if "absMtPositionX" in d:                      # tesla-android beta client shape
        ax, ay = to_abs(d.get("absMtPositionX", 0), d.get("absMtPositionY", 0), normalized=False)
        tid = d.get("trackingId", 0)
        emit(ax, ay, press=(False if tid == -1 else True))
        return
    t = d.get("type", "move")                      # our shape
    ax, ay = to_abs(d.get("x", 0), d.get("y", 0), normalized=True)
    emit(ax, ay, press={"down": True, "up": False}.get(t, None))


async def ws_handler(ws, *args):
    peer = getattr(ws, "remote_address", None)
    print("touch client connected: %s" % (peer,), flush=True)
    try:
        async for msg in ws:
            try:
                handle(msg)
            except Exception as ex:
                print("bad event (%s): %s" % (type(ex).__name__, ex), flush=True)
    except Exception:
        pass
    finally:
        if down:
            emit(0, 0, press=False)                # never leave a button stuck
        print("touch client gone: %s (events=%d)" % (peer, stats["events"]), flush=True)


async def main():
    async with websockets.serve(ws_handler, BIND, PORT, ping_interval=20):
        print("touch backend listening on ws://%s:%d" % (BIND, PORT), flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
