#!/usr/bin/env python3
"""A stand-in for the Mac's phone server, for the offline UI test (ios/check.sh offline).

It answers the calls the phone makes with one session. GET /test/down?s=N makes it go away
for N seconds: the port refuses connections, as when the Mac sleeps. GET /test/log lists the
changes it got (script saves, comments, chat messages, uploads).
"""
import json, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8797
NOW = "2026-10-03T10:00:00Z"
SID = "Tests/offline-video"
state = {"script": "The first line of the script.\n\nThe second paragraph.", "comments": [], "log": [], "up": True,
         "chat": {"running": False, "messages": []}, "chat_revision": 0}


def message(index, text, role="claude"):
    return {"id": str(uuid.uuid5(uuid.NAMESPACE_URL, "takes-scroll-%d" % index)),
            "role": role, "text": text, "done": False}

session = {"id": SID, "title": "Offline video", "project": "Tests", "created": NOW, "updated": NOW,
           "takes": 0, "running": False, "unread": False, "notice": False, "published": False}


FOLDER = "/tmp/" + SID


def file(folder, name, kind, model=None):
    f = {"path": "%s/%s/%s" % (FOLDER, folder, name), "name": name, "folder": folder, "kind": kind,
         "size": 1000, "modified": NOW}
    if model:
        f["model"] = model
    return f


def files():
    """GET /test/files turns these on: six edits, and generated files with the model that made them."""
    if not state.get("files"):
        return []
    return ([file("edits", "hook-v%d.mp4" % i, "video") for i in range(1, 7)] +
            [file("generated", "desk-v1.png", "image", "Nano Banana 2.1"),
             file("generated", "intro-v1.wav", "audio", "The user (ElevenLabs)")])


def wav(seconds=2, rate=8000):
    """A quiet sound for /media, so the chat's sound card can play."""
    import struct
    n = seconds * rate
    return (b"RIFF" + struct.pack("<I", 36 + n * 2) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
            + b"data" + struct.pack("<I", n * 2) + b"\0" * (n * 2))




STYLES = {"styles": [
    {"name": "Bold", "description": "Big type", "isNew": True, "usedBy": [], "openComments": 0},
    {"name": "Magazine", "description": "Paper pages", "isNew": False, "poster": "/tmp/styles/Magazine/preview.png",
     "usedBy": [SID], "openComments": 1}],
    "projects": ["Tests"]}

STYLE = {"id": "_library/styles/Magazine", "name": "Magazine", "folder": "/tmp/_library/styles/Magazine",
         "readme": "# Magazine\n\nPaper pages with thin-line figures. Instrument Serif for titles, Inter for the rest.\n\n## Colours\n\nOne oxblood accent.",
         "readmeComments": 0, "hasTokens": True, "tokensComments": 0,
         "swatches": [{"name": "paper", "value": "#f4efe6", "usage": "page"}, {"name": "ink", "value": "#1b1b1b", "usage": "text"},
                      {"name": "oxblood", "value": "#7a1f2b", "usage": "accent"}, {"name": "rule", "value": "var(--x)", "usage": ""}],
         "type": [{"name": "Title", "family": "Georgia", "size": 40, "weight": 700}, {"name": "Body", "family": "Helvetica Neue", "size": 16, "weight": 400}],
         "fonts": [],
         "groups": [{"name": "logos", "items": [{"name": "logo.svg", "versions": [
             {"path": "/tmp/_library/styles/Magazine/assets/logos/logo-v1.svg", "name": "logo-v1.svg", "version": 1, "kind": "image",
              "size": 100, "modified": NOW, "openComments": 0},
             {"path": "/tmp/_library/styles/Magazine/assets/logos/logo-v2.svg", "name": "logo-v2.svg", "version": 2, "kind": "image",
              "size": 100, "modified": NOW, "note": "Use on dark pages", "openComments": 1}]}]},
                    {"name": "motion", "items": [{"name": "title-card.mp4", "versions": [
             {"path": "/tmp/_library/styles/Magazine/assets/motion/title-card-v1.mp4", "name": "title-card-v1.mp4", "version": 1,
              "kind": "video", "size": 100, "modified": NOW, "note": "Opens each video", "openComments": 0}]}]}],
         "openComments": 1}


