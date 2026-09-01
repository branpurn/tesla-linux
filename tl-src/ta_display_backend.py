#!/usr/bin/env python3
"""
Tesla Linux — GStreamer -> WebSocket display backend (MVP).

Captures the X display, H.264-encodes it, and streams the raw Annex-B elementary
stream to WebSocket clients — the exact wire format the tesla-android beta client's
h264-webcodecs renderer expects (splits NAL start codes, caches SPS/PPS, feeds
WebCodecs). No custom framing.

Design notes:
  * one asyncio.Queue per client + a dedicated sender task (proper backpressure;
    drops oldest frames rather than piling up unbounded send() tasks)
  * dead clients are removed on send failure
  * last SPS/PPS is cached and pushed to a client the moment it connects, so a new
    viewer doesn't wait for the next config interval

Env:
  TA_DISPLAY   X display to capture      (default :0)
  TA_PORT      WS listen port            (default 9091)
  TA_BIND      bind address              (default 127.0.0.1)
  TA_BITRATE   bitrate kbps              (default 8000)
  TA_FPS       framerate                 (default 30)
  TA_ENCODER   x264enc | v4l2h264enc     (default: v4l2h264enc if /dev/video11 else x264enc)
"""
import asyncio, os, threading
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib
import websockets

DISPLAY = os.environ.get("TA_DISPLAY", ":0")
PORT    = int(os.environ.get("TA_PORT", "9091"))
BIND    = os.environ.get("TA_BIND", "127.0.0.1")
BITRATE = int(os.environ.get("TA_BITRATE", "8000"))
FPS     = int(os.environ.get("TA_FPS", "30"))
ENCODER = os.environ.get("TA_ENCODER") or ("v4l2h264enc" if os.path.exists("/dev/video11") else "x264enc")

QUEUE_MAX = 8          # frames buffered per client before we start dropping
clients = {}           # websocket -> asyncio.Queue
last_config = None     # cached SPS/PPS access unit
loop = None
stats = {"frames": 0, "sent": 0, "dropped": 0}


def build_pipeline():
    if ENCODER == "v4l2h264enc":
        enc = ('v4l2h264enc extra-controls="controls,video_bitrate=%d,h264_i_frame_period=%d" '
               '! video/x-h264,level=(string)4' % (BITRATE * 1000, FPS))
    else:
        enc = ("x264enc tune=zerolatency speed-preset=ultrafast bitrate=%d key-int-max=%d "
               "! video/x-h264,profile=constrained-baseline" % (BITRATE, FPS))
    return (
        "ximagesrc use-damage=0 remote=1 ! "
        "video/x-raw,framerate=%d/1 ! videoconvert ! video/x-raw,format=I420 ! "
        "%s ! "
        "h264parse config-interval=-1 ! "
        "video/x-h264,stream-format=byte-stream,alignment=au ! "
        "appsink name=sink emit-signals=true max-buffers=2 drop=true sync=false"
        % (FPS, enc)
    )


def nal_types(buf):
    """Return the set of NAL unit types present in an Annex-B buffer."""
    types = set()
    n = len(buf)
    for i in range(n - 4):
        if buf[i] == 0 and buf[i + 1] == 0:
            if buf[i + 2] == 1:
                types.add(buf[i + 3] & 0x1F)
            elif buf[i + 2] == 0 and buf[i + 3] == 1 and i + 4 < n:
                types.add(buf[i + 4] & 0x1F)
    return types


def on_sample(sink):
    sample = sink.emit("pull-sample")
    if sample is None:
        return Gst.FlowReturn.OK
    buf = sample.get_buffer()
    ok, mapinfo = buf.map(Gst.MapFlags.READ)
    if ok:
        data = bytes(mapinfo.data)
        buf.unmap(mapinfo)
        stats["frames"] += 1
        if loop is not None:
            loop.call_soon_threadsafe(_dispatch, data)
    return Gst.FlowReturn.OK


def _dispatch(data):
    """Runs on the asyncio loop thread: cache config, fan out to per-client queues."""
    global last_config
    types = nal_types(data)
    if 7 in types:                      # SPS present -> remember this access unit
        last_config = data
    for q in list(clients.values()):
        if q.full():
            try:
                q.get_nowait()          # drop oldest
                stats["dropped"] += 1
            except asyncio.QueueEmpty:
                pass
        q.put_nowait(data)


async def ws_handler(ws, *args):
    q = asyncio.Queue(maxsize=QUEUE_MAX)
    clients[ws] = q
    peer = getattr(ws, "remote_address", None)
    print("client connected: %s  total=%d" % (peer, len(clients)), flush=True)
    if last_config:                     # jump-start: send cached SPS/PPS immediately
        q.put_nowait(last_config)
    sent = 0
    try:
        while True:
            data = await q.get()
            await ws.send(data)         # awaited: real backpressure, real errors
            sent += 1
            stats["sent"] += 1
            if sent == 1:
                print("first frame delivered to %s" % (peer,), flush=True)
            elif sent % 300 == 0:
                print("%s: %d frames sent" % (peer, sent), flush=True)
    except Exception as e:
        print("client %s ended: %s: %s" % (peer, type(e).__name__, e), flush=True)
    finally:
        clients.pop(ws, None)
        print("client gone: %s (sent=%d)  total=%d" % (peer, sent, len(clients)), flush=True)


def gst_thread():
    Gst.init(None)
    pipe_str = build_pipeline()
    print("PIPELINE: " + pipe_str, flush=True)
    pipeline = Gst.parse_launch(pipe_str)
    pipeline.get_by_name("sink").connect("new-sample", on_sample)

    def on_msg(_bus, msg):
        if msg.type == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            print("GST ERROR: %s | %s" % (err, dbg), flush=True)
        elif msg.type == Gst.MessageType.EOS:
            print("GST EOS", flush=True)
        return True

    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect("message", on_msg)
    pipeline.set_state(Gst.State.PLAYING)
    print("pipeline PLAYING (encoder=%s display=%s)" % (ENCODER, DISPLAY), flush=True)
    GLib.MainLoop().run()


async def report():
    while True:
        await asyncio.sleep(10)
        print("stats: frames=%d sent=%d dropped=%d clients=%d config_cached=%s"
              % (stats["frames"], stats["sent"], stats["dropped"], len(clients),
                 bool(last_config)), flush=True)


async def main():
    global loop
    loop = asyncio.get_running_loop()
    os.environ["DISPLAY"] = DISPLAY
    threading.Thread(target=gst_thread, daemon=True).start()
    asyncio.ensure_future(report())
    async with websockets.serve(ws_handler, BIND, PORT, max_size=None,
                                ping_interval=20, ping_timeout=20, compression=None):
        print("WS backend listening on ws://%s:%d  (encoder=%s)" % (BIND, PORT, ENCODER), flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
