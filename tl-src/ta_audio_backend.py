#!/usr/bin/env python3
"""
Tesla Linux — desktop audio -> WebSocket backend.

Captures the desktop audio sink's monitor and streams it as raw interleaved
PCM (S16LE) over a WebSocket. Raw PCM needs no decoder in the browser (Web Audio
plays it directly), which keeps latency low and compatibility total; on a LAN the
~1.5 Mbit/s cost is irrelevant. A compressed codec can replace this later when we
match the tesla-android client's audio worker format.

Wire format: binary frames of interleaved little-endian int16 samples,
             RATE Hz, CHANNELS channels. No header — the client is told the
             format out-of-band (it's fixed).

Env:
  TA_AUDIO_PORT  listen port      (default 9093)
  TA_BIND        bind address     (default 127.0.0.1)
  TA_AUDIO_SRC   pulse/pipewire source name (default: default monitor)
  TA_RATE        sample rate      (default 48000)
  TA_CHANNELS    channels         (default 2)
"""
import asyncio, os, threading
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib
import websockets

PORT     = int(os.environ.get("TA_AUDIO_PORT", "9093"))
BIND     = os.environ.get("TA_BIND", "127.0.0.1")
RATE     = int(os.environ.get("TA_RATE", "48000"))
CHANNELS = int(os.environ.get("TA_CHANNELS", "2"))
SRC      = os.environ.get("TA_AUDIO_SRC", "")

QUEUE_MAX = 24
clients = {}
loop = None
stats = {"chunks": 0, "sent": 0, "dropped": 0}


def build_pipeline():
    src = "pulsesrc" + (" device=%s" % SRC if SRC else "")
    return (
        "%s ! queue max-size-time=100000000 ! audioconvert ! audioresample ! "
        "audio/x-raw,format=S16LE,rate=%d,channels=%d,layout=interleaved ! "
        "appsink name=asink emit-signals=true max-buffers=8 drop=true sync=false"
        % (src, RATE, CHANNELS)
    )


def on_sample(sink):
    sample = sink.emit("pull-sample")
    if sample is None:
        return Gst.FlowReturn.OK
    buf = sample.get_buffer()
    ok, mapinfo = buf.map(Gst.MapFlags.READ)
    if ok:
        data = bytes(mapinfo.data)
        buf.unmap(mapinfo)
        stats["chunks"] += 1
        if loop is not None and clients:
            loop.call_soon_threadsafe(_dispatch, data)
    return Gst.FlowReturn.OK


def _dispatch(data):
    for q in list(clients.values()):
        if q.full():
            try:
                q.get_nowait()
                stats["dropped"] += 1
            except asyncio.QueueEmpty:
                pass
        q.put_nowait(data)


async def ws_handler(ws, *args):
    q = asyncio.Queue(maxsize=QUEUE_MAX)
    clients[ws] = q
    peer = getattr(ws, "remote_address", None)
    print("audio client connected: %s  total=%d" % (peer, len(clients)), flush=True)
    sent = 0
    try:
        while True:
            data = await q.get()
            await ws.send(data)
            sent += 1
            stats["sent"] += 1
            if sent == 1:
                print("first audio chunk delivered to %s" % (peer,), flush=True)
    except Exception as ex:
        print("audio client %s ended: %s" % (peer, type(ex).__name__), flush=True)
    finally:
        clients.pop(ws, None)
        print("audio client gone: %s (sent=%d)" % (peer, sent), flush=True)


def gst_thread():
    Gst.init(None)
    p = build_pipeline()
    print("AUDIO PIPELINE: " + p, flush=True)
    pipeline = Gst.parse_launch(p)
    pipeline.get_by_name("asink").connect("new-sample", on_sample)

    def on_msg(_bus, msg):
        if msg.type == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            print("GST AUDIO ERROR: %s | %s" % (err, dbg), flush=True)
        return True

    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect("message", on_msg)
    pipeline.set_state(Gst.State.PLAYING)
    print("audio pipeline PLAYING (%d Hz, %d ch)" % (RATE, CHANNELS), flush=True)
    GLib.MainLoop().run()


async def report():
    while True:
        await asyncio.sleep(15)
        print("audio stats: chunks=%d sent=%d dropped=%d clients=%d"
              % (stats["chunks"], stats["sent"], stats["dropped"], len(clients)), flush=True)


async def main():
    global loop
    loop = asyncio.get_running_loop()
    threading.Thread(target=gst_thread, daemon=True).start()
    asyncio.ensure_future(report())
    async with websockets.serve(ws_handler, BIND, PORT, max_size=None,
                                ping_interval=20, compression=None):
        print("audio backend listening on ws://%s:%d" % (BIND, PORT), flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
