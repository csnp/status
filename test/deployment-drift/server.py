"""A witness server whose status and body are controlled by files on disk.

Reads CASE_STATUS and CASE_BODY from the working directory on every request so a case can
change what the domain answers without restarting anything.
"""
import http.server, socketserver, os, sys

PORT = int(sys.argv[1])


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status = int(open("CASE_STATUS").read().strip())
        body = open("CASE_BODY", "rb").read()
        self.send_response(status)
        if 300 <= status < 400:
            self.send_header("Location", "https://elsewhere.example/")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if status != 304:
            self.wfile.write(body)

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), H) as httpd:
    httpd.serve_forever()
