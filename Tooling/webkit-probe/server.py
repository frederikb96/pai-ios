"""Serves the probe page and appends what it reports, one JSON line per event.

The simulator shares the host's network stack, so the page reaches this server as 127.0.0.1.
`POST /log` takes the page's state, `POST /mark?step=<name>` the probe script's step boundaries.
"""

import http.server
import json
import pathlib
import sys
import urllib.parse

HERE = pathlib.Path(__file__).parent
LOG = pathlib.Path(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(HERE), **kwargs)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        if url.path == "/log":
            line = body
        elif url.path == "/mark":
            line = json.dumps({"mark": urllib.parse.parse_qs(url.query)["step"][0]})
        else:
            self.send_error(404)
            return
        with LOG.open("a") as f:
            f.write(line.strip() + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
