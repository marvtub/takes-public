#!/usr/bin/env python3
"""A stand-in for the Mac's phone server, for the offline UI test (ios/check.sh offline).

It answers the calls the phone makes with one session. GET /test/down?s=N makes it go away
for N seconds: the port refuses connections, as when the Mac sleeps. GET /test/log lists the
changes it got (script saves, comments, chat messages, uploads). GET /test/reset puts it back as
it started: every UI test calls it first (TakesPhoneUITests/Standin.swift).
"""
import json, os, sys, threading, time, uuid
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




def carousel():
    """GET /test/carousel turns this on: four slides, shown on the LinkedIn post in place of the video."""
    state["carousel"] = {"slides": [
        {"kicker": "Swipe →", "title": "5 things I wish I knew before filming on my phone", "body": "Save this for your next video."},
        {"kicker": "Tip 1", "title": "Light from the front", "body": "Face a window."},
        {"kicker": "Tip 2", "title": "Lock the exposure", "body": "Hold on your face until AE/AF Lock shows."},
        {"kicker": "That's it", "title": "Save this. Film one today.", "body": "Follow for a tip every week."}],
        "on": {"linkedin": True}, "docTitle": "5 things"}


# GET /test/screens turns these on for ScreensTests (2026-10-28: they walked the Mac's own library
# before): the post with a variant and hooks, two more videos, and comment drafts to review.
POST = {"text": "Four days and 75 updates.\n\nThis is the body of the post.", "status": "draft",
        "variants": [{"slug": "short", "name": "Short", "author": "claude", "note": "Tighter, one idea", "text": "Short one"}],
        "hooks": [{"id": "h1", "text": "Four days and 75 updates.", "note": "Numbers first"},
                  {"id": "h2", "text": "I shipped 75 updates in four days."}]}
SHOP = dict(session, id="Tests/claude-ran-a-shop", title="Claude ran a shop", created="2026-09-20T10:00:00Z",
            updated="2026-09-20T10:00:00Z", takes=2, stage="edit")
BOARD = dict(session, id="Tests/make-videos", title="How I make videos with Takes", created="2026-09-10T10:00:00Z",
             updated="2026-09-10T10:00:00Z", stage="board", shots=6)


def screens_detail(sid):
    """The detail of SHOP or BOARD."""
    if sid == SHOP["id"]:
        return {"session": SHOP, "folder": "/tmp/" + sid, "script": "Claude ran a shop for a month.", "files": [],
                "post": {"text": "Claude ran a shop for a month. Here is what it sold.", "status": "posted",
                         "media": "/tmp/%s/edits/shop-v1.mp4" % sid},
                "chat": {"running": False, "messages": []}, "openComments": 0, "profile": None, "storyboard": None}
    shots = [{"id": "s%d" % i, "section": "hook" if i == 1 else "main", "kind": "SHOT", "say": "Line %d of the video." % i,
              "how": "At the desk.", "seconds": 4, "start": 4.0 * (i - 1),
              "image": "/tmp/%s/storyboard/s%d.png" % (sid, i),
              "comments": [], "ratio": 0.8} for i in range(1, 7)]
    shots[4]["how"] = "Close up on the phone. Note: hold it still."
    return {"session": BOARD, "folder": "/tmp/" + sid, "script": "How I make videos.", "files": [], "post": None,
            "chat": {"running": False, "messages": []}, "openComments": 0, "profile": None, "storyboard": shots}


def suggestion(i, status, author, text, **more):
    s = {"id": "s%d" % i, "created": NOW, "status": status, "angle": "Agrees, adds one number",
         "post": {"url": "https://www.linkedin.com/feed/update/urn:li:activity:%d" % i, "author": author,
                  "headline": "Founder", "text": text, "posted": "2d", "comments": 12, "reactions": 140},
         "drafts": [{"text": "Same here: the second take is always better.",
                     "variants": ["Same here: the second take is always better.", "We film twice too. The first one is a warm-up.",
                                  "Two takes, every time. The first finds the words."]}]}
    s.update(more)
    return s


