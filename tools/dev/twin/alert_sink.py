#!/usr/bin/env python3
"""Stands in for Slack and the Event-Driven Ansible webhook on the twin: records what Alertmanager sent,
one JSON line per delivery, so `twin.sh burn` can prove an alert really arrived at both."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OUT = Path(os.environ.get("ALERT_SINK_FILE", "/alerts/received.jsonl"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        record = {"path": self.path, "body": body.decode("utf-8", "replace")}
        with OUT.open("a", encoding="utf-8") as out:
            out.write(json.dumps(record) + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")   # Alertmanager's Slack notifier retries on anything else, as Slack answers "ok"


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 5000), Handler).serve_forever()
