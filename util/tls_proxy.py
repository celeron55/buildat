#!/usr/bin/env python3
# A TLS front for a check, as the user's proxy is in production: each
# "port:target" listens with TLS on port. A target "host:port" is a
# buildat server, reached with X-Forwarded-For added to the request's
# head (the server trusts it from loopback); a target that is a directory
# is served as static files.
#   util/tls_proxy.py <cert.pem> <key.pem> port:target...
import functools, http.server, os, socket, ssl, sys, threading

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])

def pipe(a, b):
    try:
        while (d := a.recv(65536)):
            b.sendall(d)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

def forward(c, addr, target):
    try:
        c = ctx.wrap_socket(c, server_side=True)
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 65536:
            d = c.recv(4096)
            if not d:
                return c.close()
            head += d
        line, rest = head.split(b"\r\n", 1)
        head = line + b"\r\nX-Forwarded-For: " + addr[0].encode() + b"\r\n" + rest
        h, p = target.rsplit(":", 1)
        b = socket.create_connection((h, int(p)))
        b.sendall(head)
        threading.Thread(target=pipe, args=(b, c), daemon=True).start()
        pipe(c, b)
    except (OSError, ssl.SSLError) as e:
        print("tls_proxy:", e, flush=True)

def tcp(port, target):
    s = socket.create_server(("127.0.0.1", port))
    while True:
        c, addr = s.accept()
        threading.Thread(target=forward, args=(c, addr, target),
                daemon=True).start()

def files(port, d):
    h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=d)
    s = http.server.ThreadingHTTPServer(("127.0.0.1", port), h)
    s.socket = ctx.wrap_socket(s.socket, server_side=True)
    s.serve_forever()

for a in sys.argv[3:]:
    port, target = a.split(":", 1)
    threading.Thread(target=files if os.path.isdir(target) else tcp,
            args=(int(port), target), daemon=True).start()
print("tls_proxy: up", flush=True)
threading.Event().wait()