def copilot():
    return {"finding": True, "posting": False, "redrafting": False, "items": [
        suggestion(1, "review", "Ana Lopez", "I record every video twice. Here is why."),
        suggestion(2, "review", "Ben Ito", "Filming on a phone is enough."),
        suggestion(3, "review", "Cleo Park", "Scripts make videos worse."),
        suggestion(4, "approved", "Dev Shah", "The first take is a draft."),
        suggestion(5, "posted", "Eli Moss", "Short videos win.", posted={"url": "https://www.linkedin.com/feed/update/5", "at": NOW},
                   stats=[{"at": NOW, "impressions": 900, "likes": 12, "replies": 2}])]}


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
         "openComments": len(state["comments"]), "profile": None, "storyboard": None,
         # The Mac always sends the script's draft bar, empty or not: it holds the Edit button.
         "scriptVariants": [], "scriptFavorite": "main", "scriptHistory": 0}
    if state.get("sides"):
        d["sides"] = state["sides"]
    if state.get("parity"):
        d.update(PARITY_DETAIL())
    if state.get("carousel"):
        d["carousel"] = state["carousel"]
        if d.get("posts"):
            d["posts"] = d["posts"] + [dict(platform="vertical", name="Vertical", text="5 phone filming tips #filmingtips", title="",
                                            status="draft", limit=2200, history=0, variants=[], hooks=[], places=["tiktok", "reels", "shorts"])]
    if state.get("styles"):
        d["style"] = state["video_style"]
        d["post"] = POST
    if state.get("screens"):
        d["post"] = POST
    return d


VERSIONS = [
    {"path": "/tmp/h/1-main.md", "created": NOW, "author": "claude", "note": "Wrote the hook", "draft": "main", "draftName": "Main",
     "text": "An older first line.\n\nThe second paragraph."},
    {"path": "/tmp/h/2-main.md", "created": "2026-10-02T09:00:00Z", "author": "user", "note": "Edited on the phone", "draft": "main",
     "draftName": "Main", "text": "The very first draft."}]


