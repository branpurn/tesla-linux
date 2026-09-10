# A/V sync findings (stream path, ~17s late audio)

Against `main` **ff28318**. Stream path only (eth `desktop.html`, not HDMI, not in-car Tesla).
YouTube in Firefox on Pi XFCE → watch via Pop insecure Edge. Video OK; audio ~17s late.

No backend code change in this note. Next slice is Frontend (see bottom).

## Paths (file:line)

### Audio (PCM stays in-order; client never drops)

1. PipeWire virtual sink `tesla` + monitor `tesla.monitor`
   - planted in `tl-src/install-tesla-linux.sh:1312-1325`
   - `TA_AUDIO_SRC=tesla.monitor` at `install-tesla-linux.sh:1235`
   - **no** `node.latency` / quantum pin
2. GStreamer capture → S16LE 48 kHz stereo
   - `tl-src/ta_audio_backend.py:40-47` — `pulsesrc` (no `buffer-time` / `latency-time`)
   - `queue max-size-time=100000000` (100 ms, not leaky)
   - `appsink max-buffers=8 drop=true sync=false`
3. Per-client asyncio queue + WS `:9093`
   - `QUEUE_MAX = 24` at `ta_audio_backend.py:34`
   - drop-oldest on full: `ta_audio_backend.py:65-73`
   - sender: `ta_audio_backend.py:76-85`
4. nginx `/sockets/audio` → loopback `:9093`
   - `install-tesla-linux.sh:1159-1167` — `proxy_buffering off`
5. Browser: raw S16LE → `AudioContext` schedule
   - `tl-src/desktop.html:204-238`
   - `playAt` only moves **forward** except when it has already fallen behind `currentTime`

### Video (drops to live)

1. `ximagesrc` → scale → H.264 Annex-B
   - `tl-src/ta_display_backend.py:49-68`
   - `appsink max-buffers=2 drop=true sync=false`
2. Per-client queue `QUEUE_MAX = 8` (~267 ms @ 30 fps)
   - `ta_display_backend.py:42`, drop-oldest `137-150`
3. nginx `/sockets/display` → `:9091` (same `proxy_buffering off`)
4. `desktop.html:48-168` — WebCodecs if `VideoDecoder` exists, else Broadway
   - insecure HTTP is not a secure context; Edge will typically take Broadway
   - `optimizeForLatency:true` on WebCodecs (`desktop.html:132`)

## Buffer budget (why 17s is not in the backends)

| Stage | Bound | Max held if full |
|---|---|---|
| pulsesrc default `buffer-time` | 200 ms (GStreamer default; **not set** here) | ~200 ms |
| GST `queue` | 100 ms | 100 ms |
| appsink | 8 buffers, drop | ~80 ms @ 10 ms frags, ~1.6 s @ 200 ms frags |
| audio WS queue | 24 chunks, drop-oldest | ~240 ms @ 10 ms, **4.8 s @ 200 ms** |
| nginx WS | `proxy_buffering off` | ~0 |
| video WS queue | 8 frames @ 30 fps | ~267 ms |
| **client `playAt`** | **unbounded** | **session age** |

17 s @ 48 kHz stereo S16LE = 816 000 frames/ch = 3.26 MiB. That matches a full
`AudioContext` lookahead, **not** `QUEUE_MAX=24` unless each GST chunk were ~708 ms
**and** the WS sender stayed backpressured (no evidence; `drop=true` keeps capture live).

Clock drift is ruled out for a ~17 s observation in one sitting: even 1000 ppm
needs ~4.7 h to accumulate 17 s.

## Most likely locus

**`desktop.html` `playAt` schedule — growing backlog while `AudioContext` is
`suspended`, then a fixed offset after the first gesture resume.**

Evidence:

1. Insecure Edge autoplay: `startAudio()` runs on load (`desktop.html:233`) and
   calls `actx.resume()` without a gesture (`231`). That resume is ignored;
   `currentTime` stays frozen. HUD will show `audio:suspended` until click.
