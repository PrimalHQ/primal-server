"""Bootstrap a new self-hosted cache: fetch the follow graph around the TrustRank seeds from relays
and import it through the importer's import listener, so TrustRank (and with it scores and
trending) has something to work on before follow lists arrive by themselves.

  bootstrap.py SEEDS_FILE RELAYS_FILE IMPORT_HOST IMPORT_PORT [TOP]

1. the seeds' profiles (0), follow lists (3) and relay lists (10002);
2. the profiles of everyone the seeds follow;
3. the follow lists of the TOP (default 1000) accounts the most seeds follow.
Stdlib only; run by `selfhost/primal.sh bootstrap` (and by the first `start`).
"""

import base64
import json
import os
import socket
import ssl
import struct
import sys
import time
from collections import Counter
from urllib.parse import urlparse


def ws_connect(url, timeout=15):
    u = urlparse(url)
    port = u.port or (443 if u.scheme == "wss" else 80)
    s = socket.create_connection((u.hostname, port), timeout=timeout)
    if u.scheme == "wss":
        s = ssl.create_default_context().wrap_socket(s, server_hostname=u.hostname)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET {u.path or '/'} HTTP/1.1\r\nHost: {u.hostname}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise ConnectionError("closed during handshake")
        buf += chunk
    if b" 101 " not in buf.split(b"\r\n", 1)[0]:
        raise ConnectionError(buf.split(b"\r\n", 1)[0].decode(errors="replace"))
    return s, buf.split(b"\r\n\r\n", 1)[1]


def ws_send(s, obj):
    p = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(p)
    hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536
                           else bytes([0x80 | 127]) + struct.pack(">Q", n))
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(p)))


class Reader:
    def __init__(self, s, buf):
        self.s, self.buf = s, buf

    def need(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk

    def frame(self):
        """next text message as JSON (fragments joined, pings answered, other frames skipped)"""
        msg, text = b"", False
        while True:
            self.need(2)
            fin, op, ln, o = self.buf[0] & 0x80, self.buf[0] & 0x0F, self.buf[1] & 0x7F, 2
            if ln == 126:
                self.need(4); ln = struct.unpack(">H", self.buf[2:4])[0]; o = 4
            elif ln == 127:
                self.need(10); ln = struct.unpack(">Q", self.buf[2:10])[0]; o = 10
            self.need(o + ln)
            data, self.buf = self.buf[o:o + ln], self.buf[o + ln:]
            if op == 8:
                raise ConnectionError("closed by relay")
            if op == 9:
                ws_send_pong(self.s, data)
            elif op in (0, 1):
                if op == 1:
                    msg, text = data, True
                else:
                    msg += data
                if fin and text:
                    return json.loads(msg)


def ws_send_pong(s, data):
    mask = os.urandom(4)
    s.sendall(bytes([0x8A, 0x80 | len(data)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def fetch(relays, filters, deadline_s=60, open_max=8):
    """events matching filters from each relay (until EOSE; at most open_max subscriptions open at
    once), newest per (pubkey, kind)"""
    best = {}
    for url in relays:
        try:
            s, rest = ws_connect(url)
            r = Reader(s, rest)
            subs, pending = {}, list(enumerate(filters))
            end = time.time() + deadline_s
            while (subs or pending) and time.time() < end:
                while pending and len(subs) < open_max:
                    i, f = pending.pop(0)
                    subs[f"b{i}"] = True
                    ws_send(s, ["REQ", f"b{i}", f])
                s.settimeout(max(1, end - time.time()))
                m = r.frame()
                if m[0] == "EVENT" and len(m) > 2:
                    e = m[2]
                    k = (e.get("pubkey"), e.get("kind"))
                    if k not in best or e.get("created_at", 0) > best[k].get("created_at", 0):
                        best[k] = e
                elif m[0] in ("EOSE", "CLOSED") and len(m) > 1 and m[1] in subs:
                    subs.pop(m[1])
                    ws_send(s, ["CLOSE", m[1]])
            s.close()
        except (OSError, ValueError, ConnectionError) as exc:
            print(f"  {url}: {exc}", file=sys.stderr)
    return best


def batches(xs, n):
    xs = list(xs)
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def import_events(host, port, events):
    total = Counter()
    with socket.create_connection((host, port), timeout=120) as s:
        f = s.makefile("rwb")
        for b in batches(events, 200):
            f.write((json.dumps(["IMPORT", b]) + "\n").encode())
            f.flush()
            reply = json.loads(f.readline())
            if reply[0] == "OK" and isinstance(reply[1], dict):
                total.update(reply[1])
    return total


def main():
    seeds_file, relays_file, host, port = sys.argv[1:5]
    top = int(sys.argv[5]) if len(sys.argv) > 5 else 1000
    seeds = [ln.split()[0] for ln in open(seeds_file) if ln.strip() and not ln.startswith("#")]
    relays = [ln.strip() for ln in open(relays_file) if ln.strip().startswith("ws")][:6]
    print(f"bootstrap: {len(seeds)} seeds, relays {', '.join(relays)}")

    ev = fetch(relays, [{"kinds": [0, 3, 10002], "authors": seeds}])
    follows = Counter()
    for (pk, kind), e in ev.items():
        if kind == 3:
            follows.update({t[1] for t in e.get("tags", []) if len(t) > 1 and t[0] == "p" and len(t[1]) == 64})
    print(f"  seeds: {len(ev)} events, {len(follows)} accounts followed")

    profiles = fetch(relays, [{"kinds": [0], "authors": b, "limit": len(b)} for b in batches(follows, 100)], deadline_s=180)
    ev.update(profiles)
    hubs = [pk for pk, _ in follows.most_common(top)]
    lists = fetch(relays, [{"kinds": [3], "authors": b, "limit": len(b)} for b in batches(hubs, 100)], deadline_s=180)
    ev.update(lists)
    print(f"  {len(profiles)} profiles, {len(lists)} follow lists of the {len(hubs)} most followed")

    counts = import_events(host, int(port), list(ev.values()))
    print(f"bootstrap: imported {dict(counts)}")


if __name__ == "__main__":
    main()
