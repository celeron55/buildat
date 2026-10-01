#!/usr/bin/env python3
# Checks a running server's one port for HTTP, WebSocket and the native
# protocol ([WEB_CLIENT]). Usage: util/test_web_transport.py host:port
# The web directory needs index.html for the 200 check.
import asyncio, socket, sys, urllib.error, urllib.request
import websockets

host, port = sys.argv[1].rsplit(":", 1)
base = f"http://{host}:{port}"

def status(path):
    try:
        return urllib.request.urlopen(base + path, timeout=5).status
    except urllib.error.HTTPError as e:
        return e.code

# A packet header is type (u16 le) and size (u32 le); the server's first
# packet on connect is core:define_packet_type, type 0
def first_type(data):
    assert len(data) >= 6, data
    return data[0] | data[1] << 8

assert status("/index.html") == 200, "index.html"
assert status("/?x=1") == 200, "/ with a query"
assert status("/nope") == 404, "missing path"
print("http ok")

# The same file again with its ETag is a 304; deflate is what was asked for
import zlib
r = urllib.request.urlopen(urllib.request.Request(base + "/index.html",
        headers={"Accept-Encoding": "deflate"}), timeout=5)
assert r.headers["Content-Encoding"] == "deflate", r.headers
assert b"<html" in zlib.decompress(r.read()), "deflated index.html"
etag = r.headers["ETag"]
assert etag, "no ETag"
try:
    code = urllib.request.urlopen(urllib.request.Request(base + "/index.html",
            headers={"If-None-Match": etag}), timeout=5).status
except urllib.error.HTTPError as e:
    code = e.code
assert code == 304, code
print("etag and deflate ok")

async def ws():
    async with websockets.connect(f"ws://{host}:{port}/",
            subprotocols=["binary"], max_size=None) as c:
        assert c.subprotocol == "binary", c.subprotocol
        data = await asyncio.wait_for(c.recv(), 5)
        assert isinstance(data, bytes) and first_type(data) == 0, data[:16]
        # A core:define_packet_type over 64 KiB (a 64 bit frame length),
        # sent as a message of three frames; harmless to the game
        name = b"test:" + b"x" * 70000
        body = bytes([200, 0]) + len(name).to_bytes(4, "little") + name
        pkt = bytes([0, 0]) + len(body).to_bytes(4, "little") + body
        await c.send([pkt[:3], pkt[3:10], pkt[10:]])
        await asyncio.wait_for(await c.ping(), 5)
        print("websocket ok:", len(data), "bytes, pong")
asyncio.run(ws())

# An oversized request is dropped
s = socket.create_connection((host, int(port)), timeout=5)
s.sendall(b"GET / HTTP/1.1\r\nX: " + b"x" * 9000)
assert s.recv(100) == b"", "oversized request not dropped"
s.close()
print("oversized request dropped")

s = socket.create_connection((host, int(port)), timeout=5)
data = s.recv(65536)
assert first_type(data) == 0, data[:16]
s.close()
print("native ok:", len(data), "bytes")
