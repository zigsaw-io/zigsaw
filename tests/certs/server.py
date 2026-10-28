"""tests/certs.sh's HTTPS server, on Python's image:

    python server.py <port> <cert> <key> <ready file> [<http port> <crl>]

It serves https://localhost:<port> on 127.0.0.1 and ::1: /ok answers "ok",
/pkg.tar.gz is a small tarball (for zig fetch), /packages.json a Composer
repository with one package, zigsaw/certs 1.0.0, whose archive isn't there
(a dry run doesn't fetch it), and anything else is 404, which git reports as a
repository that isn't there, not a TLS error. Given an HTTP port and a CRL
file, it also serves http://localhost:<http port>, the same and /ca.crl,
where the certificate's CRL distribution point says (clients that check
revocation through Windows, as curl over Schannel does, fetch it). Once it
listens, it makes the ready file. It runs until it's ended.
"""

import http.server
import io
import json
import socket
import ssl
import sys
import tarfile
import threading

port, cert, key, ready = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
http_port, crl = (int(sys.argv[5]), sys.argv[6]) if len(sys.argv) > 6 else (None, None)


def tarball():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        data = b"hello\n"
        info = tarfile.TarInfo("pkg/hello.txt")
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


# path: (content type, body). zig fetch wants a content type it knows.
bodies = {
    "/ok": ("text/plain", b"ok\n"),
    "/pkg.tar.gz": ("application/gzip", tarball()),
    "/packages.json": ("application/json", json.dumps({"packages": {"zigsaw/certs": {"1.0.0": {
        "name": "zigsaw/certs",
        "version": "1.0.0",
        "dist": {"type": "zip", "url": f"https://localhost:{port}/certs.zip"},
    }}}}).encode()),
}
if crl:
    with open(crl, "rb") as f:
        bodies["/ca.crl"] = ("application/pkix-crl", f.read())


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        found = bodies.get(self.path.split("?")[0])
        if found is None:
            self.send_error(404)
            return
        kind, body = found
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class Plain(http.server.ThreadingHTTPServer):
    pass


class Plain6(Plain):
    address_family = socket.AF_INET6


class Server(Plain):
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
if http_port:
    servers += [Plain(("127.0.0.1", http_port), Handler), Plain6(("::1", http_port), Handler)]
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
open(ready, "w").close()
servers[0].serve_forever()
