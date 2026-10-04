#!/usr/bin/env python3
"""A stand-in for the Mac's phone server, for the offline UI test (ios/check.sh offline).

It answers the calls the phone makes with one session. GET /test/down?s=N makes it go away
for N seconds: the port refuses connections, as when the Mac sleeps. GET /test/log lists the
changes it got (script saves, comments, chat messages, uploads).
"""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8797
NOW = "2026-10-03T10:00:00Z"
SID = "Tests/offline-video"
state = {"script": "The first line of the script.\n\nThe second paragraph.", "comments": [], "log": [], "up": True}

session = {"id": SID, "title": "Offline video", "project": "Tests", "created": NOW, "updated": NOW,
           "takes": 0, "running": False, "unread": False, "notice": False, "published": False}


def detail():
    return {"session": session, "folder": "/tmp/" + SID, "script": state["script"], "files": [],
            "post": None, "chat": {"running": False, "messages": []},
            "openComments": len(state["comments"]), "profile": None, "storyboard": None}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % a))

    def send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def route(self, method):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        p = u.path
        if p == "/test/down":
            secs = float(q.get("s", "20"))
            self.send({"ok": True})
            threading.Thread(target=down, args=(secs,), daemon=True).start()
            return
        if p == "/test/log":
            return self.send(state["log"])
        if p == "/api/ping":
            return self.send({"ok": "takes"})
        if p == "/api/pair":
            self.body()
            return self.send({"token": "test-token"})
        if p == "/api/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                while state["up"]:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    time.sleep(1)
            except OSError:
                pass
            self.close_connection = True
            return
        if p == "/api/sessions":
            if method == "POST":
                j = json.loads(self.body())
                n = dict(session, id="%s/new-%d" % (j.get("project") or "Inbox", len(state["log"])), title="")
                state["log"].append({"new": n["id"]})
                return self.send(n)
            return self.send([session])
        if p == "/api/session":
            return self.send(detail())
        if p == "/api/chat":
            if method == "POST":
                state["log"].append({"say": json.loads(self.body())["text"], "id": q.get("id")})
                return self.send({})
            return self.send(detail()["chat"])
        if p == "/api/chat/read":
            return self.send({})
        if p == "/api/script" and method == "POST":
            j = json.loads(self.body())
            if j.get("base") != state["script"]:
                return self.send({"error": "The script changed on the Mac."}, 409)
            state["script"] = j["text"]
            state["log"].append({"script": j["text"]})
            return self.send({})
        if p == "/api/comments":
            if method == "POST":
                j = json.loads(self.body())
                c = {"id": "c%d" % (len(state["comments"]) + 1), "file": j["file"], "quote": j.get("quote"),
                     "text": j["text"], "status": "open", "by": "user", "at": NOW}
                state["comments"].append(c)
                state["log"].append({"comment": j["text"]})
                return self.send(c)
            return self.send(state["comments"])
        if p == "/api/copilot":
            return self.send({"items": [], "finding": False, "posting": False, "redrafting": False})
        if p == "/api/upload":
            n = len(self.body())
            state["log"].append({"upload": q.get("name"), "bytes": n})
            return self.send({"path": "/tmp/" + (q.get("name") or "file")})
        return self.send({"error": "not here"}, 404)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")


server = None


def serve():
    global server
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer.daemon_threads = True
    server = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    server.serve_forever()


def down(secs):
    time.sleep(0.3)
    state["up"] = False
    server.shutdown()
    server.server_close()
    time.sleep(secs)
    state["up"] = True
    threading.Thread(target=serve, daemon=True).start()


if __name__ == "__main__":
    threading.Thread(target=serve, daemon=True).start()
    print("stand-in on", PORT, flush=True)
    while True:
        time.sleep(3600)
