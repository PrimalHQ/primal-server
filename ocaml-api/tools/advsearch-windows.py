# advsearch-windows.py HOST WANT [UNTIL]: emulate Advsearch.run's window loop (1h, x4 while empty, back to 1h after a
# hit, 9 s deadline) for the query in ./reads-window.sql (from `primalctl advsearch-sql`) through psql, printing each
# window's span, time and hits — shows where a slow feed page spends its time.
import sys, time, subprocess, re
host, want = sys.argv[1], int(sys.argv[2]); until = int(sys.argv[3]) if len(sys.argv) > 3 else int(time.time())
sql = open("reads-window.sql").read().strip()
t, dt, have, w, start = until, 3600, 0, 0, time.time(); seen = set()
while have < want and w < 80:
    s = t - dt
    q = re.sub(r"published_at >= \d+", "published_at >= %d" % s, sql); q = re.sub(r"published_at <= \d+", "published_at <= %d" % t, q)
    script = "set statement_timeout=9000;\nbegin;\ndeclare cur no scroll cursor for %s;\nfetch %d from cur;\nrollback;\n" % (q, want - have)
    t0 = time.time()
    out = subprocess.run(["psql", "-h", host, "-p", "54017", "-U", "pr", "primal1", "-At"], input=script, capture_output=True, text=True).stdout
    rows = [l for l in out.splitlines() if l.startswith("\\x") and l.split("|")[0] not in seen]
    for l in rows: seen.add(l.split("|")[0])
    w += 1
    print("win %2d  back %6.1fh .. %6.1fh  dt=%6dh  %6.0f ms  rows %d" % (w, (until - s) / 3600, (until - t) / 3600, dt / 3600, (time.time() - t0) * 1000, len(rows)), flush=True)
    if rows: have += len(rows); t = int(rows[-1].split("|")[1]); dt = 3600
    else: t = s; dt *= 4
    if time.time() - start > 9: print("deadline 9 s hit"); break
print("total %.1f s, windows %d, rows %d" % (time.time() - start, w, have))
