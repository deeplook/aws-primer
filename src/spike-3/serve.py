"""Serve the local static UI with a runtime API endpoint setting."""

import argparse
import http.client
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, directory=None, api_url, image_backend, **kwargs):
        self.api_url = api_url
        self.image_backend = image_backend
        super().__init__(*args, directory=directory, **kwargs)

    def do_GET(self):
        if self.path == "/config.js":
            body = (f"window.SPIKE_CONFIG = {{ apiBaseUrl: {json.dumps('/api')}, "
                    f"imageBackend: {json.dumps(self.image_backend)} }};\n").encode()
            self.send_response(200)
            self.send_header("content-type", "text/javascript; charset=utf-8")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api" or self.path.startswith("/api/"):
            self._proxy_api()
            return
        super().do_GET()

    def do_POST(self):
        if self.path == "/api" or self.path.startswith("/api/"):
            self._proxy_api()
            return
        self.send_error(404)

    def do_OPTIONS(self):
        if self.path == "/api" or self.path.startswith("/api/"):
            self._proxy_api()
            return
        self.send_error(404)

    def _proxy_api(self):
        api = urlsplit(self.api_url)
        if api.scheme != "http" or not api.hostname or not api.port:
            self.send_error(502, "The local API endpoint is invalid.")
            return
        api_path = self.path[4:] or "/"
        if not api_path.startswith("/"):
            api_path = "/" + api_path
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else None
        headers = {"Host": api.netloc}
        for name in ("Content-Type", "Accept"):
            if name in self.headers:
                headers[name] = self.headers[name]
        connection = http.client.HTTPConnection("localhost", api.port, timeout=30)
        try:
            connection.request(self.command, api_path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            self.send_response(response.status)
            for name in ("Content-Type", "Cache-Control"):
                if response.getheader(name):
                    self.send_header(name, response.getheader(name))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except OSError as error:
            self.send_error(502, f"Could not reach local Floci API: {error}")
        finally:
            connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", default="http://localhost:4567")
    parser.add_argument("--image-backend", choices=("stub", "bedrock"), default="stub")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    directory = Path(__file__).parent / "site"
    server = ThreadingHTTPServer(("127.0.0.1", args.port),
        lambda *a, **kw: Handler(*a, directory=str(directory), api_url=args.api_url,
                                  image_backend=args.image_backend, **kw))
    server.api_url = args.api_url
    print(f"Portrait Studio: http://localhost:{args.port} (API {args.api_url})")
    server.serve_forever()


if __name__ == "__main__":
    main()
