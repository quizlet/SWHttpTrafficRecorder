#!/usr/bin/env python3
"""Local HTTP server for the recorder tests. Writes the bound port to the path in argv[1]."""

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        body = ("body-for:" + path).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def main():
    port_path = sys.argv[1]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(port_path, "w", encoding="utf-8") as port_file:
        port_file.write("%s\n" % server.server_address[1])
    server.serve_forever()


if __name__ == "__main__":
    main()