2. WS PCM still arrives. Scheduler does **not** cap lookahead:

```226:227:tl-src/desktop.html
    if(playAt<actx.currentTime) playAt=actx.currentTime+0.05;   // resync if we fell behind
    s.start(playAt); playAt+=buf.duration;
```

   Behind → snap to live. Ahead → keep stacking. Suspended `currentTime≈0` means
   every chunk adds to `playAt`.
3. After ~17 s of YouTube already playing on the Pi, first pointerdown resumes
   the context (`234-238`). Scheduled sources start at t=0…17; playback is the
   audio from connect time. `playAt` stays ~17 s ahead forever.
4. Video cannot do this: display/appsink/WS all drop. Painted frames stay live.
   Same page, two policies → “video OK, audio late.”
5. Gesture-audio path is intentional (`204-207`) and must be **kept**. The bug
   is “schedule every sample during suspend,” not “resume on click.”

Secondary (same code, different trigger): Broadway on insecure Edge can stall
the main thread; the browser WS buffer is unbounded. A burst of `onmessage`
then jumps `playAt` by the stall length. Still client backlog, not capture.

Unlikely for **17 s** (measure before touching):

- PipeWire `null-audio-sink` without `node.latency` — typical extra is 10s–100s of ms
- `pulsesrc` default 200 ms
- GST/WS queues (bounded, drop)

Those can add a **small fixed** capture delay. They cannot hold 17 s unless
`chunk_ms` is huge (log it if the Frontend slice fails).

## Class

| Class | Verdict |
|---|---|
| Fixed GStreamer/Pulse/WS buffer | No. Bounded ≪ 17 s when sender keeps up. |
| Client sample-rate drift | No. Too slow to reach 17 s in one watch. |
| **Growing backlog → fixed offset** | **Yes.** `playAt` grows during `suspended` (or WS burst); after resume it is a constant ~17 s lookahead. |

## Live checks (no code)

On the Pop Edge HUD (`desktop.html:38`):

- `audio:suspended` vs `audio:on` — if you heard the late audio only after the
  first click, that is this bug.
- `decKind` `broadway` vs `webcodecs` — insecure Edge is expected Broadway.
- After audio is `on`, wait 30 s. If lag stays ~17 s, it is a frozen offset
  (suspend pile-up). If it keeps growing, it is ongoing burst/backlog.

On the Pi (optional, does not block the next slice):

```text
journalctl -u tesla-linux-audio -n 50
# expect: dropped stays 0 or tiny if eth is keeping up
# 17 s of drop-oldest would also print a large dropped count
```

## Next fix slice (ONE)

**Owner: Frontend (`desktop.html` only).** Backend `ta_*.py` / bake / PipeWire
untouched. Keep gesture resume. Do not invent WebRTC.

Change (tiny):

1. Cap schedule lookahead (e.g. `MAX_AHEAD = 0.15`). If
   `playAt - actx.currentTime > MAX_AHEAD`, snap to `currentTime + 0.05`
   (drop the backlog; stay live like video).
2. On successful `actx.resume()`, reset `playAt = actx.currentTime + 0.08`.
3. HUD: show `ahead_ms` next to `audio:on` so the PASS is visible.

Do **not** remove load-time `startAudio()` or the pointer/key/touch resume
listeners.

### PASS

Same repro (YT on Pi Firefox → eth `desktop.html` on Pop insecure Edge):

- HUD `ahead_ms` ≤ 200 at first audible audio **and** after 60 s of YT
- Lip-sync vs **streamed** video (clap or talking-head) within **±200 ms**
- Gesture still unlocks audio on insecure Edge
- HUD still shows Broadway when `VideoDecoder` is absent
- Bake / `ta_*.py` unchanged

If `ahead_ms` ≤ 200 and lips are still ~17 s late, content is already stale at
`pulsesrc` — then a **later** Backend slice pins
`buffer-time`/`latency-time` + PipeWire `node.latency` and logs `chunk_ms` /
queue depth. Do not start there; the math does not put 17 s in those queues.
