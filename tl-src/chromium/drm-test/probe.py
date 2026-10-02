#!/usr/bin/env python3
"""Tesla Linux Chromium probe (runs ON the Pi, DISPLAY=:0).

Starts a short-lived Chromium (own throwaway profile, remote-debugging port),
opens a page, and reports: Widevine/EME support, the media decoder Chromium
picked (CDP Media domain), whether the GPU process holds /dev/video10, CPU of
the browser process tree, and playback numbers. Never touches other windows.

  probe.py --exe /usr/bin/chromium-drm --page {HTTP}/drm.html#h=720 [--seconds 25]
  probe.py --exe ... --eme-only
"""
import functools, http.server, threading, argparse, json, os, shutil, subprocess, sys, tempfile, time, urllib.request
from websockets.sync.client import connect


def tree(root):
    ch = {}
    for p in os.listdir('/proc'):
        if p.isdigit():
            try:
                s = open(f'/proc/{p}/stat').read()
                ch.setdefault(int(s.rsplit(')', 1)[1].split()[1]), []).append(int(p))
            except Exception:
                pass
    out, st = [], [root]
    while st:
        x = st.pop(); out.append(x); st += ch.get(x, [])
    return out


def ticks(p):
    try:
        f = open(f'/proc/{p}/stat').read().rsplit(')', 1)[1].split()
        return int(f[11]) + int(f[12])
    except Exception:
        return 0


def cmdline(p):
    try:
        return open(f'/proc/{p}/cmdline', 'rb').read().replace(b'\0', b' ').decode()
    except Exception:
        return ''


def video_fds(pids):
    hit = {}
    for p in pids:
        try:
            for fd in os.listdir(f'/proc/{p}/fd'):
                t = os.readlink(f'/proc/{p}/fd/{fd}')
                if t.startswith('/dev/video'):
                    hit.setdefault(t, set()).add(p)
        except Exception:
            pass
    return {k: sorted(v) for k, v in hit.items()}


class CDP:
    def __init__(self, url):
        self.ws = connect(url, max_size=2**26); self.i = 0; self.events = []

    def call(self, method, **params):
        self.i += 1; mid = self.i
        self.ws.send(json.dumps({'id': mid, 'method': method, 'params': params}))
        while True:
            m = json.loads(self.ws.recv())
            if m.get('id') == mid:
                return m
            self.events.append(m)

    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                self.events.append(json.loads(self.ws.recv(timeout=max(0.05, end - time.time()))))
            except TimeoutError:
                break

    def ev(self, expr):
        r = self.call('Runtime.evaluate', expression=expr, returnByValue=True, awaitPromise=True)
        return r.get('result', {}).get('result', {}).get('value')


EME = """(async()=>{const R={};
const cfg=(rob,ct)=>({initDataTypes:['cenc'],audioCapabilities:[{contentType:'audio/mp4;codecs="mp4a.40.2"',robustness:rob}],videoCapabilities:[{contentType:ct,robustness:rob}]});
for (const [n,rob,ct] of [['SW_SECURE_CRYPTO','SW_SECURE_CRYPTO','video/mp4;codecs="avc1.4d401e"'],['default','','video/mp4;codecs="avc1.4d401e"'],['SW_SECURE_DECODE','SW_SECURE_DECODE','video/mp4;codecs="avc1.4d401e"'],['HW_SECURE_ALL(L1)','HW_SECURE_ALL','video/mp4;codecs="avc1.4d401e"']]){
 try{const a=await navigator.requestMediaKeySystemAccess('com.widevine.alpha',[cfg(rob,ct)]);R[n]='ok';}catch(e){R[n]='no: '+e.name}}
return R})()"""


