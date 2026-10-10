#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Offline HTTP fixture for packaged-app navigation and reader checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
from html import escape
from time import sleep
from pathlib import Path
from threading import Event

retry_enabled = Event()

PAGE = b'''<!doctype html><html><head><title>Radius HTTP fixture</title></head>
<body><main><h1>Local browser check</h1><p>This page is served from loopback, without internet access.</p>
<a href="/next">Navigate</a><a href="/popup" target="_blank">Open a tab</a>
<form action="/submitted" method="post" target="_blank"><input name="test" value="preserved"><button>Submit</button></form>
<input type="file" multiple></main></body></html>'''

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow-download":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="radius-download-fixture.bin"')
            self.send_header("Content-Length", str(1024 * 1024))
            self.end_headers()
            try:
                for _ in range(64):
                    self.wfile.write(b"r" * (16 * 1024))
                    self.wfile.flush()
                    sleep(0.15)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path == "/navigation-retry/enable":
            retry_enabled.set()
        elif self.path == "/navigation-retry" and not retry_enabled.is_set():
            # A genuine provisional network failure, with no committed HTTP
            # response. The same address becomes available for native Retry.
            self.close_connection = True
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            self.close_connection = True
            return
        if length < 0 or length > 16 * 1024:
            self.send_error(413, "Fixture request body exceeds 16 KB")
            self.close_connection = True
            return
        submitted = self.rfile.read(length)
        if self.path != "/submitted":
            self.do_GET()
            return
        body = escape(submitted.decode("utf-8", errors="replace"))
        page = (
            "<!doctype html><html><head><title>Radius POST fixture</title></head>"
            '<body><output id="request-method">POST</output>'
            f'<pre id="submitted-body">{body}</pre>'
            "<script>if (window.opener) window.opener.radiusPostPopup = window;</script>"
            "</body></html>"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port-file", type=Path, help="Write a dynamically allocated loopback port when ready.")
args = parser.parse_args()
server = ThreadingHTTPServer(("127.0.0.1", 0 if args.port_file else 8765), Handler)
if args.port_file:
    args.port_file.write_text(str(server.server_port), encoding="ascii")
print(f"Fixture ready at http://127.0.0.1:{server.server_port}/", flush=True)
server.serve_forever()
