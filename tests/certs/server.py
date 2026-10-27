"""tests/certs.sh's HTTPS server, on Python's image:

    python server.py <port> <cert> <key> <ready file>

It serves https://localhost:<port> on 127.0.0.1 and ::1: /ok answers "ok",
/pkg.tar.gz is a small tarball (for zig fetch), and anything else is 404,
which git reports as a repository that isn't there, not a TLS error. Once it
listens, it makes the ready file. It runs until it's ended.
"""

import http.server
import io
import socket
import ssl
import sys
import tarfile
import threading

port, cert, key, ready = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]


def tarball():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        data = b"hello\n"
        info = tarfile.TarInfo("pkg/hello.txt")
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


bodies = {"/ok": b"ok\n", "/pkg.tar.gz": tarball()}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = bodies.get(self.path.split("?")[0])
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    """Does each connection's handshake in its thread: a client that refuses
    the certificate doesn't hold up the others."""

    def finish_request(self, request, client_address):
        try:
            request = context.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError):
            return
        super().finish_request(request, client_address)


class Server6(Server):
    address_family = socket.AF_INET6


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
servers = [Server(("127.0.0.1", port), Handler), Server6(("::1", port), Handler)]
threading.Thread(target=servers[1].serve_forever, daemon=True).start()
open(ready, "w").close()
servers[0].serve_forever()
