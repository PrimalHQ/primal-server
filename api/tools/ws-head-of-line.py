# ws-head-of-line.py WS_URL: on ONE connection send the slow anonymous reads feed first, then the five profile calls,
# and print when each EOSE arrives (request_concurrency check; needs ws-direct.py next to it, run with tools/websockets.sh)
import sys, json, time, zlib, asyncio, websockets
import importlib.util, os
_spec = importlib.util.spec_from_file_location("ws_direct", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ws-direct.py"))
_m = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_m); reqs = _m.reqs  # the request catalogue
url = sys.argv[1]
order = ["anon_reads", "p_profile", "p_scored", "p_reads", "p_tiers", "p_notes"]
async def main():
    t0 = time.time()
    async with websockets.connect(url, max_size=None, open_timeout=10) as ws:
        for name in order:
            func, kw = reqs[name]
            await ws.send(json.dumps(["REQ", name, {"cache": [func, kw]}]))
        done = set()
        while len(done) < len(order):
            m = await asyncio.wait_for(ws.recv(), 30)
            j = json.loads(m)
            if j[0] == "EOSE":
                done.add(j[1]); print("%6.2fs EOSE %s" % (time.time() - t0, j[1]), flush=True)
asyncio.run(main())
