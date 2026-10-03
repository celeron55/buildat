#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4, protocol fuzzing: a raw client sending every
# packet name a server module listens for, with payloads that are random or
# shaped like cereal's portable binary and then broken (lengths in the
# gigabytes, cut short, wrong types), over a few connections at once,
# reconnecting when the server drops one. It watches nothing itself;
# proto_fuzz.sh watches the server.
#
#   proto_fuzz.py <port> <seconds> <names file> [seed]
import os, random, socket, struct, sys, time

port, seconds = int(sys.argv[1]), float(sys.argv[2])
names = [l.strip() for l in open(sys.argv[3]) if l.strip()]
rnd = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else None)

def packet(t, data):
    return struct.pack("<HI", t, len(data)) + data

def define(t, name):
    n = name.encode()
    return packet(0, struct.pack("<HI", t, len(n)) + n)

def u64(n):
    return struct.pack("<Q", n)

def cereal_value(depth=0):
    k = rnd.randrange(8)
    if k == 0:   # a string
        s = os.urandom(rnd.choice([0, 1, 5, 40, 300]))
        return u64(len(s)) + s
    if k == 1:   # a string that says it is huge
        return u64(rnd.choice([2**31, 2**32 + 5, 2**63, 2**64 - 1])) + b"ab"
    if k == 2:   # a vector of values
        n = rnd.choice([0, 1, 3, 10])
        out = u64(n)
        for _ in range(n):
            out += cereal_value(depth + 1) if depth < 3 else b"\x00"
        return out
    if k == 3:   # a vector that says it is huge
        return u64(rnd.choice([10**6, 2**40, 2**64 - 1]))
    if k == 4:
        return struct.pack("<i", rnd.randrange(-2**31, 2**31))
    if k == 5:
        return struct.pack("<d", rnd.choice([0.0, -1.0, 1e308, float("nan"),
                float("inf")]))
    if k == 6:
        return bytes([rnd.randrange(256)])
    return os.urandom(rnd.randrange(0, 16))

def payload():
    k = rnd.randrange(5)
    if k == 0:
        return b""
    if k == 1:
        return os.urandom(rnd.randrange(1, 200))
    # A portable binary archive: the endianness byte, then values
    out = bytes([1]) + b"".join(cereal_value() for _ in range(rnd.randrange(1, 6)))
    if k == 3 and len(out) > 2:   # cut short
        out = out[:rnd.randrange(1, len(out))]
    if k == 4:                    # a byte flipped
        b = bytearray(out)
        b[rnd.randrange(len(b))] ^= 1 << rnd.randrange(8)
        out = bytes(b)
    return out

class Conn:
    def __init__(self):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.s.setblocking(False)
        self.types = {}
        self.next = 100

    def send(self, name, data):
        out = b""
        if name not in self.types:
            self.types[name] = self.next
            out += define(self.next, name)
            self.next += 1
        out += packet(self.types[name], data)
        self.s.sendall(out)

    def drain(self):
        try:
            while self.s.recv(65536):
                pass
        except BlockingIOError:
            pass

conns, sent, dropped = [], 0, 0
end = time.time() + seconds
while time.time() < end:
    while len(conns) < 3:
        try:
            conns.append(Conn())
        except OSError:
            time.sleep(0.5)
            break
    for c in list(conns):
        try:
            c.drain()
            for _ in range(rnd.randrange(1, 20)):
                c.send(rnd.choice(names), payload())
                sent += 1
        except (OSError, BrokenPipeError, ConnectionResetError):
            conns.remove(c)
            dropped += 1
    time.sleep(0.01)
print("sent %d packets, %d connections dropped by the server" % (sent, dropped))