def PARITY_DETAIL():
    """GET /test/parity turns these on: takes, script variants, history, hooks and posts (2026-10-09)."""
    takes = [dict(file("takes", "Take %d" % n, "video"), path="%s/take-0%d-camera.mov" % (FOLDER, n), take=n,
                  keeper=n == 1, duration=12.0, shot="s1",
                  cut={"state": "done", "start": 1.2, "end": 9.8, "clean": True, "why": "No stumbles", "by": "agent" if n == 1 else "gemini"})
             for n in (1, 2)]
    gen = [dict(file("generated", "desk-v1.png", "image", "GPT Image 2.5"), change="Change generated/desk-v1.png with make_image: ",
                final="Make the final of generated/desk-v1.png with make_image (from=generated/desk-v1.png).")]
    a, b = FOLDER + "/storyboard/s1.png", FOLDER + "/generated/desk-v1.png"
    board = [{"id": "s1", "section": "hook", "kind": "SHOT", "say": "Four days and 75 updates.", "how": "Close up at the desk.",
              "seconds": 4, "start": 0, "image": state.get("shot_video", a), "comments": [], "ratio": 0.8,
              "variants": [a, b], "video": state.get("shot_video", a), "finals": {b: "Make the final of generated/desk-v1.png for shot s1."}}]
    return {"files": takes + gen + files(), "storyboard": board, "scriptVariants": state["script_variants"], "scriptFavorite": "main",
            "scriptHistory": 2, "scriptHooks": [{"id": "h1", "text": "The first line of the script.", "note": "Plain"},
                                                {"id": "h2", "text": "What if the script wrote itself?"}],
            "publishedOn": ["LinkedIn"],
            "post": {"text": "Four days and 75 updates.\n\nThis is the body of the post.", "status": state["post_status"],
                     "history": 2, "firstComment": state.get("first_comment"),
                     "variants": [{"slug": "short", "name": "Short", "author": "claude", "note": "Tighter", "text": "Short one"}],
                     "hooks": []},
            "posts": [dict(platform="linkedin", name="LinkedIn", text="Four days and 75 updates.", title="", status=state["post_status"],
                           limit=3000, history=2, variants=[], hooks=[], at=state.get("post_at"), tz=state.get("post_at") and "America/Los_Angeles"),
                      dict(platform="x", name="X", text="Four days. 75 updates.", title="", status="draft", limit=280, history=1,
                           variants=[{"slug": "thread", "name": "Thread", "author": "claude", "note": "As a thread", "text": "One\n\nTwo"}],
                           hooks=[{"id": "x1", "text": "Four days. 75 updates.", "note": "Short"}, {"id": "x2", "text": "75 updates in 4 days."}])]}


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
        if not state["up"]:
            # Away: a kept-alive connection gets no answer either, as when the Mac sleeps. Without
            # this the phone and the tests still reached it on an open connection.
            self.close_connection = True
            return
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        p = u.path
        if not p.startswith("/test/"):
            state.setdefault("seen", []).append(p)
        if p == "/test/seen":
            # What the phone read: its copy for offline is in once it read the comments.
            return self.send(sorted(set(state.get("seen", []))))
        if p == "/test/down":
            secs = float(q.get("s", "20"))
            self.send({"ok": True})
            threading.Thread(target=down, args=(secs,), daemon=True).start()
            return
        if p == "/test/log":
            return self.send(state["log"])
        if p == "/test/reset":
            # Each UI test starts here: the whole suite shares one stand-in, and the last test's
            # fixtures, changes and log broke the next one (2026-10-28).
            state.clear()
            state.update(json.loads(json.dumps(FRESH)))
            session.clear()
            session.update(FRESH_SESSION)
            return self.send({"ok": True})
        if p == "/test/screens":
            state["screens"] = True
            state["copilot"] = copilot()
            return self.send({"ok": True})
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
        if p == "/test/chat/busy":
            # Takes works: a message from the phone waits in the queue (2026-10-10).
            state["chat"] = {"running": True, "messages": [message(1, "Cut the intro", role="user")], "queued": []}
            state["chat_revision"] += 1
            return self.send({"ok": True})
        if p == "/api/chat/unqueue" and method == "POST":
            state["log"].append({p: q.get("index")})
            chat = json.loads(json.dumps(state["chat"]))
            i = int(q.get("index", "-1"))
            if 0 <= i < len(chat.get("queued") or []):
                chat["queued"].pop(i)
            state["chat"] = chat
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
        if p == "/test/carousel":
            carousel()
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
        if p == "/test/parity":
            state["parity"] = True
            m = [message(300, "Cut the intro to ten seconds", role="user"), message(301, "Done. The new edit is in edits/."),
                 dict(message(302, "Compacted the conversation · 120k → 18k tokens", role="tool"), done=True)]
            for x in m:
                x["done"] = True
            state["chat"] = {"running": False, "messages": m, "context": {"used": 142000, "window": 200000}}
            state["script_variants"] = [{"slug": "short", "name": "Short", "author": "claude", "note": "Tighter, one idea", "text": "Short script."}]
            state["post_status"] = "draft"
            return self.send({"ok": True})
        if p == "/api/schedule" and method == "POST":
            j = json.loads(self.body() or b"{}")
            state["log"].append({p: j, "platform": q.get("platform")})
            a = j.get("action")
            if a == "set":
                state["post_at"], state["post_status"] = j.get("at"), "ready" if state["post_status"] == "draft" else state["post_status"]
            elif a == "ready":
                state["post_status"] = "ready"
            elif a == "clear":
                state["post_at"] = None
            elif a == "draft":
                state["post_status"], state["post_at"] = "draft", None
            return self.send({"ok": True})
        if p in ("/api/trash", "/api/rename", "/api/move", "/api/published", "/api/script/draft", "/api/post/draft") and method == "POST":
            j = json.loads(self.body() or b"{}")
            state["log"].append({p: j})
            if p == "/api/script/draft" and j.get("action") == "new":
                state["script_variants"].append({"slug": "variant-2", "name": "Variant 2", "author": "user", "note": "", "text": state["script"]})
            if p == "/api/post/draft" and j.get("action") == "status":
                state["post_status"] = j.get("status", "draft")
                state["post_at"] = j.get("at") or None
            if p in ("/api/rename", "/api/move") and j.get("what") != "take" and j.get("what") != "project":
                session["title"] = j.get("name") or session["title"]
                return self.send(session)
            if p == "/api/trash" and j.get("what") == "unstarred":
                return self.send({"trashed": 1})
            return self.send({"ok": True})
        if p == "/api/shot" and method == "POST":
            j = json.loads(self.body() or b"{}")
            state["log"].append({p: j})
            if j.get("action") == "pick":
                state["shot_video"] = j.get("path")
            return self.send({"ok": True})
        if p == "/api/broll":
            if method == "POST":
                j = json.loads(self.body() or b"{}")
                state["log"].append({p: j})
                if j.get("action") in ("add", "remove"):
                    state["broll_added"] = j["action"] == "add"
                return self.send({"ok": True})
            return self.send([{"folder": "1 Desk work", "name": "Desk work", "clips": [
                {"path": "/tmp/lib/broll/1 Desk work/2023-11 Typing (V).mov", "title": "Typing", "vertical": True, "added": bool(state.get("broll_added"))},
                {"path": "/tmp/lib/broll/1 Desk work/2023-10 Coffee (H).mov", "title": "Coffee", "vertical": False, "added": False}]},
                {"folder": "2 City", "name": "City", "clips": [{"path": "/tmp/lib/broll/2 City/Street.mov", "title": "Street", "added": False}]}])
        if p == "/api/sounds":
            if method == "POST":
                state["log"].append({p: json.loads(self.body() or b"{}")})
                return self.send({"ok": True})
            return self.send({"sounds": [
                {"rel": "Music/1_Chasing the Truth.mp3", "title": "Chasing the Truth", "group": "Music", "path": "/tmp/lib/audio/Music/1_Chasing the Truth.mp3"},
                {"rel": "Music/2_Morning.mp3", "title": "Morning", "group": "Music", "path": "/tmp/lib/audio/Music/2_Morning.mp3"},
                {"rel": "SFX/3_Whoosh.mp3", "title": "Whoosh", "group": "SFX", "path": "/tmp/lib/audio/SFX/3_Whoosh.mp3"}]})
        if p == "/api/search":
            state["log"].append({p: q})
            if not q.get("q"):
                return self.send({"hits": [], "status": "Ready. 812 files indexed."})
            hits = [{"kind": "session", "path": FOLDER, "start": 0, "text": "Tests", "title": "Offline video", "session": SID},
                    {"kind": "board", "path": "/tmp", "start": 0, "title": "Styles", "board": "styles"},
                    {"kind": "video", "path": FOLDER + "/take-01-camera.mov", "start": 0, "session": SID},
                    {"kind": "speech", "path": FOLDER + "/edits/hook-v2.mp4", "start": 12.5, "text": "hands typing on the keyboard", "session": SID,
                     "w": 1080, "h": 1920, "seconds": 48.0},
                    {"kind": "video", "path": FOLDER + "/edits/hook-v2.mp4", "start": 31.0, "session": SID, "w": 1080, "h": 1920, "seconds": 48.0}]
            if q.get("filter", "all") != "all":
                hits = [h for h in hits if h["kind"] in ("video", "speech")]
            if q.get("sort", "best") != "best":
                hits = [dict(h, section="This week" if i < 2 else "September 2026") for i, h in enumerate(hits)]
            return self.send({"hits": hits, "status": "Ready. 812 files indexed."})
        if p == "/api/projects":
            return self.send(["Tests", "Later"])
        if p in ("/api/script/history", "/api/post/history"):
            return self.send(VERSIONS)
        if p == "/api/voice":
            if method == "POST":
                j = json.loads(self.body() or b"{}")
                state["log"].append({"voice": j})
                state["voice"] = "done"
            return self.send({"state": state.get("voice", "none"), "on": True, "strength": 0.8, "quiet": False,
                              "summary": "echo -17 → -27 dB · noise removed · -14 LUFS", "estimate": 20,
                              "file": FOLDER + "/voice/take-01-camera.wav" if state.get("voice") else None})
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
        if p == "/api/plugins" and state.get("parity"):
            return self.send([{"id": "consistency", "title": "Plan", "icon": "calendar"}])
        if p == "/api/plan":
            # Plan (2026-10-25): the Mac's own answers for its test library (PlanPhoneTests.writeStandIn).
            if method == "POST":
                state["log"].append({p: json.loads(self.body() or b"{}")})
                return self.send({"ok": True})
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "TakesPhoneUITests/plan-standin.json")) as f:
                c = json.load(f)
            if "choices" in q:
                return self.send(c["choices"])
            return self.send(c["plan"])
        if p == "/api/carousel" and method == "POST":
            j = json.loads(self.body())
            c = state.get("carousel") or {"slides": [], "on": {}, "docTitle": ""}
            if "platform" in j:
                c["on"][j["platform"]] = j.get("on") == "true"
            elif j.get("action") == "add":
                c["slides"].append({"kicker": "", "title": "New slide", "body": ""})
            elif "look" in j:
                c["look"] = j["look"]
            elif "slide" in j:
                c["slides"][int(j["slide"])].update({k: j[k] for k in ("title", "body", "layout") if k in j})
            state["carousel"] = c
            state["log"].append({p: j})
            return self.send({"ok": True})
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
        if p == "/test/update":
            state["update"] = True
            return self.send({"ok": True})
        if p == "/api/update" and state.get("update"):
            return self.send({"stamp": "491610a Oct 11 16:05", "changes": [
                "Ideas: the body reads as markdown; click it or the pencil to type",
                "What's new: every change starts open, not only with six or fewer",
                "Rail: drop the Connections and Site stats numbers"]})
        if p == "/api/update" and state.get("files"):
            return self.send({"renew": "Xcode lost your Apple ID. On the Mac: Xcode > Settings > Apple Accounts, sign in. The app stops in 30 h."})
        if p == "/api/performance":
            # STANDIN_SOCIAL: a social.json to draw the Performance charts from (none in the repo).
            f = os.environ.get("STANDIN_SOCIAL")
            social = json.load(open(f)) if f and os.path.exists(f) else None
            return self.send({"posts": [], "social": social, "profile": None})
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
                # A new id each time, as the Mac's new folders: the phone keeps a copy of each session it saw.
                n = dict(session, id="%s/new-%s" % (j.get("project") or "Inbox", uuid.uuid4().hex[:8]), title="")
                state["log"].append({"new": n["id"]})
                state.setdefault("made", {})[n["id"]] = n
                return self.send(n)
            if state.get("parity") and state.get("post_status", "draft") != "draft":
                return self.send([dict(session, plan=[{"platform": "linkedin", "status": state["post_status"], "at": state.get("post_at")}])])
            return self.send([session] + ([SHOP, BOARD] if state.get("screens") else []))
        if p == "/api/session":
            if q.get("id") in state.get("made", {}):
                # A new video: no script, no files, no chat, so it shows "Just record".
                return self.send({"session": state["made"][q["id"]], "folder": "/tmp/" + q["id"], "script": "", "files": [],
                                  "post": None, "chat": {"running": False, "messages": []}, "openComments": 0,
                                  "profile": None, "storyboard": None})
            if state.get("screens") and q.get("id") in (SHOP["id"], BOARD["id"]):
                return self.send(screens_detail(q["id"]))
            return self.send(detail())
        if p == "/api/chat":
            if method == "POST":
                text = json.loads(self.body())["text"]
                state["log"].append({"say": text, "id": q.get("id")})
                if state["chat"].get("running") and "queued" in state["chat"]:
                    chat = json.loads(json.dumps(state["chat"]))
                    chat["queued"].append(text)
                    state["chat"] = chat
                    state["chat_revision"] += 1
                elif state["chat_revision"]:
                    chat = json.loads(json.dumps(state["chat"]))
                    chat["messages"].append(message(len(chat["messages"]), text, role="user"))
                    chat["running"] = True
                    state["chat"] = chat
                    state["chat_revision"] += 1
                return self.send({})
            return self.send(detail()["chat"])
        if p == "/api/chat/new" and method == "POST":
            state["log"].append({p: True})
            state["past"] = True
            state["chat"] = {"running": False, "messages": []}
            return self.send(state["chat"])
        if p == "/api/chat/history":
            if method == "POST":
                j = json.loads(self.body() or b"{}")
                state["log"].append({p: j})
                return self.send(state["chat"])
            return self.send([{"file": "c1.json", "title": "Cut the intro to ten seconds", "date": NOW, "count": 1},
                              {"file": "c0.json", "title": "Write the hook", "date": "2026-10-02T09:00:00Z", "count": 4}])
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
            c = state.get("copilot") or {"items": [], "finding": False, "posting": False, "redrafting": False}
            if method == "POST":
                j = json.loads(self.body() or b"{}")
                state["log"].append({p: j})
                a = j.get("action")
                for s in c["items"]:
                    if s["id"] == j.get("id"):
                        s["status"] = {"approve": "approved", "posted": "posted", "decline": "declined", "feedback": "redraft"}.get(a, "review")
                        s["skipped"] = NOW if a == "skip" else None
            return self.send(c if method == "GET" else {"ok": True})
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


# The first state, for GET /test/reset.
FRESH = json.loads(json.dumps(state))
FRESH_SESSION = dict(session)
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
