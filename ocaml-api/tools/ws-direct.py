# ws-direct.py NAME[,NAME..] WS_URL...: send one named request (see `reqs`) to each server concurrently and print
# duration, message count, kinds and notification types; a quick same-data check between two API servers.
import sys, json, time, zlib, asyncio, websockets, collections
QA = "88cc134b1a65f54ef48acc1df3665063d3ea45f04eab8af4646e561c5ae99079"
reqs = {
 "reads": ["mega_feed_directive", {"spec": "{\"id\":\"nostr-reads-feed\",\"kind\":\"reads\"}", "limit": 20, "offset": 0, "user_pubkey": QA}],
 "notifs": ["get_notifications", {"pubkey": QA, "user_pubkey": QA, "limit": 20, "type_group": "all"}],
 "reads1": ["mega_feed_directive", {"spec": "{\"id\":\"nostr-reads-feed\",\"kind\":\"reads\"}", "limit": 20, "offset": 1, "until": int(time.time()) - 86400, "user_pubkey": QA}],
 "home1": ["multi_kind_mega_feed_directive", {"spec": "{\"id\":\"latest\",\"kind\":\"notes\"}", "limit": 20, "offset": 1, "until": int(time.time()) - 7200, "kinds": [1,6,1068,6969], "user_pubkey": QA}],
 "notifs_old": ["get_notifications", {"pubkey": QA, "user_pubkey": QA, "limit": 20, "type_group": "all", "until": 1758700000}],
 "home": ["multi_kind_mega_feed_directive", {"spec": "{\"id\":\"latest\",\"kind\":\"notes\"}", "limit": 20, "offset": 0, "kinds": [1,6,1068,6969], "user_pubkey": QA}],
}
async def one(url, name):
    func, kw = reqs[name]
    t0 = time.time(); kinds = collections.Counter(); ntypes = collections.Counter(); notice = None; n = 0
    try:
        async with websockets.connect(url, max_size=None, open_timeout=10) as ws:
            await ws.send(json.dumps(["REQ", "x", {"cache": [func, kw]}]))
            while True:
                m = await asyncio.wait_for(ws.recv(), 40)
                j = json.loads(m)
                if j[0] == "EOSE": break
                if j[0] == "NOTICE": notice = j[2]; break
                if j[0] == "EVENT":
                    n += 1; e = j[2]; kinds[e.get("kind")] += 1
                    if e.get("kind") == 10000110: ntypes[json.loads(e["content"]).get("type")] += 1
    except Exception as ex: notice = "EXC %r" % ex
    print("%-28s %-7s %5.1fs n=%-4d %s %s %s" % (url, name, time.time()-t0, n, dict(sorted(kinds.items(), key=lambda kv:-kv[1])[:5]), dict(ntypes) if ntypes else "", notice or ""), flush=True)
async def main():
    for name in sys.argv[1].split(","):
        await asyncio.gather(*[one(u, name) for u in sys.argv[2:]])
asyncio.run(main())