def detail():
    d = {"session": session, "folder": FOLDER, "script": state["script"], "files": files(),
         "post": None, "chat": state["chat"],
         "openComments": len(state["comments"]), "profile": None, "storyboard": None}
    if state.get("sides"):
        d["sides"] = state["sides"]
    if state.get("styles"):
        d["style"] = state["video_style"]
        d["post"] = {"text": "Four days and 75 updates.\n\nThis is the body of the post.", "status": "draft",
                     "variants": [{"slug": "short", "name": "Short", "author": "claude", "note": "Tighter, one idea", "text": "Short one"}],
                     "hooks": [{"id": "h1", "text": "Four days and 75 updates.", "note": "Numbers first"},
                               {"id": "h2", "text": "I shipped 75 updates in four days."}]}
    return d


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
        if p == "/test/chat/start":
            messages = [message(i, "Earlier message %d.\n\n" % i +
                                "A paragraph about making a video and reading its script.\n\n" * 4)
                        for i in range(24)]
            # A finished run of five tool steps folds to one line; a run of two stays open.
            def tool(i, text):
                return dict(message(i, text, role="tool"), done=True)
            messages += [tool(100 + i, t) for i, t in enumerate(
                ["Bash · cd /tmp/letter; python3 ascii2.py", "Read · a4.jpg", "Bash · ffmpeg -i in.mov",
                 "Read · a5.jpg", "Grep · ascii"])]
            messages.append(message(110, "The ASCII video is rendered."))
            messages += [tool(111 + i, t) for i, t in enumerate(["Bash · ls edits", "Read · sheet5.jpg"])]
            messages.append(message(24, "Latest reply marker"))
            state["chat"] = {"running": True, "messages": messages}
            state["chat_revision"] += 1
            return self.send({"ok": True})
        if p == "/test/chat/grow":
            # Replace the last message as a real streaming event does, retaining its id.
            chat = json.loads(json.dumps(state["chat"]))
            chat["messages"][-1]["text"] += "\n\n" + "More streamed words that wrap onto several lines. " * 100
            state["chat"] = chat
            state["chat_revision"] += 1
            return self.send({"ok": True})
        if p == "/test/chat/finish":
            chat = json.loads(json.dumps(state["chat"]))
            chat["running"] = False
            chat["messages"][-1]["done"] = True
            state["chat"] = chat
            state["chat_revision"] += 1
            return self.send({"ok": True})
        if p == "/test/files":
            state["files"] = True
            chat = {"running": False, "messages": [
                message(200, "Here is the voice-over:\n\n%s/generated/intro-v1.wav" % FOLDER),
                dict(message(201, "And the picture:\n\n%s/generated/desk-v1.png" % FOLDER), done=True)]}
            chat["messages"][0]["done"] = True
            state["chat"] = chat
            state["chat_revision"] += 1
            return self.send({"ok": True})
        if p == "/test/styles":
            state["styles"] = True
            state["video_style"] = {"own": None, "project": "Magazine", "names": ["Bold", "Magazine"]}
            return self.send({"ok": True})
        if p == "/api/styles":
            return self.send(STYLES)
        if p == "/api/style":
            if method == "POST":
                j = json.loads(self.body())
                state["log"].append({"style": j})
                return self.send({"ok": True})
            return self.send(dict(STYLE, name=q.get("name") or "Only Tests"))
        if p == "/api/session/style" and method == "POST":
            j = json.loads(self.body())
            state["log"].append({"video_style": j})
            vs = state["video_style"]
            if j.get("project") == "1":
                vs["project"], vs["own"] = j["style"], None
            else:
                vs["own"] = j.get("style") or None
            return self.send(vs)
        if p == "/api/side" and method == "POST":
            j = json.loads(self.body())
            post = next((x for x in state.get("sides") or [] if x["file"] == j.get("file")), None)
            if post is None:
                return self.send({"error": "That post is gone from the Mac"}, 400)
            for k in ("title", "text", "status"):
                if k in j:
                    post[k] = j[k]
            state["log"].append({"side": q.get("side"), **{k: v for k, v in j.items() if k != "base"}})
            return self.send({"ok": True})
        if p == "/media" and q.get("path", "").endswith(".wav"):
            b = wav()
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        if p == "/api/update" and state.get("files"):
            return self.send({"renew": "Xcode lost your Apple ID. On the Mac: Xcode > Settings > Apple Accounts, sign in. The app stops in 30 h."})
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
                revision = -1
                while state["up"]:
                    if state["chat_revision"] and revision != state["chat_revision"]:
                        revision = state["chat_revision"]
                        chat = state["chat"]
                        event = {"type": "chat", "id": SID, "running": chat["running"],
                                 "count": len(chat["messages"]), "tail": chat["messages"][-1:]}
                        self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    else:
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
                text = json.loads(self.body())["text"]
                state["log"].append({"say": text, "id": q.get("id")})
                if state["chat_revision"]:
                    chat = json.loads(json.dumps(state["chat"]))
                    chat["messages"].append(message(len(chat["messages"]), text, role="user"))
                    chat["running"] = True
                    state["chat"] = chat
                    state["chat_revision"] += 1
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
