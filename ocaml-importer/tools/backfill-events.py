# backfill-events.py START END [batch] [step_hours]: pull kind-30023 events from a peer cache DB (<julia-host>) by
# created_at window and push them through this host's import listener (["IMPORT", [events]] lines on
# 127.0.0.1:12118); the DAG re-covers by imported_at, so derived tables (reads, ...) follow. Idempotent.
# Used 2026-10-06 to backfill <stage-host>'s missing long-form events of 2026-07-13..09-30 (274,902 imported,
# 1,719 rejected by the importer gate, ~60 events/s with three parallel date ranges).
import sys, json, socket, subprocess, time, datetime
start = datetime.datetime.fromisoformat(sys.argv[1]).replace(tzinfo=datetime.timezone.utc)
end = datetime.datetime.fromisoformat(sys.argv[2]).replace(tzinfo=datetime.timezone.utc)
batch = int(sys.argv[3]) if len(sys.argv) > 3 else 200
step = datetime.timedelta(hours=int(sys.argv[4])) if len(sys.argv) > 4 else datetime.timedelta(days=1)
SQL = ("select json_build_object('id', encode(id,'hex'), 'pubkey', encode(pubkey,'hex'), 'created_at', created_at, 'kind', kind, "
       "'tags', tags, 'content', content, 'sig', encode(sig,'hex'))::text from event where created_at >= %d and created_at < %d and kind = 30023 order by created_at")
tot = {"imported": 0, "duplicates": 0, "rejected": 0, "errors": 0}
def send(sock, f, evs):
    sock.sendall((json.dumps(["IMPORT", evs]) + "\n").encode())
    line = f.readline()
    r = json.loads(line)
    if r[0] != "OK": raise RuntimeError(line)
    for k in tot: tot[k] += r[1].get(k, 0)
    return r[1]
t = start
while t < end:
    t0 = time.time()
    s, u = int(t.timestamp()), int((t + step).timestamp())
    out = subprocess.run(["psql", "-h", "<julia-host>", "-p", "54017", "-U", "pr", "primal1", "-At", "-c", "set statement_timeout=120000", "-c", SQL % (s, u)],
                         capture_output=True, text=True)
    if out.returncode != 0: print("psql failed", t, out.stderr[:200], flush=True); sys.exit(1)
    evs = [json.loads(l) for l in out.stdout.split("\n") if l.startswith("{")]
    pulled = time.time()
    sock = socket.create_connection(("127.0.0.1", 12118)); f = sock.makefile("r")
    day = {"imported": 0, "duplicates": 0, "rejected": 0, "errors": 0}
    for i in range(0, len(evs), batch):
        r = send(sock, f, evs[i:i + batch])
        for k in day: day[k] += r.get(k, 0)
    sock.close()
    print("%s  %5d events  pull %.1fs  import %.1fs  %s" % (t.date() if step >= datetime.timedelta(days=1) else t.isoformat()[:13], len(evs), pulled - t0, time.time() - pulled, day), flush=True)
    t += step
print("TOTAL", tot, flush=True)
