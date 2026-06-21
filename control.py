#!/usr/bin/env python3
"""
SRT test-source control server + web dashboard.

- Serves a dashboard at http://127.0.0.1:8080/
- Shows live SRT connections (read from MediaMTX's control API on :9997)
- Starts/stops CALLER-mode pushes (ffmpeg) to remote SRT listeners (e.g. mimoLive),
  each with auto-reconnect so it survives the receiver going away and coming back.

Stdlib only. Needs: MediaMTX running with `api: yes`, and ffmpeg in PATH.
A caller push pulls a local MediaMTX stream (read:<stream>) and forwards it
(stream-copy) to  srt://<host>:<port>?mode=caller&latency=<ms>.
"""
import json, os, re, subprocess, threading, time, socket
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MTX_API  = os.environ.get("MTX_API", "http://127.0.0.1:9997")
SRT_HOST = os.environ.get("SRT_HOST", "127.0.0.1")
SRT_PORT = int(os.environ.get("SRT_PORT", "8890"))
BIND     = (os.environ.get("DASH_HOST", "127.0.0.1"), int(os.environ.get("DASH_PORT", "8080")))

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")          # stream names + hostnames/IPs
_callers, _lock, _seq = {}, threading.Lock(), [0]


# ---------- MediaMTX API ----------
def mtx_get(path):
    try:
        with urllib.request.urlopen(MTX_API + path, timeout=3) as r:
            return json.loads(r.read().decode()), None
    except Exception as e:
        return None, str(e)


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))          # no packet sent; just picks the egress iface
        ip = s.getsockname()[0]; s.close(); return ip
    except Exception:
        return "127.0.0.1"


# ---------- caller (ffmpeg) management ----------
def _runner(c):
    src = f"srt://{SRT_HOST}:{SRT_PORT}?streamid=read:{c['stream']}"
    dst = f"srt://{c['host']}:{c['port']}?mode=caller&latency={c['latency']}&pkt_size=1316"
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error",
           "-i", src, "-c", "copy", "-f", "mpegts", dst]
    while not c["stop"]:
        try:
            c["proc"] = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            c["state"] = f"error: {e}"; return
        c["state"] = "running"
        c["proc"].wait()
        c["proc"] = None
        c["runs"] += 1
        if c["stop"]:
            break
        c["state"] = "reconnecting"            # remote listener not up / dropped — retry
        for _ in range(20):
            if c["stop"]:
                break
            time.sleep(0.1)
    c["state"] = "stopped"


def add_caller(stream, host, port, latency):
    stream, host = str(stream), str(host)
    if not NAME_RE.match(stream): raise ValueError("invalid stream name")
    if not NAME_RE.match(host):   raise ValueError("invalid host")
    port, latency = int(port), int(latency)
    if not (1 <= port <= 65535):  raise ValueError("port out of range")
    if not (0 <= latency <= 8000): raise ValueError("latency out of range")
    with _lock:
        _seq[0] += 1
        cid = _seq[0]
        c = {"id": cid, "stream": stream, "host": host, "port": port, "latency": latency,
             "state": "starting", "runs": 0, "stop": False, "proc": None, "created": time.time()}
        _callers[cid] = c
        threading.Thread(target=_runner, args=(c,), daemon=True).start()
    return cid


def stop_caller(cid):
    with _lock:
        c = _callers.pop(cid, None)        # remove immediately; worker keeps its own ref
    if not c:
        return False
    c["stop"] = True
    p = c.get("proc")
    if p:
        try: p.terminate()
        except Exception: pass
    return True


def public_callers():
    with _lock:
        return [{k: c[k] for k in ("id", "stream", "host", "port", "latency", "state", "runs", "created")}
                for c in _callers.values()]


def status():
    paths, perr = mtx_get("/v3/paths/list")
    conns, cerr = mtx_get("/v3/srtconns/list")
    out = {"ok": perr is None, "error": perr or cerr, "lanip": lan_ip(),
           "srt_port": SRT_PORT, "paths": [], "conns": [], "callers": public_callers()}
    if paths:
        for p in paths.get("items", []):
            out["paths"].append({"name": p.get("name"), "ready": p.get("ready"),
                                 "readers": len(p.get("readers") or []),
                                 "source": (p.get("source") or {}).get("type")})
    if conns:
        for x in conns.get("items", []):
            out["conns"].append({"id": x.get("id"), "remoteAddr": x.get("remoteAddr"),
                                 "state": x.get("state"), "path": x.get("path"),
                                 "recv": x.get("bytesReceived"), "sent": x.get("bytesSent"),
                                 "created": x.get("created")})
    return out


