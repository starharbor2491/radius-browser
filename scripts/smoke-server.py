#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Offline HTTP fixture for packaged-app navigation and reader checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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

ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
