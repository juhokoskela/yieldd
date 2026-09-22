"""Bounded, fixed-response endpoint for an explicitly requested live network test."""
import http.server
import time


class Marker(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/yieldd-network-probe":
            self.send_error(404)
            return
        body = b"yieldd-controlled-endpoint\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class BoundedServer(http.server.HTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(2)
        return connection, address


server = BoundedServer(("0.0.0.0", 0), Marker)
server.timeout = 1
print(server.server_port, flush=True)
deadline = time.monotonic() + 120
try:
    while time.monotonic() < deadline:
        server.handle_request()
finally:
    server.server_close()
