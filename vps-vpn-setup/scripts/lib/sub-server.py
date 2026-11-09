#!/usr/bin/env python3
"""Tiny token-guarded static file server for subscription delivery.

Serves only /<token>/<allowed-file>; everything else is 404. No directory
listing, no caching, no logging of the token. Started by systemd as
vpnctl-sub.service and stopped with `vpnctl sub --unserve`.

The URL is a bearer credential: anyone holding it gets the nodes. Keep the
token long, rotate it by re-running `vpnctl sub --serve`, and turn the service
off when you are not sharing.
"""

import argparse
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ALLOWED = {"clash.yaml", "v2ray.txt", "uris.txt", "singbox.json"}
MIME = {
    "clash.yaml": "text/yaml; charset=utf-8",
    "v2ray.txt": "text/plain; charset=utf-8",
    "uris.txt": "text/plain; charset=utf-8",
    "singbox.json": "application/json; charset=utf-8",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "vpnctl-sub"
    sys_version = ""

    def _not_found(self):
        body = b"not found\n"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = [p for p in self.path.split("?")[0].strip("/").split("/") if p]
        if len(parts) != 2 or parts[0] != self.server.token or parts[1] not in ALLOWED:
            self._not_found()
            return
        path = os.path.join(self.server.root, parts[1])
        if not os.path.isfile(path):
            self._not_found()
            return
        with open(path, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", MIME[parts[1]])
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # no secrets in the journal
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--token", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()

    if len(args.token) < 16:
        sys.exit("token must be at least 16 characters")
    if not os.path.isdir(args.dir):
        sys.exit("directory does not exist: %s" % args.dir)

    srv = ThreadingHTTPServer((args.bind, args.port), Handler)
    srv.root = os.path.abspath(args.dir)
    srv.token = args.token
    srv.serve_forever()


if __name__ == "__main__":
    main()