WALK = r"""(function(){function t(n){let s='';if(n.nodeType==3)return n.textContent+' ';if(n.shadowRoot)s+=t(n.shadowRoot);for(const c of n.childNodes)s+=t(c);if(n.nodeType==1&&/^(DIV|P|TR|H\d|LI|BR|SPAN)$/.test(n.tagName))s+='\n';return s}return t(document.body)})()"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', required=True)
    ap.add_argument('--page', default='about:blank')
    ap.add_argument('--seconds', type=float, default=25)
    ap.add_argument('--port', type=int, default=9337)
    ap.add_argument('--eme-only', action='store_true')
    ap.add_argument('--extra', default='', help='extra chromium flags')
    ap.add_argument('--profile', default='')
    ap.add_argument('--json', default='')
    ap.add_argument('--js', default='', help='JS (file path @f or expr) run on the page ~8 s after load, before measuring')
    ap.add_argument('--report-js', default='', help='JS (@file or expr) evaluated at the end; result in report["js"]')
    ap.add_argument('--gpu', action='store_true', help='also read chrome://gpu feature status + GL renderer')
    ap.add_argument('--components', action='store_true', help='also read chrome://components (Widevine version/status)')
    ap.add_argument('--own-profile', action='store_true', help="exe picks its own profile (chromium-drm; set TL_DRM_PROFILE); don't pass --user-data-dir. --profile then only says where to log/clean up")
    ap.add_argument('--http-port', type=int, default=0, help='serve this dir on 127.0.0.1 (EME needs a secure origin, not file://)')
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    if a.page == 'about:blank': a.page = '{HTTP}/blank.html'   # EME needs a secure origin
    class Q(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *x): pass
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', a.http_port), functools.partial(Q, directory=here))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    hp = srv.server_address[1]
    a.page = a.page.replace('{HTTP}', f'http://127.0.0.1:{hp}')
    prof = a.profile or tempfile.mkdtemp(prefix='tl-probe-')
    env = dict(os.environ, DISPLAY=os.environ.get('DISPLAY', ':0'))
    # --temp-flags: keep the launcher's own flags; add isolation + debugging.
    cmd = a.exe.split() + ([] if a.own_profile else [f'--user-data-dir={prof}']) + [f'--remote-debugging-port={a.port}',
                           '--window-size=800,520', '--window-position=40,40'] + a.extra.split() + ['about:blank']
    pr = subprocess.Popen(cmd, env=env, stdout=open(prof + '/out.log', 'w'), stderr=subprocess.STDOUT)
    rep = {'exe': a.exe, 'cmd': ' '.join(cmd)}
    try:
        for _ in range(60):
            try:
                tg = json.load(urllib.request.urlopen(f'http://127.0.0.1:{a.port}/json'))
                if tg: break
            except Exception:
                time.sleep(0.5)
        rep['browser'] = json.load(urllib.request.urlopen(f'http://127.0.0.1:{a.port}/json/version'))
        tab = [t for t in tg if t['type'] == 'page'][0]
        c = CDP(tab['webSocketDebuggerUrl'])
        c.call('Media.enable'); c.call('Page.enable')
        c.call('Page.navigate', url=a.page); time.sleep(2)
        rep['eme'] = c.ev(EME)
        rep['mse_types'] = c.ev("JSON.stringify(Object.fromEntries(['audio/mp4;codecs=\"mp4a.40.2\"','audio/mp4;codecs=\"mp4a.40.29\"','audio/mp4;codecs=\"mp4a.40.5\"','audio/mp4;codecs=\"opus\"','video/mp4;codecs=\"avc1.640028\"','video/mp4;codecs=\"avc1.640033\"','video/mp4;codecs=\"hev1.2.4.L93.90\"','video/webm;codecs=\"vp9\"'].map(t=>[t,MediaSource.isTypeSupported(t)])))")
        if a.components:
            c.call('Page.navigate', url='chrome://components'); time.sleep(3)
            txt = c.ev(WALK) or ''
            ls = [l.strip() for l in txt.splitlines() if l.strip()]
            i = next((k for k, l in enumerate(ls) if 'idevine' in l), None)
            rep['components_widevine'] = ls[i:i + 4] if i is not None else None
            c.call('Page.navigate', url='about:blank'); time.sleep(1)
        if a.gpu:
            c.call('Page.navigate', url='chrome://gpu'); time.sleep(4)
            txt = c.ev(WALK) or ''
            ls = [l.strip() for l in txt.splitlines() if l.strip()]
            keys = ('Canvas', 'Direct Rendering', 'Compositing', 'Multiple Raster', 'Rasterization', 'Video Decode', 'Video Encode', 'Vulkan', 'WebGL', 'Skia', 'GL_RENDERER', 'GL_VENDOR', 'ANGLE', 'Driver', 'Hardware')
            rep['gpu'] = [l for l in ls if any(l.startswith(k) for k in keys)][:40]
            rep['gpu_decoders'] = [l for l in ls if 'h264' in l.lower() or 'v4l2' in l.lower()][:12]
            c.call('Page.navigate', url='about:blank'); time.sleep(1)
        if a.eme_only:
            return finish(rep, a)
        root = pr.pid
        rd = lambda x: open(x[1:]).read() if x.startswith('@') else x
        if a.js:
            time.sleep(8); rep['js_setup'] = c.ev(rd(a.js))
        t0 = time.time(); base = {}
        time.sleep(min(10, a.seconds / 2))                      # let it start + buffer
        pids = tree(root); base = {p: ticks(p) for p in pids}; w0 = time.time()
        c.pump(max(1, a.seconds - 10))
        pids2 = tree(root); w1 = time.time()
        cpu = sum(ticks(p) - base.get(p, 0) for p in pids2) / os.sysconf('SC_CLK_TCK') / (w1 - w0) * 100
        rep['cpu_pct_of_one_core'] = round(cpu, 1)
        rep['video_fds'] = {k: [(p, cmdline(p).split('--type=')[1].split()[0] if '--type=' in cmdline(p) else 'browser') for p in v]
                            for k, v in video_fds(pids2).items()}
        rep['page_state'] = c.ev('JSON.stringify(window.S||null)')
        rep['video'] = c.ev("(()=>{const v=document.querySelector('video');if(!v)return null;const q=v.getVideoPlaybackQuality();return {t:v.currentTime,w:v.videoWidth,h:v.videoHeight,frames:q.totalVideoFrames,dropped:q.droppedVideoFrames,paused:v.paused,mediaKeys:!!v.mediaKeys}})()")
        # decoder names from the CDP Media domain
        dec = {}
        for m in c.events:
            if m.get('method') == 'Media.playerPropertiesChanged':
                for pr_ in m['params']['properties']:
                    if pr_['name'] in ('kVideoDecoderName', 'kAudioDecoderName', 'kIsPlatformVideoDecoder', 'kVideoDecoderName', 'kVideoPlaybackFreezing', 'kVideoEncrypted', 'kIsVideoEncrypted'):
                        dec[pr_['name']] = pr_['value']
        rep['media_props'] = dec
        if a.report_js:
            rep['js'] = c.ev(rd(a.report_js))
        rep['loadavg'] = open('/proc/loadavg').read().strip()
        if os.environ.get('TL_PROBE_SHOT'):
            time.sleep(1)
            subprocess.run(['gst-launch-1.0', '-q', 'ximagesrc', 'num-buffers=1', '!', 'videoconvert', '!', 'pngenc', '!',
                            'filesink', f'location={os.environ["TL_PROBE_SHOT"]}'], env=env, timeout=30)
        return finish(rep, a)
    finally:
        pr.terminate()
        try: pr.wait(8)
        except Exception: pr.kill()
        for p in subprocess.run(['pgrep', '-f', f'user-data-dir={prof}'], capture_output=True, text=True).stdout.split():
            try: os.kill(int(p), 15)
            except Exception: pass
        time.sleep(1)
        if not a.profile: shutil.rmtree(prof, ignore_errors=True)


def finish(rep, a):
    s = json.dumps(rep, indent=1, default=str)
    print(s)
    if a.json: open(a.json, 'w').write(s)


if __name__ == '__main__':
    main()