# ---------- HTTP ----------
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if self.path == "/api/status":
            return self._send(200, json.dumps(status()))
        self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if self.path == "/api/callers":
            try:
                d = json.loads(raw or b"{}")
                cid = add_caller(d.get("stream", "teststream"), d["host"],
                                 d.get("port", 9000), d.get("latency", 120))
                return self._send(200, json.dumps({"id": cid}))
            except Exception as e:
                return self._send(400, json.dumps({"error": str(e)}))
        if self.path == "/api/callers/stopall":
            for c in public_callers():
                stop_caller(c["id"])
            return self._send(200, json.dumps({"ok": True}))
        self._send(404, json.dumps({"error": "not found"}))

    def do_DELETE(self):
        m = re.match(r"^/api/callers/(\d+)$", self.path)
        if m:
            ok = stop_caller(int(m.group(1)))
            return self._send(200 if ok else 404, json.dumps({"ok": ok}))
        self._send(404, json.dumps({"error": "not found"}))


PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SRT Test Source — Control</title>
<style>
  :root{--bg:#0f1115;--panel:#171a21;--line:#262b36;--fg:#e6e9ef;--mut:#8b93a3;
        --accent:#4ea1ff;--ok:#3ddc84;--warn:#ffb454;--bad:#ff5d5d;--pub:#b48cff}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,Segoe UI,Roboto,sans-serif}
  header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px}
  header h1{font-size:16px;margin:0;font-weight:600}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--bad)}
  .dot.up{background:var(--ok)}
  main{padding:20px;max-width:1100px;margin:0 auto;display:grid;gap:20px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
  .card h2{font-size:13px;margin:0;padding:12px 16px;border-bottom:1px solid var(--line);
           color:var(--mut);text-transform:uppercase;letter-spacing:.06em;font-weight:600}
  table{width:100%;border-collapse:collapse}
  th,td{padding:9px 16px;text-align:left;border-bottom:1px solid var(--line);font-variant-numeric:tabular-nums}
  th{color:var(--mut);font-weight:500;font-size:12px}
  tr:last-child td{border-bottom:none}
  .badge{display:inline-block;padding:1px 8px;border-radius:20px;font-size:12px;font-weight:600}
  .b-read{background:rgba(78,161,255,.16);color:var(--accent)}
  .b-publish{background:rgba(180,140,255,.16);color:var(--pub)}
  .b-running{background:rgba(61,220,132,.16);color:var(--ok)}
  .b-reconnecting{background:rgba(255,180,84,.16);color:var(--warn)}
  .b-idle,.b-stopped{background:rgba(139,147,163,.16);color:var(--mut)}
  .mut{color:var(--mut)}
  code{background:#0b0d11;border:1px solid var(--line);padding:1px 6px;border-radius:5px;color:#cfe3ff}
  form{display:flex;flex-wrap:wrap;gap:10px;align-items:flex-end;padding:16px}
  label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--mut)}
  input,select{background:#0b0d11;border:1px solid var(--line);color:var(--fg);
               padding:7px 9px;border-radius:7px;font:inherit;min-width:120px}
  button{background:var(--accent);color:#05203f;border:0;padding:8px 14px;border-radius:7px;
         font:inherit;font-weight:600;cursor:pointer}
  button.ghost{background:transparent;border:1px solid var(--line);color:var(--fg);font-weight:500}
  button.stop{background:transparent;border:1px solid var(--bad);color:var(--bad);padding:4px 10px}
  .row{display:flex;justify-content:space-between;align-items:center;padding:0 16px}
  .empty{padding:14px 16px;color:var(--mut)}
  .hint{padding:0 16px 14px;color:var(--mut);font-size:12px}
</style></head><body>
<header>
  <span class="dot" id="dot"></span>
  <h1>SRT Test Source — Control</h1>
  <span class="mut" id="hdr"></span>
