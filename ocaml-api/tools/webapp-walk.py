import sys, json, time, zlib, re
from playwright.sync_api import sync_playwright
cache = sys.argv[1]            # e.g. wss://stage.primal.net/v1
tag = sys.argv[2]
pages = sys.argv[3].split(",") if len(sys.argv) > 3 else ["/home", "/reads"]
frames = []   # (t, dir, text)
t0 = time.time()
def dec(payload):
    if isinstance(payload, (bytes, bytearray)):
        try: return zlib.decompress(payload).decode()
        except Exception as e: return "<<binary %d %s>>" % (len(payload), e)
    return payload
with sync_playwright() as p:
    b = p.chromium.launch(headless=True)
    ctx = b.new_context(viewport={"width": 1400, "height": 1000})
    ctx.add_init_script("try{localStorage.setItem('cacheServer', %s)}catch(e){}" % json.dumps(cache))
    pg = ctx.new_page()
    cons = []
    pg.on("console", lambda m: cons.append((round(time.time()-t0,1), m.type, m.text[:300])))
    pg.on("pageerror", lambda e: cons.append((round(time.time()-t0,1), "pageerror", str(e)[:300])))
    def on_ws(ws):
        frames.append((round(time.time()-t0,1), "open", ws.url))
        ws.on("framesent", lambda f: frames.append((round(time.time()-t0,1), ">", dec(f))))
        ws.on("framereceived", lambda f: frames.append((round(time.time()-t0,1), "<", dec(f))))
        ws.on("close", lambda w: frames.append((round(time.time()-t0,1), "close", ws.url)))
        ws.on("socketerror", lambda e: frames.append((round(time.time()-t0,1), "socketerror", str(e))))
    pg.on("websocket", on_ws)
    for path in pages:
        frames.append((round(time.time()-t0,1), "nav", path))
        pg.goto("https://primal.net" + path, wait_until="domcontentloaded", timeout=60000)
        pg.wait_for_timeout(9000)
        def counts():
            return pg.evaluate("""() => ({
              notes: document.querySelectorAll('[data-event]').length,
              articles: document.querySelectorAll('a[href^="/a/"]').length,
              links_e: document.querySelectorAll('a[href^="/e/"]').length,
              sidebar_trending: document.querySelectorAll('[class*="sidebar"] a[href^="/e/"], [class*="Sidebar"] a[href^="/e/"]').length,
              text_len: document.body.innerText.length,
              height: document.body.scrollHeight,
              scrollY: window.scrollY,
            })""")
        c1 = counts(); frames.append((round(time.time()-t0,1), "counts-initial", json.dumps(c1)))
        for i in range(3):
            pg.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            pg.mouse.wheel(0, 20000)
            pg.wait_for_timeout(5000)
            ci = counts(); frames.append((round(time.time()-t0,1), "counts-scroll%d" % (i+1), json.dumps(ci)))
        pg.screenshot(path="shot-%s%s.png" % (tag, path.replace("/", "_")), full_page=False)
        txt = pg.evaluate("document.body.innerText")
        open("text-%s%s.txt" % (tag, path.replace("/", "_")), "w").write(txt)
    b.close()
with open("frames-%s.jsonl" % tag, "w") as f:
    for fr in frames: f.write(json.dumps(fr) + "\n")
with open("console-%s.txt" % tag, "w") as f:
    for c in cons: f.write("%s %s %s\n" % c)
# summary: per request subid -> sent count, events, eose, notice
reqs = {}
order = []
for t, d, m in frames:
    if d in ("nav", "open", "close", "socketerror") or d.startswith("counts"):
        print("%6.1f %-14s %s" % (t, d, m)); continue
    try: j = json.loads(m)
    except Exception: print("%6.1f %s UNPARSEABLE %s" % (t, d, str(m)[:100])); continue
    if d == ">" and j[0] == "REQ":
        sid = j[1]; func = j[2]["cache"][0]; args = j[2]["cache"][1] if len(j[2]["cache"]) > 1 else {}
        key = (sid, func)
        reqs.setdefault(sid, []).append({"t": t, "func": func, "args": json.dumps(args)[:160], "events": 0, "kinds": {}, "eose": None, "notice": None})
        order.append(sid)
    elif d == "<":
        sid = j[1] if len(j) > 1 else None
        r = reqs.get(sid, [None])[-1]
        if r is None: print("%6.1f < unmatched %s" % (t, m[:120])); continue
        if j[0] == "EVENT":
            r["events"] += 1; k = j[2].get("kind"); r["kinds"][k] = r["kinds"].get(k, 0) + 1
        elif j[0] == "EOSE": r["eose"] = t
        elif j[0] == "NOTICE": r["notice"] = str(j[2])[:200]
        else: print("%6.1f < other %s" % (t, m[:120]))
seen = set()
for sid in order:
    for r in reqs[sid]:
        k = (sid, r["t"])
        if k in seen: continue
        seen.add(k)
        print("%6.1f %-40s %-32s ev=%-4d eose=%-6s %s %s" % (r["t"], sid[:40], r["func"], r["events"], r["eose"], "NOTICE:"+r["notice"] if r["notice"] else "", r["args"]))
