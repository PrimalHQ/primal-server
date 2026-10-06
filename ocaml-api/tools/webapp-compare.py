# webapp-compare.py TAG_A TAG_B: line up the requests of two webapp-walk runs (frames-TAG.jsonl) by page and
# function (signed-event args and id lists normalised, replies attributed to the oldest open request of a subid)
# and flag unanswered/empty/notice differences; events inside zlib EVENTS frames are counted.
# compare.py TAG_A TAG_B : per page and request, messages/kinds/notices/latency from frames-TAG.jsonl
import sys, json, collections
def load(tag):
    page = None; reqs = {}; order = []
    for l in open("frames-%s.jsonl" % tag):
        t, d, m = json.loads(l)
        if d == "nav": page = m; continue
        if d.startswith("counts"): continue
        if d not in (">", "<"): continue
        try: j = json.loads(m)
        except Exception: continue
        if d == ">" and j[0] == "REQ":
            c = j[2].get("cache", [None, {}]); func = c[0]; args = c[1] if len(c) > 1 else {}
            def norm(k, v):
                if k == "event_from_user": return "<signed:%s>" % (v.get("kind") if isinstance(v, dict) else "?")
                if k in ("events", "event_ids", "pubkeys", "identifier"): return "<%d>" % len(v) if isinstance(v, list) else "<id>"
                return v
            key = (page, func, json.dumps({k: norm(k, v) for k, v in args.items() if k not in ("until", "since", "user_pubkey", "pubkey", "subid")}, sort_keys=True)[:140])
            r = {"t": t, "n": 0, "kinds": collections.Counter(), "eose": None, "notice": None, "key": key}
            reqs.setdefault(j[1], []).append(r); order.append(r)
        elif d == "<" and len(j) > 1:
            lst = reqs.get(j[1])
            if not lst: continue
            open_ = [r for r in lst if r["eose"] is None]
            r = open_[0] if open_ else lst[-1]
            if j[0] == "EVENTS":
                for e in j[2]:
                    r["n"] += 1; r["kinds"][e.get("kind")] += 1
            elif j[0] == "EVENT": r["n"] += 1; r["kinds"][j[2].get("kind")] += 1
            elif j[0] == "EOSE": r["eose"] = round(t - r["t"], 1)
            elif j[0] == "NOTICE": r["notice"] = str(j[2])[:80]
    return order
a, b = load(sys.argv[1]), load(sys.argv[2])
def group(order):
    g = collections.OrderedDict()
    for r in order: g.setdefault(r["key"], []).append(r)
    return g
ga, gb = group(a), group(b)
def fmt(rs):
    if not rs: return "-"
    return " | ".join("%s%s ev=%d %s%s" % ("" if r["eose"] is not None else "NO-EOSE ", "%.1fs" % r["eose"] if r["eose"] is not None else "", r["n"], ",".join("%s:%d" % kv for kv in sorted(r["kinds"].items(), key=lambda kv: -kv[1])[:4]), " NOTICE:" + r["notice"] if r["notice"] else "") for r in rs)
page = None
for key in list(ga) + [k for k in gb if k not in ga]:
    if key[0] != page: page = key[0]; print("\n=== %s" % page)
    ra, rb = ga.get(key, []), gb.get(key, [])
    flag = ""
    if not ra or not rb: flag = "ONLY-%s" % ("A" if ra else "B")
    elif any(r["eose"] is None for r in ra) and all(r["eose"] is not None for r in rb): flag = "A-UNANSWERED"
    elif any(r["notice"] for r in ra) != any(r["notice"] for r in rb): flag = "NOTICE-DIFF"
    elif sum(r["n"] for r in ra) == 0 and sum(r["n"] for r in rb) > 0: flag = "A-EMPTY"
    print("%-12s %-34s %s\n%13sA: %s\n%13sB: %s" % (flag, key[1], key[2][:90], "", fmt(ra), "", fmt(rb)))