</header>
<main>
  <section class="card">
    <div class="row"><h2 style="border:0;padding:12px 0">Incoming SRT connections</h2>
      <span class="mut" id="srturl"></span></div>
    <table><thead><tr><th>Remote</th><th>State</th><th>Path</th><th>Received</th><th>Sent</th></tr></thead>
      <tbody id="conns"></tbody></table>
    <div class="empty" id="conns-empty" style="display:none">No SRT connections.</div>
  </section>

  <section class="card">
    <h2>Outgoing caller-mode pushes</h2>
    <table><thead><tr><th>Target</th><th>Stream</th><th>Latency</th><th>State</th><th>Restarts</th><th></th></tr></thead>
      <tbody id="callers"></tbody></table>
    <div class="empty" id="callers-empty">No caller pushes running.</div>
    <form id="f">
      <label>Stream<select id="stream"></select></label>
      <label>Host<input id="host" placeholder="receiver IP" value=""></label>
      <label>Port<input id="port" type="number" value="9000" style="min-width:90px"></label>
      <label>Latency ms<input id="lat" type="number" value="120" style="min-width:90px"></label>
      <button type="submit">Start push</button>
      <button type="button" class="ghost" id="stopall">Stop all</button>
    </form>
    <div class="hint">Pushes the chosen stream to a remote SRT <b>listener</b> in caller mode
      (e.g. mimoLive set to Listener). Auto-reconnects if the receiver isn't up yet.</div>
  </section>
</main>
<script>
const $=s=>document.querySelector(s);
const fmtB=n=>{if(n==null)return '–';const u=['B','KB','MB','GB'];let i=0;n=+n;while(n>=1024&&i<3){n/=1024;i++}return n.toFixed(i?1:0)+' '+u[i]};
const badge=(s)=>`<span class="badge b-${s}">${s}</span>`;
let streamsLoaded=false;

async function tick(){
  let d; try{ d=await (await fetch('/api/status')).json(); }catch(e){ $('#dot').className='dot'; return; }
  $('#dot').className='dot'+(d.ok?' up':'');
  $('#hdr').textContent = d.ok ? `MediaMTX up · ${d.paths.length} stream(s)` : ('MediaMTX unreachable: '+(d.error||''));
  $('#srturl').innerHTML = d.lanip ? `pull base: <code>srt://${d.lanip}:${d.srt_port}?streamid=read:&lt;stream&gt;</code>` : '';

  // populate stream dropdown once
  if(!streamsLoaded && d.paths.length){ const sel=$('#stream'); sel.innerHTML='';
    d.paths.forEach(p=>{const o=document.createElement('option');o.value=p.name;o.textContent=p.name;sel.appendChild(o)});
    streamsLoaded=true; }

  const cb=$('#conns'); cb.innerHTML='';
  d.conns.forEach(c=>{ const tr=document.createElement('tr');
    tr.innerHTML=`<td>${c.remoteAddr||'–'}</td><td>${badge(c.state||'idle')}</td>
      <td>${c.path?('<code>'+c.path+'</code>'):'<span class=mut>—</span>'}</td>
      <td>${fmtB(c.recv)}</td><td>${fmtB(c.sent)}</td>`; cb.appendChild(tr); });
  $('#conns-empty').style.display = d.conns.length?'none':'block';

  const kb=$('#callers'); kb.innerHTML='';
  d.callers.forEach(c=>{ const tr=document.createElement('tr');
    tr.innerHTML=`<td><code>${c.host}:${c.port}</code></td><td>${c.stream}</td><td>${c.latency} ms</td>
      <td>${badge(c.state)}</td><td>${c.runs}</td>
      <td><button class="stop" onclick="stopCaller(${c.id})">Stop</button></td>`; kb.appendChild(tr); });
  $('#callers-empty').style.display = d.callers.length?'none':'block';
}
async function stopCaller(id){ await fetch('/api/callers/'+id,{method:'DELETE'}); tick(); }
$('#stopall').onclick=async()=>{ await fetch('/api/callers/stopall',{method:'POST'}); tick(); };
$('#f').onsubmit=async(e)=>{ e.preventDefault();
  const body={stream:$('#stream').value,host:$('#host').value.trim(),port:+$('#port').value,latency:+$('#lat').value};
  const r=await fetch('/api/callers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  if(!r.ok){ const e=await r.json(); alert('Error: '+(e.error||r.status)); } tick();
};
tick(); setInterval(tick,2000);
</script></body></html>"""


if __name__ == "__main__":
    srv = ThreadingHTTPServer(BIND, H)
    print(f"SRT control dashboard:  http://{BIND[0]}:{BIND[1]}")
    print(f"MediaMTX API:           {MTX_API}")
    print("Ctrl-C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        for c in public_callers():
            stop_caller(c["id"])
        print("\nstopped.")
