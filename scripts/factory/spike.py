#!/usr/bin/env python3
"""F02 spike: drive CutCut MCP headless. Log CÂM: chỉ in 'FACTORY <bước> ok|fail <giây> [mã]' + tên tool."""
import base64, json, os, re, subprocess, sys, tempfile, time, urllib.request, zlib

PORT, KEY, FOLDER = sys.argv[1], sys.argv[2], sys.argv[3]
URL = f"http://127.0.0.1:{PORT}/mcp"
sid = None
_id = 0

def rpc(method, params=None, notify=False):
    global sid, _id
    _id += 1
    msg = {"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})}
    if not notify: msg["id"] = _id
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", "Authorization": f"Bearer {KEY}"}
    if sid: h["Mcp-Session-Id"] = sid
    req = urllib.request.Request(URL, json.dumps(msg).encode(), h)
    with urllib.request.urlopen(req, timeout=120) as r:
        sid = r.headers.get("Mcp-Session-Id") or sid
        body = r.read()
    return json.loads(body) if body else None

def call(tool, **args):
    r = rpc("tools/call", {"name": tool, "arguments": args})
    if "error" in r: raise RuntimeError(f"{tool}:rpc")
    res = r["result"]; txt = "".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
    if res.get("isError"): raise RuntimeError(f"{tool}:err:{txt[:60]}")  # ponytail: 60 ký tự lỗi app (không chứa dữ liệu khách — clip tự sinh)
    try: return json.loads(txt)
    except Exception: return {"_text": txt}

def wait(res, limit=1800):
    jid = res.get("jobId") if isinstance(res, dict) else None
    if not jid: return res
    t = time.time()
    while time.time() - t < limit:
        j = call("get_job", jobId=jid, wait=25)
        st = j.get("status")
        if st == "done": return j.get("result", j)
        if st in ("failed", "cancelled"): raise RuntimeError(f"job:{st}:{str(j.get('message',''))[:60]}")
    raise RuntimeError("job:timeout")

T = {}
def step(name, fn):
    t = time.time()
    try:
        out = fn(); T[name] = round(time.time() - t, 1)
        print(f"FACTORY {name} ok {T[name]}", flush=True); return out
    except Exception as e:
        print(f"FACTORY {name} fail {round(time.time()-t,1)} {str(e)[:90]}", flush=True); raise

step("initialize", lambda: (rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "factory-spike", "version": "0"}}),
                            rpc("notifications/initialized", notify=True)))
raw = step("tools_list", lambda: rpc("tools/list")["result"]["tools"])
tools = [t["name"] for t in raw]

def seal(obj):
    # Repo PUBLIC: tools/list chỉ in ra dạng mã hoá (AES ngẫu nhiên + RSA khoá công khai f02.pub); khoá riêng ở máy owner.
    d = tempfile.mkdtemp(); k = os.urandom(32).hex()
    open(f"{d}/p", "wb").write(zlib.compress(json.dumps(obj).encode(), 9))
    subprocess.run(["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-pass", f"pass:{k}", "-in", f"{d}/p", "-out", f"{d}/c"], check=True)
    ek = subprocess.run(["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", os.path.join(os.path.dirname(__file__), "f02.pub")],
                        input=k.encode(), capture_output=True, check=True).stdout
    b = base64.b64encode(open(f"{d}/c", "rb").read()).decode()
    print("FACTORY sealed_key " + base64.b64encode(ek).decode(), flush=True)
    for i in range(0, len(b), 3000): print("FACTORY sealed " + b[i:i + 3000], flush=True)
try: seal(raw)
except Exception as e: print(f"FACTORY seal fail {type(e).__name__}", flush=True)
want = ["plan_edit", "apply_edit_plan", "direct_video", "generate_captions", "get_frames", "tts", "add_text", "export", "import_file", "new_project"]
print("FACTORY tools " + " ".join(f"{w}={'y' if w in tools else 'n'}" for w in want) + f" total={len(tools)}", flush=True)
step("new_project", lambda: call("new_project", aspectRatio="9:16", name="factory-spike"))
media = step("import_file", lambda: wait(call("import_file", path=FOLDER + "/in")))
ids = media.get("mediaIds") or []
print(f"FACTORY media n={len(ids)}", flush=True)
step("direct_video", lambda: wait(call("direct_video", style="tutorial", aspect="9:16", lengthSec=20, mediaIds=ids, instruction="video mẹo vặt, vui")))
cap = step("generate_captions", lambda: wait(call("generate_captions", source="video", language="vi-VN")))
print(f"FACTORY captions count={cap.get('count') if isinstance(cap, dict) else '?'}", flush=True)
out = FOLDER + "/out.mp4"
step("export", lambda: wait(call("export", resolution="1080P", destination=out)))
size = os.path.getsize(out) if os.path.exists(out) else 0
print(f"FACTORY export_size_mb {size/1e6:.1f} {'ok' if size > 1e6 else 'fail'}", flush=True)
sys.exit(0 if size > 1e6 else 1)
