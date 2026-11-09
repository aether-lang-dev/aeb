#!/usr/bin/env python3
"""A stand-in for github.com + api.github.com, for itests/gh-release-fallback.sh.

  gh-mock.py PORT DIR MODE

Every regular file in DIR (but requests.log) is a release asset. The web side
(/<o>/<r>/releases/download/<tag>/<file>) answers 504 for all of it, as
aether's did on 2026-11-09. The API side serves /repos/<o>/<r>/releases/tags/<tag>
and /repos/<o>/<r>/releases/assets/<id>, the latter only for
Accept: application/octet-stream, redirecting to /cdn/<file> as the real one
redirects to release-assets.githubusercontent.com.

MODE: ok | baddigest | noasset | apidown
Each request is appended to DIR/requests.log with its Authorization header.
"""
import hashlib, json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, d, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3]
files = sorted(f for f in os.listdir(d) if f != "requests.log" and os.path.isfile(os.path.join(d, f)))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body=b"", ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        with open(os.path.join(d, "requests.log"), "a") as f:
            f.write("GET %s auth=%s accept=%s\n" % (self.path, self.headers.get("Authorization", "-"),
                                                    self.headers.get("Accept", "-")))
        p = self.path
        if "/releases/download/" in p:
            return self._send(504, b"Gateway Timeout", "text/plain")
        if mode == "apidown" and p.startswith("/repos/"):
            return self._send(504, b"Gateway Timeout", "text/plain")
        m = re.match(r"^/repos/([^/]+)/([^/]+)/releases/tags/([^/]+)$", p)
        if m:
            assets = []
            for i, f in enumerate(files):
                if mode == "noasset": break
                data = open(os.path.join(d, f), "rb").read()
                dig = "0" * 64 if mode == "baddigest" else hashlib.sha256(data).hexdigest()
                # key order as the real API: url, id, node_id, name, label, uploader, ..., digest
                assets.append({"url": "http://x/repos/o/r/releases/assets/%d" % (1000 + i),
                               "id": 1000 + i, "node_id": "RA_x", "name": f, "label": None,
                               "uploader": {"login": "bot", "id": 7},
                               "content_type": "application/octet-stream", "state": "uploaded",
                               "size": len(data), "digest": "sha256:" + dig})
            return self._send(200, json.dumps({"id": 5, "name": m.group(3), "tag_name": m.group(3),
                                               "author": {"id": 9}, "assets": assets}, indent=2).encode())
        m = re.match(r"^/repos/([^/]+)/([^/]+)/releases/assets/(\d+)$", p)
        if m:
            if self.headers.get("Accept") != "application/octet-stream":
                return self._send(200, b"{}")
            return self._send(302, b"", extra={"Location": "/cdn/" + files[int(m.group(3)) - 1000]})
        m = re.match(r"^/cdn/(.+)$", p)
        if m:
            return self._send(200, open(os.path.join(d, m.group(1)), "rb").read(), "application/octet-stream")
        self._send(404, b"not found", "text/plain")

HTTPServer(("127.0.0.1", port), H).serve_forever()
