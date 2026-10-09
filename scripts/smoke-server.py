#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Offline HTTP fixture for packaged-app navigation and reader checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
from pathlib import Path

PAGE = b'''<!doctype html><html><head><title>Radius HTTP fixture</title></head>
<body><main><h1>Local browser check</h1><p>This page is served from loopback, without internet access.</p>
<a href="/next">Navigate</a><a href="/popup" target="_blank">Open a tab</a>
<form action="/submitted" method="post" target="_blank"><input name="test" value="preserved"><button>Submit</button></form>
<input type="file" multiple></main></body></html>'''

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.do_GET()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port-file", type=Path, help="Write a dynamically allocated loopback port when ready.")
args = parser.parse_args()
server = ThreadingHTTPServer(("127.0.0.1", 0 if args.port_file else 8765), Handler)
if args.port_file:
    args.port_file.write_text(str(server.server_port), encoding="ascii")
print(f"Fixture ready at http://127.0.0.1:{server.server_port}/", flush=True)
server.serve_forever()
