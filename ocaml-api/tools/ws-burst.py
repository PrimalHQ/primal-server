# Raw WebSocket client that controls the exact TCP writes (the httpun-ws frame-queue reproducer).
#   ws-burst.py HOST PORT burst|each [SIZES]
# SIZES (e.g. 3000,200 or 200,200,200): get_app_releases REQs padded to those byte sizes, after a
# set_primal_protocol zlib REQ (NOZLIB=1 skips it). Without SIZES, replays the ">" frames of
# ./frames-stage.jsonl (webapp-walk.py output). "burst" sends every frame in ONE write, "each" one
# write per frame with 20 ms gaps. Prints what comes back and how many subids were answered.
import sys, socket, os, struct, json, time, zlib, base64, select
host, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sizes = [int(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else []
UP = "532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb"
def req(sid, func, kw=None): return json.dumps(["REQ", sid, {"cache": [func] + ([kw] if kw is not None else [])}])
def frame(text, binary=False):
    payload = text.encode() if not binary else text
    op = 0x82 if binary else 0x81
    n = len(payload); mask = os.urandom(4)
    if n < 126: hdr = bytes([op, 0x80 | n])
    elif n < 65536: hdr = bytes([op, 0x80 | 126]) + struct.pack(">H", n)
    else: hdr = bytes([op, 0x80 | 127]) + struct.pack(">Q", n)
    return hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
msgs = [] if os.environ.get("NOZLIB") else [req("p", "set_primal_protocol", {"compression": "zlib"})]
if sizes:
    for i, sz in enumerate(sizes):
        # a get_app_releases request padded with a junk kwarg to the requested size
        base = req("r%d" % i, "get_app_releases", {"pad": ""})
        pad = max(0, sz - len(base))
        msgs.append(req("r%d" % i, "get_app_releases", {"pad": "x" * pad}))
else:
    for l in open("frames-stage.jsonl"):
        t, d, m = json.loads(l)
        if t > 24: break
        if d == ">": msgs.append(m)
    msgs = [m for i, m in enumerate(msgs) if not (i > 0 and "set_primal_protocol" in m)]
s = socket.create_connection((host, port)); s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /v1 HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (host, key)).encode())
buf = b""
while b"\r\n\r\n" not in buf: buf += s.recv(4096)
hdr, buf = buf.split(b"\r\n\r\n", 1)
print("handshake:", hdr.split(b"\r\n")[0].decode())
data = b"".join(frame(m) for m in msgs)
t0 = time.time()
if mode == "burst": s.sendall(data); print("sent %d bytes in one write (%d frames)" % (len(data), len(msgs)))
else:
    for m in msgs: s.sendall(frame(m)); time.sleep(0.02)
    print("sent %d frames separately" % len(msgs))
# read server frames for 8 s
def parse(buf):
    out = []
    while len(buf) >= 2:
        op = buf[0] & 0x0f; n = buf[1] & 0x7f; o = 2
        if n == 126:
            if len(buf) < 4: break
            n = struct.unpack(">H", buf[2:4])[0]; o = 4
        elif n == 127:
            if len(buf) < 10: break
            n = struct.unpack(">Q", buf[2:10])[0]; o = 10
        if len(buf) < o + n: break
        out.append((op, buf[o:o+n])); buf = buf[o+n:]
    return out, buf
deadline = time.time() + 8
seen = []
while time.time() < deadline:
    r, _, _ = select.select([s], [], [], 0.2)
    if not r: continue
    d = s.recv(1 << 20)
    if not d: print("%.2f EOF" % (time.time()-t0)); break
    buf += d
    frames, buf = parse(buf)
    for op, p in frames:
        if op == 2:
            try: p = zlib.decompress(p)
            except Exception: pass
        try: j = json.loads(p); seen.append(j[1]); print("%6.2f < %s %s %s" % (time.time()-t0, j[0], j[1][:30], ("n=%d" % len(j[2])) if j[0]=="EVENTS" else ""))
        except Exception: print("%6.2f < op=%d len=%d" % (time.time()-t0, op, len(p)))
print("answered subids:", len(set(seen)), "of", len(msgs))
s.close()
