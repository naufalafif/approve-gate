#!/usr/bin/env python3
"""A tiny local stand-in for the ntfy relay, for tests only (tests/e2e.sh).

It speaks the part of the ntfy protocol Approve Gate uses:
  POST /<topic>                         store a message
  GET  /<topic>/json?since=<time|id>    stream messages as JSON lines (add poll=1 to get them and close)
Messages live in memory. Usage: relay.py PORT
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

lock = threading.Condition()
topics = {}  # topic -> list of messages
counter = 0


def matching(topic, since):
    msgs = topics.get(topic, [])
    if since.isdigit():
        return [m for m in msgs if m["time"] >= int(since)]
    ids = [m["id"] for m in msgs]
    return msgs[ids.index(since) + 1:] if since in ids else msgs


class Relay(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        global counter
        topic = urlparse(self.path).path.strip("/")
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with lock:
            counter += 1
            msg = {"id": f"m{counter}", "time": int(time.time()), "event": "message", "topic": topic, "message": body}
            topics.setdefault(topic, []).append(msg)
            lock.notify_all()
        out = json.dumps(msg).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        url = urlparse(self.path)
        topic = url.path.strip("/").removesuffix("/json")
        q = parse_qs(url.query)
        since = q.get("since", ["0"])[0]
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        try:
            with lock:
                sent = matching(topic, since)
            for m in sent:
                self.wfile.write((json.dumps(m) + "\n").encode())
            self.wfile.flush()
            if q.get("poll") == ["1"]:
                return
            seen = len(topics.get(topic, []))
            while True:
                with lock:
                    lock.wait(timeout=20)
                    new = topics.get(topic, [])[seen:]
                    seen += len(new)
                for m in new:
                    self.wfile.write((json.dumps(m) + "\n").encode())
                if not new:
                    self.wfile.write(b'{"event":"keepalive"}\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Relay).serve_forever()
