#!/usr/bin/env python3
"""Tóm tắt .ips: loại exception + lý do + 8 khung đầu của luồng chết (chỉ tên ảnh + hàm)."""
import json, sys
t = open(sys.argv[1]).read()
head, _, body = t.partition("\n")
try: d = json.loads(body)
except Exception: print("unparsed"); sys.exit()
e = d.get("exception", {}); print(f"type={e.get('type')} sig={e.get('signal')} sub={e.get('subtype','')[:80]}")
print(f"term={str(d.get('termination', {}).get('indicator', ''))[:120]}")
if d.get("asi"): print("asi=" + " | ".join(str(v)[:160] for v in d["asi"].values())[:300])
imgs = d.get("usedImages", [])
for fr in (d.get("lastExceptionBacktrace") or [])[:14]:
    img = imgs[fr["imageIndex"]].get("name", "?") if fr.get("imageIndex", -1) < len(imgs) else "?"
    print(f"exc {img} {str(fr.get('symbol', '?'))[:140]}")
th = next((x for x in d.get("threads", []) if x.get("triggered")), None) or {}
for fr in (th.get("frames") or [])[:8]:
    img = imgs[fr["imageIndex"]].get("name", "?") if fr.get("imageIndex", -1) < len(imgs) else "?"
    print(f"frame {img} {str(fr.get('symbol', '?'))[:120]}")
