#!/usr/bin/env python3
"""MCP server for Takes (stdio, stdlib only).

Lets any MCP agent (Claude Code, Codex, Cursor, Gemini CLI, Antigravity, opencode, pi, Claude Desktop) manage
the Takes library: projects, sessions, scripts, takes.
It writes the same on-disk format as the app (see Sources/Takes/Library.swift).
The app rescans every 2 seconds, so changes show up without a click.

Register:  python3 <path>/takes_mcp.py --setup   (adds it to every agent on this Mac)
       or:  claude mcp add takes --scope user -- python3 <path>/takes_mcp.py
"""
import array
import concurrent.futures
import glob
import hashlib
import json
import math
import os
import platform
import random
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import wave
from datetime import datetime, timedelta, timezone

PROTOCOL = "2025-06-18"


# ---------- library on disk ----------

def root():
    if os.environ.get("TAKES_ROOT"):
        return os.environ["TAKES_ROOT"]
    try:
        out = subprocess.run(["defaults", "read", "de.marvinaziz.takes", "root"],
                             capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return os.path.expanduser("~/Movies/Takes")


def slug(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    parts = [p for p in re.split(r"[^\w]|_", s) if p]
    return "-".join(parts)[:60]


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso_ms():
    t = datetime.now(timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)


def parse_iso(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return None


def lib_parts(path, r=None):
    """The parts of path below the library root, [] for the root itself, or None when path is not inside
    the library. Lexical: '..' cannot climb out, while a folder the user links into the library still counts
    as inside (audit #10, 2026-10-11)."""
    r = r or root()
    p = os.path.normpath(os.path.abspath(os.path.expanduser(path)))
    for base in dict.fromkeys([os.path.normpath(os.path.abspath(os.path.expanduser(r))), os.path.realpath(r)]):
        if p == base:
            return []
        if p.startswith(base.rstrip(os.sep) + os.sep):
            return p[len(base.rstrip(os.sep)) + 1:].split(os.sep)
    return None


def inside_root(path, r=None):
    """True when path is the library root or inside it."""
    return lib_parts(path, r) is not None


def is_session_path(path):
    """A session is a folder inside a project: <root>/<project>/<session>. The root and a project are not."""
    parts = lib_parts(path)
    return parts is not None and len(parts) == 2


def project_name(name):
    """A project folder name from the caller's name: '/' becomes '-'. Empty, '.' and '..' are refused, so a
    project can never be the root or a folder outside it."""
    name = str(name or "").replace("/", "-").strip()
    if name in ("", ".", ".."):
        raise ValueError("Give a project name, e.g. 'LinkedIn Posts'.")
    return name


RESOLVED = {}  # ref -> folder, for refs this tool call found by an old path (handle adds resolved_from)


def resolve_session(ref):
    """A session folder from an absolute path, 'Project/folder', the session id, or an old path
    (2026-10-11): a renamed or moved session keeps working for the agent that still has its old path."""
    ref = str(ref or "").strip()
    path = ref if os.path.isabs(ref) else os.path.join(root(), ref)
    path = os.path.normpath(os.path.expanduser(path))
    if ref and os.path.isdir(path):
        # '', '.', 'Proj' or 'Proj/..' used to resolve to the root or a whole project, and '../x' to a folder
        # outside the library: trash_sessions or update_session then acted on all of it (audit #10).
        if not is_session_path(path):
            raise ValueError("Not a session: %s. A session is a folder inside a project in the library, e.g. "
                             "'LinkedIn Posts/2026-10-11-my-post'; list_sessions gives them." % ref)
        return path
    if re.fullmatch(r"[0-9a-f]{12}", ref):
        hits = sessions_with_id(ref)
        if len(hits) > 1:
            raise ValueError("Two sessions have the id %s: %s, %s. Use the path." % (ref, hits[0], hits[1]))
        if hits:
            return hits[0]
    found = follow_moves(path) if ref else None
    if not found and ref and not os.path.isdir(os.path.dirname(path)):
        # The project has a new name: the folder name alone, when one session has it.
        name = os.path.basename(path)
        hits = [p for p in glob.glob(os.path.join(glob.escape(root()), "*", glob.escape(name)))
                if os.path.isdir(p) and not os.path.basename(os.path.dirname(p)).startswith((".", "_"))]
        found = hits[0] if len(hits) == 1 else None
    if found and is_session_path(found):
        RESOLVED[ref] = found
        return found
    raise ValueError("No session at %s. It may have been renamed: call list_sessions, or pass the session id "
                     "from get_session." % path)


def resolve_project(name):
    name = str(name or "").strip()
    path = os.path.normpath(name if os.path.isabs(name) else os.path.join(root(), name))
    parts = lib_parts(path)
    if not name or parts is None or len(parts) != 1:
        raise ValueError("No project '%s'. A project is a folder in the Takes library: use list_projects or "
                         "create_project." % name)
    if not os.path.isdir(path):
        raise ValueError("No project '%s'. Use list_projects or create_project." % name)
    return path


def title_from_folder(name):
    if len(name) > 11 and re.match(r"\d{4}-\d{2}-\d{2}-", name):
        name = name[11:]
    return name.replace("-", " ")


def read_meta(session):
    p = os.path.join(session, "session.json")
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    created = datetime.fromtimestamp(os.stat(session).st_birthtime, timezone.utc)
    return {"title": title_from_folder(os.path.basename(session)),
            "createdAt": created.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "named": True, "takes": []}


def clock(sec):
    s = int(round(sec))
    return "%d:%02d" % (s // 60, s % 60)


def write_meta(session, meta):
    meta.setdefault("id", session_id(session, meta))
    with open(os.path.join(session, "session.json"), "w") as f:
        json.dump(meta, f, indent=2, sort_keys=True)
    # SESSION.md, same shape the app writes.
    date = meta["createdAt"][:10]
    lines = ["# %s\n" % meta["title"],
             "Project: %s  \nCreated: %s  \nFolder: `%s`" % (os.path.basename(os.path.dirname(session)), date, session)]
    if meta.get("published"):
        lines.append("Published: " + ", ".join(
            "%s (%s)" % (p.get("platform") or "Published", p["at"][:10]) + (" " + p["url"] if p.get("url") else "")
            for p in meta["published"]))
    lines += ["", "## Takes\n"]
    takes = meta.get("takes", [])
    if not takes:
        lines.append("_No takes yet._")
    else:
        lines.append("Camera files carry the mic audio. Screen files carry the mic too, for syncing by waveform. "
                     "`screen offset` is how many seconds after the camera file the screen file starts.\n")
        lines.append("| Take | Name | Keeper | Camera | Screen | Length | Screen offset |\n|---|---|---|---|---|---|---|")
        for n in sorted({t["number"] for t in takes}):
            g = [t for t in takes if t["number"] == n]
            cam = next((t for t in g if t["kind"] == "camera"), None)
            scr = next((t for t in g if t["kind"] == "screen"), None)
            dur = (cam or scr or {}).get("duration")
            off = "–"
            if cam and scr and parse_iso(cam["startedAt"]) and parse_iso(scr["startedAt"]):
                off = "%+.2fs" % (parse_iso(scr["startedAt"]) - parse_iso(cam["startedAt"])).total_seconds()
            lines.append("| %d | %s | %s | %s | %s | %s | %s |" % (
                n, g[0].get("name") or "", "★" if g[0].get("keeper") else "",
                "`%s`" % cam["file"] if cam else "–", "`%s`" % scr["file"] if scr else "–",
                clock(dur) if dur else "?", off))
    lines.append("\n## Script\n\nSee `script.md`.")
    with open(os.path.join(session, "SESSION.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def unique(path):
    base, n = path, 2
    while os.path.exists(path):
        path = "%s-%d" % (base, n)
        n += 1
    return path


# ---------- session id and old paths (2026-10-11, same files as Sources/Takes/Library.swift) ----------
#
# session.json "id": 12 hex characters, sha1 of createdAt (the raw string) and the folder's inode. The
# inode stays on a rename and on a move inside the volume, so the app and the server get the same id
# for an old session without a write. Once written, the stored id wins.
# <root>/.moves.json: {"<old Project/folder>": "<new Project/folder>"}, written by every folder move,
# so an old path still finds its session.

MOVES_FILE = ".moves.json"
MOVES_MAX = 500
FS_TYPES = {}  # library root -> file system name


def lib_root(s):
    """The library a session folder is in: two folders up."""
    return os.path.dirname(os.path.dirname(os.path.normpath(os.path.abspath(s))))


def fs_type(path):
    """'apfs', 'exfat', 'smbfs', ... from statfs; None when it cannot tell."""
    import ctypes
    import ctypes.util
    if path in FS_TYPES:
        return FS_TYPES[path]
    kind = None
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        buf = ctypes.create_string_buffer(4096)  # struct statfs: f_fstypename is 16 bytes at offset 72
        if libc.statfs(path.encode(), buf) == 0:
            kind = buf.raw[72:88].split(b"\0")[0].decode() or None
    except Exception:
        pass
    FS_TYPES[path] = kind
    return kind


def raw_created(s):
    """createdAt as session.json spells it, else the folder's birth time (what read_meta gives)."""
    try:
        with open(os.path.join(s, "session.json")) as f:
            c = json.load(f).get("createdAt")
        if isinstance(c, str) and c:
            return c
    except (OSError, ValueError, AttributeError):
        pass
    created = datetime.fromtimestamp(os.stat(s).st_birthtime, timezone.utc)
    return created.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def derived_id(s, created=None):
    created = created if isinstance(created, str) and created else raw_created(s)
    return hashlib.sha1(("%s:%d" % (created, os.stat(s).st_ino)).encode()).hexdigest()[:12]


def session_id(s, meta=None):
    """The stored id, else the one derived from createdAt and the folder's inode."""
    meta = meta if meta is not None else read_meta(s)
    sid = meta.get("id")
    return sid if isinstance(sid, str) and sid else derived_id(s, meta.get("createdAt"))


def shown_id(s, meta=None):
    """The id tools show. Off APFS an inode may change on remount: only a stored id is shown there."""
    meta = meta if meta is not None else read_meta(s)
    if meta.get("id") or fs_type(lib_root(s)) in (None, "apfs"):
        return session_id(s, meta)
    return None


def all_session_folders(r=None):
    r = r or root()
    return [p for p in glob.glob(os.path.join(glob.escape(r), "*", "*"))
            if os.path.isdir(p) and not os.path.basename(os.path.dirname(p)).startswith((".", "_"))
            and not os.path.basename(p).startswith((".", "_"))]


def sessions_with_id(sid):
    out = []
    for p in all_session_folders():
        try:
            if session_id(p) == sid:
                out.append(p)
        except (OSError, ValueError):
            continue
    return out


def read_moves(r=None):
    try:
        with open(os.path.join(r or root(), MOVES_FILE)) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def record_move(old, new):
    """One folder move into <root>/.moves.json. A move back to a name that is a key removes that key
    first, so no loop forms (A -> B -> A)."""
    r = lib_root(new)
    a, b = os.path.relpath(old, r), os.path.relpath(new, r)
    if a == b:
        return
    path = os.path.join(r, MOVES_FILE)
    if os.path.exists(path):
        try:
            with open(path) as f:
                d = json.load(f)
            if not isinstance(d, dict):
                raise ValueError
        except (OSError, ValueError):
            return  # never write over a file that does not read
    else:
        d = {}
    d.pop(b, None)
    d.pop(a, None)
    d[a] = b
    while len(d) > MOVES_MAX:
        d.pop(next(iter(d)))
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=1, ensure_ascii=False)
    os.replace(path + ".tmp", path)
    plan_follow_move(r, a, b)


def plan_follow_move(r, a, b):
    """A Plan board card follows its session to the new folder (a card on the old path showed no
    picture after a move, 2026-10-11). One card per session: a card already on b wins."""
    path = os.path.join(r, LIB, "plan.json")
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return
    videos = d.get("videos") if isinstance(d, dict) else None
    if not isinstance(videos, list) or not any(isinstance(v, dict) and v.get("session") == a for v in videos):
        return
    has_b = any(isinstance(v, dict) and v.get("session") == b for v in videos)
    out = []
    for v in videos:
        if isinstance(v, dict) and v.get("session") == a:
            if has_b:
                continue
            v = dict(v, session=b)
        out.append(v)
    d["videos"] = out
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
    os.replace(path + ".tmp", path)


def follow_moves(path, r=None):
    """The folder an old path moved to, through .moves.json (up to 20 steps), or None."""
    r = r or root()
    rel = os.path.relpath(path, r)
    if rel.startswith(".."):
        return None
    moves, seen = read_moves(r), set()
    for _ in range(20):
        if rel not in moves or rel in seen:
            return None
        seen.add(rel)
        rel = moves[rel]
        p = os.path.join(r, rel)
        if os.path.isdir(p):
            return p
    return None


def moved_away(path, sid=None):
    """True when path is an old name of another session that still exists: a new folder must not take
    it. A name that leads to session sid itself (rename back, Undo) or to nothing (trashed) is free."""
    to = follow_moves(path, lib_root(path))
    if not to:
        return False
    try:
        return session_id(to) != sid
    except (OSError, ValueError):
        return True


def free_session_path(path, sid=None):
    """unique() for session folders: also skips names other sessions moved away from."""
    base, n = path, 2
    while os.path.exists(path) or moved_away(path, sid):
        path = "%s-%d" % (base, n)
        n += 1
    return path


def trash(paths):
    if paths:
        subprocess.run(["/usr/bin/trash"] + list(paths), check=True, capture_output=True)


def session_summary(session):
    meta = read_meta(session)
    takes = meta.get("takes", [])
    numbers = {t["number"] for t in takes}
    keepers = {t["number"] for t in takes if t.get("keeper")}
    script = os.path.join(session, "script.md")
    return {"session": os.path.relpath(session, root()), "path": session, "id": shown_id(session, meta),
            "title": meta["title"], "created": meta["createdAt"], "takes": len(numbers), "keepers": len(keepers),
            "published": meta.get("published") or False,
            "has_script": os.path.exists(script) and os.path.getsize(script) > 0}


def arrange(items, folder, name, new_first):
    """Apply the order the user dragged in the app (<folder>/.order.json, a list of folder names)."""
    try:
        with open(os.path.join(folder, ".order.json")) as f:
            rank = {n: i for i, n in enumerate(json.load(f))}
    except (OSError, ValueError):
        return items
    known = sorted((x for x in items if name(x) in rank), key=lambda x: rank[name(x)])
    fresh = [x for x in items if name(x) not in rank]
    return fresh + known if new_first else known + fresh


def sessions_in(project):
    out = []
    for name in os.listdir(project):
        p = os.path.join(project, name)
        if os.path.isdir(p) and not name.startswith((".", "_")):
            out.append(session_summary(p))
    out.sort(key=lambda s: s["created"], reverse=True)
    return arrange(out, project, lambda s: os.path.basename(s["path"].rstrip("/")), True)


# ---------- script variants + history (same format as Sources/Takes/Scripts.swift) ----------

def parse_fm(raw):
    if raw.startswith("---\n"):
        end = raw.find("\n---\n", 3)
        if end != -1:
            fields = {}
            for line in raw[4:end].split("\n"):
                if ":" in line:
                    k, v = line.split(":", 1)
                    fields[k.strip()] = v.strip()
            return fields, raw[end + 5:]
    return {}, raw


def render_fm(fields, body):
    return "---\n" + "\n".join("%s: %s" % (k, str(v).replace("\n", " ")) for k, v in fields) + "\n---\n" + body


def read_text(path):
    with open(path) as f:
        return f.read()


def write_text(path, text):
    with open(path, "w") as f:
        f.write(text)


def variants(session):
    d = os.path.join(session, "variants")
    out = []
    if os.path.isdir(d):
        for name in os.listdir(d):
            if name.endswith(".md"):
                fm, body = parse_fm(read_text(os.path.join(d, name)))
                out.append({"variant": name[:-3], "name": fm.get("name", name[:-3]), "author": fm.get("author", ""),
                            "note": fm.get("note", ""), "created": fm.get("created", ""), "script": body})
    return sorted(out, key=lambda v: (v["created"], v["variant"]))


def draft_text(session, draft):
    if draft == "main":
        p = os.path.join(session, "script.md")
    else:
        p = os.path.join(session, "variants", draft + ".md")
    if not os.path.exists(p):
        return None
    return read_text(p) if draft == "main" else parse_fm(read_text(p))[1]


def history(session):
    d = os.path.join(session, "history")
    out = []
    if os.path.isdir(d):
        for name in os.listdir(d):
            if name.endswith(".md"):
                fm, body = parse_fm(read_text(os.path.join(d, name)))
                out.append({"version": name[:-3], "created": fm.get("created", ""), "author": fm.get("author", ""),
                            "note": fm.get("note", ""), "draft": fm.get("draft", "main"), "_body": body,
                            "_mtime": os.stat(os.path.join(d, name)).st_mtime_ns})
    out.sort(key=lambda v: (v["created"].replace("Z", "").ljust(23, "0"), v.pop("_mtime")), reverse=True)
    return out


def snapshot(session, draft, author, note):
    text = draft_text(session, draft)
    if text is None or not text.strip():
        return None
    last = next((v for v in history(session) if v["draft"] == draft), None)
    if last and last["_body"] == text:
        return None
    d = os.path.join(session, "history")
    os.makedirs(d, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    path, n = os.path.join(d, "%s-%s.md" % (stamp, draft)), 2
    while os.path.exists(path):
        path = os.path.join(d, "%s-%s-%d.md" % (stamp, draft, n))
        n += 1
    write_text(path, render_fm([("author", author), ("note", note), ("created", now_iso_ms()), ("draft", draft)], text))
    return os.path.basename(path)[:-3]


def set_main_script(session, text, author, note):
    """Write script.md with history on both sides, so the change can always be undone."""
    snapshot(session, "main", "user", "Before %s's change" % author.capitalize())
    write_text(os.path.join(session, "script.md"), text)
    snapshot(session, "main", author, note or "Edited by %s" % author.capitalize())


# ---------- tools ----------

def t_list_projects(_):
    r = root()
    os.makedirs(r, exist_ok=True)
    projects = []
    for name in sorted(os.listdir(r), key=str.lower):
        p = os.path.join(r, name)
        if os.path.isdir(p) and not name.startswith((".", "_")):
            projects.append({"project": name, "sessions": len(sessions_in(p))})
    return {"library": r, "projects": arrange(projects, r, lambda x: x["project"], False)}


def t_create_project(a):
    name = project_name(a["name"])
    p = os.path.join(root(), name)
    os.makedirs(p, exist_ok=True)
    return {"project": name, "path": p}


def t_list_sessions(a):
    return {"sessions": sessions_in(resolve_project(a["project"]))}


def t_get_session(a):
    s = resolve_session(a["session"])
    meta = read_meta(s)
    script_path = os.path.join(s, "script.md")
    script = open(script_path).read() if os.path.exists(script_path) else ""
    takes = []
    cuts = read_cuts(s)
    ready, jobs = {}, None
    for t in sorted(meta.get("takes", []), key=lambda t: (t["number"], t["kind"])):
        n = t["number"]
        if n not in ready:
            # Word times on the video clock (prepare_take). Read from the words file only: no ffprobe here.
            g = [x for x in meta.get("takes", []) if x["number"] == n]
            vt = next((x for x in g if x["kind"] == "camera"), g[0])
            doc = words_doc(os.path.join(s, vt["file"]))
            if is_ready(doc):
                ready[n] = {"edit_ready": True, "audio_offset_s": doc.get("audio_offset_s")}
            else:
                jobs = prepare_jobs(s) if jobs is None else jobs
                st = prepare_state(s, n, jobs)
                ready[n] = dict({"edit_ready": False}, **({"prepare": "running"} if st == "running" else
                                                            {"prepare_error": st[1]} if isinstance(st, tuple) else {}))
        v = voice_view(s, t)
        c = cuts.get(str(n))
        c = {k: v for k, v in c.items() if k not in ("pid", "model")} if c else None
        takes.append(dict(t, path=os.path.join(s, t["file"]), **ready[n], **({"voice": v} if v else {}),
                          **({"best_cut": c} if c else {}), **take_said(s, t, meta.get("takes", []))))
    checks = check_states(s)
    out = {"session": os.path.relpath(s, root()), "path": s, "id": shown_id(s, meta), "title": meta["title"],
           "created": meta["createdAt"], "script": script, "variants": variants(s),
           "favorite_script": meta.get("favorite"),
           "published": meta.get("published") or False,
           "style": dict(zip(("name", "picked_by"), style_pick(os.path.dirname(s), s))),
           "history_versions": len(history(s)), "takes": takes,
           "assets": assets(s, {t["file"] for t in meta.get("takes", [])}),
           "post": post_overview(s),
           "x_post": post_overview(s, "x"),
           "youtube_post": post_overview(s, "youtube"),
           "vertical_post": post_overview(s, "vertical"),
           **({"article": post_overview(s, "article")} if BLOG else {}),
           "hooks": read_hooks(s).get("hooks", []),
           "storyboard": storyboard_view(s),
           **session_recipes(s),
           "hook_in_script": next((h["id"] for h in read_hooks(s).get("hooks", [])
                                   if h["text"].strip() == first_paragraph(script)), None),
           "open_comments": sum(1 for c in read_comments(s)["comments"] if c.get("status") != "resolved"),
           **({"checks": checks} if checks else {}),
           "folders": FOLDERS,
           "warnings": misplaced(s),
           "library": "Style for this project: get_library with project '%s'." % os.path.basename(os.path.dirname(s)),
           **({"posting_plan": plan_brief()} if read_plan() else {}),
           "manifest": os.path.join(s, "SESSION.md")}
    # The rules for what comes next on this session, once per chat: no refusal later (2026-10-10).
    return with_rules(out, *next_steps(s))


# Where each kind of file goes. The one source of truth for Claude; the app shows the same folders.
FOLDERS = {
    "edits/": "Edited videos only, as <slug>-vN.mp4, each with its recipe <slug>-vN.recipe.json. Make them with "
              "render_edit + publish_edit.",
    "thumbnails/": "Thumbnail images for an edit, as <slug>-vN.png (options: <slug>-<option>-vN.png). "
                   "Get the path from next_path kind=thumbnail.",
    "stills/": "Frames the user saved from a paused video. Read them; never write here.",
    "storyboard/": "The storyboard and its sketches. Write it only with set_storyboard.",
    "generated/": "AI videos (replicate, higgsfield) and images (make_image), as <name>-vN.<ext>. Write here only with those tools.",
    "assets/": "Files the user dropped on the Assets tab. Read them; never write here.",
    "(library)": "Reusable style (logos, icons, images, motion graphics, fonts, colours, type) goes in the "
                 "style or project library, never in a session. See get_library.",
    "_work/": "Cuts of cut_take and rough_cut, as <name>-vN.mp4 with .wav, .words.json and .json. Takes "
              "keeps the newest 5 of a name. List the folder to find an earlier cut. Write here only with those tools.",
    "_edit/": "_edit/<name>/ holds an edit's sources and renders. Takes manages it. Other scratch stays outside the "
              "session.",
}


def misplaced(s):
    """Files in the wrong folder, so Claude can see and fix its own mistakes."""
    out = []
    for folder, want, what in (("edits", ("video",), "an edited video"), ("thumbnails", ("image",), "an image")):
        d = os.path.join(s, folder)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.startswith(".") or f.endswith((".words.json", ".srt", ".vtt", RECIPE_EXT) + EXPORT_EXTS):
                continue  # transcripts, recipes and exports sit next to their video
            kind = media_kind(f)
            if kind not in want:
                out.append("%s/%s is not %s. %s" % (folder, f, what,
                           "Thumbnails go in thumbnails/." if kind == "image" else "Move it out of %s/." % folder))
            elif not split_version(f)[1]:
                out.append("%s/%s has no version number: name it <slug>-vN (next_path does this)." % (folder, f))
    return out


def media_kind(name):
    ext = os.path.splitext(name)[1].lower()
    if ext in (".mp4", ".mov", ".m4v", ".webm"):
        return "video"
    if ext in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".heic", ".tiff"):
        return "image"
    return "other"


VERSIONED = re.compile(r"^(.*?)-v(\d+)$")


def split_version(name):
    """'logo-v3.svg' -> ('logo', 3, '.svg'). No -vN -> version None."""
    stem, ext = os.path.splitext(name)
    m = VERSIONED.match(stem)
    return (m.group(1), int(m.group(2)), ext) if m else (stem, None, ext)


def versions_in(d, base):
    """Every version number of <base>-vN.* in folder d. A <base>-vN.recipe.json with no video yet is a
    claim of publish_edit: that N is taken too."""
    if not os.path.isdir(d):
        return []
    return sorted({v for b, v in (edit_name_of(f) for f in os.listdir(d)) if b == base and v})


def t_next_path(a):
    """The next free versioned path, so every export lands in the right folder with the right name."""
    kind = a["kind"]
    base = slug(split_version(a["name"])[0]) or "untitled"
    if kind in ("edit", "thumbnail"):
        s = resolve_session(a["session"])
        d = os.path.join(s, "edits" if kind == "edit" else "thumbnails")
        ext = a.get("ext") or (".mp4" if kind == "edit" else ".png")
    elif kind == "library":
        group = (a.get("group") or "").strip().strip("/")
        if not group or "/" in group or group.startswith((".", "_")):
            raise ValueError("Give a group: one folder name such as Logos, Icons, Images or Motion.")
        d = os.path.join(library_dir(a.get("library")), "assets", group)
        ext = a.get("ext") or ""
        if not ext:
            raise ValueError("Give ext for a library file, e.g. '.svg' or '.mp4'.")
    else:
        raise ValueError("kind is edit, thumbnail or library.")
    ext = ext if ext.startswith(".") else "." + ext
    have = versions_in(d, base)
    if kind in ("edit", "thumbnail"):  # a version a running job will write is taken too
        folder = os.path.basename(d)
        have = sorted(set(have) | {v for b, v, _ in (split_version(os.path.basename(o)) for o in claimed_outputs(s)
                                                     if os.path.dirname(o) == folder) if b == base and v})
    n = (have[-1] if have else 0) + 1
    os.makedirs(d, exist_ok=True)
    prev = next((os.path.join(d, f) for f in sorted(os.listdir(d))
                 if split_version(f)[:2] == (base, have[-1]) and not f.endswith(RECIPE_EXT)), None) if have else None
    out = {"path": os.path.join(d, "%s-v%d%s" % (base, n, ext)), "version": n, "previous": prev,
           "note": "Write the file to exactly this path. Never overwrite an earlier version."
                   + (" For an edit, render_edit + publish_edit do this for you and keep the recipe." if kind == "edit" else "")}
    # A path refuses nothing: the rules come with it, once per chat (2026-10-10).
    if kind == "edit":
        return with_rules(out, *EDIT_AREAS)
    if kind == "thumbnail":
        return with_rules(out, "thumbnail")
    return out


# ---------- style library ----------
#
# <root>/_library/styles/<Style>/ are the user's named styles (Magazine, ...). Each project picks one in
# <project>/_library/project.json {"style": "<Style>"}; <project>/_library/ also holds that project's own
# additions, which win over the style. Each style and project library has a claude.ai Design System layout:
#   README.md              the style guide
#   tokens.json            colours, type, spacing, radius: {"color": {"tokens": [{name, value, usage}]}, ...}
#   assets/<Group>/<name>-vN.<ext>   logos, icons, images, motion graphics (rendered .mp4)
#   fonts/                 font files
#   src/<name>/            sources, e.g. a HyperFrames composition (not shown in the app)
#   comments.json, comments/   the user's comments, same format as a session's
#   style.json             (styles only) {"template", "description", "source", "status": "new" until the user keeps it}
#   preview.mp4, preview.png   (styles only) the sample clip in this style, for the app's Styles board
#   assets.json            where each asset came from and what it is for: {"assets/Motion/x-v1.mp4": {"note", "from", "added"}}
#
# A session can pick its own style (session.json "style"); else it uses its project's pick.

LIB = "_library"
LIB_SKIP = {"comments.json", ".order.json", "project.json", "assets.json"}
STYLE_SAMPLE = "style-sample.mp4"  # in <root>/_library: the clip every style preview uses


def styles_dir():
    return os.path.join(root(), LIB, "styles")


def style_names():
    d = styles_dir()
    if not os.path.isdir(d):
        return []
    return sorted((x for x in os.listdir(d) if not x.startswith(".") and os.path.isdir(os.path.join(d, x))),
                  key=str.lower)


def default_style():
    names = style_names()
    return "Magazine" if "Magazine" in names else (names[0] if names else None)


def chosen_style(project, session=None):
    """The style a video uses: the session's pick, else its project's pick in project.json, else the default."""
    return style_pick(project, session)[0]


def style_pick(project, session=None):
    """(style, where the pick comes from: 'session', 'project' or 'default')."""
    if session:
        pick = read_meta(session).get("style")
        if pick in style_names():
            return pick, "session"
    try:
        with open(os.path.join(resolve_project(project), LIB, "project.json")) as f:
            pick = json.load(f).get("style")
        if pick in style_names():
            return pick, "project"
    except (OSError, ValueError, AttributeError):
        pass
    return default_style(), "default"


def library_dir(level):
    """'style:<Name>' is one of the user's styles ('user' = the default style); anything else is a project."""
    level = (level or "user").strip()
    # The comment copilot's files (lessons, target list, style guide): Comments > Library.
    if level == "comments":
        return comments_dir()
    if level.lower().startswith("style:"):
        name = level.split(":", 1)[1].strip()
        if not name or "/" in name or name.startswith((".", "_")):
            raise ValueError("Give a style name, e.g. 'style:Magazine'.")
        return os.path.join(styles_dir(), name)
    if level in ("user", "style"):
        name = default_style()
        if not name:
            raise ValueError("The user has no styles yet. Make one with library 'style:<Name>'.")
        return os.path.join(styles_dir(), name)
    return os.path.join(resolve_project(level), LIB)


def style_meta(name):
    try:
        with open(os.path.join(styles_dir(), name, "style.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def asset_notes(d):
    try:
        with open(os.path.join(d, "assets.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def style_uses():
    """{style: [sessions with edits that use it]}: the session's pick, else its project's."""
    out = {}
    r = root()
    for p in sorted(os.listdir(r)) if os.path.isdir(r) else []:
        pd = os.path.join(r, p)
        if p.startswith((".", "_")) or not os.path.isdir(pd):
            continue
        for f in sorted(os.listdir(pd)):
            sd = os.path.join(pd, f)
            ed = os.path.join(sd, "edits")
            if f.startswith((".", "_")) or not os.path.isdir(ed):
                continue
            if not any(x.lower().endswith((".mp4", ".mov")) for x in os.listdir(ed)):
                continue
            try:
                name = chosen_style(pd, sd)
            except (OSError, ValueError):
                continue
            if name:
                out.setdefault(name, []).append(os.path.relpath(sd, r))
    return out


def style_card(name, uses=None):
    d = os.path.join(styles_dir(), name)
    card = dict({"name": name, "library": "style:" + name}, **style_meta(name))
    for f in ("preview.mp4", "preview.png"):
        if os.path.exists(os.path.join(d, f)):
            card[f.replace(".", "_")] = os.path.join(d, f)
    if uses is not None:
        card["used_by"] = uses.get(name, [])
    return card


def library_files(d):
    out = []
    for dirpath, dirs, files in os.walk(d):
        rel = os.path.relpath(dirpath, d)
        dirs[:] = [x for x in dirs if not x.startswith(".") and not (rel == "." and x == "comments")]
        for f in files:
            if f.startswith(".") or (rel == "." and f in LIB_SKIP):
                continue
            out.append(os.path.normpath(os.path.join(rel, f)))
    return sorted(out)


def library_view(level):
    d = library_dir(level)
    view = {"library": level, "path": d, "exists": os.path.isdir(d)}
    if not view["exists"]:
        return view
    readme = os.path.join(d, "README.md")
    view["readme"] = read_text(readme) if os.path.exists(readme) else None
    try:
        with open(os.path.join(d, "tokens.json")) as f:
            view["tokens"] = json.load(f)
    except (OSError, ValueError):
        view["tokens"] = None
    notes = asset_notes(d)
    opened = {}
    for c in read_comments(d)["comments"]:
        if c.get("status") != "resolved":
            opened[c["file"]] = opened.get(c["file"], 0) + 1
    groups = {}
    for rel in library_files(d):
        parts = rel.split(os.sep)
        if parts[0] != "assets" or len(parts) < 3:
            continue
        group, name = parts[1], "/".join(parts[2:])
        base, v, ext = split_version(name)
        item = groups.setdefault(group, {}).setdefault(base + ext, {"name": base + ext, "versions": []})
        item["versions"].append(dict({"version": v, "file": rel, "path": os.path.join(d, rel),
                                      "open_comments": opened.get(rel, 0)}, **notes.get(rel, {})))
    view["assets"] = {}
    for g, items in sorted(groups.items()):
        lst = []
        for it in items.values():
            it["versions"].sort(key=lambda x: x["version"] or 0)
            it["latest"] = it["versions"][-1]["path"]
            lst.append(it)
        view["assets"][g] = sorted(lst, key=lambda x: x["name"])
    view["fonts"] = [r for r in library_files(d) if r.startswith("fonts" + os.sep)]
    view["open_comments"] = sum(opened.values())
    return view


def merged_tokens(user, project):
    """Project tokens override the user's by name, family by family."""
    out = json.loads(json.dumps(user or {}))
    for fam, val in (project or {}).items():
        if isinstance(val, dict) and isinstance(val.get("tokens"), list) and isinstance(out.get(fam), dict):
            names = {t.get("name") for t in val["tokens"]}
            out[fam]["tokens"] = [t for t in out[fam].get("tokens", []) if t.get("name") not in names] + val["tokens"]
        else:
            out[fam] = val
    return out


def t_get_library(a):
    uses = style_uses()
    styles = [style_card(n, uses) for n in style_names()]
    sample = os.path.join(root(), LIB, STYLE_SAMPLE)
    session = resolve_session(a["session"]) if a.get("session") else None
    project = os.path.dirname(session) if session else a.get("project")
    if not project:
        return {"styles": styles, "default": default_style(), "layout": LIBRARY_LAYOUT,
                "sample": sample, "sample_exists": os.path.exists(sample),
                "note": "Pass session (or project) to get the style that video uses, with its tokens and assets."}
    name, picked = style_pick(resolve_project(project), session)
    style = library_view("style:" + name) if name else {"exists": False}
    proj = library_view(project)
    return {"style": name, "picked_by": picked, "template": style_meta(name).get("template") if name else None,
            "styles": styles, "style_library": style, "project": proj,
            "tokens": merged_tokens(style.get("tokens"), proj.get("tokens")), "layout": LIBRARY_LAYOUT,
            "note": ("The user picks the style per video on the Assets tab, or per project (set_style). picked_by "
                     "says which. Use the project library first, the style for anything it lacks. 'tokens' is the "
                     "merge (project wins by name). 'template' names the video-edit template for this style. Always "
                     "use an asset's latest version, and read its open comments first. After an edit, keep its "
                     "reusable parts with save_to_library. New style: create_style.")}


def t_set_style(a):
    name = (a.get("style") or "").strip()
    if a.get("session"):
        s = resolve_session(a["session"])
        meta = read_meta(s)
        if name:
            if name not in style_names():
                raise ValueError("No style '%s'. Styles: %s." % (name, ", ".join(style_names()) or "none"))
            meta["style"] = name
        else:
            meta.pop("style", None)
        write_meta(s, meta)
        return {"session": os.path.relpath(s, root()), "style": chosen_style(os.path.dirname(s), s),
                "picked_by": style_pick(os.path.dirname(s), s)[1]}
    if not a.get("project"):
        raise ValueError("Give session or project.")
    if name not in style_names():
        raise ValueError("No style '%s'. Styles: %s." % (name, ", ".join(style_names()) or "none"))
    d = os.path.join(resolve_project(a["project"]), LIB)
    os.makedirs(d, exist_ok=True)
    write_text(os.path.join(d, "project.json"), json.dumps({"style": name}, indent=2) + "\n")
    return {"project": a["project"], "style": name}


def t_save_to_library(a):
    """Keep a reusable part of an edit (a title card, a lower third, a caption look, a cover layout) as the
    next version of a library asset, with a note on what it is and where it came from."""
    session = resolve_session(a["session"]) if a.get("session") else None
    src = os.path.expanduser(a["file"])
    if not os.path.isabs(src):
        if not session:
            raise ValueError("file is relative: give session too, or an absolute path.")
        src = os.path.join(session, src)
    if not os.path.isfile(src):
        raise ValueError("No file at %s." % src)
    lib = a.get("library") or ("style:" + chosen_style(os.path.dirname(session), session) if session else None)
    if not lib:
        raise ValueError("Give library: 'style:<Name>' or a project name.")
    ext = os.path.splitext(src)[1]
    nxt = t_next_path({"kind": "library", "library": lib, "group": a["group"], "name": a["name"], "ext": ext})
    shutil.copy2(src, nxt["path"])
    d = library_dir(lib)
    rel = os.path.relpath(nxt["path"], d)
    info = {"note": (a.get("note") or "").strip(), "added": now_iso()}
    if session:
        info["from"] = os.path.relpath(session, root())
    if a.get("source_dir"):
        sd = os.path.expanduser(a["source_dir"])
        if not os.path.isdir(sd):
            raise ValueError("No folder at %s." % sd)
        dst = os.path.join(d, "src", os.path.splitext(os.path.basename(nxt["path"]))[0])
        shutil.copytree(sd, dst, ignore=shutil.ignore_patterns("node_modules", ".*", "renders", "*.mp4"))
        info["source"] = os.path.relpath(dst, d)
    notes = asset_notes(d)
    notes[rel] = info
    write_text(os.path.join(d, "assets.json"), json.dumps(notes, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    return {"library": lib, "file": rel, "path": nxt["path"], "version": nxt["version"],
            "note": "The user sees it on the Styles board and can comment on it. Read its comments (get_library) "
                    "before you use or change it; a change is a new version, never an overwrite."}


def t_create_style(a):
    name = (a.get("name") or "").strip()
    if not name or "/" in name or name.startswith((".", "_")):
        raise ValueError("Give a style name, e.g. 'Bold Notes'.")
    d = os.path.join(styles_dir(), name)
    if os.path.exists(d):
        raise ValueError("Style '%s' exists. Pick another name, or edit it." % name)
    os.makedirs(os.path.join(d, "assets"), exist_ok=True)
    meta = {"description": (a.get("description") or "").strip(), "status": "new", "created": now_iso()}
    for k in ("source", "template"):
        if a.get(k):
            meta[k] = a[k].strip()
    write_text(os.path.join(d, "style.json"), json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    sample = os.path.join(root(), LIB, STYLE_SAMPLE)
    return {"style": name, "library": "style:" + name, "path": d, "sample": sample,
            "sample_exists": os.path.exists(sample),
            "next": ["Study the source (open a link in your one background Chrome tab; read an image or video file).",
                     "Write README.md (the look in rules), tokens.json (colours, type) and fonts/ (free fonts only).",
                     "Build a title card, a lower third and a caption look in this style (HyperFrames); keep each "
                     "with save_to_library library='style:%s' group=Motion." % name,
                     "Render preview.mp4 (6 s) and preview.png (its best frame) into %s: the sample clip %s with "
                     "the title card, a caption and the lower third on it. Every style uses the same sample, so "
                     "The user compares like with like. No sample yet: cut 6 s of the user talking from a recent "
                     "keeper take to that path first." % (d, sample),
                     "Tell the user it is on the Styles board. The user keeps it there, or trashes it."]}


LIBRARY_LAYOUT = {
    "README.md": "The style guide: voice, look, rules that name the tokens.",
    "tokens.json": "Design values as lists, like a claude.ai Design System: {\"color\": {\"tokens\": [{\"name\", "
                   "\"value\", \"usage\"}]}, \"type\": {\"families\": {...}, \"groups\": [...]}, \"spacing\": "
                   "{\"tokens\": [...]}, \"radius\": {\"tokens\": [...]}}.",
    "assets/<Group>/<name>-vN.<ext>": "Logos, Icons, Images, Motion (rendered .mp4 previews). New file = new "
                                      "version from next_path kind=library; never overwrite one.",
    "fonts/": "Font files.",
    "src/<name>/": "Sources, e.g. a HyperFrames composition for a motion graphic. Not shown in the app.",
    "style.json": "Styles only: {\"template\": \"magazine\", \"description\": \"one line\", \"source\": "
                  "\"what it was made from\", \"status\": \"new\" until the user keeps it}. template names the "
                  "video-edit skill template this style goes with.",
    "preview.mp4, preview.png": "Styles only: the shared sample clip in this style. The Styles board shows them.",
    "assets.json": "Written by save_to_library: each asset's note, the session it came from, its source folder.",
}


def t_copy_library(a):
    """Copy (or move) library files between the user library and project libraries."""
    src, dst = library_dir(a["from"]), library_dir(a["to"])
    if os.path.normpath(src) == os.path.normpath(dst):
        raise ValueError("from and to are the same library.")
    if not os.path.isdir(src):
        raise ValueError("No library at %s." % src)
    items = a.get("items") or library_files(src)
    copied, merged, skipped = [], [], []
    for rel in items:
        rel = os.path.normpath(rel)
        if rel.startswith("..") or os.path.isabs(rel):
            raise ValueError("Bad item %s: give paths inside the library, e.g. assets/Logos/mark-v2.svg." % rel)
        s_path, d_path = os.path.join(src, rel), os.path.join(dst, rel)
        if not os.path.isfile(s_path):
            raise ValueError("No file %s in %s." % (rel, src))
        os.makedirs(os.path.dirname(d_path), exist_ok=True)
        if rel == "tokens.json" and os.path.exists(d_path):
            with open(d_path) as f:
                have = json.load(f)
            with open(s_path) as f:
                incoming = json.load(f)
            write_text(d_path, json.dumps(merged_tokens(have, incoming), indent=2, ensure_ascii=False) + "\n")
            merged.append(rel)
        elif os.path.exists(d_path):
            skipped.append(rel)
        else:
            with open(s_path, "rb") as f_in, open(d_path, "wb") as f_out:
                f_out.write(f_in.read())
            copied.append(rel)
    if a.get("move"):
        trash([os.path.join(src, r) for r in copied + merged])
    return {"from": src, "to": dst, "copied": copied, "merged_tokens": merged,
            "skipped_existing": skipped, "moved": bool(a.get("move")),
            "note": "tokens.json merges by token name (incoming wins). Existing files are never overwritten."}


def assets(s, take_files):
    """Every file the app shows on the session's Assets tab: stills/, edits/, assets/ and the rest."""
    skip_files = {"script.md", "session.json", "SESSION.md", ".order.json", "hooks.json", "comments.json", "evergreen.json", "cuts.json", "checks.json"}
    out = []
    for dirpath, dirs, files in os.walk(s):
        rel = os.path.relpath(dirpath, s)
        top = "" if rel == "." else rel.split(os.sep)[0]
        dirs[:] = [d for d in dirs if not d.startswith(".") and not (rel == "." and (
            d.startswith("_") or d in ("variants", "history", "comments", "posts", "voice", "storyboard")))]
        for f in files:
            if f.startswith(".") or f.endswith((".words.json", RECIPE_EXT)) or (rel == "." and (f in skip_files or f in take_files)):
                continue
            path = os.path.join(dirpath, f)
            out.append({"folder": top, "file": os.path.relpath(path, s), "path": path,
                        "bytes": os.path.getsize(path)})
    open_by_file = {}
    for c in read_comments(s)["comments"]:
        if c.get("status") != "resolved":
            open_by_file[c["file"]] = open_by_file.get(c["file"], 0) + 1
    for a in out:
        if open_by_file.get(a["file"]):
            a["open_comments"] = open_by_file[a["file"]]
    return sorted(out, key=lambda x: x["file"])


def read_comments(s):
    try:
        with open(os.path.join(s, "comments.json")) as f:
            data = json.load(f)
            data.setdefault("comments", [])
            return data
    except (OSError, ValueError):
        return {"comments": []}


def write_comments(s, data):
    path = os.path.join(s, "comments.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def clock(sec):
    return "%d:%04.1f" % (int(sec) // 60, sec % 60)


def comment_view(s, c):
    out = dict(c)
    out["path"] = os.path.join(s, c["file"])
    if c.get("shot"):
        # A comment on a storyboard shot: the shot and its sketch, so Claude sees what it is about.
        x = next((x for x in read_storyboard(s)["shots"] if x.get("id") == c["shot"]), None)
        out["when"] = "storyboard shot %s" % c["shot"]
        out["area"] = None
        out["shot_now"] = {k: x.get(k) for k in ("id", "section", "kind", "say", "do", "sketch", "video")} if x else None
        img = x and x.get("image") and os.path.join(s, STORYBOARD_DIR, x["image"])
        out["frame"] = img if img and os.path.exists(img) else None
        return out
    if c.get("quote") is not None:
        out["when"] = "selected text"
    elif c.get("start") is not None:
        out["when"] = clock(c["start"]) + ("-" + clock(c["end"]) if c.get("end") is not None
                                           and c["end"] - c["start"] >= 0.1 else "")
    elif c.get("rect"):
        out["when"] = "still image"
    elif c["file"].endswith(".md"):
        out["when"] = "whole text"
    else:
        out["when"] = "whole video"
    r = c.get("rect")
    out["area"] = None if c.get("quote") is not None else ("x %.0f%%-%.0f%%, y %.0f%%-%.0f%% of the frame (from top left)"
                   % (r[0] * 100, (r[0] + r[2]) * 100, r[1] * 100, (r[1] + r[3]) * 100)) if r else "whole frame"
    if c.get("frame"):
        fp = os.path.join(s, c["frame"])
        out["frame"] = fp if os.path.exists(fp) else None
    return out


def comment_root(a):
    """A session folder, or a library ('style:<Name>' or a project name)."""
    if a.get("library"):
        d = library_dir(a["library"])
        if not os.path.isdir(d):
            raise ValueError("No library at %s." % d)
        return d
    if not a.get("session"):
        raise ValueError("Give session or library.")
    return resolve_session(a["session"])


# ---------- transcripts ----------
#
# A video's transcript sits next to it as <video stem>.words.json: Whisper output with word times
# ({"segments": [{"words": [...]}]}, {"words": [...]} or a plain list of {word|text, start, end}),
# or as <video stem>.srt / .vtt. get_comments uses it to quote what is said at each comment.

def transcript_words(video):
    stem = os.path.splitext(video)[0]
    j = stem + ".words.json"
    if os.path.exists(j):
        try:
            with open(j) as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = None
        words = []
        if isinstance(data, dict):
            if isinstance(data.get("words"), list):
                words = data["words"]
            for seg in data.get("segments") or []:
                if isinstance(seg, dict):
                    words += seg.get("words") or [{"text": seg.get("text", ""), "start": seg.get("start"), "end": seg.get("end")}]
        elif isinstance(data, list):
            words = data
        out = []
        for w in words:
            # {"word"|"text", "start", "end"} from Whisper, or a compact [word, start, end] list.
            try:
                if isinstance(w, (list, tuple)):
                    t, start, end = str(w[0]).strip(), w[1], (w[2] if len(w) > 2 else None)
                elif isinstance(w, dict):
                    t, start, end = (w.get("word") or w.get("text") or "").strip(), w.get("start"), w.get("end")
                else:
                    continue
                if t and start is not None:
                    out.append((float(start), float(end or start), t))
            except (IndexError, TypeError, ValueError):
                continue  # one bad word never costs the whole transcript
        return out
    for ext in (".srt", ".vtt"):
        if os.path.exists(stem + ext):
            return cues(read_text(stem + ext))
    return None


def cues(text):
    out = []
    stamp = r"(\d+):(\d{2}):(\d{2})[,.](\d{3})"
    for block in re.split(r"\n\s*\n", text.replace("\r", "")):
        m = re.search(stamp + r"\s*-->\s*" + stamp, block)
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
        body = " ".join(l.strip() for l in block[m.end():].split("\n") if l.strip())
        if body:
            out.append((start, end, re.sub(r"<[^>]+>", "", body)))
    return out


# Take time is video time (2026-10-11). A camera take's audio starts 0.16-0.24 s after its first
# frame. A WAV made with plain -vn starts at the first sound, so its times run that much early (the
# voice played 5 frames early). Every WAV taken from a take goes through extract_voice: second 0 of the
# WAV is frame 0 of the video. A voice WAV made before then is paired with take times by voice_offset.

VIDEO_CLOCK = "aresample=async=1:first_pts=0"   # pads or trims the start: the audio runs on video time
CLOCKS = {}  # (path, size, mtime) -> take_clock


def extract_voice(src, out, rate=48000, channels=1, codec="pcm_f32le", extra_af=None, extra=()):
    """A take's sound as a WAV on the video clock: second 0 of the WAV is frame 0 of the video."""
    ff("-i", src, "-vn", "-af", VIDEO_CLOCK + ("," + extra_af if extra_af else ""), "-ac", channels, "-ar", rate,
       "-c:a", codec, *extra, out)


def frac(x):
    try:
        a, b = str(x).split("/") if "/" in str(x) else (x, 1)
        return float(a) / float(b) if float(b) else 0.0
    except (TypeError, ValueError):
        return 0.0


def take_clock(path):
    """{audio_offset_s, fps, fps_mode, duration, width, height, pix_fmt, color...} of a video, None when it
    has no video (or cannot be read). audio_offset_s is None without sound."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    key = (path, st.st_size, st.st_mtime)
    if key in CLOCKS:
        return dict(CLOCKS[key])
    probe = find_tool("ffprobe")
    if not probe:
        raise ValueError("ffprobe is not installed. Open Takes and click Finish setup, or run brew install ffmpeg.")
    r = subprocess.run([probe, "-v", "error", "-show_entries",
                        "stream=codec_type,start_time,r_frame_rate,avg_frame_rate,width,height,pix_fmt,channels,"
                        "color_primaries,color_transfer,color_space:stream_side_data=rotation",
                        "-show_entries", "format=duration", "-of", "json", path],
                       capture_output=True, text=True, timeout=60)
    try:
        d = json.loads(r.stdout or "{}")
    except ValueError:
        return None
    streams = d.get("streams") or []
    v = next((x for x in streams if x.get("codec_type") == "video"), None)
    a = next((x for x in streams if x.get("codec_type") == "audio"), None)
    if not v:
        return None
    rate, avg = frac(v.get("r_frame_rate")), frac(v.get("avg_frame_rate"))
    fps = round(rate) if 24 <= rate <= 60 else min((24, 25, 30, 50, 60), key=lambda f: abs(f - (avg or 30)))
    try:
        dur = float((d.get("format") or {}).get("duration"))
    except (TypeError, ValueError):
        dur = None
    w, h = v.get("width"), v.get("height")
    rot = next((x.get("rotation") for x in v.get("side_data_list") or [] if "rotation" in x), 0) or 0
    if w and h and abs(int(rot)) % 180 == 90:
        w, h = h, w
    off = None
    if a:
        off = round(float(a.get("start_time") or 0) - float(v.get("start_time") or 0), 3)
    out = {"audio_offset_s": off, "fps": fps,
           "fps_mode": "cfr" if v.get("r_frame_rate") == v.get("avg_frame_rate") or abs(rate - avg) < 1e-6 else "vfr",
           "duration": round(dur, 3) if dur else None, "width": w, "height": h, "pix_fmt": v.get("pix_fmt"),
           "channels": (a or {}).get("channels")}
    for k in ("color_primaries", "color_transfer", "color_space"):
        if v.get(k) and v[k] != "unknown":
            out[k] = v[k]
    CLOCKS[key] = out
    return dict(out)


def words_doc(video):
    """The words file next to a video as a dict, {} when there is none, None when it does not read."""
    p = os.path.splitext(video)[0] + ".words.json"
    if not os.path.exists(p):
        return {}
    try:
        with open(p) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else {"words": d} if isinstance(d, list) else None


def voice_offset(s, key):
    """Seconds a voice WAV starts after video t=0: 0 for 'clock: video', else the take's audio offset."""
    v = read_voice(s, key) or {}
    if v.get("clock") == "video":
        return 0.0
    m = re.match(r"take-(\d+)-(camera|screen)$", key)
    if not m:
        return 0.0
    try:
        t = voice_take(s, int(m.group(1)), m.group(2))
    except ValueError:
        return 0.0
    c = take_clock(os.path.join(s, t["file"]))
    return float((c or {}).get("audio_offset_s") or 0.0)


def said(words, start, end, pad=1.0):
    """The words spoken from pad seconds before start to pad seconds after end."""
    lo, hi = start - pad, (end if end is not None else start) + pad
    return " ".join(t for s, e, t in words if e >= lo and s <= hi) or None


def t_get_comments(a):
    """The user's review comments on files in a session or a library."""
    s = comment_root(a)
    status = a.get("status", "open")
    out, words_cache = [], {}
    for c in read_comments(s)["comments"]:
        if a.get("file") and c["file"] != a["file"] and os.path.join(s, c["file"]) != a["file"]:
            continue
        if status != "all" and (c.get("status") == "resolved") != (status == "resolved"):
            continue
        v = comment_view(s, c)
        if c.get("start") is not None:
            if c["file"] not in words_cache:
                try:
                    words_cache[c["file"]] = transcript_words(os.path.join(s, c["file"]))
                except Exception:  # a broken transcript loses its quotes, not every comment
                    words_cache[c["file"]] = None
            w = words_cache[c["file"]]
            v["said"] = said(w, c["start"], c.get("end")) if w else None
            if w is None:
                v["said_note"] = "No transcript. Write <video stem>.words.json (Whisper word times) next to the video."
        out.append(v)
    return {"comments": out,
            "note": "Video and image comments: read each 'frame' PNG, it shows the moment with the area "
                    "outlined in orange; fix it as a new version (next_path). Text comments carry 'quote', "
                    "the text the user selected: in a session script (script.md, variants/<slug>.md) change it "
                    "with update_session / update_variant; in the post (posts/linkedin.md, posts/x.md, posts/youtube.md, posts/vertical.md" + (", posts/article.md" if BLOG else "") + ") with set_post (and that platform), in a post variant (posts/variants/<slug>.md, posts/x/variants/<slug>.md) with set_post variant=<slug>; in a library "
                    "README.md or tokens.json edit the file. Storyboard comments carry 'shot' (its id) and "
                    "'shot_now': change the shot with set_storyboard (keep every id; the storyboard skill), "
                    "and the script with update_session if the lines change. "
                    "Then reply_comment with resolve=true and a lesson for each (get_rules for that step first: a rule "
                    "that covers it, 'new' with rule={area, text}, or 'one-off')."}


def t_reply_comment(a):
    """One reply, or many at once (replies=[...]), in one write."""
    s = comment_root(a)
    data = read_comments(s)
    by_id = {c["id"]: c for c in data["comments"]}
    items = a.get("replies") or [a]
    missing = [r.get("id") for r in items if r.get("id") not in by_id]
    if missing:
        raise ValueError("No comment %s. Use get_comments." % ", ".join(map(str, missing)))
    # A session comment that gets resolved needs its lesson (library comments do not).
    lessons = read_lessons() if a.get("session") else None
    if lessons is not None:
        bare = [r["id"] for r in items if r.get("resolve") and not r.get("lesson")
                and by_id[r["id"]].get("status") != "resolved"]
        if bare:
            raise ValueError("Give each resolved comment a lesson (%s): a rule id from get_rules when an "
                             "existing rule covers it, 'new' with rule={area, text} when it applies to the next "
                             "videos too, or 'one-off'." % ", ".join(bare))
    done, notes = [], {}
    for r in items:
        c = by_id[r["id"]]
        if lessons is not None and r.get("lesson"):
            one = {"merge": notes["merge"]} if "merge" in notes else {}  # one merge note for all rules
            apply_lesson(lessons, s, c, r, one)
            if "merge" in one:
                notes["merge"] = one["merge"]
            for k, v in one.items():
                if v not in notes.get(k, ""):
                    notes[k] = (notes[k] + " " + v) if k in notes else v
        if r.get("text", "").strip() or r.get("fixed_in"):
            reply = {"by": "claude", "text": r.get("text", "").strip(), "at": now_iso()}
            if r.get("fixed_in"):
                f = r["fixed_in"]
                rel = os.path.relpath(f, s) if os.path.isabs(f) else f
                if not os.path.exists(os.path.join(s, rel)):
                    raise ValueError("fixed_in %s does not exist in %s." % (rel, s))
                reply["file"] = rel
                if r.get("fixed_at") is not None:
                    reply["time"] = round(float(r["fixed_at"]), 2)
            c.setdefault("replies", []).append(reply)
        if "resolve" in r:
            c["status"] = "resolved" if r["resolve"] else "open"
        done.append(c)
    if lessons is not None and any(r.get("lesson") for r in items):
        write_lessons(lessons)
    write_comments(s, data)
    views = [comment_view(s, c) for c in done]
    out = views[0] if len(views) == 1 and not a.get("replies") else {"updated": views}
    return {**out, **notes}


# ---------- lessons: what the agent learned from the user's comments ----------
# <root>/_library/rules/<area>.json {"rules": [{id, area, text, on, by, made, from: [ref], repeats: [ref],
# check?}]}: one file per step of the content journey, so an agent reads only the steps it works on
# (2026-10-09: one lessons.json held them all, and one "post" area held every platform). The comment
# copilot's lessons are rules/comments.md, markdown it reads and the user edits in Comments > Library.
# A ref is "<project>/<session>#<comment id>". Each resolved session comment carries
# "lesson": "one-off" or a rule id, and "repeat": true when that rule was made before the comment:
# the agent made the same mistake again. The Feedback board shows the rules (the user edits, turns
# off or deletes them) and how the number of comments per video changes. A rule with a check is
# measured by check_edit, so it no longer rests on the agent's memory.
# Rules stay few and short (AREA_MAX per area, RULE_MAX characters): every chat reads them. Longer
# words go in details (DETAILS_MAX). In a full area a new rule comes with merge: {into, text, was}
# and waits on the Feedback board: The user merges it (the target gets the text, this one turns off with
# merged_into) or keeps both (2026-10-10). The app's LearnedRule has the same fields.
AREAS = ["storyboard", "script", "sound", "cut", "picture", "captions", "graphics", "thumbnail",
         "post-all", "post-linkedin", "post-x", "post-youtube", "post-vertical", "other"]
EDIT_AREAS = ["sound", "cut", "picture", "captions", "graphics"]
AREA_MAX = 10
RULE_MAX = 220
WAITING_MAX = 5  # rules waiting for the user's merge, per area
DETAILS_MAX = 600
CHECKS = {
    "loudness": "Integrated loudness in LUFS: {target, tolerance} (default -14 ± 1).",
    "peak": "True peak in dBTP: {max} (default -1).",
    "pauses": "No silence longer than {max} seconds (default 0.4), quieter than {floor} dB (default -35).",
    "length": "At most {max} seconds long.",
}
# Code checks on page drafts (2026-10-20, factory evals step 5): a site-page rule can carry one. Filled in the admin
# build (PAGE_CHECKS in the KPIs section); check_draft runs them, set_rule and learn_from_change accept them.
PAGE_CHECKS = {}
# Functions run before get_rules reads the rules (the admin build moves the user's draft notes into rules there).
RULE_SOURCES = []
# The old "post" area at the split: these two are about LinkedIn ("see more", the first comment).
SPLIT_POST = {"post-1": "post-linkedin", "post-2": "post-linkedin"}


def rules_dir():
    return os.path.join(root(), LIB, "rules")


def area_file(area):
    return os.path.join(rules_dir(), area + ".json")


def post_area(file):
    """The post rules a comment on this file belongs to: posts/x.md and posts/x/variants/ are X."""
    f = (file or "").replace(os.sep, "/")
    for p in ("x", "youtube", "vertical"):
        if f.startswith("posts/%s.md" % p) or f.startswith("posts/%s/" % p):
            return "post-" + p
    if f.startswith(("posts/linkedin.md", "posts/variants/", "posts/first-comment", "posts/hooks.json", "posts/history/")):
        return "post-linkedin"
    return "post-all"


def split_old_lessons():
    """Moves the one lessons.json into a file per area, once. It stays as lessons-before-split.json.
    A chat that started before the split still runs the old server: it finds no lessons.json, starts
    an empty one and adds its new rule there. Those rules move in too (absorb_old_rules)."""
    old = os.path.join(root(), LIB, "lessons.json")
    if not os.path.isfile(old):
        return
    try:
        with open(old) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return
    for r in d.get("rules", []):
        if r.get("area") == "post":
            r["area"] = SPLIT_POST.get(r["id"], "post-all")
        elif r.get("area") not in AREAS:
            r["area"] = "other"
    if os.path.isdir(rules_dir()) and any(f.endswith(".json") for f in os.listdir(rules_dir())):
        absorb_old_rules(d.get("rules", []))
        keep = "lessons-absorbed-%s.json" % time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    else:
        write_lessons({"rules": d.get("rules", [])})
        keep = "lessons-before-split.json"
    try:
        os.replace(old, os.path.join(root(), LIB, keep))
    except FileNotFoundError:
        pass  # the app or another chat moved it first


def absorb_old_rules(rules):
    """Adds the rules an old server wrote to lessons.json after the split. It saw no rules, so its ids
    start again at <area>-1: a taken id gets the next free one, and the comments that point to it follow."""
    d = read_lessons(split=False)
    texts = {" ".join(r["text"].lower().split()) for r in d["rules"]}
    for r in rules:
        if " ".join((r.get("text") or "").lower().split()) in texts or not r.get("id"):
            continue
        if any(x["id"] == r["id"] for x in d["rules"]):
            n = 1 + max([int(x["id"].rsplit("-", 1)[1]) for x in d["rules"]
                         if x["id"].startswith(r["area"] + "-") and x["id"].rsplit("-", 1)[1].isdigit()] or [0])
            new = "%s-%d" % (r["area"], n)
            for ref in r.get("from", []) + r.get("repeats", []):
                path, _, cid = ref.partition("#")
                s = os.path.join(root(), path)
                cs = read_comments(s)
                for c in cs["comments"]:
                    if c.get("id") == cid and c.get("lesson") == r["id"]:
                        c["lesson"] = new
                        write_comments(s, cs)
            r["id"] = new
        d["rules"].append(r)
        texts.add(" ".join(r["text"].lower().split()))
    write_lessons(d)


def read_lessons(split=True):
    if split:
        split_old_lessons()
    rules, bad = [], []
    for area in AREAS:
        try:
            with open(area_file(area)) as f:
                d = json.load(f)
        except FileNotFoundError:
            continue
        except (OSError, ValueError):
            bad.append(area)
            continue
        mine = d.get("rules") if isinstance(d, dict) else None
        if not isinstance(mine, list):
            bad.append(area)
            continue
        # A hand-edited rule without an id or text is skipped, and the file is never rewritten, so
        # it stays as the user wrote it (2026-10-10: one such rule broke get_session in every chat).
        good = [r for r in mine if isinstance(r, dict) and isinstance(r.get("id"), str) and r["id"]
                and isinstance(r.get("text"), str) and r["text"].strip()]
        if len(good) < len(mine):
            bad.append(area)
        rules += [dict(r, area=area) for r in good]
    return {"rules": rules, "unreadable": bad}


def need_writable(d, area):
    """write_lessons leaves an unreadable area file alone, so a change there would be lost."""
    if area in d.get("unreadable", []):
        raise ValueError("Nothing written. The user's rules file %s does not read: it is not JSON with a "
                         "rules list, or a rule has no id or text. Ask the user to fix the file." % area_file(area))


def write_lessons(d):
    """One file per area. A file that did not read (the user's typo) is left alone, never emptied."""
    os.makedirs(rules_dir(), exist_ok=True)
    for area in AREAS:
        if area in d.get("unreadable", []):
            continue
        mine = [r for r in d["rules"] if r["area"] == area]
        p = area_file(area)
        if not mine:
            if os.path.exists(p):
                os.remove(p)
            continue
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"rules": mine}, f, indent=2, ensure_ascii=False)
        os.replace(tmp, p)


# The rules a chat has seen, so a tool shows them once per chat (2026-10-09: "make sure the agents
# actually look into those"). Write tools refuse once when their step has unseen rules, and the
# refusal carries them; get_session and next_path add them to their result instead.
# Each message of a Takes chat starts a new MCP process, so memory alone forgot them after every
# message (about 30 refusals in one chat, 2026-10-10). The state lives on disk per chat:
# <root>/_library/.rules-seen/<chat>.json {"chat", "updated", "rules": {id: hash}, "comments": hash}.
# A rule counts as seen while its hash (text and details) matches, so a changed rule shows again.
# The app deletes the file when the chat compacts or a run ends early (Chat.swift forgetRules).
SEEN = {}  # by chat id (None: the agent gives none, Codex or Cursor: one process is one chat), and
           # for a chat whose file cannot be written
SEEN_DAYS = 30  # Claude Code keeps a conversation 30 days


def chat_id():
    """The Claude Code conversation: the same id for every message and after a restart of Takes
    (claude sets CLAUDE_CODE_SESSION_ID for its MCP servers). Every Takes chat also sets TAKES_CHAT_ID
    (Codex 2026-10-11, all agents 2026-10-12: pi hands it on to its MCP servers). None for other
    agents. A Codex or pi process started from a Claude Code Bash tool inherits the id and shares
    that chat's seen file."""
    v = (os.environ.get("TAKES_CHAT_ID") or os.environ.get("CLAUDE_CODE_SESSION_ID") or "").strip()
    return v if re.fullmatch(r"[A-Za-z0-9-]{8,64}", v) else None


def seen_file():
    c = chat_id()
    return os.path.join(root(), LIB, ".rules-seen", c + ".json") if c else None


def read_seen():
    c = chat_id()
    if c in SEEN or not c:
        d = SEEN.get(c) or {}
    else:
        try:
            with open(seen_file()) as f:
                d = json.load(f)
        except (OSError, ValueError):
            d = {}
    rules = d.get("rules") if isinstance(d, dict) else None
    return {"rules": dict(rules) if isinstance(rules, dict) else {},
            "comments": d.get("comments") if isinstance(d, dict) else None}


def write_seen(d):
    """Writes the whole file at once (a temp file, then replace). When it cannot, memory keeps it."""
    c, p = chat_id(), seen_file()
    if p:
        out = {"chat": c, "updated": now_iso(), "rules": d["rules"], "comments": d.get("comments")}
        tmp = "%s.%d.tmp" % (p, os.getpid())
        try:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(tmp, "w") as f:
                json.dump(out, f)
            os.replace(tmp, p)
            SEEN.pop(c, None)
            prune_seen(os.path.dirname(p))
            return
        except OSError:
            try:
                os.remove(tmp)
            except OSError:
                pass
    SEEN[c] = d


def prune_seen(folder):
    """Seen files of chats older than Claude Code keeps them."""
    old = time.time() - SEEN_DAYS * 86400
    for f in os.listdir(folder):
        try:
            if os.path.getmtime(os.path.join(folder, f)) < old:
                os.remove(os.path.join(folder, f))
        except OSError:
            pass


def forget_seen():
    """For tests: this chat starts again with nothing seen."""
    SEEN.clear()
    p = seen_file()
    if p and os.path.exists(p):
        os.remove(p)


def short_hash(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]


def rule_hash(r):
    return short_hash((r.get("text") or "") + "\n" + (r.get("details") or ""))


def comments_text():
    return read_text(lessons_path()).strip() or None


def unseen_rules(areas):
    """The rules of these steps this chat has not seen (or that changed since), and the comment
    copilot's lessons when 'comments' is one of the steps and they are new to it."""
    seen = read_seen()
    rules = [r for r in read_lessons()["rules"] if r["area"] in areas and r.get("on", True)
             and not r.get("merged_into") and seen["rules"].get(r["id"]) != rule_hash(r)]
    text = comments_text() if "comments" in areas else None
    if text and seen["comments"] == short_hash(text):
        text = None
    return rules, text


def mark_seen(rules, comments=None):
    if not rules and not comments:
        return
    d = read_seen()
    d["rules"].update({r["id"]: rule_hash(r) for r in rules})
    if comments:
        d["comments"] = short_hash(comments)
    write_seen(d)


def rule_lines(rules, comments=None):
    lines = []
    for r in rules:
        lines.append("- %s: %s" % (r["id"], r["text"]))
        if r.get("details"):
            lines.append("  details: %s" % r["details"])
    if comments:
        lines.append(comments)
    return lines


def need_rules(*areas):
    """Write tools: refuse once per chat when the step has rules this chat has not seen. The
    refusal carries them and marks them seen, so the same call goes through when sent again."""
    rules, comments = unseen_rules(areas)
    if not rules and not comments:
        return
    mark_seen(rules, comments)
    raise ValueError("Nothing written yet. These are the user's rules for %s (from past comments). Check your work "
                     "against each one, then send the same call again: it goes through.\n%s"
                     % (", ".join(areas), "\n".join(rule_lines(rules, comments))))


def show_rules(*areas):
    """Read tools: the rules of these steps that this chat has not seen, marked seen. None when there
    are none. It never refuses."""
    rules, comments = unseen_rules(areas)
    if not rules and not comments:
        return None
    mark_seen(rules, comments)
    return {"steps": list(areas), "new": rule_lines(rules, comments),
            "note": "The user's rules from past comments. Follow each one in what you make next. "
                    "Each shows once per chat; get_rules shows all."}


def with_rules(out, *areas):
    """A tool result with the unread rules of these steps as its first key (a cut-off result keeps
    them). Every tool that writes an edit or a thumbnail file returns through this."""
    r = show_rules(*areas)
    return {"rules": r, **out} if r else out


def next_steps(s):
    """The steps a chat on this session most likely works on next: no takes yet, plan the video;
    takes, edit them; edits, edit again and make the thumbnail."""
    if not read_meta(s).get("takes"):
        return ["script", "storyboard"]
    d = os.path.join(s, "edits")
    if os.path.isdir(d) and any(media_kind(f) == "video" for f in os.listdir(d)):
        return EDIT_AREAS + ["thumbnail"]
    return list(EDIT_AREAS)


def rule_view(r):
    v = {"id": r["id"], "area": r["area"], "text": r["text"]}
    if r.get("details"):
        v["details"] = r["details"]
    if r.get("check"):
        v["check"] = r["check"]
    if r.get("repeats"):
        v["repeated"] = len(r["repeats"])
    if r.get("by") == "you":
        v["by_user"] = True
    if r.get("merge"):
        v["waiting_merge"] = {"into": r["merge"].get("into"), "text": r["merge"].get("text")}
    if r.get("backtest"):
        v["backtest"] = r["backtest"]
    return v


def counts(r):
    """Counts toward the AREA_MAX of its area: on, not waiting for a merge, not merged away. The app's
    LearnedRule.counts is the same, so the board and Takes agree when an area is full."""
    return r.get("on", True) and not r.get("merge") and not r.get("merged_into")


def comment_ref(s, cid):
    return "%s#%s" % (os.path.relpath(s, root()), cid)


def clean_check(c, area=None):
    """A rule's check: an edit check (CHECKS), or on a site-page rule a page check (PAGE_CHECKS, admin build)."""
    if not c:
        return None
    kinds = PAGE_CHECKS if area == "site-page" and PAGE_CHECKS else CHECKS
    if not isinstance(c, dict) or c.get("kind") not in kinds:
        raise ValueError("check.kind is one of: %s." % ", ".join(sorted(kinds)))
    out = {"kind": c["kind"]}
    for k in ("target", "tolerance", "max", "floor"):
        if c.get(k) is not None:
            out[k] = float(c[k])
    if kinds is PAGE_CHECKS:
        phrases = c.get("phrases")
        if phrases is not None:
            if isinstance(phrases, str):
                phrases = [phrases]
            phrases = [" ".join(str(x).split()) for x in phrases if " ".join(str(x).split())][:20]
            if not phrases or any(len(x) > 80 for x in phrases):
                raise ValueError("check.phrases is a list of 1 to 20 phrases, each at most 80 characters.")
            out["phrases"] = phrases
        if c["kind"] == "banned" and not out.get("phrases"):
            raise ValueError("A banned check needs phrases: the words the user struck out.")
        if c["kind"] != "banned" and out.get("max") is not None and out["max"] < 1:
            raise ValueError("check.max is at least 1.")
    return out


def clean_details(details):
    if details is not None and not isinstance(details, str):
        raise ValueError("details is text, at most %d characters." % DETAILS_MAX)
    details = " ".join((details or "").split())
    if len(details) > DETAILS_MAX:
        raise ValueError("details is at most %d characters." % DETAILS_MAX)
    return details


# Where a long rule splits into its sentence and details: a sentence end before an uppercase letter,
# so "e.g. the" and "0.25 s. then" stay in one piece.
SENTENCE_END = re.compile(r"[.!?] (?=[A-Z])")


def new_rule(d, area, text, check=None, by="takes", ref=None, details=None, merge_into=None, merged=None,
             notes=None):
    """Adds a rule to d (not written). A full area needs merge_into and merged: the new rule waits on
    the Feedback board until the user merges it or keeps both. notes gets 'split' and 'merge' for the
    agent."""
    notes = {} if notes is None else notes
    area = (area or "").strip().lower()
    if area not in AREAS:
        raise ValueError("area is one of: %s." % ", ".join(AREAS))
    text = " ".join((text or "").split())
    if not text:
        raise ValueError("Give the rule's text: one short sentence.")
    details = clean_details(details)
    if len(text) > RULE_MAX:
        m = None if details else SENTENCE_END.search(text)
        if not m or not 40 <= m.start() + 1 <= RULE_MAX:
            raise ValueError("Rule is %d characters. Put one sentence (at most %d) in text and the rest in "
                             "details." % (len(text), RULE_MAX))
        rest = " ".join(text[m.end():].split())
        if len(rest) > DETAILS_MAX:
            raise ValueError("Rule is %d characters. Put one sentence (at most %d) in text and at most %d "
                             "characters in details." % (len(text), RULE_MAX, DETAILS_MAX))
        text, details = text[:m.start() + 1], rest
        notes["split"] = "Saved the first sentence as the rule and the rest as details."
    need_writable(d, area)
    mine = [r for r in d["rules"] if r["area"] == area and counts(r)]
    merge = None
    if merge_into:
        target = next((r for r in mine if r["id"] == merge_into), None)
        if target is None:
            raise ValueError("merge_into is a rule in the %s area: %s." % (area, ", ".join(r["id"] for r in mine)))
        merged = " ".join((merged or "").split())
        if not merged or len(merged) > RULE_MAX:
            raise ValueError("merged is one sentence of 1 to %d characters that holds both rules." % RULE_MAX)
        merge = {"into": target["id"], "text": merged, "was": target["text"]}
    elif len(mine) >= AREA_MAX:
        raise ValueError("The %s area has %d rules, the most it keeps. Nothing written yet. Add merge_into (the "
                         "id of the closest rule below) and merged (one sentence that holds both) to the rule, "
                         "then send the call again. The user approves the merge on the Feedback board. Both rules "
                         "are on until the user decides.\n%s" % (area, len(mine), "\n".join(rule_lines(mine))))
    if merge and sum(1 for r in d["rules"] if r["area"] == area and r.get("merge")) >= WAITING_MAX:
        raise ValueError("Nothing written. The user has %d merges to check in %s on the Feedback board. Add no "
                         "rule there until the user decides. For a comment, use lesson '%s' or 'one-off'."
                         % (WAITING_MAX, area, merge["into"]))
    n = 1 + max([int(r["id"].rsplit("-", 1)[1]) for r in d["rules"]
                 if r["id"].startswith(area + "-") and r["id"].rsplit("-", 1)[1].isdigit()] or [0])
    r = {"id": "%s-%d" % (area, n), "area": area, "text": text, "on": True, "by": by, "made": now_iso(),
         "from": [ref] if ref else [], "repeats": []}
    if details:
        r["details"] = details
    c = clean_check(check, area)
    if c:
        r["check"] = c
    if merge:
        r["merge"] = merge
        pair = "“%s” into “%s”" % (text, merge["was"])
        notes["merge"] = ((notes["merge"] + "; " + pair) if notes.get("merge") else
                          "Waiting on the Feedback board. Tell the user in one line, with the rule texts and no ids, "
                          "which rules it asks to merge: " + pair)
    d["rules"].append(r)
    return r


def t_get_rules(a):
    """The rules learned from the user's comments, the ones that are on."""
    for f in RULE_SOURCES:
        f()
    d = read_lessons()
    areas = a.get("area")
    if isinstance(areas, str):
        areas = [x.strip() for x in areas.split(",") if x.strip()]
    if not areas:
        # Only the list of steps: every rule at once is ~4k tokens, and an agent needs one or two steps
        # (2026-10-09). area=all still gives everything, for the Feedback board.
        on = [r for r in d["rules"] if r.get("on", True) and not r.get("merged_into")]
        steps = []
        for x in AREAS:
            n = sum(r["area"] == x for r in on)
            if n:
                steps.append({"area": x, "rules": n})
                if sum(r["area"] == x and counts(r) for r in on) >= AREA_MAX:
                    steps[-1]["full"] = True
        lines = [l for l in read_text(lessons_path()).splitlines() if l.lstrip().startswith("-")]
        steps.append({"area": "comments", "rules": len(lines)})
        return {"steps": steps, "note": "Call get_rules again with the steps you work on, e.g. area='post-all,"
                "post-x', 'script', 'edit' (sound, cut, picture, captions, graphics), 'thumbnail', "
                "'comments'. area='all' gives every rule. A full step needs merge_into and merged on a new rule."}
    if "all" in areas:
        areas = []
    # "post" is every post file; "edit" the five steps of an edit.
    areas = [y for x in (areas or []) for y in ([z for z in AREAS if z.startswith("post-")] if x == "post"
                                                else EDIT_AREAS if x == "edit" else [x])]
    raw = [r for r in d["rules"] if r.get("on", True) and not r.get("merged_into")
           and (not areas or r["area"] in areas)]
    out = {"rules": [rule_view(r) for r in raw]}
    if not areas or "comments" in areas:
        out["comments"] = read_text(lessons_path())
    mark_seen(raw, (out.get("comments") or "").strip() or None)
    out["note"] = ("Follow every rule here; they come from the user's comments. A rule the user wrote or changed "
                   "(by_user) wins over anything else. 'comments' holds the comment copilot's lessons. Before you "
                   "show an edit, run check_edit on it. When you resolve a comment, give it a lesson in "
                   "reply_comment: an existing rule id, 'new' with rule={area, text}, or 'one-off' (area 'post' "
                   "picks the platform from the commented file). Keep the set small: at most %d per area, so "
                   "sharpen a rule before you add one. A full area takes a new rule only with merge_into and "
                   "merged; the user approves the merge on the Feedback board." % AREA_MAX)
    return out


def t_set_rule(a):
    """Add, change, turn off or remove one rule."""
    d = read_lessons()
    if not a.get("id"):
        notes = {}
        r = new_rule(d, a.get("area"), a.get("text"), a.get("check"), ref=a.get("from"), details=a.get("details"),
                     merge_into=a.get("merge_into"), merged=a.get("merged"), notes=notes)
        write_lessons(d)
        return {"added": rule_view(r), **notes}
    r = next((x for x in d["rules"] if x["id"] == a["id"]), None)
    if r is None:
        raise ValueError("No rule %s. Use get_rules." % a["id"])
    need_writable(d, r["area"])
    if a.get("merge_into") or a.get("merged"):
        raise ValueError("merge_into and merged go only with a new rule (no id).")
    if r.get("by") == "you" and ("text" in a or "details" in a or "on" in a or a.get("remove")):
        raise ValueError("The user wrote or changed rule %s. Ask the user before you change it." % r["id"])
    if a.get("remove"):
        d["rules"].remove(r)
        write_lessons(d)
        return {"removed": r["id"]}
    was = (r.get("text"), r.get("check"))
    if "text" in a:
        text = " ".join((a["text"] or "").split())
        if not text or len(text) > RULE_MAX:
            raise ValueError("Rule text: one sentence, 1 to %d characters. Put the rest in details." % RULE_MAX)
        r["text"] = text
    if "details" in a:
        details = clean_details(a["details"])
        if details:
            r["details"] = details
        else:
            r.pop("details", None)
    if "check" in a:
        c = clean_check(a["check"], r["area"])
        if c:
            r["check"] = c
        else:
            r.pop("check", None)
    if "on" in a:
        r["on"] = bool(a["on"])
    # 2026-10-20 (factory evals step 4): a backtest is about the rule as it was tested: a new check, or new text on a
    # rule the judge tests, needs learn_from_change again. Until then the rule only advises.
    if r.get("backtest") and (r.get("check") != was[1] or (not r.get("check") and r.get("text") != was[0])):
        r.pop("backtest")
    r["changed"] = now_iso()
    write_lessons(d)
    return {"changed": rule_view(r)}


def apply_lesson(d, s, c, r, notes=None):
    """Puts the reply's lesson on comment c, and the comment on its rule. Returns the rule id or 'one-off'."""
    lesson = (r.get("lesson") or "").strip()
    ref = comment_ref(s, c["id"])
    if lesson == "one-off":
        c["lesson"] = "one-off"
        c.pop("repeat", None)
        return lesson
    if lesson == "new":
        rule = dict(r.get("rule") or {})
        if (rule.get("area") or "").strip().lower() == "post":
            rule["area"] = post_area(c.get("file"))
        made = new_rule(d, rule.get("area"), rule.get("text"), rule.get("check"), ref=ref,
                        details=rule.get("details"), merge_into=rule.get("merge_into"), merged=rule.get("merged"),
                        notes=notes)
        c["lesson"] = made["id"]
        c.pop("repeat", None)
        return made["id"]
    rule = next((x for x in d["rules"] if x["id"] == lesson), None)
    if rule is None:
        raise ValueError("Comment %s: lesson is a rule id from get_rules, 'new' with rule={area, text}, "
                         "or 'one-off' (not '%s')." % (c["id"], lesson))
    need_writable(d, rule["area"])
    # The rule was there before the user wrote the comment: the same mistake again, but only when the
    # edit broke what the rule says (missed). A new ask or taste near the rule ("add some logos" under
    # "show real logos") is no repeat: 11 of the first 50 repeats were those (2026-10-11).
    made, at = parse_iso(rule.get("made", "")), parse_iso((c.get("at") or "")[:19] + "Z")
    old = bool(made and at and made < at)
    if old and not isinstance(r.get("missed"), bool):
        raise ValueError("Comment %s came after rule %s: give missed=true when the edit broke what the rule says, "
                         "missed=false when the comment asks for something new or is taste near it." % (c["id"], rule["id"]))
    c["lesson"] = rule["id"]
    c.pop("request", None)
    if old and r["missed"]:
        c["repeat"] = True
        if ref not in rule.setdefault("repeats", []):
            rule["repeats"].append(ref)
        return rule["id"]
    c.pop("repeat", None)
    if old:
        c["request"] = True
    if ref in (rule.get("repeats") or []):
        rule["repeats"].remove(ref)
    if ref not in rule.setdefault("from", []):
        rule["from"].append(ref)
    return rule["id"]


# ---------- checks ----------

def measure(path, kind, c):
    """One measured value for a check kind, and where it fails (a list of seconds) for pauses."""
    ffmpeg = find_tool("ffmpeg")
    if kind == "length":
        return media_seconds(path), []
    if kind in ("loudness", "peak"):
        out = subprocess.run([ffmpeg, "-hide_banner", "-nostats", "-i", path, "-vn", "-af",
                              "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True).stderr
        summary = out.rsplit("Summary:", 1)[-1]
        key = r"I:\s*(-?[\d.]+|-inf)\s*LUFS" if kind == "loudness" else r"Peak:\s*(-?[\d.]+|-inf)\s*dBFS"
        m = re.search(key, summary)
        if not m:
            raise ValueError("No audio to measure.")
        return (float("-inf") if m.group(1) == "-inf" else float(m.group(1))), []
    if kind == "pauses":
        longest = c.get("max", 0.4)
        out = subprocess.run([ffmpeg, "-hide_banner", "-nostats", "-i", path, "-vn", "-af",
                              "silencedetect=noise=%sdB:d=%s" % (c.get("floor", -35), longest),
                              "-f", "null", "-"], capture_output=True, text=True).stderr
        starts = [float(x) for x in re.findall(r"silence_start:\s*(-?[\d.]+)", out)]
        ends = [(float(e), float(dur)) for e, dur in
                re.findall(r"silence_end:\s*(-?[\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)", out)]
        total = media_seconds(path)
        # A silence at the very start or end is the cover frame or a fade, not a pause.
        gaps = [(s, dur) for s, (e, dur) in zip(starts, ends) if s > 0.3 and e < total - 0.3]
        return (max([dur for _, dur in gaps] or [0.0])), [round(s, 2) for s, _ in gaps]
    raise ValueError("Unknown check %s." % kind)


def media_seconds(path):
    probe = find_tool("ffprobe")
    out = subprocess.run([probe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True).stdout.strip()
    try:
        return float(out)
    except ValueError:
        raise ValueError("Cannot read %s." % path)


def run_check(path, c):
    kind = c["kind"]
    value, at = measure(path, kind, c)
    if kind == "loudness":
        target, tol = c.get("target", -14.0), c.get("tolerance", 1.0)
        ok = abs(value - target) <= tol
        want = "%g ± %g LUFS" % (target, tol)
    elif kind == "peak":
        ok, want = value <= c.get("max", -1.0), "at most %g dBTP" % c.get("max", -1.0)
    elif kind == "pauses":
        ok, want = not at, "no pause over %g s" % c.get("max", 0.4)
    else:
        ok, want = value <= c.get("max", 0), "at most %g s" % c.get("max", 0)
    res = {"pass": ok, "value": round(value, 2) if value not in (float("inf"), float("-inf")) else str(value), "want": want}
    if at:
        res["at"] = at[:12]
    return res


# Built-in checks run on every edit, rule or no rule: each one is a problem the user heard or saw that
# the old checks passed (2026-10-10 audit: robotic voice, 8 kHz cut, echo, sound out of sync, green
# picture, a half sentence, a frozen clip, a chapter track that froze a card). Each compares the
# edit with the part of the take it came from, so a style choice is never a problem; only a change
# from the take is. Limits are wide on purpose: widen them here, never per user.
BUILTIN = {
    "streams":       {"max_gap": 0.1},
    "av_sync":       {"max": 0.04},
    "frozen_video":  {"max": 8.0, "share": 0.5},
    "band_balance":  {"max": 8.0, "highs": 12.0, "floor": 30.0, "cliff": 20.0},
    "echo":          {"more": 0.08, "ratio": 1.4, "repeat": 0.12, "clear": 4.0},
    "picture_drift": {"chroma": 3.0, "sat": 0.85, "blur": 1.3, "same": 0.5},
    "words":         {"edge": 0.08, "twice": 0.5},
    "regression":    {"margin": 0.05, "cut": 0.15, "cut_share": 0.6},
    # face height / height of the card the face sits in. Edits the user passed: median 0.30, 90% under
    # 0.48; the two he called too tight ("zoom out", "crop me better"): 0.52-0.54 (2026-10-11).
    "framing":       {"tight": 0.5, "min_face": 0.25, "min_card": 0.5, "frames": 2, "samples": 16},
}
CHECK_BUDGET = 60   # seconds for all built-ins in one call; what is not done by then skips
CHECK_TIMEOUT = 60  # seconds for one built-in
CHECKS_CACHE = ".checks-cache"  # <session>/.checks-cache/<file>.<mtime>.json: a dot folder, so no asset list shows it
ENV_RATE = 8000     # the envelope reads the sound at 8 kHz: enough for loudness every 10 ms
FRAME = 0.01        # one envelope value per 10 ms
CHUNK = 5.0         # align: the edit is found in the take 5 s at a time
NEAR = 10.0         # align: first look this far around where the last piece ended
MATCH = 0.75        # align: a piece matches at this correlation or more (heavy echo: 0.79; another take: 0.6)
BANDS = [125, 250, 500, 1000, 2000, 4000, 8000, 16000]
AUDIO_EXT = (".m4a", ".wav", ".mp3", ".aac", ".aif", ".aiff", ".flac", ".caf")
NO_SOURCE = "Takes does not know which take this edit came from. Pass source."
NOT_FOUND = "Takes could not find this edit in %s (heavy music, another take or another file)."
GIVEN_SHARE = 0.25  # a source argument still needs this share of the edit's sound found in it
OUT_OF_TIME = "Out of time. Run check_edit again; the second run is faster."
LABELS = {"streams": "Extra track", "frozen_video": "Frozen picture", "echo": "Echo", "words": "Missing words",
          "regression": "Fix undone", "framing": "Framed too tight"}


class Skip(Exception):
    """A check that cannot measure this edit: pass null, and the reason in skip."""


def mmss(sec):
    s = int(max(0.0, sec))
    return "%d:%02d" % (s // 60, s % 60)


def percentile(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    return xs[min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))]


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2.0


def probe_streams(path):
    """Every stream and chapter of a file, from one ffprobe."""
    probe = find_tool("ffprobe")
    if not probe:
        raise ValueError("ffprobe is not installed. Open Takes and click Finish setup, or run brew install ffmpeg.")
    r = subprocess.run([probe, "-v", "error", "-show_streams", "-show_chapters", "-show_format", "-of", "json", path],
                       capture_output=True, text=True, timeout=60)
    try:
        d = json.loads(r.stdout or "{}")
    except ValueError:
        d = {}
    streams = d.get("streams") or []
    v = next((x for x in streams if x.get("codec_type") == "video"
              and not (x.get("disposition") or {}).get("attached_pic")), None)
    a = next((x for x in streams if x.get("codec_type") == "audio"), None)

    def num(x, k):
        try:
            return float((x or {}).get(k))
        except (TypeError, ValueError):
            return None
    dur = num(d.get("format"), "duration")
    return {"streams": streams, "chapters": d.get("chapters") or [], "video": v, "audio": a, "duration": dur,
            "fps": frac((v or {}).get("avg_frame_rate")) or frac((v or {}).get("r_frame_rate")) or 30.0,
            "rate": int(num(a, "sample_rate") or 0),
            "hdr": (v or {}).get("color_transfer") in ("arib-std-b67", "smpte2084"),
            "v_start": num(v, "start_time") or 0.0, "a_start": num(a, "start_time") or 0.0,
            "v_dur": num(v, "duration"), "a_dur": num(a, "duration")}


def made_pieces(s, doc):
    """cut_take's made_from of a words doc as pieces [{"take": (n, kind), "edit": [a, b], "src": [c, d]}];
    a piece that does not read is left out, and so is another session's cut."""
    made = (doc or {}).get("made_from") if isinstance((doc or {}).get("made_from"), dict) else None
    if not made or made.get("session_id") not in (None, session_id(s)):
        return [], None
    out = []
    for g in made.get("cut") or []:
        try:
            a, c, d = float(g["at"]), float(g["in"]), float(g["out"])
            k = (int(g["take"]), g.get("kind") or "camera")
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        if d > c:
            out.append({"take": k, "edit": [a, a + d - c], "src": [c, d]})
    return out, made.get("grade") or made.get("lut")


def work_pieces(s, rel, path):
    """The made_from pieces of the cut_take cut an edit was rendered from: the edit's sound is found in
    the newest _work cuts (same name first, at most 3), and each part found takes its cut's pieces."""
    if rel.startswith(WORK_DIR + os.sep):
        return [], None
    base = split_version(os.path.basename(rel))[0]
    found = []
    for wj in glob.glob(os.path.join(glob.escape(os.path.join(s, WORK_DIR)), "*-v*.words.json")):
        mp4 = wj[:-len(".words.json")] + ".mp4"
        if os.path.isfile(mp4):
            found.append((split_version(os.path.basename(mp4))[0] != base, -os.path.getmtime(wj), wj, mp4))
    for _, _, wj, mp4 in sorted(found)[:3]:
        pieces, grade = made_pieces(s, words_doc(mp4))
        if not pieces:
            continue
        try:
            al = align(envelope(s, path), envelope(s, mp4))
        except (ValueError, OSError, subprocess.SubprocessError):
            continue
        if al["coverage"] < 0.5:
            continue
        out = []
        for g in al["segments"]:  # edit -> cut -> take
            a, b = g["edit"]
            c = g["src"][0]
            for x in pieces:
                lo, hi = max(c, x["edit"][0]), min(c + b - a, x["edit"][1])
                if hi - lo >= 0.3:
                    off = x["src"][0] - x["edit"][0]
                    out.append(dict({"take": x["take"], "edit": [round(a + lo - c, 2), round(a + hi - c, 2)],
                                     "src": [round(lo + off, 2), round(hi + off, 2)]},
                                    **({"rough": True} if g.get("rough") else {})))
        if out:
            return out, grade
    return [], None


def edit_source(s, rel, given=None):
    """The take an edit was cut from: {path, known, segments, grade, offset}. The one reader of an edit's
    provenance. Order: the source argument (align must still find the edit in it), the made_from of the
    edit's own words file (cut_take writes it), the made_from of the _work cut the edit was rendered from,
    else a guess (keeper camera take, else the newest camera take) that align must confirm (known False);
    then the other takes are candidates too, newest first. segments: [{"edit": [a, b], "src": [c, d]}] in
    seconds, both on the video clock, of the take with the most time in the edit (parts from other takes
    are not in segments)."""
    takes = read_meta(s).get("takes", [])
    out = {"path": None, "known": False, "given": False, "segments": None, "grade": None, "offset": 0.0,
           "candidates": []}
    path = os.path.join(s, rel)
    if given:
        p = os.path.normpath(given if os.path.isabs(given) else os.path.join(s, given))
        if not os.path.isfile(p) or os.path.relpath(p, s).startswith("..") or p == path:
            raise ValueError("No take %s in this session. Pass a take file from get_session, e.g. "
                             "'take-03-camera.mov'." % given)
        out.update(path=p, known=True, given=True)
    else:
        pieces, grade = made_pieces(s, words_doc(path))
        if not pieces:
            pieces, grade = work_pieces(s, rel, path)
        by = {}
        for g in pieces:
            by[g["take"]] = by.get(g["take"], 0.0) + g["edit"][1] - g["edit"][0]
        if by:
            n, kind = max(by, key=by.get)
            try:
                t = voice_take(s, n, kind)
            except ValueError:
                t = None
            if t and os.path.isfile(os.path.join(s, t["file"])):
                out.update(path=os.path.join(s, t["file"]), known=True, grade=grade,
                           segments=[{k: v for k, v in g.items() if k != "take"} for g in pieces
                                     if g["take"] == (n, kind)])
        if not out["path"]:
            cams = sorted((t for t in takes if t.get("kind") == "camera"), key=lambda t: t["number"]) \
                or sorted(takes, key=lambda t: t["number"])
            pick = next((t for t in cams if t.get("keeper")), cams[-1] if cams else None)
            if pick and not os.path.isfile(os.path.join(s, pick["file"])):
                out["missing"] = pick["file"]
            elif pick:
                out["path"] = os.path.join(s, pick["file"])
                rest = sorted((t for t in takes if t is not pick), key=lambda t: (t.get("kind") != "camera", -t["number"]))
                out["candidates"] = [p for p in (os.path.join(s, t["file"]) for t in rest) if os.path.isfile(p)][:3]
    if out["path"]:
        try:
            out["offset"] = float((take_clock(out["path"]) or {}).get("audio_offset_s") or 0.0)
        except ValueError:
            pass
    return out


def envelope(s, path):
    """Loudness every 10 ms (dBFS) of a file's sound on the video clock, cached per file and mtime."""
    import array
    st = os.stat(path)
    rel = os.path.relpath(path, s)
    name = (rel if not rel.startswith("..") else hashlib.sha1(path.encode()).hexdigest()[:10] + "-" +
            os.path.basename(path)).replace(os.sep, "__")
    d = os.path.join(s, CHECKS_CACHE)
    p = os.path.join(d, "%s.%d-%d.json" % (name, int(st.st_mtime), st.st_size))
    try:
        with open(p) as f:
            env = json.load(f)
        if isinstance(env, list) and all(isinstance(x, (int, float)) for x in env):
            return env
    except (OSError, ValueError):
        pass
    r = subprocess.run([need_ffmpeg(), "-v", "error", "-i", path, "-vn", "-af", VIDEO_CLOCK, "-ac", "1",
                        "-ar", str(ENV_RATE), "-f", "s16le", "-"], capture_output=True, timeout=600)
    raw = r.stdout[:len(r.stdout) // 2 * 2]
    a = array.array("h")
    a.frombytes(raw)
    if sys.byteorder == "big":
        a.byteswap()
    n = int(ENV_RATE * FRAME)
    full = float(n) * 32768.0 * 32768.0
    env = [round(10 * math.log10(sum(x * x for x in a[i:i + n]) / full + 1e-10), 1) for i in range(0, len(a) - n + 1, n)]
    try:
        os.makedirs(d, exist_ok=True)
        for old in glob.glob(os.path.join(glob.escape(d), glob.escape(name) + ".*.json")):
            os.remove(old)
        with open(p + ".tmp", "w") as f:
            json.dump(env, f, separators=(",", ":"))
        os.replace(p + ".tmp", p)
    except OSError:
        pass  # a read-only session still gets its checks, only slower
    return env


def _ncc_search(chunk, src, lo, hi, step=1):
    """(best position, correlation) of chunk in src[lo:hi] (positions every step)."""
    import operator
    n = len(chunk)
    m = sum(chunk) / n
    c = [x - m for x in chunk]
    cn = math.sqrt(sum(x * x for x in c))
    if cn < 1e-6:
        return None, 0.0
    lo, hi = max(0, lo), min(len(src) - n, hi)
    if hi < lo:
        return None, 0.0
    best, at = -2.0, None
    s1 = [0.0]
    s2 = [0.0]
    for x in src[lo:hi + n]:
        s1.append(s1[-1] + x)
        s2.append(s2[-1] + x * x)
    mul = operator.mul
    for p in range(lo, hi + 1, step):
        k = p - lo
        a, b = s1[k + n] - s1[k], s2[k + n] - s2[k]
        var = b - a * a / n
        if var <= 1e-6:
            continue
        r = sum(map(mul, c, src[p:p + n])) / (cn * math.sqrt(var))
        if r > best:
            best, at = r, p
    return at, best


def _coarse(env, k=5):
    return [sum(env[i:i + k]) / k for i in range(0, len(env) - k + 1, k)]


def align(edit_env, src_env):
    """Which part of the take each part of the edit came from: the step every check that compares with the
    take shares. Pure Python. The edit is found 5 s at a time (then 2 s where 5 s found nothing) by
    correlation of the loudness: coarse every 50 ms, then every 10 ms. It looks near the pieces found
    before first; a search of the whole take runs only on a miss. Pieces with the same offset merge into a
    segment; its edges move to where the sound stops matching. Returns {"segments": [{"edit": [a, b],
    "src": [c, d], "rough"?}], "coverage": share of the edit's sound}."""
    # Pauses flat at 25 dB under the loud parts: room sound, echo and noise in them do not count. Music
    # under the edit's voice lifts its pauses: then both are cut flat just over the music.
    if not edit_env or not src_env:
        return {"segments": [], "coverage": 0.0}
    depth = max(8.0, min(25.0, percentile(edit_env, 0.95) - percentile(edit_env, 0.10) - 6))
    fe, fs = (percentile(x, 0.95) - depth for x in (edit_env, src_env))
    e = [max(x, fe) - fe for x in edit_env]
    sv = [max(x, fs) - fs for x in src_env]
    n, step = len(e), int(CHUNK / FRAME)
    if n < 100 or len(sv) < 100:
        return {"segments": [], "coverage": 0.0}
    ec, sc = _coarse(e), _coarse(sv)
    # A long edit cut from a long take jumps around: one whole-take search per 15 s of edit, at least 4.
    budget = {"full": max(4, int(n * FRAME / 15))}
    hits = []

    def scan(size, thr, spans):
        """Finds chunks of size frames (half overlapping) of the edit spans in the take, at correlation
        thr or more; near the pieces found before first, then in the whole take."""
        last = None
        for lo, hi in spans:
            for a in range(lo, max(lo + 1, hi - size // 2), size // 2):
                L = min(size, n - a)
                if L < size * 0.6:
                    break
                chunk = e[a:a + L]
                if max(chunk) - min(chunk) < 6:  # a pause or a held tone: matches anything
                    continue
                cc = ec[a // 5:(a + L) // 5]
                p, r = (None, 0.0)
                near = [last] if last is not None else []
                near += [off for x, y, off in hits if x - 3 * size <= a <= y + 3 * size]
                for o in dict.fromkeys(near):  # near the pieces before and after first
                    guess = (a + o) // 5
                    p2, r2 = _ncc_search(cc, sc, guess - int(NEAR / 0.05), guess + int(NEAR / 0.05))
                    if r2 > r:
                        p, r = p2, r2
                if r < thr and budget["full"] > 0:
                    budget["full"] -= 1
                    p2, r2 = _ncc_search(cc, sc, 0, len(sc))
                    if r2 > r:
                        p, r = p2, r2
                if p is None or r < thr:
                    continue
                # The 50 ms match decides; 10 ms only places it (echo blurs single frames).
                p, r = _ncc_search(chunk, sv, p * 5 - 8, p * 5 + 8)
                if p is None or r < thr - 0.15:
                    continue
                hits.append((a, a + L, p - a))
                last = p - a
    scan(step, MATCH, [(0, n)])
    # A cut every few seconds (ums and pauses out) leaves no 5 s piece whole: 2 s pieces where 5 s found
    # nothing, with a higher bar (a short piece of another take can match too).
    hits.sort()
    free, at = [], 0
    for x, y, _ in hits + [(n, n, 0)]:
        if x - at >= 200:
            free.append((at, x))
        at = max(at, y)
    budget["full"] += max(4, int(n * FRAME / 10))
    scan(int(2.0 / FRAME), MATCH + 0.1, free)
    hits.sort()
    segs = []
    for a, b, off in hits:
        if segs and abs(segs[-1][2] - off) <= 2 and a <= segs[-1][1]:
            segs[-1][1] = max(segs[-1][1], b)
        else:
            segs.append([a, b, off])
    out = []
    es, ss = _smooth(e), _smooth(sv)
    for a, b, off in segs:
        lo, hi, good = _edges(es, ss, a, b, off)
        if hi - lo < b - a - 200:
            # The sound changed too much to find the cut (heavy echo or noise): keep the matched pieces
            # less 0.5 s at each end, and mark the edges rough (words does not judge them).
            lo, hi, rough = a + 50, b - 50, True
        else:
            rough = False
        if hi - lo >= 50:
            out.append([lo, hi, off, rough, good])
    out.sort(key=lambda x: x[0])
    for i in range(len(out) - 1):
        lo, hi = out[i + 1][0], out[i][1]
        if hi > lo:
            # Both reach into one stretch (a pause matches both): the cut goes where the fewest frames
            # disagree, in the middle of the best places.
            g1, g2 = out[i][4], out[i + 1][4]
            cost = [sum(not g1(k) for k in range(lo, x)) + sum(not g2(k) for k in range(x, hi)) for x in range(lo, hi + 1)]
            best = [lo + k for k, c in enumerate(cost) if c == min(cost)]
            cut = best[len(best) // 2]
            out[i][1], out[i + 1][0] = cut, cut
    loud = [i for i in range(n) if e[i] > 1]
    covered = sum(1 for i in loud if any(x[0] <= i < x[1] for x in out))
    segments = [dict({"edit": [round(a * FRAME, 2), round(b * FRAME, 2)],
                      "src": [round((a + off) * FRAME, 2), round((b + off) * FRAME, 2)]}, **({"rough": True} if rough else {}))
                for a, b, off, rough, _ in out if b > a]
    return {"segments": segments, "coverage": round(covered / float(len(loud)), 3) if loud else 0.0}


def _smooth(x):
    return [(x[max(0, i - 1)] + x[i] + x[min(len(x) - 1, i + 1)]) / 3.0 for i in range(len(x))]


def _edges(e, sv, a, b, off):
    """Grows (and trims) a matched piece to where the edit's sound stops following the take: (lo, hi,
    good), good(i) says whether edit frame i follows the take at this offset. Levels
    above the pause floor (0); a filter or a gain change moves the whole piece, so that shift is taken off.
    e and sv come smoothed over 30 ms: a filter changes how fast a word starts."""
    core = [i for i in range(a, b) if 0 <= i + off < len(sv)]
    gain = median([e[i] - sv[i + off] for i in core if e[i] > 3 and sv[i + off] > 3]) or 0.0
    # Echo or noise in the edit moves single frames: the limit grows with how far the matched core moves.
    tol = max(4.0, (percentile([abs(e[i] - sv[i + off] - gain) for i in core], 0.7) or 0.0) + 2.0)

    def good(i):
        j = i + off
        if i < 0 or i >= len(e) or j < 0 or j >= len(sv):
            return False
        return (e[i] < 1 and sv[j] < 1) or abs(e[i] - sv[j] - gain) < tol
    w = 15

    def ok(i):  # most of the 150 ms from i on follow the take
        return sum(good(k) for k in range(i, i + w)) >= w * 0.6
    mid = (a + b) // 2
    lo = mid
    while lo > 0 and ok(lo - w):
        lo -= 1
    while lo < mid and not good(lo):
        lo += 1
    hi = mid
    while hi < len(e) and ok(hi):
        hi += 1
    hi = min(len(e), hi + w - 1)
    while hi > lo and not good(hi - 1):
        hi -= 1
    return lo, hi, good


# For a grab that runs beside others in a thread pool: one decoder thread. By default ffmpeg starts one
# per core and decodes frames ahead it never uses; one thread used 40-50% less CPU (2026-10-22).
ONE_THREAD = ["-threads", "1", "-filter_threads", "1", "-filter_complex_threads", "1"]


def grey_frames(path, start, dur, rate, size=(32, 18), one_thread=False):
    """Small grey frames of path from start for dur seconds at rate per second: a list of byte strings.
    one_thread: ONE_THREAD, for a call that runs in a thread pool."""
    w, h = size
    r = subprocess.run([need_ffmpeg(), "-v", "error"] + (ONE_THREAD if one_thread else [])
                       + ["-ss", "%.3f" % max(0.0, start), "-i", path, "-t", "%.3f" % dur, "-an",
                          "-vf", "fps=%g,scale=%d:%d,format=gray" % (rate, w, h), "-f", "rawvideo", "-"],
                       capture_output=True, timeout=120)
    raw = r.stdout
    return [raw[i:i + w * h] for i in range(0, len(raw) - w * h + 1, w * h)]


def _mad(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / float(max(1, len(a)))


def ssim(a, b):
    """Global SSIM of two grey frames of the same size (bytes)."""
    n = float(len(a))
    if not n or len(a) != len(b):
        return 0.0
    ma, mb = sum(a) / n, sum(b) / n
    va = sum((x - ma) ** 2 for x in a) / n
    vb = sum((x - mb) ** 2 for x in b) / n
    cov = sum((x - ma) * (y - mb) for x, y in zip(a, b)) / n
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    return ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))


def frame_stats(path, t, hdr=False, crop=None, size=None):
    """(U, V, saturation, blur, grey 64x36 bytes) of the frame at t, at 720 px high (size: (w, h) instead).
    crop: (x, y, w, h) in pixels of the shown frame, cut out first. An HDR file is tone-mapped to bt709
    first, as a viewer's SDR screen shows it."""
    tmp = tempfile.mkdtemp(prefix="takes-frame-")
    meta = os.path.join(tmp, "m.txt")
    tone = ("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,"
            "zscale=t=bt709:m=bt709:r=tv," if hdr else "")
    blur = "blurdetect," if has_filter("blurdetect") else ""  # an older ffmpeg: no blur, the rest still runs
    cut = "crop=%d:%d:%d:%d," % (crop[2], crop[3], crop[0], crop[1]) if crop else ""
    scale = "scale=%d:%d:flags=area" % size if size else "scale=-2:720"
    graph = ("[0:v]%s%s%s,format=yuv420p,split[a][b];[a]signalstats,%smetadata=print:file=%s[m];"
             "[b]scale=64:36,format=gray[g]" % (tone, cut, scale, blur, meta.replace("\\", "/").replace(":", "\\:")))
    try:
        # ONE_THREAD: chk_picture_drift runs four of these at once.
        r = subprocess.run([need_ffmpeg(), "-v", "error"] + ONE_THREAD + ["-ss", "%.3f" % max(0.0, t), "-i", path,
                            "-frames:v", "1", "-filter_complex", graph, "-map", "[m]", "-f", "null", os.devnull,
                            "-map", "[g]", "-frames:v", "1", "-f", "rawvideo", "-"], capture_output=True, timeout=60)
        text = read_text(meta) if os.path.exists(meta) else ""
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if r.returncode != 0:
        raise ValueError("ffmpeg: " + ((r.stderr or b"").decode(errors="replace").strip().splitlines() or ["failed"])[-1])
    val = {k: float(v) for k, v in re.findall(r"lavfi\.(signalstats\.\w+|blur)=(-?[\d.]+)", text)}
    if "signalstats.UAVG" not in val:
        raise ValueError("No picture at %.2f s." % t)
    return (val["signalstats.UAVG"], val["signalstats.VAVG"], val.get("signalstats.SATAVG", 0.0),
            val.get("blur"), r.stdout[:64 * 36])


FILTERS = {}


def has_filter(name):
    if name not in FILTERS:
        r = subprocess.run([need_ffmpeg(), "-hide_banner", "-filters"], capture_output=True, text=True, timeout=30)
        FILTERS[name] = bool(re.search(r"\s%s\s" % re.escape(name), r.stdout or ""))
    return FILTERS[name]


def band_levels(path, ranges, gate=None):
    """Per octave band (125 Hz to 16 kHz), the median level of the speech frames (100 ms frames within
    12 dB of the loudest) minus the 1 kHz band, over ranges [[a, b]] of the file (video clock). One ffmpeg."""
    ranges = [[a, b] for a, b in ranges if b - a >= 0.3][:60]
    if not ranges:
        raise Skip("Too little sound to measure.")
    sel = "+".join("between(t,%.3f,%.3f)" % (a, b) for a, b in ranges)
    tmp = tempfile.mkdtemp(prefix="takes-bands-")
    stats = ("asetnsamples=n=4800:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level,"
             "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=%s")
    parts = ["[0:a]%s,aselect='%s',asetpts=N/SR/TB,aformat=channel_layouts=mono,aresample=48000,asplit=%d%s"
             % (VIDEO_CLOCK, sel, len(BANDS) + 1, "".join("[i%d]" % i for i in range(len(BANDS) + 1)))]
    for i, c in enumerate(BANDS):
        lo, hi = c / math.sqrt(2), min(c * math.sqrt(2), 23500)
        steep = ",".join(["highpass=f=%d:poles=2" % lo] * 3 + ["lowpass=f=%d:poles=2" % hi] * 3)
        parts.append("[i%d]%s,%s,anullsink" % (i, steep, stats % os.path.join(tmp, "b%d.txt" % i)))
    parts.append("[i%d]%s[o]" % (len(BANDS), stats % os.path.join(tmp, "full.txt")))
    try:
        r = subprocess.run([need_ffmpeg(), "-v", "error", "-i", path, "-filter_complex", ";".join(parts),
                            "-map", "[o]", "-f", "null", "-"], capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            raise ValueError("ffmpeg: " + ((r.stderr or "").strip().splitlines() or ["failed"])[-1])

        def read(name):
            try:
                text = read_text(os.path.join(tmp, name))
            except OSError:
                return []
            return [float(x) if x not in ("-inf", "inf", "nan") else -120.0
                    for x in re.findall(r"RMS_level=(-?inf|nan|-?[\d.]+)", text)]
        full = read("full.txt")
        bands = [read("b%d.txt" % i) for i in range(len(BANDS))]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if len(full) < 10:
        raise Skip("Too little sound to measure.")
    top = percentile(full, 0.95)
    speech = [i for i, x in enumerate(full) if x >= top - 12]
    lv = {c: median([b[i] for i in speech if i < len(b)]) for c, b in zip(BANDS, bands)}
    ref = lv.get(1000)
    if ref is None:
        raise Skip("Too little sound to measure.")
    return {c: round(v - ref, 1) for c, v in lv.items() if v is not None}


def voice_tails(edit, take):
    """(edit, take): median seconds the voice takes to die away after a word ends, from the last loud
    10 ms to 30 dB under the loudest (or 4 dB over the room's floor). The word ends come from the take, and
    the edit is read at the same moments, so echo that only lengthens a word still counts. edit and take
    are lists of envelope pieces, frame for frame the same sound (align)."""
    def levels(pieces):
        allv = [x for p in pieces for x in p]
        if len(allv) < 200:
            raise Skip("Too little sound to measure the room.")
        top, floor = percentile(allv, 0.95), percentile(allv, 0.10)
        if top - floor < 25:
            raise Skip("Music or noise under the voice. Takes cannot measure the room.")
        return top - 12, max(top - 30, floor + 4)

    def tail(env, ps, i, lo):
        """Frames until env is down at lo; the take's next word ends the count (the echo runs into it)."""
        j = i
        while j < min(len(env), len(ps)) and env[j] > lo and ps[j] < hs and j - i < 80:
            j += 1
        return (j - i + 1) * FRAME if j < min(len(env), len(ps)) and j - i < 80 else None
    hs, ls = levels(take)
    _, le = levels(edit)
    te, ts = [], []
    for pe, ps in zip(edit, take):
        for i in range(1, min(len(pe), len(ps)) - 6):
            if ps[i - 1] >= hs > max(ps[i:i + 6]):  # a word ends, then 60 ms or more without a word
                a, b = tail(pe, ps, i, le), tail(ps, ps, i, ls)
                if a is not None and b is not None:
                    te.append(a)
                    ts.append(b)
    if len(ts) < 5:
        raise Skip("Too few pauses in the voice to measure the room.")
    return median(te), median(ts)


# Words: numbers and short forms said the same way on both sides ("10" = "ten", "it's" = "it is").
ONES = ("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
        "seventeen eighteen nineteen").split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
SHORT = {"can't": ["can", "not"], "won't": ["will", "not"], "let's": ["let", "us"], "n't": ["not"],
         "'re": ["are"], "'ll": ["will"], "'ve": ["have"], "'m": ["am"], "'d": ["would"], "'s": ["is"]}


def number_words(n):
    if n < 20:
        return [ONES[n]]
    if n < 100:
        return [TENS[n // 10]] + ([ONES[n % 10]] if n % 10 else [])
    if n < 1000:
        return [ONES[n // 100], "hundred"] + (number_words(n % 100) if n % 100 else [])
    if n < 10 ** 6:
        return number_words(n // 1000) + ["thousand"] + (number_words(n % 1000) if n % 1000 else [])
    return [str(n)]


def spoken(word):
    """The tokens a word says: 'It's' -> ['it', 'is'], '10' -> ['ten'], '2,000' -> ['two', 'thousand']."""
    w = norm_word(word.replace("’", "'").replace(",", ""))
    if not w:
        return []
    if w.isdigit():
        return number_words(int(w))
    for k in ("can't", "won't", "let's"):
        if w == k:
            return list(SHORT[k])
    for k in ("n't", "'re", "'ll", "'ve", "'m", "'d", "'s"):
        if w.endswith(k) and len(w) > len(k):
            return [w[:-len(k)]] + SHORT[k]
    return [w.replace("'", "")]


def sentence_ends(s, words):
    """For each take word: does a sentence end with it? From the script (script.md or a variant) mapped on
    the take's words; a word the script does not cover ends a sentence at a pause of 0.35 s or more."""
    from difflib import SequenceMatcher
    toks, last = [], {}
    for i, (_, _, w) in enumerate(words):
        for t in spoken(w):
            toks.append(t)
            last[i] = len(toks) - 1
    texts = [read_text(os.path.join(s, "script.md"))] if os.path.exists(os.path.join(s, "script.md")) else []
    texts += [read_text(p) for p in sorted(glob.glob(os.path.join(glob.escape(s), "variants", "*.md")))]
    best, mapped = 0, {}
    for text in texts:
        stoks, ends = [], set()
        for piece in re.split(r"(?<=[.!?])\s+|\n+", script_plain(text or "")):
            tk = [t for w in piece.split() for t in spoken(w)]
            if tk:
                stoks += tk
                ends.add(len(stoks) - 1)
        sm = SequenceMatcher(None, toks, stoks, autojunk=False)
        m = {}
        for b in sm.get_matching_blocks():
            for k in range(b.size):
                m[b.a + k] = (b.b + k) in ends
        if len(m) > best:
            best, mapped = len(m), m
    use = toks and best >= 0.3 * len(toks)
    out = []
    for i, (st, en, _) in enumerate(words):
        if i == len(words) - 1:
            out.append(True)
        elif use and last.get(i) in mapped:
            out.append(mapped[last[i]])
        else:
            out.append(words[i + 1][0] - en >= 0.35)
    return out


def need_source(ctx):
    if not ctx["known"] or not ctx["segments"]:
        raise Skip(ctx["why"])


def chk_streams(ctx):
    p, lim = ctx["probe"], BUILTIN["streams"]
    extra = [x for x in p["streams"] if x.get("codec_type") in ("data", "subtitle", "attachment")]
    want = "no data, subtitle or chapter track; sound and picture within %g s of the same length" % lim["max_gap"]
    if extra or p["chapters"]:
        return (len(extra) + len(p["chapters"]), [], "The file has an extra track that can freeze the video.",
                {"want": want, "fix": "%d data/subtitle tracks and %d chapters. Copy it to the next version "
                 "(next_path) without them: ffmpeg -i <file> -map 0:v:0? -map 0:a:0? -c copy -map_chapters -1 "
                 "-dn -sn <new file>." % (len(extra), len(p["chapters"]))})
    if p["video"] and p["audio"] and p["v_dur"] and p["a_dur"]:
        gap = round(p["a_dur"] - p["v_dur"], 2)
        if abs(gap) > lim["max_gap"]:
            return (gap, [], "The sound stops before the picture ends." if gap < 0 else
                    "The sound goes on after the picture ends.",
                    {"want": want, "label": "Sound length",
                     "fix": "Sound is %.2f s %s than the picture. Pad or trim the sound to the picture's length "
                            "(apad + -shortest, or atrim) in the next version." % (abs(gap), "shorter" if gap < 0 else "longer")})
        return (gap, [], None, {"want": want})
    return (0, [], None, {"want": want})


def picture_offset(ctx):
    """Seconds the sound is late against the picture, from the take: where the edit's picture is in the
    take, against where its sound is (align). Raises Skip when the picture does not show it clearly."""
    segs = sorted(ctx["segments"], key=lambda g: g["edit"][1] - g["edit"][0])
    g = segs[-1]
    if g["edit"][1] - g["edit"][0] < 3.0:
        raise Skip("No part of the edit is long enough to check the sync.")
    off = g["src"][0] - g["edit"][0]
    rate = float(min(30, round(ctx["src_probe"]["fps"] or 30)))
    width = 2.0
    mid = (g["edit"][0] + g["edit"][1]) / 2.0
    xe = round((mid - width / 2) * rate) / rate
    xs = round((xe + off - 1.0) * rate) / rate
    if xs < 0:
        xs = 0.0
    E = grey_frames(ctx["path"], xe, width, rate)
    S = grey_frames(ctx["src"]["path"], xs, width + 2.0, rate)
    if len(E) < rate * width * 0.8 or len(S) < len(E) + rate:
        raise Skip("Takes could not read the picture to check the sync.")
    if sum(_mad(E[i], E[i + 1]) for i in range(len(E) - 1)) / (len(E) - 1) < 0.5:
        raise Skip("The picture does not move. Takes cannot check the sync.")
    scores = [sum(_mad(E[i], S[k + i]) for i in range(len(E))) / len(E) for k in range(len(S) - len(E) + 1)]
    k = min(range(len(scores)), key=scores.__getitem__)
    if scores[k] > 0.7 * median(scores):
        raise Skip("The picture does not show a clear match in the take. Takes cannot check the sync.")
    d = 0.0
    if 0 < k < len(scores) - 1:
        den = scores[k - 1] - 2 * scores[k] + scores[k + 1]
        d = 0.5 * (scores[k - 1] - scores[k + 1]) / den if den > 1e-9 else 0.0
    return round((xs + (k + d) / rate - xe) - off, 3)


def secs(x):
    """0.2 -> '0.2', 0.05 -> '0.05': what the user reads."""
    return ("%.1f" % abs(x)) if abs(x) >= 0.095 else ("%.2f" % abs(x)).rstrip("0").rstrip(".")


def chk_av_sync(ctx):
    p, lim = ctx["probe"], BUILTIN["av_sync"]
    if not p["audio"]:
        raise Skip("The edit has no sound.")
    late = round(p["a_start"] - p["v_start"], 3)
    how = "file start times"
    if ctx["known"] and ctx["segments"] and ctx["src_probe"] and ctx["src_probe"]["video"]:
        # What a viewer sees wins over the container's start times (a copy of a take keeps its own).
        try:
            late, how = picture_offset(ctx), "picture against the take"
        except Skip:
            pass
    want = "sound within %g s of the picture" % lim["max"]
    if abs(late) <= lim["max"]:
        return (late, [], None, {"want": want})
    word = "late" if late > 0 else "early"
    return (late, [], "The sound is %s by %s s." % (word, secs(late)),
            {"want": want, "label": "Sound " + word,
             "fix": "Sound is %.2f s %s (%s). Render the next version with the voice on the video clock "
                    "(aresample=async=1:first_pts=0, or cut_take) and both streams starting at 0. The take's own "
                    "audio offset is %.2f s." % (abs(late), word, how, ctx["src"]["offset"] if ctx["src"] else 0.0)})


def chk_frozen_video(ctx):
    p, lim = ctx["probe"], BUILTIN["frozen_video"]
    # Software decode: on an M-series Mac it ran 5x faster than -hwaccel videotoolbox here (2026-10-11,
    # 84 s of 1080p: 1.2 s against 5.9 s), as it uses every core.
    r = subprocess.run([need_ffmpeg(), "-v", "info", "-hide_banner", "-nostats", "-i", ctx["path"], "-an", "-vf",
                        "fps=5,scale=320:-2,freezedetect=n=-60dB:d=2", "-f", "null", "-"],
                       capture_output=True, text=True, timeout=300)
    starts = [float(x) for x in re.findall(r"freeze_start:\s*(-?[\d.]+)", r.stderr or "")]
    ends = [float(x) for x in re.findall(r"freeze_end:\s*(-?[\d.]+)", r.stderr or "")]
    total = p["duration"] or media_seconds(ctx["path"])
    freezes = []
    for i, a in enumerate(starts):  # a keyframe can split one still into two: join them
        b = ends[i] if i < len(ends) else total
        if freezes and a - freezes[-1][1] < 0.5:
            freezes[-1] = (freezes[-1][0], b)
        else:
            freezes.append((a, b))
    segs = ctx["segments"] if ctx["known"] else []
    bad = []
    for a, b in freezes:
        laps = [(max(a, g["edit"][0]), min(b, g["edit"][1]), g) for g in segs or []]
        laps = [(x, y, g) for x, y, g in laps if y - x > 0]
        loose = (b - a) - sum(y - x for x, y, _ in laps)
        if loose > lim["max"] or loose > lim["share"] * total:
            bad.append((a, b))
            continue
        for x, y, g in laps:
            if y - x < 2.0:
                continue
            off = g["src"][0] - g["edit"][0]
            f1 = grey_frames(ctx["src"]["path"], x + off + 0.1, 0.2, 5, (64, 36))[:1]
            f2 = grey_frames(ctx["src"]["path"], y + off - 0.3, 0.2, 5, (64, 36))[:1]
            if f1 and f2 and _mad(f1[0], f2[0]) > 3:  # the take moves here; the edit does not
                bad.append((x, y))
                break
    want = "no still picture over %g s where the take moves" % lim["max"]
    if not bad:
        return (round(max([b - a for a, b in freezes] or [0.0]), 2), [], None, {"want": want})
    a, b = max(bad, key=lambda x: x[1] - x[0])
    return (round(b - a, 2), [x for x, _ in bad], "The picture stops from %s to %s." % (mmss(a), mmss(b)),
            {"want": want, "fix": "The picture holds still for %.1f s from %.2f s. Check the cut or the render "
                                  "there: a held frame, a still image or a stream that ends early." % (b - a, a)})


def chk_band_balance(ctx):
    p, lim = ctx["probe"], BUILTIN["band_balance"]
    if not p["audio"]:
        raise Skip("The edit has no sound.")
    want = "within %g dB of the take at 125 Hz to 4 kHz" % lim["max"]
    known = ctx["known"] and ctx["segments"]
    ranges = [g["edit"] for g in ctx["segments"]] if known else [[0.0, p["duration"] or media_seconds(ctx["path"])]]
    ranges, used = [list(r) for r in ranges], 0.0
    for r in ranges:  # at most 600 s of sound
        r[1] = min(r[1], r[0] + max(0.0, 600 - used))
        used += r[1] - r[0]
    le = band_levels(ctx["path"], ranges)
    floor = None
    if p["rate"] >= 44100 and le.get(16000) is not None and le[16000] < -lim["floor"] \
            and le[16000] < le.get(8000, 0.0) - lim["cliff"]:
        floor = le[16000]
    dull = ("The voice sounds dull. It lost its high tones.",
            "Keep the sound at 48 kHz from take to export (no 16 or 22 kHz step) and do not low-pass the voice. "
            "Use the take's clean voice once.")
    if not known:
        if floor is not None:
            return (floor, [], dull[0], {"want": want, "label": "Dull voice",
                                         "fix": "16 kHz band is %d dB under 1 kHz and falls off a cliff after 8 kHz. %s"
                                                % (-floor, dull[1])})
        raise Skip(ctx["why"])
    ls = band_levels(ctx["src"]["path"], [g["src"] for g in ctx["segments"] if g["edit"][0] < 600])
    diffs = {c: round(le[c] - ls[c], 1) for c in BANDS if c != 1000 and c in le and c in ls and ls[c] > -60}
    bad = [(c, d) for c, d in diffs.items() if (c <= 4000 and abs(d) > lim["max"]) or (c >= 8000 and d < -lim["highs"])]
    if not bad and floor is None:
        return (max(diffs.values(), key=abs) if diffs else 0.0, [], None, {"want": want})
    if not bad:
        return (floor, [], dull[0], {"want": want, "label": "Dull voice",
                                     "fix": "16 kHz band is %d dB under 1 kHz. %s" % (-floor, dull[1])})
    c, d = max(bad, key=lambda x: abs(x[1]))
    name = "%d Hz" % c if c < 1000 else "%d kHz" % (c // 1000)
    if d < 0 and c < 1000:
        say, label, fix = ("The voice sounds thin. It lost its low tones.", "Thin voice",
                           "Use the take's clean voice once. Do not run the voice chain twice and do not high-pass the voice.")
    elif d < 0:
        say, label, fix = dull[0], "Dull voice", dull[1]
    elif c < 1000:
        say, label, fix = ("The voice sounds boomy. It has more low tones than the take.", "Boomy voice",
                           "Take out the low boost (EQ or a second voice chain).")
    else:
        say, label, fix = ("The voice sounds sharp. It has more high tones than the take.", "Sharp voice",
                           "Take out the high boost (EQ or a second voice chain).")
    return (d, [], say, {"want": want, "label": label,
                         "fix": "%s band is %d dB %s the take. %s" % (name, abs(d), "under" if d < 0 else "over", fix)})


def solve(A, b):
    """x of A x = b (Gauss-Jordan with pivots); None when A is singular."""
    n = len(b)
    M = [list(row) + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        M[c], M[p] = M[p], M[c]
        if abs(M[c][c]) < 1e-12:
            return None
        for r in range(n):
            if r != c and M[r][c]:
                f = M[r][c] / M[c][c]
                M[r] = [x - f * y for x, y in zip(M[r], M[c])]
    return [M[i][n] / M[i][i] for i in range(n)]


def voice_repeat(edit, take, lo=-4, hi=22):
    """(delay s, share, noise): the edit's sound level as the take's, plus copies of it 40 to 200 ms later (an
    echo the take does not have). Least squares of the edit's level every 10 ms on the take's at lags
    lo..hi frames, both as the change from the frame before (so the slow rise and fall of words does not
    blur the lags). Music, noise or room tone that is not in the take only adds noise to the fit, so it
    does not hide an echo. share: the loudest copy (two lags next to each other) over the voice itself
    (the lags around the peak), in amplitude: aecho with decay 0.4 reads 0.25 to 0.35, a clean cut under
    0.07 (2026-10-11, real takes and synthetic). noise: the root mean square of the other lags 40 to
    200 ms, on the same scale: an echo is 5 to 17 times it, a clean or cleaned voice at most 3.2 times.
    edit and take are lists of envelope pieces in dB, frame for frame the same sound (align)."""
    import operator
    mul = operator.mul
    lags = list(range(lo, hi + 1))
    n = len(lags)
    G = [[0.0] * n for _ in range(n)]
    r = [0.0] * n
    count = 0
    for pe, ps in zip(edit, take):
        L = min(len(pe), len(ps)) - 1
        if L - hi + lo < 50 or count > 30000:
            continue
        E = [10 ** (x / 20.0) for x in pe[:L + 1]]
        S = [10 ** (x / 20.0) for x in ps[:L + 1]]
        E = [y - x for x, y in zip(E, E[1:])]
        S = [y - x for x, y in zip(S, S[1:])]
        Y = E[hi:L + lo]
        X = [S[hi - k:L + lo - k] for k in lags]
        for a in range(n):
            r[a] += sum(map(mul, X[a], Y))
            for b in range(a, n):
                G[a][b] += sum(map(mul, X[a], X[b]))
        count += len(Y)
    if count < 300:
        raise Skip("Too little voice to measure the echo.")
    for a in range(n):
        for b in range(a):
            G[a][b] = G[b][a]
    ridge = 1e-3 * sum(G[i][i] for i in range(n)) / n
    for i in range(n):
        G[i][i] += ridge
    h = solve(G, r)
    if not h:
        raise Skip("Takes could not measure the echo.")
    k0 = max(range(len(h)), key=lambda i: h[i])
    main = sum(h[max(0, k0 - 2):k0 + 3])
    if main <= 0:
        raise Skip("The edit's sound does not follow the take. Takes cannot measure the echo.")
    best, at = 0.0, None
    for j in range(k0 + 4, min(len(h) - 1, k0 + 20)):
        v = max(0.0, h[j]) + max(0.0, h[j + 1])
        if v > best:
            best, at = v, j
    if at is None:
        return 0.0, 0.0
    win = [(i, max(0.0, h[i])) for i in range(max(0, k0 - 2), min(len(h), k0 + 3))]
    c0 = sum(i * v for i, v in win) / max(1e-12, sum(v for _, v in win))
    lag = at + max(0.0, h[at + 1]) / best - c0
    rest = [h[j] for j in range(k0 + 4, min(len(h), k0 + 21)) if j not in (at, at + 1)]
    noise = math.sqrt(sum(x * x for x in rest) / len(rest)) if rest else 0.0
    return round(lag * FRAME, 3), round(best / main, 3), round(noise / main, 3)


def chk_echo(ctx):
    lim = BUILTIN["echo"]
    if not ctx["probe"]["audio"]:
        raise Skip("The edit has no sound.")
    need_source(ctx)
    ee, es = ctx["env_e"], ctx["env_s"]
    # The voice alone, when the edit has it beside it (a cut_take cut's .wav): no music in the way.
    stem = os.path.splitext(ctx["path"])[0] + ".wav"
    if os.path.isfile(stem):
        try:
            v = envelope(ctx["s"], stem)
            if abs(len(v) - len(ee)) * FRAME < 0.5:
                ee = v
        except (ValueError, OSError, subprocess.SubprocessError):
            pass
    pe, ps, used = [], [], 0.0
    for g in ctx["segments"]:
        if used > 600:
            break
        used += g["edit"][1] - g["edit"][0]
        pe.append(ee[int(g["edit"][0] / FRAME):int(g["edit"][1] / FRAME)])
        ps.append(es[int(g["src"][0] / FRAME):int(g["src"][1] / FRAME)])
    tails = repeat = why = None
    try:
        tails = voice_tails(pe, ps)
    except Skip as e:
        why = e
    try:
        repeat = voice_repeat(pe, ps)
    except Skip as e:
        why = why or e
    if tails is None and repeat is None:
        raise why
    want = ("voice tail at most %g s longer than the take's; no repeat of the voice 40 to 200 ms later over %d %% "
            "of its level" % (lim["more"], round(lim["repeat"] * 100)))
    fix = "Use the take's clean voice once; do not run the voice chain twice or add reverb or aecho."
    if tails:
        te, ts = tails
        more = round(te - ts, 2)
        if more > lim["more"] and te > lim["ratio"] * ts:
            return (more, [], "The voice has more echo than the take.",
                    {"want": want, "fix": "The voice dies away in %.2f s, the take's in %.2f s. %s" % (te, ts, fix)})
    # A repeat counts when it stands out of the fit's noise: a cleaned voice (ClearVoice, Resemble Enhance)
    # is not the take's sound times a number, and its fit swings by 15 % at every lag (2026-10-11).
    if repeat and repeat[1] > lim["repeat"] and repeat[1] > lim["clear"] * repeat[2]:
        return (repeat[1], [], "The voice has more echo than the take.",
                {"want": want, "fix": "The voice repeats %d ms later at %d %% of its level. The take does not. %s"
                                      % (round(repeat[0] * 1000), round(repeat[1] * 100), fix)})
    out = {"want": want}
    if tails is None:
        out["note"] = "%s Takes measured only the repeat of the voice." % why
    return (round(tails[0] - tails[1], 2) if tails else repeat[1], [], None, out)


def ncc_bytes(a, b):
    n = float(len(a))
    if not n or len(a) != len(b):
        return 0.0
    ma, mb = sum(a) / n, sum(b) / n
    va = sum((x - ma) ** 2 for x in a)
    vb = sum((x - mb) ** 2 for x in b)
    if va < 1e-6 or vb < 1e-6:
        return 1.0 if abs(ma - mb) < 4 else 0.0
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / math.sqrt(va * vb)


def shown_size(v):
    """(width, height) of a video stream as a player shows it: a 90 degree rotation swaps them."""
    w, h = int((v or {}).get("width") or 0), int((v or {}).get("height") or 0)
    rot = 0.0
    for d in (v or {}).get("side_data_list") or []:
        try:
            rot = float(d.get("rotation") or rot)
        except (TypeError, ValueError):
            pass
    try:
        rot = float(((v or {}).get("tags") or {}).get("rotate") or rot)
    except (TypeError, ValueError):
        pass
    return (h, w) if int(round(abs(rot))) % 180 == 90 else (w, h)


def recipe_region(s, rel, take_size):
    """The part of the take (x, y, w, h in its pixels) that render_edit put in the frame, from the edit's
    recipe: frame.crop, then the centre cut to the frame's shape. None without a recipe."""
    try:
        r = load_recipe(s, recipe_path(rel))
    except ValueError:
        return None
    f = (r or {}).get("frame") if isinstance((r or {}).get("frame"), dict) else None
    tw, th = take_size
    if not f or not f.get("w") or not f.get("h") or not tw or not th:
        return None
    c = f.get("crop") if isinstance(f.get("crop"), dict) else None
    try:
        x, y, w, h = (float(c[k]) for k in ("x", "y", "w", "h")) if c else (0.0, 0.0, float(tw), float(th))
        a = float(f["w"]) / float(f["h"])
    except (KeyError, TypeError, ValueError, ZeroDivisionError):
        return None
    if w / h > a:
        x, w = x + (w - h * a) / 2.0, h * a
    else:
        y, h = y + (h - w / a) / 2.0, w / a
    return clamp_region((x, y, w, h), take_size)


def clamp_region(r, size):
    x, y, w, h = (int(round(v)) for v in r)
    w, h = max(2, min(w, size[0])) // 2 * 2, max(2, min(h, size[1])) // 2 * 2
    return (max(0, min(x, size[0] - w)), max(0, min(y, size[1] - h)), w, h)


REGION_PX = 240.0  # find_region: the take's long side in pixels for the search
REGION_COARSE_PX = 80.0  # find_region's first pass: every size and place on a small frame, then 240 px near the best


def find_region(edit, te, take, ts, edit_size, take_size):
    """(x, y, w, h in take pixels, correlation): where the edit's frame at te sits in the take's frame at ts.
    A reframe (a 9:16 cut of a 16:9 take, a punch-in) is a crop of the take, scaled: small grey frames,
    every crop size from the full frame down to half of it, every place, the best correlation.
    Every place at 240 px in pure Python took 5 s a check (2026-10-22), so a first pass looks at every
    size and place on an 80 px frame, and 240 px looks only around the sizes and places that pass found."""
    import operator
    (ew, eh), (tw, th) = edit_size, take_size
    a = float(ew) / eh
    w0, h0 = (th * a, float(th)) if a <= float(tw) / th else (float(tw), tw / a)
    mul = operator.mul

    def level(px):
        """The search at one size of the take: its long side px. None when the take gives no frame."""
        k = px / max(tw, th)
        sw, sh = max(8, int(round(tw * k))), max(8, int(round(th * k)))
        raw = grey_frames(take, ts, 0.25, 4, (sw, sh))
        if not raw:
            return None
        T = [list(raw[0][r * sw:(r + 1) * sw]) for r in range(sh)]
        I1 = [[0.0] * (sw + 1) for _ in range(sh + 1)]
        I2 = [[0.0] * (sw + 1) for _ in range(sh + 1)]
        for r in range(sh):
            a1 = a2 = 0.0
            for c in range(sw):
                v = T[r][c]
                a1 += v
                a2 += v * v
                I1[r + 1][c + 1] = I1[r][c + 1] + a1
                I2[r + 1][c + 1] = I2[r][c + 1] + a2
        edits = {}

        def score(f, x, y):
            cw, ch = edits[f][0]
            n = cw * ch
            s1 = I1[y + ch][x + cw] - I1[y][x + cw] - I1[y + ch][x] + I1[y][x]
            s2 = I2[y + ch][x + cw] - I2[y][x + cw] - I2[y + ch][x] + I2[y][x]
            var = s2 - s1 * s1 / n
            E, en = edits[f][1], edits[f][2]
            if var <= 1e-6 or en <= 1e-6:
                return -1.0
            return sum(sum(map(mul, E[r], T[y + r][x:x + cw])) for r in range(ch)) / math.sqrt(var * en)

        def prep(f):
            """The edit's frame at the size of a crop of f of the take, mean taken off; None when too small."""
            if f not in edits:
                cw, ch = int(round(w0 * f * k)), int(round(h0 * f * k))
                fr = grey_frames(edit, te, 0.25, 4, (cw, ch)) if 12 <= cw <= sw and 12 <= ch <= sh else None
                if fr:
                    m = sum(fr[0]) / float(cw * ch)
                    E = [[fr[0][r * cw + c] - m for c in range(cw)] for r in range(ch)]
                    edits[f] = ((cw, ch), E, sum(v * v for row in E for v in row))
                else:
                    edits[f] = None
            return edits[f]

        def places(f, xs=None, ys=None, step=1):
            if not prep(f):
                return []
            cw, ch = edits[f][0]
            xs = xs or range(0, sw - cw + 1, step)
            ys = ys or range(0, sh - ch + 1, step)
            return [(score(f, x, y), f, x, y) for x in xs if 0 <= x <= sw - cw for y in ys if 0 <= y <= sh - ch]

        def near(f, mx, my, r):
            """Every place within r pixels of the crop of f whose middle is at (mx, my)."""
            if not (0.45 <= f <= 1.0 and prep(f)):
                return []
            x0, y0 = int(round(mx - edits[f][0][0] / 2.0)), int(round(my - edits[f][0][1] / 2.0))
            return places(f, range(x0 - r, x0 + r + 1), range(y0 - r, y0 + r + 1))

        def middle(v):
            _, f, x, y = v
            return (x + edits[f][0][0] / 2.0) / k, (y + edits[f][0][1] / 2.0) / k
        return {"k": k, "places": places, "near": near, "middle": middle}

    coarse, fine = level(REGION_COARSE_PX), level(REGION_PX)
    if coarse is None or fine is None:
        return None, 0.0

    def again(v, r=4):
        """A place found at 80 px, looked at again at 240 px: one pixel there is three here."""
        mx, my = coarse["middle"](v)
        return fine["near"](v[1], mx * fine["k"], my * fine["k"], r)
    first, found = [], []
    for f in (1.0, 0.9, 0.8, 0.7, 0.6, 0.5):
        here = coarse["places"](f)
        first += here
        if f == 1.0 and here:
            found += again(max(here))
            if found and max(found)[0] >= 0.99:
                break  # the whole frame, or a full-height cut of it: the usual edit
    if not first:
        return None, 0.0
    # The best place of the three best sizes, near the best of all, at 240 px too: a still frame
    # matches its own middle as well, so the bigger crop must get its look.
    if not (found and max(found)[0] >= 0.99):
        best = {}
        for v in first:
            if v[0] > best.get(v[1], (-2.0,))[0]:
                best[v[1]] = v
        top = max(first)[0]
        for v in sorted(best.values(), reverse=True)[:3]:
            if v[0] >= top - 0.05 and v[1] != 1.0:
                found += again(v)
    if not found:
        return None, 0.0
    k = fine["k"]
    for step in (0.05, 0.025):  # finer: the sizes between two steps around the same middle, every pixel
        mx, my = fine["middle"](max(found))
        bf = max(found)[1]
        for f in (round(bf - step, 3), bf, round(bf + step, 3)):
            found += fine["near"](f, mx * k, my * k, 3)
    top = max(found)
    # The biggest crop that matches as well wins: a still frame matches its own middle too.
    sc, f, x, y = max((v for v in found if v[0] >= top[0] - 0.005), key=lambda v: (v[1], v[0]))
    return clamp_region((x / k, y / k, w0 * f, h0 * f), take_size), sc


def chk_picture_drift(ctx):
    lim = BUILTIN["picture_drift"]
    need_source(ctx)
    sp = ctx["src_probe"]
    if not sp or not sp["video"]:
        raise Skip("The take has no picture.")
    hdr = sp["hdr"] or ctx["probe"]["hdr"]
    tone = not hdr or has_filter("zscale")
    inner = [(g["edit"][0] + 0.3, g["edit"][1] - 0.3, g["src"][0] - g["edit"][0]) for g in ctx["segments"]
             if g["edit"][1] - g["edit"][0] > 1.0]
    total = sum(b - a for a, b, _ in inner)
    if total <= 0:
        raise Skip("Too few frames match the take to compare the picture.")
    times, n = [], 12
    for i in range(n):
        x = (i + 0.5) * total / n
        for a, b, off in inner:
            if x <= b - a:
                times.append((a + x, a + x + off))
                break
            x -= b - a
    # The part of the take in the edit's frame: the recipe's crop, else found in the picture (a 9:16 cut
    # of a 16:9 take or a punch-in was "too few frames match" before, 2026-10-11). Both sides are then
    # compared at the smaller one's own size, so a softer picture reads the same at 9:16 and at 16:9.
    es, ts = shown_size(ctx["probe"]["video"]), shown_size(sp["video"])
    region = recipe_region(ctx["s"], ctx["rel"], ts) if all(es) and all(ts) else None
    if region is None and all(es) and all(ts):
        for te, tt in (times[len(times) // 2], times[len(times) // 4], times[3 * len(times) // 4]):
            region, sc = find_region(ctx["path"], te, ctx["src"]["path"], tt, es, ts)
            if region and sc >= 0.8:
                break
            region = None
        if region is None:
            raise Skip("Takes could not find the edit's picture in the take.")
    if region and region == (0, 0, ts[0] // 2 * 2, ts[1] // 2 * 2):
        region = None
    rw, rh = (region[2], region[3]) if region else ts
    cw, ch = (es if es[0] * es[1] <= rw * rh else (rw, rh)) if all(es) and rw else (0, 0)
    if cw * ch > 1920 * 1080:  # a 4K pair: both at 1080p, still the same scale on both sides
        k = math.sqrt(1920 * 1080.0 / (cw * ch))
        cw, ch = cw * k, ch * k
    size = (max(2, int(cw) // 2 * 2), max(2, int(ch) // 2 * 2)) if cw and ch else None

    def pair(t):
        try:
            return (frame_stats(ctx["path"], t[0], ctx["probe"]["hdr"] and tone, size=size),
                    frame_stats(ctx["src"]["path"], t[1], sp["hdr"] and tone, crop=region, size=size))
        except ValueError:
            return None
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        pairs = [x for x in ex.map(pair, times) if x and ncc_bytes(x[0][4], x[1][4]) >= lim["same"]]
    if len(pairs) < 4:
        raise Skip("Too few frames match the take to compare the picture.")
    du = median([e[0] - s[0] for e, s in pairs])
    dv = median([e[1] - s[1] for e, s in pairs])
    src_sat = median([s[2] for e, s in pairs])
    # A grey take has no colour to lose: 0 / 0 read as "washed out" on every edit of it (2026-10-11).
    sat = median([e[2] for e, s in pairs]) / src_sat if src_sat > 1.0 else 1.0
    blurs = [(e[3], s[3]) for e, s in pairs if e[3] is not None and s[3] is not None and s[3] > 0]
    blur = median([e / s for e, s in blurs]) if blurs else 1.0
    color = tone and not ctx["src"].get("grade")
    found = []  # (how far over the limit, value, say end, label)
    if du < -lim["chroma"] and dv < -lim["chroma"]:
        found.append((min(du, dv) / -lim["chroma"], round(min(du, dv), 1), "greener than the take.", "Picture color"))
    elif color and max(abs(du), abs(dv)) > lim["chroma"]:
        found.append((max(abs(du), abs(dv)) / lim["chroma"], round(max(du, dv, key=abs), 1),
                      "a different color than the take.", "Picture color"))
    if color and sat < lim["sat"]:
        found.append((lim["sat"] / max(sat, 1e-6), round(sat, 2), "more washed out than the take.", "Picture color"))
    if blur > lim["blur"]:
        found.append((blur / lim["blur"], round(blur, 2), "softer than the take.", "Soft picture"))
    want = "U and V within %g, saturation at least %g x and blur at most %g x the take" % (lim["chroma"], lim["sat"], lim["blur"])
    extra = {"want": want}
    if not tone:
        extra["note"] = "The take is HDR and this ffmpeg has no zscale, so Takes did not compare the colors."
    elif ctx["src"].get("grade"):
        extra["note"] = "The edit has a grade, so only green and blur are compared."
    if not found:
        return (round(max(abs(du), abs(dv)), 1), [], None, extra)
    _, value, end, label = max(found)
    extra.update(label=label, fix="Against the take: U %+.1f, V %+.1f, saturation %.2f x, blur %.2f x (%d frames). "
                                  "Render the next version without the color change or scale filter; an HDR take needs "
                                  "tone mapping to bt709 (zscale + tonemap)." % (du, dv, sat, blur, len(pairs)))
    return (value, [], "The picture is " + end, extra)


# ---------- framing ----------
# The user: "zoom out a little and center me", "make sure to crop me better" (2026-10-11). The faces come
# from takes-faces (Apple Vision, Sources/TakesFaces) in Takes.app. A face is judged inside the card it
# sits in: the nearest straight edges around it where most pixels change at once (a card on a
# background, a split line), else the frame. Only "too tight" is checked: off centre failed 17 of 72
# edits he passed, as a face beside text on purpose reads the same.
FACE_W = 180  # the grey frame the card edges are found in


def faces_helper():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.environ.get("TAKES_FACES"), os.path.join(here, "..", "MacOS", "takes-faces"),
              os.path.join(here, "..", ".build", "release", "takes-faces"),
              os.path.join(here, "..", ".build", "debug", "takes-faces"),
              os.path.expanduser("~/Applications/Takes.app/Contents/MacOS/takes-faces"),
              "/Applications/Takes.app/Contents/MacOS/takes-faces"):
        if p and os.access(p, os.X_OK):
            return os.path.realpath(p)
    return None


def face_boxes(images):
    """{image: [[x, y, w, h], ...]} in 0...1, y from the top. None without the helper."""
    helper = faces_helper()
    if not helper or not images:
        return None
    r = subprocess.run([helper] + list(images), capture_output=True, text=True, timeout=120)
    out = {}
    for line in (r.stdout or "").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        out[d.get("path")] = d.get("faces") or []
    return out


def face_card(g, w, h, box):
    """(left, top, right, bottom) of the card around a face box, in grey-frame pixels."""
    x0, y0, x1, y1 = (int(v) for v in (box[0] * w, box[1] * h, (box[0] + box[2]) * w, (box[1] + box[3]) * h))
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w - 1, x1), min(h - 1, y1)

    def edge(pairs):
        pairs = list(pairs)
        return pairs and sum(1 for a, b in pairs if abs(a - b) > 18) >= 0.85 * len(pairs)
    cols = range(x0, max(x0 + 1, x1))
    top = next((y for y in range(y0, 0, -1) if edge((g[y * w + x], g[(y - 1) * w + x]) for x in cols)), 0)
    bottom = next((y + 1 for y in range(y1, h - 1) if edge((g[y * w + x], g[(y + 1) * w + x]) for x in cols)), h)
    rows = range(max(top, y0), max(max(top, y0) + 1, min(bottom, y1 + (y1 - y0))))
    left = next((x for x in range(x0, 0, -1) if edge((g[y * w + x], g[y * w + x - 1]) for y in rows)), 0)
    right = next((x + 1 for x in range(x1, w - 1) if edge((g[y * w + x], g[y * w + x + 1]) for y in rows)), w)
    return left, top, right, bottom


def framing_samples(path, times, size):
    """[(t, [{"size": face h / card h, "card": card w / frame w}])] for each time with a frame."""
    w = FACE_W
    h = max(2, int(round(w * size[1] / float(size[0]))) // 2 * 2)
    tmp = tempfile.mkdtemp(prefix="takes-faces-")
    try:
        def grab(t):
            """The frame at t as a PNG for takes-faces and as grey bytes, from one ffmpeg: two took twice the
            CPU, and the grey one's 0.04 s window at 25 fps found no frame at some times (2026-10-22)."""
            png = os.path.join(tmp, "%.2f.png" % t)
            r = subprocess.run([need_ffmpeg(), "-v", "error", "-y"] + ONE_THREAD + [
                "-ss", "%.3f" % t, "-i", path, "-an", "-filter_complex",
                "[0:v]split[a][b];[a]scale=640:-2[p];[b]scale=%d:%d,format=gray[g]" % (w, h),
                "-map", "[p]", "-frames:v", "1", png, "-map", "[g]", "-frames:v", "1", "-f", "rawvideo", "-"],
                capture_output=True, timeout=60)
            g = r.stdout[:w * h]
            return t, png, (g if len(g) == w * h else None)
        with concurrent.futures.ThreadPoolExecutor(4) as ex:
            got = [x for x in ex.map(grab, times) if x[2] and os.path.exists(x[1])]
        boxes = face_boxes([png for _, png, _ in got])
        if boxes is None:
            raise Skip("Takes cannot find faces here: takes-faces is not in Takes.app. Update Takes.")
        out = []
        for t, png, g in got:
            found = []
            for b in boxes.get(png) or []:
                left, top, right, bottom = face_card(g, w, h, b)
                found.append({"size": b[3] * h / max(1.0, bottom - top), "card": (right - left) / float(w)})
            out.append((t, found))
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def framing_verdict(samples, lim):
    """(value, times, say or None, extra) from framing_samples."""
    tight, biggest = [], 0.0
    for t, found in samples:
        sizes = [f["size"] for f in found if f["card"] >= lim["min_card"] and f["size"] >= lim["min_face"]]
        if sizes:
            biggest = max(biggest, max(sizes))
            if max(sizes) > lim["tight"]:
                tight.append((t, max(sizes)))
    want = "the face at most %g of its card's height" % lim["tight"]
    if len(tight) < lim["frames"]:
        extra = {"want": want}
        if not biggest:
            extra["note"] = "No face big enough to judge."
        return (round(biggest, 2), [], None, extra)
    worst = max(v for _, v in tight)
    return (round(worst, 2), [t for t, _ in tight], "The face fills %d%% of its card's height at %s: too tight." % (
        round(worst * 100), ", ".join(mmss(t) for t, _ in tight[:4])),
        {"want": want, "fix": "Zoom out: show head and shoulders with room above the hair or cap, the face "
                              "about a third of the card's height, centred in it."})


def chk_framing(ctx):
    lim = BUILTIN["framing"]
    v = ctx["probe"]["video"]
    size = shown_size(v) if v else (0, 0)
    if not v or not all(size):
        raise Skip("The edit has no picture.")
    total = ctx["probe"]["duration"] or media_seconds(ctx["path"])
    n = lim["samples"]
    times = [round((i + 0.5) * total / n, 2) for i in range(n)] if total > 0 else []
    return framing_verdict(framing_samples(ctx["path"], times, size), lim)


def quote(ws):
    return "“%s”" % " ".join(w for _, _, w in ws)


def chk_words(ctx):
    lim = BUILTIN["words"]
    need_source(ctx)
    if not is_ready(words_doc(ctx["src"]["path"])):
        # Older transcripts (Apple's) stretch words over the pauses: every cut would look like a cut word.
        raise Skip("The take has no transcript yet." if not os.path.exists(os.path.splitext(ctx["src"]["path"])[0]
                                                                           + ".words.json") else
                   "The take has no exact word times yet. cut_take and rough_cut make them.")
    words = sorted(transcript_words(ctx["src"]["path"]) or [])
    if not words:
        raise Skip("The take has no transcript yet.")
    ends = sentence_ends(ctx["s"], words)
    segs = sorted(ctx["segments"], key=lambda g: g["edit"][0])
    inside = []
    for g in segs:
        c, d = g["src"]
        inside.append([i for i, (a, b, _) in enumerate(words) if c <= (a + b) / 2.0 <= d])

    def at(g, x):  # take time -> edit time
        return g["edit"][0] + x - g["src"][0]

    def filler(i):
        return norm_word(words[i][2]) in FILLERS

    def joins(i, j):
        """The take's word j follows word i in the edit as said: next word, a retry or only ums between."""
        if j <= i + 1:
            return True
        between = [k for k in range(i + 1, j) if not filler(k)]
        return not between or norm_word(words[between[0]][2]) == norm_word(words[j][2])
    # Voice in the edit that is in no segment (a pick-up from another take, a voice-over): what is said
    # there is not known, so a cut next to it is not judged (a sentence can go on in the other take).
    env = ctx["env_e"] or []
    loud = (percentile(env, 0.95) or 0.0) - 25.0
    spans = [(int(x["edit"][0] / FRAME), int(x["edit"][1] / FRAME)) for x in segs]

    def open_voice(x, y):
        lo, hi = max(0, int(x / FRAME)), min(len(env), int(y / FRAME))
        return sum(1 for i in range(lo, hi) if env[i] > loud and not any(a <= i < b for a, b in spans)) * FRAME >= 0.2
    missing, clipped, twice = [], [], []
    for k, g in enumerate(segs):
        c, d = g["src"]
        if g.get("rough"):
            continue  # its edges are not known to the word
        open_in, open_out = open_voice(g["edit"][0] - 1.0, g["edit"][0]), open_voice(g["edit"][1], g["edit"][1] + 1.0)
        for i, (a, b, w) in enumerate(words):
            if b - a <= 0.05:
                continue
            if a < d - 0.02 and b > d + lim["edge"] and not open_out:
                clipped.append((at(g, max(d, c)), [words[i]]))
            elif b > c + 0.02 and a < c - lim["edge"] and not open_in:
                clipped.append((at(g, c), [words[i]]))
        ins = inside[k]
        if not ins:
            continue
        last, first = ins[-1], ins[0]
        nxt = next((inside[j][0] for j in range(k + 1, len(segs)) if inside[j]), None)
        prv = next((inside[j][-1] for j in range(k - 1, -1, -1) if inside[j]), None)
        if not ends[last] and not open_out and not (nxt is not None and joins(last, nxt)):
            missing.append((at(g, words[last][1]), words[max(first, last - 3):last + 1], "stops"))
        before = first - 1
        while before >= 0 and filler(before):
            before -= 1
        if before >= 0 and not ends[before] and not open_in and not (prv is not None and joins(prv, first)):
            missing.append((g["edit"][0], words[first:min(last, first + 3) + 1], "starts"))
        if k + 1 < len(segs):
            h = segs[k + 1]
            lap = min(d, h["src"][1]) - max(c, h["src"][0])
            if h["edit"][0] - g["edit"][1] < 0.5 and lap > lim["twice"] and not h.get("rough"):
                said = [x for x in words if max(c, h["src"][0]) <= (x[0] + x[1]) / 2 <= min(d, h["src"][1])]
                twice.append((h["edit"][0], said or words[ins[-1]:ins[-1] + 1], round(lap, 2)))
    out = []
    if missing:
        t, ws, how = missing[0]
        out.append((len(missing), [x[0] for x in missing],
                    "The cut %s in the middle of a sentence at %s: %s." % (how, mmss(t), quote(ws)),
                    {"label": "Missing words", "want": "every cut at a sentence end or joined to the rest of it",
                     "fix": "%d cuts inside a sentence (first at %.2f s of the edit). Keep the whole sentence: move "
                            "the cut to its end or add the rest from the take." % (len(missing), t)}))
    if clipped:
        t, ws = clipped[0]
        out.append((len(clipped), [x[0] for x in clipped], "A word is cut off at %s: %s." % (mmss(t), quote(ws)),
                    {"label": "Cut word", "want": "no word cut by more than %g s" % lim["edge"],
                     "fix": "%d words cut at a segment edge (first at %.2f s). Move the cut into the pause next to "
                            "the word (cut_take snaps cuts to word edges)." % (len(clipped), t)}))
    if twice:
        t, ws, lap = twice[0]
        out.append((lap, [x[0] for x in twice], "Words are said twice at %s: %s." % (mmss(t), quote(ws[:4])),
                    {"label": "Words twice", "want": "back-to-back cuts overlap by at most %g s of the take" % lim["twice"],
                     "fix": "Two back-to-back cuts repeat %.2f s of the take at %.2f s. Start the second cut where the "
                            "first one ends." % (lap, t)}))
    return out or (0, [], None, {"want": "every cut at a sentence end, no cut word, nothing said twice"})


def one_frame(path, t):
    f = grey_frames(path, t, 0.25, 4, (64, 36))
    return f[0] if f else None


def version_segments(s, rel):
    """(take path, segments) of an edit version, as check_edit finds them: its made_from, else align
    with the guessed take. (None, []) when the version is not found in a take."""
    path = os.path.join(s, rel)
    try:
        src = edit_source(s, rel)
        if src["segments"]:
            return src["path"], src["segments"]
        if src["path"] and probe_streams(path)["audio"]:
            al = align(envelope(s, path), envelope(s, src["path"]))
            if al["segments"] and al["coverage"] >= 0.5:
                return src["path"], al["segments"]
    except (ValueError, OSError, subprocess.SubprocessError):
        pass
    return None, []


def span_union(spans):
    out = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        elif b > a:
            out.append((a, b))
    return out


def span_minus(spans, cut):
    out = []
    for a, b in spans:
        pieces = [(a, b)]
        for c, d in cut:
            pieces = [p for x, y in pieces for p in ((x, min(y, c)), (max(x, d), y)) if p[1] - p[0] > 1e-6]
        out += pieces
    return out


def words_undone(ctx, c, fix, start, end):
    """cut_undone when the take times are not known: the words (each version's words.json) said in the
    comment's range, with the two words before them, that the fixed version does not say and this file
    says again."""
    s = ctx["s"]
    wa, wb, wc = (transcript_words(os.path.join(s, f)) for f in (c["file"], fix["file"], ctx["path"]))
    if not wa or not wb or not wc:
        return None

    def toks(ws, lo=None, hi=None):
        return [(t, w) for w in ws if lo is None or lo <= (w[0] + w[1]) / 2.0 <= hi for t in spoken(w[2])]
    cut = toks(wa, start, end)
    before = [x for x in toks(wa) if (x[1][0] + x[1][1]) / 2.0 < start][-2:]
    if not cut or not before:
        return None
    seq = [t for t, _ in before + cut]

    def find(ws):
        tk = toks(ws)
        return next((tk[i + len(before)][1] for i in range(len(tk) - len(seq) + 1)
                     if [t for t, _ in tk[i:i + len(seq)]] == seq), None)
    if find(wb) is not None:
        return None
    w = find(wc)
    if w is None:
        return None
    said = [x[1] for x in cut]
    said = [x for i, x in enumerate(said) if x not in said[:i]]
    return w[0], said, round(said[-1][1] - said[0][0], 2), [(said[0][0], said[-1][1])]


def cut_undone(ctx, c, fix, seg_of):
    """A part of the take that the comment's range had in its version, that the fixed version cut, and that
    this file has again: (seconds in this file, take words or None, back seconds) or None. Only the take
    times count, so a hiccup that comes back is found though the sound around it is the same."""
    lim = BUILTIN["regression"]
    start = float(c["start"])
    end = float(c["end"]) if c.get("end") is not None and float(c["end"]) - start >= 0.1 else start + 1.0
    pa, sa = seg_of(c["file"])
    pb, sb = seg_of(fix["file"])
    if not sa or not sb or pa != ctx["src"]["path"] or pb != pa:
        return words_undone(ctx, c, fix, start, end)
    had = []
    for g in sa:
        lo, hi = max(start, g["edit"][0]), min(end, g["edit"][1])
        if hi - lo > 0:
            off = g["src"][0] - g["edit"][0]
            had.append((lo + off, hi + off))
    # The fixed version's edges are known to about 0.05 s: a sliver there is not a cut.
    gone = [(a, b) for a, b in span_minus(span_union(had), span_union([tuple(g["src"]) for g in sb]))
            if b - a >= lim["cut"]]
    if not gone:
        return None
    here = [(g["src"][0], g["src"][1], g["edit"][0]) for g in ctx["segments"]]
    back, at = 0.0, None
    for a, b in gone:
        for c0, d0, e0 in here:
            lo, hi = max(a, c0), min(b, d0)
            if hi - lo > 0:
                back += hi - lo
                at = e0 + lo - c0 if at is None else min(at, e0 + lo - c0)
    total = sum(b - a for a, b in gone)
    if at is None or back < lim["cut"] or back < lim["cut_share"] * total:
        return None
    words = transcript_words(ctx["src"]["path"]) or []
    said = [w for w in words if any(a <= (w[0] + w[1]) / 2.0 <= b for a, b in gone)]
    return at, said or None, round(back, 2), gone


def chk_regression(ctx):
    """A fix the user approved that came undone: per resolved comment fixed in an earlier version of this
    slug, is this file nearer the version he commented on than the fixed one, in sound and in picture?"""
    lim, s, rel = BUILTIN["regression"], ctx["s"], ctx.get("line_rel") or ctx["rel"]
    want = "no approved fix undone"
    folder = os.path.dirname(rel)
    base, ver, _ = split_version(os.path.basename(rel))
    if ver is None:
        return (0, [], None, {"want": want})

    def same(f):
        return bool(f) and os.path.dirname(f) == folder and split_version(os.path.basename(f))[0] == base

    def version(f):
        return split_version(os.path.basename(f))[1] or 0
    comments = read_comments(s)["comments"]
    cand = []
    for c in comments:
        if c.get("status") != "resolved" or c.get("start") is None or not same(c.get("file")):
            continue
        fix = next((r for r in reversed(c.get("replies") or []) if same(r.get("file"))), None)
        if not fix or not (version(c["file"]) < version(fix["file"]) < ver):
            continue
        if os.path.isfile(os.path.join(s, c["file"])) and os.path.isfile(os.path.join(s, fix["file"])):
            cand.append((c, fix))
    cand = sorted(cand, key=lambda x: x[0].get("at") or "", reverse=True)[:20]
    p, sound = ctx["probe"], ctx["probe"]["audio"]
    env = envelope(s, ctx["path"]) if sound and cand else None
    out, compared, segs = [], 0, {}

    def seg_of(f):
        if f not in segs:
            segs[f] = version_segments(s, f)
        return segs[f]
    for c, fix in cand:
        start = float(c["start"])
        L = min(6.0, max(1.0, float(c.get("end") if c.get("end") is not None else start + 1.0) - start))
        fa = float(fix["time"]) if fix.get("time") is not None else start
        fv = version(fix["file"])
        if any(o is not c and same(o.get("file")) and version(o["file"]) >= fv and o.get("start") is not None
               and o["start"] < fa + L and (o.get("end") if o.get("end") is not None else o["start"]) > fa
               for o in comments):
            continue  # a comment on the fixed version or later asked to change this part again
        name = os.path.splitext(os.path.basename(fix["file"]))[0]
        back = cut_undone(ctx, c, fix, seg_of) if ctx["known"] and ctx["segments"] else None
        if back:
            at, said, secs_back, gone = back
            what = quote(said[:6]) if said else "the part of %.1f s" % sum(b - a for a, b in gone)
            out.append((secs_back, [at], "A part you asked to cut is back at %s: %s (cut in %s)." % (mmss(at), what, name),
                        {"comment": c["id"], "want": want,
                         "fix": "Cut it again: %.2f s that %s cut (%.2f to %.2f s of %s) is in this version at "
                                "%.2f s. Start from %s. If the change is on purpose, ask the user first."
                                % (secs_back, name, start, float(c["end"] if c.get("end") is not None else start + 1.0),
                                   os.path.splitext(os.path.basename(c["file"]))[0], at, name)}))
            compared += 1
            continue
        broken, fixed = os.path.join(s, c["file"]), os.path.join(s, fix["file"])
        votes, where = [], fa
        if sound and probe_streams(broken)["audio"] and probe_streams(fixed)["audio"]:
            eb, ef = envelope(s, broken), envelope(s, fixed)
            n, fi, bi = int(L / FRAME), int(fa / FRAME), int(start / FRAME)
            fw, bw = ef[fi:fi + n], eb[bi:bi + n]
            if len(fw) == n and len(bw) == n:
                q, _ = _ncc_search(fw, env, fi - int(NEAR / FRAME), fi + int(NEAR / FRAME))
                q = fi if q is None else q
                tw = env[q:q + n]
                if len(tw) == n:
                    where = q * FRAME

                    def sim(x, y):
                        return 1.0 / (1.0 + _mad(x, y) / 3.0)
                    if sim(bw, fw) < 0.9:  # the fix changed the sound here
                        votes.append(sim(tw, bw) - sim(tw, fw))
        if p["video"]:
            fb, ff_, ft = one_frame(broken, start + L / 2), one_frame(fixed, fa + L / 2), one_frame(ctx["path"], where + L / 2)
            if fb and ff_ and ft and ssim(fb, ff_) < 0.95:  # the fix changed the picture here
                votes.append(ssim(ft, fb) - ssim(ft, ff_))
        compared += 1
        if votes and all(v >= lim["margin"] for v in votes):
            text = re.sub(r"\s+", " ", c.get("text") or "").strip()
            text = text if len(text) <= 40 else text[:39].rstrip() + "…"
            out.append((round(min(votes), 2), [where],
                        "A fix you approved changed at %s: “%s” (fixed in %s)." % (mmss(where), text, name),
                        {"comment": c["id"], "want": want,
                         "fix": "Start from %s at %s. If the change is on purpose, ask the user first." % (name, mmss(fa))}))
    return out or (compared, [], None, {"want": want})


PICTURE_CHECKS = ("av_sync", "frozen_video", "picture_drift", "framing")


def run_builtin(s, rel, path, given=None, as_rel=None):
    """The built-in checks of one file, in a fixed order: streams, then align, then the rest in parallel."""
    t0 = time.time()
    p = probe_streams(path)
    if not p["video"] and not p["audio"]:
        raise ValueError("Takes cannot read this file (no video or sound stream). Render it again.")
    src = edit_source(s, rel, given)
    ctx = {"s": s, "rel": rel, "path": path, "probe": p, "line_rel": as_rel or rel, "src": src, "src_probe": None, "env_e": None,
           "env_s": None, "segments": None, "known": False,
           "why": NO_SOURCE if src["path"] else "The take file %s is missing." % src["missing"] if src.get("missing")
           else "The session has no take to compare with."}

    def run(name, fn):
        try:
            got = fn(ctx)
        except Skip as e:
            return [{"check": name, "pass": None, "skip": str(e)}]
        except (ValueError, OSError, subprocess.SubprocessError) as e:
            return [{"check": name, "pass": None, "error": str(e)}]
        out = []
        for value, at, say, extra in (got if isinstance(got, list) else [got]):
            r = {"check": name}
            if extra.get("comment"):
                r["comment"] = extra["comment"]
            if say:
                r["label"] = extra.get("label") or LABELS.get(name)
            r["pass"] = say is None
            r["value"] = value
            if extra.get("want"):
                r["want"] = extra["want"]
            if at:
                r["at"] = [round(x, 2) for x in at[:12]]
            if say:
                r["say"], r["fix"] = say, extra.get("fix")
            if extra.get("note"):
                r["note"] = extra["note"]
            out.append(r)
        return out
    results = run("streams", chk_streams)
    if src["path"] and p["audio"]:
        try:
            ctx["src_probe"] = probe_streams(src["path"])
            if ctx["src_probe"]["audio"]:
                with concurrent.futures.ThreadPoolExecutor(2) as ex:
                    fe, fs = ex.submit(envelope, s, path), ex.submit(envelope, s, src["path"])
                    ctx["env_e"], ctx["env_s"] = fe.result(), fs.result()
                if src["segments"]:
                    ctx["segments"], ctx["known"] = src["segments"], True
                else:
                    al = align(ctx["env_e"], ctx["env_s"])
                    for other in src["candidates"] if al["coverage"] < 0.5 else []:
                        # Not the guessed take: the edit may come from another one.
                        sp = probe_streams(other)
                        if not sp["audio"] or time.time() - t0 > CHECK_BUDGET / 3:
                            continue
                        env = envelope(s, other)
                        a2 = align(ctx["env_e"], env)
                        if a2["coverage"] > al["coverage"]:
                            al, ctx["env_s"], ctx["src_probe"] = a2, env, sp
                            src.update(path=other, offset=float((take_clock(other) or {}).get("audio_offset_s") or 0.0))
                        if al["coverage"] >= 0.5:
                            break
                    ctx["segments"] = al["segments"]
                    ctx["known"] = bool(al["segments"]) and al["coverage"] >= (GIVEN_SHARE if src["given"] else 0.5)
                    if src["given"] and not ctx["known"]:
                        ctx["why"] = NOT_FOUND % os.path.basename(src["path"])
            else:
                ctx["why"] = "The take has no sound, so Takes cannot find the edit in it."
        except (ValueError, OSError, subprocess.SubprocessError) as e:
            ctx["why"] = "Takes could not read the take: %s" % e
    elif src["path"]:
        ctx["why"] = "The edit has no sound, so Takes cannot find it in the take."
    names = ["av_sync", "frozen_video", "band_balance", "echo", "picture_drift", "framing", "words", "regression"]
    if not p["video"]:
        names = [n for n in names if n not in PICTURE_CHECKS]  # a sound-only edit: picture checks are not listed
    ex = concurrent.futures.ThreadPoolExecutor(4)
    futures = [(n, ex.submit(run, n, globals()["chk_" + n])) for n in names]
    for n, f in futures:
        left = CHECK_BUDGET - (time.time() - t0)
        try:
            results += f.result(timeout=max(0.0, min(CHECK_TIMEOUT, left)))
        except concurrent.futures.TimeoutError:
            results.append({"check": n, "pass": None, "skip": OUT_OF_TIME})
    ex.shutdown(wait=False, cancel_futures=True)
    return results, ctx


def save_check(s, rel, entry):
    """Sets checks.json[rel] under a lock; every other entry stays. A checks.json that does not read is
    kept aside as .checks-unreadable-<time>.json and a new one starts."""
    import fcntl
    cp = os.path.join(s, "checks.json")
    with open(os.path.join(s, ".checks.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            saved = {}
            if os.path.exists(cp):
                try:
                    with open(cp) as fh:
                        saved = json.load(fh)
                    if not isinstance(saved, dict):
                        raise ValueError("not an object")
                except ValueError:
                    os.replace(cp, os.path.join(s, ".checks-unreadable-%s.json" % time.strftime("%Y%m%d-%H%M%S")))
                    saved = {}
            saved[rel] = entry
            tmp = os.path.join(s, ".checks.json.tmp")
            with open(tmp, "w") as fh:
                json.dump(saved, fh, indent=2, ensure_ascii=False)
            os.replace(tmp, cp)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def t_check_edit(a):
    """The built-in checks (the edit against its take), then every learned rule that has a check. Saves the
    result in checks.json for the app (the line under the player, the Assets badge, the Feedback board)."""
    s = resolve_session(a["session"])
    f = a.get("file")
    if not f:
        raise ValueError("Give file: an edit from get_session, e.g. 'edits/<name>-v2.mp4'.")
    path = os.path.normpath(f if os.path.isabs(f) else os.path.join(s, f))
    rel = os.path.relpath(path, s)
    if rel.startswith(".."):
        raise ValueError("%s is not in this session. Pass an edit from get_session, e.g. 'edits/<name>-v2.mp4'." % f)
    if not os.path.isfile(path):
        raise ValueError("No file %s. Use get_session for the edit files, or next_path for a new one." % f)
    # A render of render_edit: the line of versions comes from its recipe's parent.
    rec = None
    try:
        rec = load_recipe(s, recipe_path(rel))
    except ValueError:
        pass
    t0, watch = time.time(), a.get("watch", True)
    review = start_review(s, path, watch)
    entry = check_file(s, rel, path, a.get("source"), lineage_rel(rec) if rec and rel.startswith(RENDERS + os.sep) else None)
    results = entry["results"]
    rules = [r for r in read_lessons()["rules"] if r.get("on", True) and (r.get("check") or {}).get("kind") in CHECKS]
    failed = [x for x in results if x["pass"] is False]
    idle = [x for x in results if x["pass"] is None]
    if failed:
        note = ("%d problem%s. Fix each one, make a new version (render_edit base=<name> changes={...}) and check it "
                "before you show it." % (len(failed), "" if len(failed) == 1 else "s"))
    else:
        note = "Every check passes. Look at the stills for the rules without a check."
    if idle:
        note += " %d check%s did not run; skip or error says why." % (len(idle), "" if len(idle) == 1 else "s")
    if not rules:
        note += (" No rule has a check yet. When a rule is repeated and a number can test it, add a check with "
                 "set_rule (kinds: %s)." % ", ".join(sorted(CHECKS)))
    return dict({"file": rel}, **entry, note=note, review=review_result(s, path, review, t0 + REVIEW_WAIT, watch))


# ---------- review: Gemini watches the edit ----------
# The built-in checks measure sound and picture against the take; they cannot say a page is too busy or a
# scene is boring. With a Gemini key, check_edit also has REVIEW_MODEL watch and hear the edit next to
# the rules, like the user would. 2026-10-13 test on 4 past edits: Argon with the rules found about half
# of the 38 comments the user wrote on them, Flash about a quarter; neither heard the audio problems the
# built-ins catch. It runs detached (about 20-40 s), once per file version (review_file); render_edit starts
# it and publish_edit returns it. Without a key, or when Gemini fails, check_edit gives the agent a
# sheet of frames to look at itself, so no user hits a wall.
REVIEW_MODEL = "gemini-4-argon"
REVIEW_PRICE = (2.0, 10.0)  # $ per 1M tokens in, out; intro price until 2026-11-30, then double
REVIEW_WAIT = 75            # s check_edit waits for the review before it answers without it
REVIEW_MAX_S = 900          # longer edits are not sent
SHEET_FRAMES = 24
REVIEW_PROMPT = """You review a finished edit of a short talking video before its creator sees it. Watch and \
listen to all of it like a picky editor and list every problem the creator would comment on: sound (glitches, \
sudden changes, distortion, lips out of sync), cuts (pauses too long, stutters, false starts, looking away, \
repeats, a clipped word), picture (glitches, a flash frame, the same shot twice, bad framing, cutout edges), \
on-screen graphics and text (unreadable, too busy, on screen too long or too short, does not match what is \
said, confusing), and pacing (a boring stretch, a long time without the speaker's face). Times are seconds \
from the start of the video and must be inside it. Only report what you can see or hear, and how sure you \
are. Do not praise."""
REVIEW_RULES = ("\n\nThe creator's rules from past reviews. Check the edit against each one; report each break "
                "as a problem with its rule id:\n")
REVIEW_SCHEMA = {"type": "OBJECT", "properties": {"problems": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
    "start": {"type": "NUMBER"}, "end": {"type": "NUMBER"},
    "area": {"type": "STRING", "enum": ["sound", "cut", "picture", "captions", "graphics", "pacing"]},
    "what": {"type": "STRING", "description": "One sentence: what is wrong."},
    "fix": {"type": "STRING", "description": "One short sentence: the change."},
    "rule": {"type": "STRING", "description": "The rule id it breaks, or ''."},
    "sure": {"type": "STRING", "enum": ["high", "medium", "low"]}},
    "required": ["start", "end", "area", "what", "sure"]}}}, "required": ["problems"]}


def review_file(s, path, kind):
    """<session>/.checks-cache/review-<inode>-<size>.<kind>: by inode, so the review of a render still holds
    once publish_edit links it into edits/ under its version name."""
    st = os.stat(path)
    return os.path.join(s, CHECKS_CACHE, "review-%d-%d.%s" % (st.st_ino, st.st_size, kind))


def write_review(p, d):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump(d, f, indent=1, ensure_ascii=False)
    os.replace(p + ".tmp", p)


def read_review(p):
    try:
        with open(p) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    if d.get("state") == "running" and d.get("pid") and not alive(d.get("pid")):
        return {"state": "failed", "error": "The review stopped before it finished."}
    return d


def edit_review(s, rel):
    """Detached: REVIEW_MODEL watches one edit and writes its problems into the checks cache."""
    import tempfile
    os.environ["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
    path = os.path.join(s, rel)
    out = review_file(s, path, "review.json")
    write_review(out, {"state": "running", "pid": os.getpid(), "model": REVIEW_MODEL, "started": now_iso()})
    tmp = tempfile.mkdtemp(prefix="takes-review-")
    try:
        rules = [r for r in read_lessons()["rules"] if r.get("on", True) and r["area"] in EDIT_AREAS]
        prompt = REVIEW_PROMPT + (REVIEW_RULES + "\n".join("- %s: %s" % (r["id"], r["text"]) for r in rules) if rules else "")
        dur = media_seconds(path)
        usage = {}
        if os.environ.get("TAKES_REVIEW_CMD"):  # tests: a stand-in that prints the JSON answer
            r = subprocess.run(json.loads(os.environ["TAKES_REVIEW_CMD"]) + [path], capture_output=True, text=True)
            if r.returncode != 0:
                raise ValueError(r.stderr.strip() or "The review failed.")
            got = json.loads(r.stdout)
        else:
            # 720 px high keeps on-screen text readable; Gemini looks at 2 frames a second.
            proxy = os.path.join(tmp, "review.mp4")
            subprocess.run([need_ffmpeg(), "-v", "error", "-y", "-i", path, "-vf", "scale=-2:720", "-c:v", "libx264",
                            "-crf", "30", "-preset", "veryfast", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                            proxy], check=True, capture_output=True, timeout=900)
            got = gemini_call(proxy, "video/mp4", gemini_key(), prompt, REVIEW_SCHEMA, "Review this edit.",
                              model=REVIEW_MODEL, fps=2, usage=usage)
        problems = []
        for x in got.get("problems") or []:
            try:
                a, b = float(x["start"]), float(x["end"])
            except (KeyError, TypeError, ValueError):
                continue
            if a > dur + 0.5:
                continue  # a time past the end: made up (2026-10-13 test: 140 s in a 118 s edit)
            x = dict(x, start=round(max(0.0, a), 1), end=round(min(dur, max(a, b)), 1))
            problems.append({k: v for k, v in x.items() if v not in ("", None)})
        problems.sort(key=lambda x: x["start"])
        tin = usage.get("promptTokenCount", 0)
        tout = usage.get("candidatesTokenCount", 0) + (usage.get("thoughtsTokenCount") or 0)
        write_review(out, {"state": "done", "model": REVIEW_MODEL, "at": now_iso(), "problems": problems,
                           "cost_usd": round(tin / 1e6 * REVIEW_PRICE[0] + tout / 1e6 * REVIEW_PRICE[1], 3)})
    except Exception as e:
        msg = str(e)
        if isinstance(e, subprocess.CalledProcessError) and e.stderr:
            msg = e.stderr.decode(errors="replace").strip().splitlines()[-1]
        write_review(out, {"state": "failed", "error": msg[:300]})
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def frame_sheet(s, path):
    """Up to SHEET_FRAMES frames of the edit in one PNG, 6 a row, for an agent to look at. Returns (file, times)."""
    dur = media_seconds(path)
    step = max(1.0, dur / SHEET_FRAMES)
    times = [round(step * (i + 0.5), 1) for i in range(max(1, int(dur / step)))][:SHEET_FRAMES]
    out = review_file(s, path, "sheet.png")
    if not os.path.exists(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run([need_ffmpeg(), "-v", "error", "-y", "-ss", "%.2f" % (step / 2), "-i", path, "-vf",
                        "fps=1/%.3f,scale=320:-2,tile=6x%d:padding=4:color=white" % (step, -(-len(times) // 6)),
                        "-frames:v", "1", out + ".tmp.png"], check=True, capture_output=True, timeout=300)
        os.replace(out + ".tmp.png", out)
    return out, times


def review_on(watch=True):
    """False turns the review off: watch=false, or TAKES_NO_REVIEW in tests (a real key must never be charged)."""
    return watch is not False and not os.environ.get("TAKES_NO_REVIEW")


def start_review(s, path, watch=True):
    """Starts Gemini's review of one edit when there is a key and none is cached. Returns its file, or None
    when nothing watches the edit."""
    if not review_on(watch) or not (gemini_key() or os.environ.get("TAKES_REVIEW_CMD")):
        return None
    try:
        if media_seconds(path) > REVIEW_MAX_S:
            return None
    except ValueError:
        return None
    p = review_file(s, path, "review.json")
    d = read_review(p)
    if d and d["state"] in ("done", "running"):
        return p
    write_review(p, {"state": "running", "pid": None, "started": now_iso()})
    spawn_detached(["--edit-review", s, os.path.relpath(path, s)])
    return p


def review_result(s, path, p, until, watch=True):
    """The review part of check_edit's answer: Gemini's problems, or what the agent does without them."""
    if not review_on(watch):
        return {"state": "off"}
    d = None
    while p:
        d = read_review(p)
        if not d or d["state"] != "running" or time.time() >= until:
            break
        time.sleep(1)
    if d and d["state"] == "done":
        return {"state": "done", "by": d.get("model"), "problems": d.get("problems", []), "cost_usd": d.get("cost_usd"),
                "note": "Gemini watched and heard the edit with the rules. Its problems are a view, not measurements: "
                        "look at the frame of each one before you fix it, and fix what is real in the next version."}
    if d and d["state"] == "running":
        return {"state": "running", "note": "Gemini is still watching the edit. Run check_edit again in about a "
                                            "minute: the built-in checks are cached, and the review is ready then."}
    if d and d.get("state") == "failed":
        why = "Gemini's review failed: %s" % d.get("error")
    elif gemini_key() or os.environ.get("TAKES_REVIEW_CMD"):
        why = "The edit is longer than %d s, so Gemini did not watch it." % REVIEW_MAX_S
    else:
        why = "Takes has no Gemini key, so nothing watched the edit."
    out = {"state": "none", "why": why}
    try:
        sheet, times = frame_sheet(s, path)
        out.update(sheet=sheet, times=times,
                   note="Watch it yourself: read the sheet (frames at these seconds, 6 a row) and check each frame "
                        "against the rules for picture, captions and graphics; check the cut against the transcript. "
                        "With a Gemini key (Takes › Settings › Gemini) Takes watches and hears each edit for about 5 cents.")
    except (ValueError, OSError, subprocess.SubprocessError) as e:
        out["note"] = "Look at stills of the edit yourself (the frame sheet failed: %s)." % str(e)[:120]
    return out


def check_file(s, rel, path, source=None, as_rel=None):
    """Every check of one file, saved in checks.json. as_rel: the edits/ path whose line of versions the
    regression check reads (a render of render_edit is not in edits/ yet)."""
    results, ctx = run_builtin(s, rel, path, source, as_rel)
    rules = [r for r in read_lessons()["rules"] if r.get("on", True) and (r.get("check") or {}).get("kind") in CHECKS]
    for r in rules:
        try:
            res = run_check(path, r["check"])
        except ValueError as e:
            res = {"pass": None, "error": str(e)}
        if res["pass"] is False:
            res = dict(res, label="Rule: " + (r["text"] if len(r["text"]) <= 30 else r["text"][:29].rstrip() + "…"),
                       say=r["text"])
        results.append(dict({"rule": r["id"], "text": r["text"]}, **res))
    failed = [x for x in results if x["pass"] is False]
    entry = {"v": 2, "at": now_iso(), "mtime": os.path.getmtime(path),
             "source": os.path.relpath(ctx["src"]["path"], s) if ctx["src"]["path"] else None,
             "known": bool(ctx["known"]), "passed": not failed, "results": results}
    save_check(s, rel, entry)
    return entry


def check_states(s):
    """get_session's checks: the check state of each edit's newest version (None without edits)."""
    d = os.path.join(s, "edits")
    if not os.path.isdir(d):
        return None
    newest = {}
    for f in os.listdir(d):
        if f.startswith(".") or f.endswith(".words.json") or not (
                media_kind(f) == "video" or os.path.splitext(f)[1].lower() in AUDIO_EXT):
            continue
        base, v, _ = split_version(f)
        if base not in newest or (v or 0) > newest[base][0]:
            newest[base] = (v or 0, f)
    if not newest:
        return None
    try:
        with open(os.path.join(s, "checks.json")) as fh:
            saved = json.load(fh)
        saved = saved if isinstance(saved, dict) else {}
    except (OSError, ValueError):
        saved = {}
    out = {}
    for base in sorted(newest):
        rel = "edits/" + newest[base][1]
        e = saved.get(rel)
        if not isinstance(e, dict) or e.get("v") != 2:
            out[rel] = {"state": "unchecked"}
        elif os.path.getmtime(os.path.join(s, rel)) > float(e.get("mtime") or 0) + 1:
            out[rel] = {"state": "stale"}
        else:
            probs = [x.get("label") or x.get("check") or "Rule" for x in e.get("results") or []
                     if isinstance(x, dict) and x.get("pass") is False]
            out[rel] = {"state": "problems", "problems": probs} if probs else {"state": "passed"}
    return out


def read_hooks(s):
    return read_hooks_file(os.path.join(s, "hooks.json"))


def read_hooks_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"hooks": [], "chosen": None}


def first_paragraph(text):
    return text.strip().split("\n\n", 1)[0].strip()


def t_set_hooks(a):
    """Hook options for the opening. The app shows them above the teleprompter to pick from."""
    s = resolve_session(a["session"])
    need_rules("script")
    hooks = write_hooks(os.path.join(s, "hooks.json"), a["hooks"])
    return {"hooks": hooks, "note": "The user picks one in the app; it replaces the first paragraph of the script."}


def write_hooks(path, given):
    hooks = []
    for i, h in enumerate(given):
        text = (h.get("text") if isinstance(h, dict) else str(h)).strip()
        if not text:
            continue
        hook = {"id": "h%d" % (i + 1), "text": text}
        if isinstance(h, dict) and h.get("note"):
            hook["note"] = h["note"].strip()
        hooks.append(hook)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump({"hooks": hooks, "chosen": None}, f, indent=2, ensure_ascii=False)
    return hooks


# ---------- the storyboard ----------
#
#   storyboard/storyboard.json   {"shots": [...], "format": "16:9", "updated": iso}
#       format: the video's shape (FORMATS); the sketches are drawn in it. Missing: 4:5, as before 2026-10-05.
#       a shot: id (s1, s2...: stays the same across set_storyboard calls, takes and comments point at it),
#               section (hook, main, end: the app shows each as its own row), kind (DESK, MG, B-ROLL, SCREEN, WALK, END...), say (the script lines it covers, word for word),
#               do (how to film or build it), sketch (what the frame shows, for the drawing), seconds (optional),
#               image (the sketch file, set when drawn), error (why it could not be drawn),
#               video (the clip or still that shows instead of the sketch: the one in the video),
#               variants (2026-10-09: every clip or still tried for the shot, in a fixed order, A B C...;
#               video is one of them. The user flips through them on the Storyboard tab and picks one)
#   storyboard/<hash>.png        one sketch per shot, named by the hash of its sketch text: a changed sketch
#                                is a new file, an unchanged one is never drawn twice.
#
# The app shows the shots as a horizontal timeline on the Storyboard tab. Sketches are drawn in the
# background (Nano Banana 2.1; GPT Image 2.5 Flare when Gemini fails; Nano Banana on Replicate when both
# fail) and land in the json one by one, so the tab fills in while you watch. storyboard/.models.json keeps
# the model that drew each sketch.
#
# No image key (2026-10-09: not every user has a Gemini key): set_storyboard saves the shots, draws nothing,
# writes "nokey": true in the json and tells the chat, so it asks the user for a key or draws the sketches
# with its own image tool and passes each as the shot's 'image'. The app shows a card with a link to
# Settings › Gemini and a Draw button, which runs the sketch runner again.

STORYBOARD_DIR = "storyboard"
# Nano Banana 2.1 (out 2026-10-06) is the cheapest of the three image models ($0.034 a 1K image) and
# draws the marker style well; GPT Image 2.5 Flare draws when Gemini fails.
SKETCH_MODELS = ("nano-banana-2.1", "flare", "replicate-nano-banana")
SKETCH_QUALITY = "low"  # marker sketches are low fidelity on purpose
SKETCH_STYLE = ("Low-fidelity film storyboard frame. Quick loose black marker sketch on plain white paper, like a "
                "director's thumbnail. Very simple lines, no shading, no color except one blue marker for motion "
                "arrows and camera moves. Simple faceless figure with a round head. Absolutely no text, no letters, "
                "no words, no numbers anywhere. Thin black rectangle border around the frame. Shot: ")


def storyboard_file(s):
    return os.path.join(s, STORYBOARD_DIR, "storyboard.json")


def read_storyboard(s):
    try:
        with open(storyboard_file(s)) as f:
            d = json.load(f)
        return d if isinstance(d.get("shots"), list) else {"shots": []}
    except (OSError, ValueError):
        return {"shots": []}


def write_storyboard(s, d):
    os.makedirs(os.path.join(s, STORYBOARD_DIR), exist_ok=True)
    d["updated"] = now_iso()
    tmp = storyboard_file(s) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    os.replace(tmp, storyboard_file(s))


# Any "W:H" shape works. These are the ones Gemini draws in; another shape is drawn in the
# nearest of them and the app fits it to the card. 4:5 was the only one before 2026-10-05.
FORMATS = ("16:9", "9:16", "4:5", "1:1", "3:4", "4:3", "2:3", "3:2", "5:4", "21:9")
DEFAULT_FORMAT = "4:5"


def parse_format(fmt):
    # "16:9", "16x9", "1920x1080" -> "16:9". Not a shape: ValueError.
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*[:x×/]\s*(\d+(?:\.\d+)?)\s*", str(fmt or ""))
    if not m or float(m.group(1)) <= 0 or float(m.group(2)) <= 0:
        raise ValueError("format is a shape such as 16:9, 9:16, 4:5 or 1:1 (any W:H works).")
    w, h = m.group(1), m.group(2)
    # Pixel sizes get reduced; a written shape stays as written (21:9, not 7:3).
    if "." not in w + h and max(int(w), int(h)) > 64:
        g = math.gcd(int(w), int(h))
        w, h = str(int(w) // g), str(int(h) // g)
    return w + ":" + h


def draw_format(fmt):
    # The Gemini shape nearest to fmt.
    w, h = (float(x) for x in fmt.split(":"))
    return min(FORMATS, key=lambda f: abs(math.log((w / h) / (float(f.split(":")[0]) / float(f.split(":")[1])))))


def sketch_name(sketch, fmt=DEFAULT_FORMAT):
    # A 4:5 sketch keeps the name it had before formats, so old sketches are not drawn again.
    key = SKETCH_STYLE + sketch + ("" if fmt == DEFAULT_FORMAT else " @" + fmt)
    return hashlib.sha1(key.encode()).hexdigest()[:12] + ".png"


SECTIONS = ("hook", "main", "end")


def shot_section(x):
    sec = (x.get("section") or "").strip().lower()
    if sec in ("hooks", "opening", "intro"):
        sec = "hook"
    if sec in ("ending", "outro", "cta"):
        sec = "end"
    if sec not in SECTIONS:
        sec = "end" if (x.get("kind") or "").strip().upper() == "END" else "main"
    return sec


def shot_ids(old, given):
    """An id per shot: the given one, else the id of the old shot with the same sketch or the same lines,
    else a new one. Takes and comments point at these ids, so a rewrite must keep them."""
    used, out = set(), []
    nums = [int(x["id"][1:]) for x in old + given if str(x.get("id", ""))[1:].isdigit()]
    nxt = max(nums or [0]) + 1
    for x in given:
        i = str(x.get("id") or "").strip()
        if not i or i in used:
            i = ""
            for o in old:
                if o.get("id") and o["id"] not in used and (
                        o.get("sketch") == (x.get("sketch") or "").strip()
                        or (x.get("say") or "").strip() and o.get("say") == (x.get("say") or "").strip()):
                    i = o["id"]
                    break
        if not i:
            i, nxt = "s%d" % nxt, nxt + 1
        used.add(i)
        out.append(i)
    return out


def storyboard_view(s):
    shots = read_storyboard(s)["shots"]
    if not shots:
        return {"shots": 0}
    takes, notes = {}, {}
    for t in read_meta(s).get("takes", []):
        if t.get("shot") and t.get("kind") == "camera":
            takes.setdefault(t["shot"], []).append(t["number"])
    for c in read_comments(s)["comments"]:
        if c.get("shot") and c.get("status") != "resolved":
            notes[c["shot"]] = notes.get(c["shot"], 0) + 1
    rows = []
    for x in shots:
        r = {"id": x.get("id"), "section": shot_section(x), "kind": x.get("kind"),
             "say": (x.get("say") or "")[:80]}
        if x.get("video"):
            r["video"] = x["video"]
        if x.get("variants"):
            r["variants"] = x["variants"]
        if x.get("generating"):
            r["generating"] = x["generating"]
        if x.get("clip_error"):
            r["clip_error"] = x["clip_error"]
        if takes.get(x.get("id")):
            r["takes"] = takes[x["id"]]
        if notes.get(x.get("id")):
            r["open_comments"] = notes[x["id"]]
        rows.append(r)
    return {"shots": len(shots), "format": read_storyboard(s).get("format") or DEFAULT_FORMAT,
            "drawn": sum(1 for x in shots if x.get("image") or x.get("video")),
            "file": storyboard_file(s), "list": rows,
            "note": "Pass each shot's id back to set_storyboard: takes and comments point at it."}


def t_set_storyboard(a):
    """Write the storyboard and draw the missing sketches in the background."""
    s = resolve_session(a["session"])
    need_rules("storyboard", "script")
    before = read_storyboard(s)
    old = before["shots"]
    fmt = (a.get("format") or before.get("format") or DEFAULT_FORMAT).strip()
    fmt = parse_format(fmt)
    shots = []
    for i, x in enumerate(a["shots"]):
        say, sketch = (x.get("say") or "").strip(), (x.get("sketch") or "").strip()
        video = shot_video(s, (x.get("video") or "").strip())
        variants = None
        if isinstance(x.get("variants"), list):
            variants = list(dict.fromkeys(shot_video(s, str(v).strip()) for v in x["variants"] if str(v).strip()))
            video = video or (variants[0] if variants else None)
            if video and video not in variants:
                variants.insert(0, video)
        given_image = (x.get("image") or "").strip()
        if not sketch and not video and not given_image:
            raise ValueError("Shot %d has no sketch: say what the frame shows." % (i + 1))
        shot = {"section": shot_section(x), "kind": (x.get("kind") or "SHOT").strip().upper(), "say": say,
                "do": (x.get("do") or "").strip(), "sketch": sketch}
        if x.get("seconds"):
            shot["seconds"] = round(float(x["seconds"]), 1)
        if video:
            # A real clip shows instead of a sketch (the app plays it on hover): nothing to draw.
            shot["video"] = video
            if variants and len(variants) > 1:
                shot["variants"] = variants
        elif given_image:
            shot["image"] = shot_image(s, given_image, sketch, fmt)
        else:
            name = sketch_name(sketch, fmt)
            if os.path.exists(os.path.join(s, STORYBOARD_DIR, name)) and not x.get("redraw"):
                shot["image"] = name
        shots.append(shot)
    olds = {o.get("id"): o for o in old}
    for shot, i, given in zip(shots, shot_ids(old, a["shots"]), a["shots"]):
        shot["id"] = i
        # Variants left out are kept while the shot still shows one of them: a rewrite of the lines
        # must not drop the angles the user is choosing between.
        o = olds.get(i) or {}
        if "variants" not in given and shot.get("video") in (o.get("variants") or []):
            shot["variants"] = o["variants"]
    # A Higgsfield clip still on its way keeps its place: the runner finds the shot by id.
    running = {o.get("id"): o["generating"] for o in old if o.get("generating")}
    for shot in shots:
        if shot["id"] in running and not shot.get("video"):
            shot["generating"] = running[shot["id"]]
    # The app shows hook, main, end in that order: keep the file in the same order.
    shots.sort(key=lambda x: SECTIONS.index(x["section"]))
    todo = sum(1 for x in shots if not x.get("image") and not x.get("video"))
    nokey = bool(todo) and not image_sources()
    write_storyboard(s, dict({"shots": shots, "format": fmt}, **({"nokey": True} if nokey else {})))
    for given in a["shots"]:
        if given.get("redraw") and not given.get("image"):
            p = os.path.join(s, STORYBOARD_DIR, sketch_name((given.get("sketch") or "").strip(), fmt))
            if os.path.exists(p):
                os.remove(p)
    gone = {o.get("id") for o in old} - {x["id"] for x in shots} - {None}
    if todo and not nokey:
        start_sketches(s)
    out = {"shots": len(shots), "format": fmt, "drawing": 0 if nokey else todo, "ids": [x["id"] for x in shots],
           "note": ("Drawing %d sketches in the background (about 30 s). The Storyboard tab fills in as they land."
                    % todo) if todo else "All sketches already drawn."}
    if nokey:
        out["no_sketches"] = todo
        out["note"] = NO_KEY_NOTE
    linked = sorted({t.get("shot") for t in read_meta(s).get("takes", [])} & gone)
    if linked:
        out["warning"] = "Shots %s are gone but takes point at them. Give their id to the shot that replaces them." % ", ".join(linked)
    return out


def shot_video(s, f):
    """A shot's clip as a path in the session. A clip from list_broll is added to the session's broll/
    first (an APFS clone); a file already in the session (broll/, edits/, a take) is used as it is."""
    if not f:
        return None
    inside = os.path.normpath(os.path.join(s, f))
    if not os.path.isabs(f) and inside.startswith(os.path.normpath(s) + os.sep) and os.path.isfile(inside):
        return os.path.relpath(inside, s)
    if os.path.isabs(f) and os.path.normpath(f).startswith(os.path.normpath(s) + os.sep) and os.path.isfile(f):
        return os.path.relpath(f, s)
    added = t_add_broll({"session": s, "files": [f]})["added"][0]
    return os.path.relpath(added, s)


NO_KEY_NOTE = ("No sketches: Takes has no image key (Gemini, OpenAI or Replicate). Ask the user for a Gemini key "
               "(Takes › Settings › Gemini; aistudio.google.com/apikey) or an OpenAI key, then call set_storyboard "
               "again or let them click Draw on the Storyboard tab. Or, if you can make images yourself, draw each "
               "sketch and pass it as the shot's 'image' (a PNG or JPG path).")


def image_sources():
    """The image services Takes can draw with right now, as names."""
    if os.environ.get("TAKES_SKETCH_CMD"):
        return ["test"]
    found = []
    if gemini_key():
        found.append("Gemini")
    if openai_key():
        found.append("OpenAI")
    if rep_key():
        found.append("Replicate")
    return found


def shot_image(s, f, sketch, fmt):
    """An image the chat made for a shot, copied into storyboard/ under the name a drawn sketch gets
    (so set_storyboard keeps it). Returns that name."""
    src = os.path.expanduser(f)
    if not os.path.isabs(src):
        src = os.path.join(s, src)
    if not os.path.isfile(src):
        raise ValueError("No image at %s." % f)
    if os.path.splitext(src)[1].lower() not in (".png", ".jpg", ".jpeg", ".webp", ".heic"):
        raise ValueError("The shot's image must be a PNG, JPG, WEBP or HEIC file: %s." % f)
    if sketch:
        name = sketch_name(sketch, fmt)
    else:
        name = hashlib.sha1(open(src, "rb").read()).hexdigest()[:12] + ".png"
    out = os.path.join(s, STORYBOARD_DIR, name)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.splitext(src)[1].lower() == ".png":
        shutil.copyfile(src, out + ".tmp")
    else:
        r = subprocess.run(["sips", "-s", "format", "png", src, "--out", out + ".tmp"], capture_output=True)
        if r.returncode != 0:
            shutil.copyfile(src, out + ".tmp")  # the app reads the file by its contents
    os.replace(out + ".tmp", out)
    note_model(s, os.path.join(STORYBOARD_DIR, name), "Made in the chat")
    return name


def start_sketches(s, retry=False):
    spawn_detached(["--sketch-run", s] + (["--retry"] if retry else []))


def sketch_run(s, retry=False):
    """Draw every shot without an image. Runs detached; one runner per session at a time.
    retry: shots that failed before are drawn again (the app's Draw button)."""
    import fcntl
    import threading
    from concurrent.futures import ThreadPoolExecutor
    os.makedirs(os.path.join(s, STORYBOARD_DIR), exist_ok=True)
    lock = open(os.path.join(s, STORYBOARD_DIR, ".drawing"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return  # another runner draws; it re-reads the storyboard before it stops
    mu = threading.Lock()
    d = read_storyboard(s)
    nokey = not image_sources()
    if retry and not nokey:
        for x in d["shots"]:
            x.pop("error", None)
    if nokey or d.pop("nokey", None) or retry:
        if nokey:
            d["nokey"] = True
        write_storyboard(s, d)
    if nokey:
        return

    def land(sketch, image=None, error=None):
        with mu:
            d = read_storyboard(s)
            for x in d["shots"]:
                if x.get("sketch") == sketch:
                    x.pop("error", None)
                    if image:
                        x["image"] = image
                    if error:
                        x["error"] = error
            write_storyboard(s, d)

    def draw(sketch):
        fmt = read_storyboard(s).get("format") or DEFAULT_FORMAT
        name = sketch_name(sketch, fmt)
        out = os.path.join(s, STORYBOARD_DIR, name)
        try:
            model = None
            if not os.path.exists(out):
                model = draw_sketch(SKETCH_STYLE + sketch, out, fmt)
            if model:
                with mu:
                    note_model(s, os.path.join(STORYBOARD_DIR, name), model)
            land(sketch, image=name)
        except Exception as e:
            land(sketch, error=str(e)[:300])

    tried = set()
    while True:
        todo = []
        for x in read_storyboard(s)["shots"]:
            k = x.get("sketch")
            if k and not x.get("image") and not x.get("video") and k not in tried and k not in todo:
                todo.append(k)
        if not todo:
            return
        tried.update(todo)
        with ThreadPoolExecutor(5) as ex:
            list(ex.map(draw, todo))


def draw_sketch(prompt, out, fmt=DEFAULT_FORMAT):
    """Draw one sketch; returns the name of the model that drew it."""
    if os.environ.get("TAKES_SKETCH_CMD"):  # tests: a stand-in that writes the PNG
        r = subprocess.run(json.loads(os.environ["TAKES_SKETCH_CMD"]) + [out], capture_output=True, text=True)
        if r.returncode != 0:
            raise ValueError(r.stderr.strip() or "The sketch failed.")
        return None
    # Not in SKETCH_STYLE, so sketch names (and drawn sketches) stay the same. Without it, Nano Banana
    # drew a small landscape box inside a 9:16 image (2026-10-06).
    prompt += " The border runs along the edges of the image: the whole %s image is the frame." % fmt
    return draw_image(prompt, out, fmt, quality=SKETCH_QUALITY, models=SKETCH_MODELS)


def draw_gemini(prompt, out, fmt, model, images=(), size="1K"):
    import base64
    import urllib.request
    key = gemini_key()
    if not key:
        raise ValueError("No Gemini key. Add one in Takes › Settings › Gemini.")
    parts = [{"text": prompt}]
    for f in images:
        mime = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}.get(
            os.path.splitext(f)[1].lower(), "image/png")
        parts.append({"inlineData": {"mimeType": mime, "data": base64.b64encode(open(f, "rb").read()).decode()}})
    image_config = {"imageSize": size}
    if fmt:
        image_config["aspectRatio"] = draw_format(fmt)
    body = {"contents": [{"parts": parts}],
            "generationConfig": {"responseModalities": ["IMAGE"], "imageConfig": image_config}}
    req = urllib.request.Request(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % model,
        method="POST", data=json.dumps(body).encode(),
        headers={"x-goog-api-key": key, "Content-Type": "application/json"})
    try:
        res = json.load(urllib.request.urlopen(req, timeout=180))
    except urllib.error.HTTPError as e:
        raise ValueError("Gemini said %s: %s" % (e.code, e.read().decode(errors="replace")[:200]))
    except urllib.error.URLError as e:
        raise ValueError("Gemini did not answer: %s" % e.reason)
    for p in res.get("candidates", [{}])[0].get("content", {}).get("parts", []):
        data = (p.get("inlineData") or p.get("inline_data") or {}).get("data")
        if data:
            with open(out + ".tmp", "wb") as f:
                f.write(base64.b64decode(data))
            os.replace(out + ".tmp", out)
            return
    raise ValueError("Gemini returned no image.")


# ---------- Images: Nano Banana 2.1, GPT Image 2.5 Flare and Sunburst (2026-10-06) ----------
#
# Every image Takes makes (sketches, make_image) goes straight to Google or OpenAI: much cheaper than a
# Higgsfield image. Higgsfield is for video only. The user picked these three as the defaults:
#   nano-banana-2.1  cheapest and fast: sketches; at 4K the sharpest, for the final
#   flare            fast, high quality: a new image
#   sunburst         best quality and editing: a change to an image
# Drafts first, final last (2026-10-09): GPT Image draws while the user finds the direction (fast, but
# 1536 px at most and soft up close). When he likes one, make_image from=<draft> redraws it with Nano
# Banana 2.1 at 4K (5504x3072), the draft and its references as the guide.
# When one fails (no key, no credit), the next one draws. Each file's model goes in .models.json in its
# folder (generated/, storyboard/), and the app shows it.

IMAGE_MODELS = {
    "nano-banana-2.1": ("gemini", "gemini-nano-banana-2.1", "Nano Banana 2.1"),
    "flare": ("openai", "gpt-image-2.5-flare", "GPT Image 2.5 Flare"),
    "sunburst": ("openai", "gpt-image-2.5-sunburst", "GPT Image 2.5 Sunburst"),
    # For a user with only a Replicate token (the Replicate plugin): the last sketch fallback.
    "replicate-nano-banana": ("replicate", "google/nano-banana", "Nano Banana · Replicate"),
}
IMAGE_MODEL = "gpt-image-2.5-flare"
FINAL_MODELS = ("nano-banana-2.1", "sunburst")
FINAL_SIZE = "4K"
FINAL_ASK = ("Redraw the first image as the finished, full-quality picture: keep its composition, framing, "
             "people, faces, clothes, light and look exactly, and make it sharp and detailed.")


def draw_image(prompt, out, fmt=None, images=(), quality="medium", models=("flare",), size=None):
    """Draw with the first model that works; returns its name ("Nano Banana 2.1"). size: Gemini's (4K)."""
    problems = []
    for m in models:
        api, model_id, label = IMAGE_MODELS[m]
        try:
            if api == "openai":
                openai_image(prompt, out, fmt, images=images, quality=quality, model=model_id)
            elif api == "replicate":
                replicate_image(prompt, out, fmt, model_id)
            else:
                draw_gemini(prompt, out, fmt, model_id, images=images, size=size or ("2K" if quality == "high" else "1K"))
            return label
        except ValueError as e:
            problems.append("%s: %s" % (label, e))
    raise ValueError(" ".join(problems))


def replicate_image(prompt, out, fmt, model):
    """Draw one image with a Replicate model (Nano Banana: prompt, aspect_ratio, output_format)."""
    import time
    if os.environ.get("TAKES_IMAGE_CMD"):  # tests: the same stand-in as GPT Image, never the real API
        r = subprocess.run(json.loads(os.environ["TAKES_IMAGE_CMD"]) + [out, prompt], capture_output=True, text=True)
        if r.returncode != 0:
            raise ValueError(r.stderr.strip() or "The image failed.")
        return
    if not rep_key():
        raise ValueError("No Replicate API token.")
    inp = {"prompt": prompt, "output_format": "png"}
    if fmt:
        inp["aspect_ratio"] = draw_format(fmt)
    p = rep_http("POST", "/models/%s/predictions" % model, {"input": inp})
    deadline = time.time() + 5 * 60
    while p.get("status") not in ("succeeded", "failed", "canceled"):
        if time.time() > deadline:
            raise ValueError("Replicate did not finish in 5 min.")
        time.sleep(2)
        p = rep_http("GET", (p.get("urls") or {}).get("get") or "/predictions/" + p["id"])
    if p["status"] != "succeeded":
        raise ValueError("Replicate: %s" % (p.get("error") or p["status"]))
    url = rep_output_url(p.get("output"))
    if not url:
        raise ValueError("Replicate gave no image.")
    rep_download(url, out)


def note_model(s, rel, label):
    """Record which model made a file: <its folder>/.models.json maps file name -> model, for the app."""
    p = os.path.join(s, os.path.dirname(rel), ".models.json")
    try:
        d = json.load(open(p))
    except (OSError, ValueError):
        d = {}
    d[os.path.basename(rel)] = label
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    os.replace(p + ".tmp", p)


def note_prompt(s, rel, prompt, images, fmt):
    """Keep how make_image drew a file (<folder>/.prompts.json), so its final can redraw it the same way."""
    p = os.path.join(s, os.path.dirname(rel), ".prompts.json")
    try:
        d = json.load(open(p))
    except (OSError, ValueError):
        d = {}
    d[os.path.basename(rel)] = {"prompt": prompt, "images": images, "format": fmt}
    with open(p + ".tmp", "w") as f:
        json.dump(d, f, indent=2)
    os.replace(p + ".tmp", p)


def drawn_with(s, rel):
    try:
        return json.load(open(os.path.join(s, os.path.dirname(rel), ".prompts.json"))).get(os.path.basename(rel)) or {}
    except (OSError, ValueError):
        return {}


def image_format(f):
    """An image's shape (16:9), read from its PNG or JPEG header; None when it cannot tell."""
    try:
        import struct
        b = open(f, "rb").read(64 * 1024)
        if b[:8] == b"\x89PNG\r\n\x1a\n":
            w, h = struct.unpack(">II", b[16:24])
            return parse_format("%d:%d" % (w, h))
        i = 2
        while i < len(b) - 9 and b[:2] == b"\xff\xd8":
            if b[i] != 0xFF:
                break
            m, n = b[i + 1], struct.unpack(">H", b[i + 2:i + 4])[0]
            if m in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", b[i + 5:i + 9])
                return parse_format("%d:%d" % (w, h))
            i += 2 + n
    except (OSError, ValueError, struct.error):
        pass
    return None


IMAGE_SIZES = ("1024x1024", "1536x1024", "1024x1536")  # the sizes every GPT Image takes


def openai_key():
    if os.environ.get("OPENAI_API_KEY"):
        return os.environ["OPENAI_API_KEY"]
    try:
        for line in open(os.path.expanduser("~/.claude/.env")):
            k, _, v = line.strip().partition("=")
            if k.strip().removeprefix("export ").strip() == "OPENAI_API_KEY":
                return v.strip().strip('"').strip("'") or None
    except OSError:
        pass
    return None


def openai_size(fmt):
    """fmt as a size GPT Image draws: long edge 1536, both edges multiples of 16, at most 3:1."""
    w, h = (float(x) for x in parse_format(fmt or DEFAULT_FORMAT).split(":"))
    r = max(1 / 3, min(3, w / h))
    if r >= 1:
        W, H = 1536, 1536 / r
    else:
        W, H = 1536 * r, 1536
    return "%dx%d" % (max(16, round(W / 16) * 16), max(16, round(H / 16) * 16))


def nearest_size(size):
    w, h = (int(x) for x in size.split("x"))
    return min(IMAGE_SIZES, key=lambda s: abs(math.log((w / h) / (int(s.split("x")[0]) / int(s.split("x")[1])))))


def openai_image(prompt, out, fmt=None, images=(), quality="medium", model=IMAGE_MODEL):
    """Draw (or, with images, change) one image with GPT Image and write it to out as PNG."""
    if os.environ.get("TAKES_IMAGE_CMD"):  # tests: a stand-in that writes the PNG
        r = subprocess.run(json.loads(os.environ["TAKES_IMAGE_CMD"]) + [out, prompt] + list(images),
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise ValueError(r.stderr.strip() or "The image failed.")
        return
    import base64
    import urllib.request
    import uuid
    key = openai_key()
    if not key:
        raise ValueError("No OPENAI_API_KEY in ~/.claude/.env.")
    size = openai_size(fmt) if fmt else "auto"

    def call(size):
        fields = {"model": model, "prompt": prompt, "size": size, "quality": quality, "n": "1"}
        if not images:
            req = urllib.request.Request("https://api.openai.com/v1/images/generations", method="POST",
                                         data=json.dumps(dict(fields, n=1)).encode(),
                                         headers={"Content-Type": "application/json"})
        else:  # multipart: one image[] part per input
            b = uuid.uuid4().hex
            parts = [b'--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'
                     % (b.encode(), k.encode(), str(v).encode()) for k, v in fields.items()]
            for f in images:
                mime = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}.get(
                    os.path.splitext(f)[1].lower(), "image/png")
                parts.append(b'--%s\r\nContent-Disposition: form-data; name="image[]"; filename="%s"\r\n'
                             b'Content-Type: %s\r\n\r\n' % (b.encode(), os.path.basename(f).encode(), mime.encode())
                             + open(f, "rb").read() + b"\r\n")
            req = urllib.request.Request("https://api.openai.com/v1/images/edits", method="POST",
                                         data=b"".join(parts) + b"--%s--\r\n" % b.encode(),
                                         headers={"Content-Type": "multipart/form-data; boundary=" + b})
        req.add_header("Authorization", "Bearer " + key)
        return json.load(urllib.request.urlopen(req, timeout=300))

    try:
        try:
            res = call(size)
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            if e.code != 400 or "size" not in body.lower() or size in IMAGE_SIZES + ("auto",):
                raise ValueError("OpenAI said %s: %s" % (e.code, openai_problem(body)))
            res = call(nearest_size(size))  # this model takes only the fixed sizes
    except urllib.error.HTTPError as e:
        raise ValueError("OpenAI said %s: %s" % (e.code, openai_problem(e.read().decode(errors="replace"))))
    except urllib.error.URLError as e:
        raise ValueError("OpenAI did not answer: %s" % e.reason)
    data = ((res.get("data") or [{}])[0]).get("b64_json")
    if not data:
        raise ValueError("OpenAI returned no image.")
    with open(out + ".tmp", "wb") as f:
        f.write(base64.b64decode(data))
    os.replace(out + ".tmp", out)


def openai_problem(body):
    try:
        msg = json.loads(body)["error"]["message"]
    except (ValueError, KeyError, TypeError):
        msg = body
    return msg.strip()[:200]


def t_make_image(a):
    """Make or change an image (Flare new, Sunburst for a change), or the final of a draft (from=, Nano
    Banana 2.1 at 4K); it lands in generated/<name>-vN.png."""
    s = resolve_session(a["session"])
    prompt = (a.get("prompt") or "").strip()
    src = (a.get("from") or "").strip()
    final = bool(a.get("final")) or bool(src)
    if not prompt and not src:
        raise ValueError("Give a prompt: what the image shows, or what to change.")
    refs = a.get("images") or ([a["image"]] if a.get("image") else [])
    if isinstance(refs, str):
        refs = [refs]
    fmt = (a.get("format") or "").strip() or None
    name = a.get("name")
    if src:
        # The final of a draft: the draft first, then what it was drawn from, same prompt and shape.
        f = session_file(s, src)
        if media_kind(f) != "image":
            raise ValueError("from= is an image of this session (the draft to finish).")
        src = os.path.relpath(f, s)
        was = drawn_with(s, src)
        refs = [src] + [r for r in (was.get("images") or []) + refs if r != src]
        prompt = " ".join(x for x in (FINAL_ASK, was.get("prompt") or "", prompt) if x)
        fmt = fmt or was.get("format") or image_format(f)
        name = name or re.sub(r"-v\d+$", "", os.path.splitext(os.path.basename(src))[0])
    board = read_storyboard(s)
    paths, kept = [], []
    for ref in refs[:16]:
        if ref == "sketch":
            shot = next((x for x in board["shots"] if x.get("id") == a.get("shot")), None)
            if not shot or not shot.get("image"):
                raise ValueError("'sketch' needs shot=<id> whose sketch is drawn.")
            paths.append(os.path.join(s, STORYBOARD_DIR, shot["image"]))
            kept.append(os.path.relpath(paths[-1], s))
            continue
        f = session_file(s, ref)
        if media_kind(f) != "image":
            raise ValueError("%s is not an image." % ref)
        paths.append(f)
        kept.append(os.path.relpath(f, s))
    fmt = fmt or (None if paths else "1:1")
    quality = (a.get("quality") or ("high" if final else "medium")).strip().lower()
    if quality not in ("low", "medium", "high"):
        raise ValueError("quality is low, medium or high.")
    name = slug(name or " ".join(prompt.split()[:5])) or "image"
    d = os.path.join(s, GENERATED_DIR)
    os.makedirs(d, exist_ok=True)
    have = versions_in(d, name)
    rel = os.path.join(GENERATED_DIR, "%s-v%d.png" % (name, (have[-1] if have else 0) + 1))
    if final:
        order, size = list(FINAL_MODELS), FINAL_SIZE
    else:
        first = (a.get("model") or ("sunburst" if paths else "flare")).strip().lower()
        if first not in IMAGE_MODELS:
            raise ValueError("model is nano-banana-2.1, flare or sunburst.")
        order, size = [first] + [m for m in ("flare", "nano-banana-2.1") if m != first], None
    label = draw_image(prompt, os.path.join(s, rel), fmt, images=paths, quality=quality, models=order, size=size)
    note_model(s, rel, label)
    if not src:
        note_prompt(s, rel, prompt, kept, fmt)
    else:
        note_prompt(s, rel, drawn_with(s, src).get("prompt") or prompt, kept[1:], fmt)
    out = {"file": rel, "model": label, "note": "Shows on the Assets tab with the model's name. Look at it before you reply."}
    if final:
        out["final"] = True
    elif label.startswith("GPT Image"):
        out["note"] += (" This is a draft (GPT Image, 1536 px). When the user likes the direction, make the final "
                        "with from=%s: Nano Banana 2.1 at 4K." % rel)
    return out


# ---------- ElevenLabs: voice-over, fixed words, other voices (2026-10-06) ----------
#
# The user's voice clone (or any voice of his ElevenLabs account) reads a script, says new words into a
# take, or replaces the voice of a clip. The key sits in the macOS Keychain (Takes › Settings ›
# Voices saves it there), else ELEVENLABS_API_KEY. The default voice is in <root>/_library/voices.json.
# New files land in <session>/generated/ with the voice's name in .models.json, so the Assets tab shows
# which voice made them.

ELEVEN_API = "https://api.elevenlabs.io"
ELEVEN_TTS_MODEL = "eleven_multilingual_v2"
ELEVEN_STS_MODEL = "eleven_multilingual_sts_v2"
ELEVEN_STT_MODEL = "scribe_v1"
ELEVEN_KEYCHAIN = "Takes ElevenLabs"
ELEVEN_SETUP = "Open Takes › Plugins › Voices and paste your ElevenLabs API key."
ELEVEN_CHUNK = 2500  # characters per text-to-speech call; neighbours go along as previous/next text
ELEVEN_FIT = (0.8, 1.25)  # how far fix_words may speed up or slow down new words to fit the old slot


def eleven_key():
    for k in ("ELEVENLABS_API_KEY", "ELEVEN_API_KEY"):
        if os.environ.get(k):
            return os.environ[k]
    if not os.environ.get("TAKES_NO_KEYCHAIN"):
        try:
            r = subprocess.run(["security", "find-generic-password", "-s", ELEVEN_KEYCHAIN, "-a", "api-key", "-w"],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
    try:
        for line in open(os.path.expanduser("~/.claude/.env")):
            k, _, v = line.strip().partition("=")
            if k.strip().removeprefix("export ").strip() == "ELEVENLABS_API_KEY":
                return v.strip().strip('"').strip("'") or None
    except OSError:
        pass
    return None


def eleven_save_key(key):
    """Keep the key in the login Keychain through the security tool, which then reads it without asking.
    The key goes on security's stdin, never in its arguments."""
    key = key.strip()
    if not key:
        cmd = 'delete-generic-password -s "%s" -a api-key\n' % ELEVEN_KEYCHAIN
    else:
        if not re.fullmatch(r"[A-Za-z0-9_\-]{10,200}", key):
            raise ValueError("That does not look like an ElevenLabs API key.")
        cmd = 'add-generic-password -U -s "%s" -a api-key -w "%s"\n' % (ELEVEN_KEYCHAIN, key)
    r = subprocess.run(["security", "-i"], input=cmd, capture_output=True, text=True, timeout=20)
    if key and r.returncode != 0:
        raise ValueError("The Keychain did not take the key.")


def eleven_problem(code, body):
    try:
        d = json.loads(body).get("detail")
        msg = d.get("message") or d.get("status") if isinstance(d, dict) else d if isinstance(d, str) else body
    except (ValueError, AttributeError):
        msg = body
    msg = str(msg).strip()[:240]
    if code == 401:
        return "ElevenLabs did not take the API key (%s). %s" % (msg, ELEVEN_SETUP)
    return "ElevenLabs said %s: %s" % (code, msg)


def eleven_http(method, path, body=None, files=None, query=None, raw=False):
    """One ElevenLabs call. body: a JSON dict, or with files (field -> path) a multipart form.
    raw=True returns the bytes (audio), else the parsed JSON."""
    import urllib.request
    import uuid
    key = eleven_key()
    if not key:
        raise ValueError("No ElevenLabs API key. " + ELEVEN_SETUP)
    url = ELEVEN_API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    headers = {"xi-api-key": key}
    data = None
    if files:
        b = uuid.uuid4().hex
        parts = [b'--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'
                 % (b.encode(), k.encode(), (json.dumps(v) if isinstance(v, (dict, list)) else
                                             str(v).lower() if isinstance(v, bool) else str(v)).encode())
                 for k, v in (body or {}).items() if v is not None]
        for field, f in files.items():
            parts.append(b'--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\n'
                         b'Content-Type: application/octet-stream\r\n\r\n' % (b.encode(), field.encode(),
                                                                             os.path.basename(f).encode())
                         + open(f, "rb").read() + b"\r\n")
        data = b"".join(parts) + b"--%s--\r\n" % b.encode()
        headers["Content-Type"] = "multipart/form-data; boundary=" + b
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            out = r.read()
    except urllib.error.HTTPError as e:
        raise ValueError(eleven_problem(e.code, e.read().decode(errors="replace")))
    except urllib.error.URLError as e:
        raise ValueError("ElevenLabs did not answer: %s" % e.reason)
    return out if raw else json.loads(out or b"{}")


def eleven_audio(path, body=None, files=None, query=None):
    """Audio bytes, in the best MP3 the plan gives (192 kbps needs Creator, else 128)."""
    last = None
    for fmt in ("mp3_44100_192", "mp3_44100_128"):
        try:
            return eleven_http("POST", path, body, files, dict(query or {}, output_format=fmt), raw=True)
        except ValueError as e:
            last = e
            if "192" not in str(e) and "format" not in str(e).lower() and "tier" not in str(e).lower():
                raise
    raise last


# Voices

def voices_config_path():
    return os.path.join(root(), LIB, "voices.json")


def read_voices_config():
    try:
        with open(voices_config_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def write_voices_config(cfg):
    p = voices_config_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
    os.replace(p + ".tmp", p)


def eleven_voices():
    """The voices of the account: own clones, designed voices, saved library voices, the premade ones."""
    out, token = [], None
    for _ in range(5):
        q = {"page_size": 100}
        if token:
            q["next_page_token"] = token
        res = eleven_http("GET", "/v2/voices", query=q)
        for v in res.get("voices") or []:
            out.append({"id": v.get("voice_id"), "name": v.get("name"), "category": v.get("category"),
                        "description": (v.get("description") or "")[:160] or None,
                        "labels": v.get("labels") or {}, "preview": v.get("preview_url")})
        token = res.get("next_page_token")
        if not res.get("has_more") or not token:
            break
    return out


def pick_voice(voices, ref):
    """A voice by id, by full name, or by the start of its name ('The user' finds 'The user PVC')."""
    ref = ref.strip()
    low = ref.casefold()
    for test in (lambda v: v["id"] == ref, lambda v: (v["name"] or "").casefold() == low,
                 lambda v: (v["name"] or "").casefold().startswith(low),
                 lambda v: low in (v["name"] or "").casefold()):
        hits = [v for v in voices if test(v)]
        if hits:
            return hits[0]
    return None


def resolve_voice(ref):
    """(voice_id, name): the asked voice, else the default from Plugins › Voices."""
    if not ref:
        d = read_voices_config().get("default")
        if d and d.get("id"):
            return d["id"], d.get("name") or d["id"]
        raise ValueError("No default voice yet. Pick one in Takes › Plugins › Voices, or pass voice.")
    voices = eleven_voices()
    v = pick_voice(voices, ref)
    if not v:
        names = ", ".join(sorted(x["name"] for x in voices if x.get("name"))[:30])
        raise ValueError("No voice '%s' in the ElevenLabs account. Voices: %s. Find more with voices search=..."
                         % (ref, names))
    return v["id"], v["name"]


def eleven_account():
    try:
        sub = eleven_http("GET", "/v1/user/subscription")
    except ValueError as e:
        return {"error": str(e)}
    used, limit = sub.get("character_count") or 0, sub.get("character_limit") or 0
    return {"plan": sub.get("tier"), "characters_left": max(0, limit - used), "characters_per_month": limit,
            "voice_slots": "%s of %s" % (sub.get("voice_slots_used"), sub.get("voice_limit"))}


def t_voices(a):
    """List, search, add and pick voices."""
    if a.get("add"):
        owner, _, vid = str(a["add"]).partition("/")
        if not vid:
            raise ValueError("add is '<public_owner_id>/<voice_id>' from voices search.")
        name = (a.get("name") or "").strip() or "Library voice"
        res = eleven_http("POST", "/v1/voices/add/%s/%s" % (owner, vid), {"new_name": name})
        out = {"added": {"id": res.get("voice_id"), "name": name}}
        if a.get("set_default"):
            write_voices_config(dict(read_voices_config(), default={"id": res.get("voice_id"), "name": name}))
            out["default"] = out["added"]
        return out
    if a.get("set_default"):
        vid, name = resolve_voice(a["set_default"])
        write_voices_config(dict(read_voices_config(), default={"id": vid, "name": name}))
        return {"default": {"id": vid, "name": name}}
    out = {"default": read_voices_config().get("default"), "account": eleven_account()}
    if "error" in out["account"]:
        return out
    if a.get("search") is not None:
        q = {"page_size": 12, "search": a["search"]}
        for k in ("gender", "accent", "language", "age", "use_case"):
            if a.get(k):
                q[k] = a[k]
        res = eleven_http("GET", "/v1/shared-voices", query=q)
        out["library"] = [{"add": "%s/%s" % (v.get("public_owner_id"), v.get("voice_id")), "name": v.get("name"),
                           "accent": v.get("accent"), "gender": v.get("gender"), "age": v.get("age"),
                           "use_case": v.get("use_case"), "description": (v.get("description") or "")[:160] or None,
                           "preview": v.get("preview_url")} for v in res.get("voices") or []]
        out["note"] = "Add one with voices add=<add> name=<name>; then use its name as voice."
    else:
        out["mine"] = eleven_voices()
    return out


def t_design_voice(a):
    """Design a voice from a description (three samples), or save one sample as a voice."""
    if a.get("save"):
        name = (a.get("name") or "").strip()
        if not name:
            raise ValueError("Give the new voice a name.")
        res = eleven_http("POST", "/v1/text-to-voice", {
            "voice_name": name, "voice_description": (a.get("description") or name)[:1000],
            "generated_voice_id": a["save"]})
        out = {"saved": {"id": res.get("voice_id"), "name": name}}
        if a.get("set_default"):
            write_voices_config(dict(read_voices_config(), default=out["saved"]))
            out["default"] = out["saved"]
        return out
    desc = (a.get("description") or "").strip()
    if len(desc) < 20:
        raise ValueError("Describe the voice in at least 20 characters: age, accent, tone, pace.")
    body = {"voice_description": desc[:1000]}
    text = (a.get("text") or "").strip()
    if len(text) >= 100:
        body["text"] = text[:1000]
    else:
        body["auto_generate_text"] = True
    res = eleven_http("POST", "/v1/text-to-voice/design", body)
    s = resolve_session(a["session"]) if a.get("session") else None
    d = os.path.join(s, GENERATED_DIR) if s else os.path.join(root(), LIB, "voices")
    os.makedirs(d, exist_ok=True)
    import base64
    base = "voice-" + (slug(a.get("name") or " ".join(desc.split()[:4])) or "design")
    samples = []
    for i, p in enumerate(res.get("previews") or []):
        f = os.path.join(d, "%s-%d.mp3" % (base, i + 1))
        with open(f, "wb") as fh:
            fh.write(base64.b64decode(p.get("audio_base_64") or ""))
        if s:
            note_model(s, os.path.relpath(f, s), "ElevenLabs voice design")
        samples.append({"save": p.get("generated_voice_id"), "file": os.path.relpath(f, s) if s else f})
    return {"samples": samples, "note": "The user listens on the Assets tab. Save the pick with design_voice "
                                        "save=<save> name=<name>."}


# Audio

def need_ffmpeg():
    ffmpeg = find_tool("ffmpeg")
    if not ffmpeg:
        raise ValueError("ffmpeg is not installed. Open Takes and click Finish setup, or run brew install ffmpeg.")
    return ffmpeg


def ff(*args):
    r = subprocess.run([need_ffmpeg(), "-v", "error", "-y"] + [str(x) for x in args],
                       capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        raise ValueError("ffmpeg: " + ((r.stderr or "").strip().splitlines() or ["failed"])[-1])


def mean_db(path, start=None, end=None):
    """Mean loudness in dB (ffmpeg volumedetect) of path, or of start..end in it."""
    cut = []
    if start is not None:
        cut = ["-ss", "%.3f" % max(0, start), "-to", "%.3f" % end]
    r = subprocess.run([need_ffmpeg(), "-v", "info", "-nostats"] + cut + ["-i", path, "-af", "volumedetect",
                                                                          "-f", "null", "-"],
                       capture_output=True, text=True, timeout=300)
    m = re.search(r"mean_volume:\s*(-?[\d.]+) dB", r.stderr or "")
    return float(m.group(1)) if m else None


def to_wav(src, out, extra=()):
    """48 kHz mono float WAV, like the voice cleanup writes."""
    ff("-i", src, *extra, "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", out)


def next_generated(s, name, ext):
    d = os.path.join(s, GENERATED_DIR)
    os.makedirs(d, exist_ok=True)
    have = versions_in(d, name)
    return os.path.join(GENERATED_DIR, "%s-v%d%s" % (name, (have[-1] if have else 0) + 1, ext))


def chunks(text, size=ELEVEN_CHUNK):
    """Paragraphs packed into calls of at most size characters (a long paragraph splits at sentences)."""
    out, cur = [], ""
    for para in [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]:
        pieces = [para] if len(para) <= size else re.split(r"(?<=[.!?])\s+", para)
        for piece in pieces:
            if cur and len(cur) + len(piece) + 2 > size:
                out.append(cur)
                cur = ""
            cur = (cur + ("\n\n" if cur else "") + piece)
    if cur:
        out.append(cur)
    return out


def tts(text, voice_id, out, model=None, settings=None, before="", after=""):
    body = {"text": text, "model_id": model or ELEVEN_TTS_MODEL}
    if before:
        body["previous_text"] = before[-1000:]
    if after:
        body["next_text"] = after[:1000]
    if settings:
        body["voice_settings"] = settings
    with open(out, "wb") as f:
        f.write(eleven_audio("/v1/text-to-speech/%s" % voice_id, body))


def voice_settings(a):
    s = {k: float(a[k]) for k in ("stability", "similarity", "style", "speed") if a.get(k) is not None}
    if "similarity" in s:
        s["similarity_boost"] = s.pop("similarity")
    return s or None


def t_voiceover(a):
    """Read text (or the session's script.md) in a voice; a WAV at -14 LUFS in generated/."""
    s = resolve_session(a["session"])
    text = (a.get("text") or "").strip() or read_text(os.path.join(s, "script.md")).strip()
    if not text:
        raise ValueError("Give text, or write script.md first.")
    vid, vname = resolve_voice(a.get("voice"))
    name = slug(a.get("name") or "voiceover-" + vname) or "voiceover"
    rel = next_generated(s, name, ".wav")
    parts = chunks(text)
    with tempfile.TemporaryDirectory() as tmp:
        files = []
        for i, p in enumerate(parts):
            f = os.path.join(tmp, "%03d.mp3" % i)
            tts(p, vid, f, a.get("model"), voice_settings(a),
                before=parts[i - 1] if i else "", after=parts[i + 1] if i + 1 < len(parts) else "")
            files.append(f)
        lst = os.path.join(tmp, "list.txt")
        with open(lst, "w") as fh:
            fh.write("".join("file '%s'\n" % f for f in files))
        ff("-f", "concat", "-safe", "0", "-i", lst, "-af", "loudnorm=I=-14:TP=-1.5:LRA=11", "-ac", "1",
           "-ar", "48000", "-c:a", "pcm_f32le", os.path.join(s, rel))
    note_model(s, rel, "ElevenLabs · " + vname)
    return {"file": rel, "voice": vname, "seconds": media_duration(os.path.join(s, rel)), "characters": len(text),
            "note": "On the Assets tab with the voice's name. -14 LUFS, 48 kHz mono."}


# Words in a take

def norm_word(w):
    return re.sub(r"[^\w']+", "", unicodedata.normalize("NFC", w).casefold())


def find_words(words, old, near=None):
    """(first, last) index of the words that say old, the match nearest to near seconds."""
    want = [norm_word(w) for w in old.split() if norm_word(w)]
    have = [norm_word(t) for _, _, t in words]
    hits = [i for i in range(len(have) - len(want) + 1) if want and have[i:i + len(want)] == want]
    if not hits:
        raise ValueError("The take never says '%s'. Copy the words from the transcript (get_comments quotes "
                         "it), or pass start and end in seconds." % old)
    i = min(hits, key=lambda i: abs(words[i][0] - near)) if near is not None else hits[0]
    return i, i + len(want) - 1, len(hits)


def eleven_transcribe(src):
    """Word times from ElevenLabs Scribe, saved as <stem>.words.json next to the file."""
    with tempfile.TemporaryDirectory() as tmp:
        mp3 = os.path.join(tmp, "a.mp3")
        extract_voice(src, mp3, rate=16000, codec="libmp3lame", extra=("-b:a", "64k"))
        res = eleven_http("POST", "/v1/speech-to-text", {"model_id": ELEVEN_STT_MODEL,
                                                          "timestamps_granularity": "word"}, files={"file": mp3})
    words = [{"word": w.get("text", "").strip(), "start": w.get("start"), "end": w.get("end")}
             for w in res.get("words") or [] if w.get("type", "word") == "word" and w.get("text", "").strip()]
    with open(os.path.splitext(src)[0] + ".words.json", "w") as f:
        json.dump({"words": words, "source": "elevenlabs " + ELEVEN_STT_MODEL}, f)
    return transcript_words(src)


def voice_source(s, src):
    """The audio edits use for this file: the take's cleaned voice when it is done, else the file itself."""
    t = next((t for t in read_meta(s).get("takes", []) if os.path.join(s, t["file"]) == src), None)
    if t:
        v = read_voice(s, voice_key(t["number"], t["kind"]))
        f = voice_files(s, voice_key(t["number"], t["kind"]))["mix"]
        if v and v.get("state") == "done" and v.get("on", True) and os.path.exists(f):
            return f, True
    return src, False


def splice(base, piece, start, end, out, length):
    """base with start..end replaced by piece (length seconds), 10 ms fades at both seams."""
    ff("-i", base, "-i", piece, "-filter_complex",
       "[0:a]atrim=0:%.4f,asetpts=N/SR/TB,afade=t=out:st=%.4f:d=0.01[a];"
       "[1:a]aresample=48000,pan=mono|c0=c0,apad,atrim=0:%.4f,asetpts=N/SR/TB,"
       "afade=t=in:d=0.01,afade=t=out:st=%.4f:d=0.01[b];"
       "[0:a]atrim=start=%.4f,asetpts=N/SR/TB,afade=t=in:d=0.01[c];"
       "[a][b][c]concat=n=3:v=0:a=1[o]" % (start, max(0, start - 0.01), length, max(0, length - 0.01), end),
       "-map", "[o]", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", out)


def with_audio(video, wav, out, delay_s=0.0):
    """video with wav as its sound. delay_s: the WAV starts that late after frame 0 (an old voice WAV,
    see voice_offset)."""
    delay = ["-af", "adelay=%d:all=1" % round(delay_s * 1000)] if delay_s and delay_s > 0.0005 else []
    ff("-i", video, "-i", wav, "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", *delay, "-c:a", "aac", "-b:a", "256k",
       "-shortest", "-movflags", "+faststart", out)


def base_offset(s, src, cleaned):
    """Where second 0 of an audio base for splice sits on the take's video clock: a cleaned voice WAV
    starts voice_offset late; the take's own sound comes out of splice from its first sample."""
    t = next((t for t in read_meta(s).get("takes", []) if os.path.join(s, t["file"]) == src), None)
    if not t:
        return 0.0
    if cleaned:
        return voice_offset(s, voice_key(t["number"], t["kind"]))
    return float((take_clock(src) or {}).get("audio_offset_s") or 0.0)


def t_fix_words(a):
    """Say new words in place of old ones in a take or clip, in the take's voice (the default voice)."""
    s = resolve_session(a["session"])
    src = session_file(s, a.get("file") or a.get("take") or "")
    new = (a.get("new") or "").strip()
    if not new:
        raise ValueError("Give new: the words to say instead.")
    words = transcript_words(src)
    if not words and (a.get("old") or a.get("start") is None):
        words = eleven_transcribe(src)
    many = 1
    if a.get("old"):
        i, j, many = find_words(words, a["old"], a.get("near"))
        start, end = words[i][0], words[j][1]
        before = " ".join(t for _, _, t in words[max(0, i - 40):i])
        after = " ".join(t for _, _, t in words[j + 1:j + 41])
        old = " ".join(t for _, _, t in words[i:j + 1])
    else:
        if a.get("start") is None or a.get("end") is None:
            raise ValueError("Give old (the words as said) or start and end in seconds.")
        start, end = float(a["start"]), float(a["end"])
        ws = words or []
        before = " ".join(t for b, e, t in ws if e <= start)[-600:]
        after = " ".join(t for b, e, t in ws if b >= end)[:600]
        old = " ".join(t for b, e, t in ws if e > start and b < end) or None
    if end <= start:
        raise ValueError("end must come after start.")
    vid, vname = resolve_voice(a.get("voice"))
    base, cleaned = voice_source(s, src)
    delay = base_offset(s, src, cleaned)
    if cleaned and delay and (words_doc(src) or {}).get("clock") == "video":
        start, end = max(0.0, start - delay), max(0.0, end - delay)  # video-clock words on an old voice WAV
    stem = slug(os.path.splitext(os.path.basename(src))[0]) + "-fix"
    rel = next_generated(s, stem, ".wav")
    with tempfile.TemporaryDirectory() as tmp:
        raw, speech = os.path.join(tmp, "new.mp3"), os.path.join(tmp, "speech.wav")
        tts(new, vid, raw, a.get("model"), voice_settings(a), before=before, after=after)
        trim = "silenceremove=start_periods=1:start_threshold=-45dB"
        ff("-i", raw, "-af", "%s,areverse,%s,areverse" % (trim, trim), "-ac", "1", "-ar", "48000",
           "-c:a", "pcm_f32le", speech)
        length = media_duration(speech) or 0.0
        slot = end - start
        ratio = length / slot if slot else 0
        fit = ELEVEN_FIT[0] <= ratio <= ELEVEN_FIT[1]
        gain = 0.0
        a_db, b_db = mean_db(base, start, end), mean_db(speech)
        if a_db is not None and b_db is not None:
            gain = max(-12.0, min(12.0, a_db - b_db))
        piece = os.path.join(tmp, "piece.wav")
        chain = ["volume=%.2fdB" % gain]
        if fit and abs(ratio - 1) > 0.01:
            chain.insert(0, "atempo=%.4f" % ratio)
        ff("-i", speech, "-af", ",".join(chain), "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", piece)
        out_len = slot if fit else (media_duration(piece) or length)
        splice(base, piece, start, end, os.path.join(s, rel), out_len)
    note_model(s, rel, "ElevenLabs · " + vname)
    out = {"file": rel, "voice": vname, "replaced": old, "with": new, "start": round(start, 3), "end": round(end, 3),
           "fits": fit, "speed": round(ratio, 3) if fit else None,
           "audio": "the take's cleaned voice" if cleaned else "the file's own audio"}
    if media_kind(src) == "video" and fit:
        vrel = rel[:-4] + ".mp4"
        with_audio(src, os.path.join(s, rel), os.path.join(s, vrel), delay)
        note_model(s, vrel, "ElevenLabs · " + vname)
        out["video"] = vrel
        out["note"] = ("Same length as the take, so its times still hold. The lips do not match the new words: "
                       "best over b-roll, a screen or a cutaway.")
    elif not fit:
        out["note"] = ("The new words take %.2f s; the old ones took %.2f s. The WAV is %+.2f s longer or shorter "
                       "from %.2f s on, so there is no video; cut it in the edit." % (length, slot, length - slot, end))
    if many > 1:
        out["warning"] = "The take says those words %d times; this changed the one at %.1f s. Pass near=<seconds> for another." % (many, start)
    return out


def t_change_voice(a):
    """Say a clip again in another voice (ElevenLabs voice changer): same timing, emotion and words."""
    s = resolve_session(a["session"])
    src = session_file(s, a.get("file") or a.get("take") or "")
    vid, vname = resolve_voice(a.get("voice"))
    base, cleaned = voice_source(s, src)
    delay = base_offset(s, src, cleaned)
    total = media_duration(base) or 0.0
    start = float(a["start"]) if a.get("start") is not None else 0.0
    end = float(a["end"]) if a.get("end") is not None else total
    if end <= start:
        raise ValueError("end must come after start.")
    if end - start > 300:
        raise ValueError("At most 5 minutes at a time. Pass start and end.")
    stem = slug(os.path.splitext(os.path.basename(src))[0]) + "-" + (slug(vname) or "voice")
    rel = next_generated(s, stem, ".wav")
    with tempfile.TemporaryDirectory() as tmp:
        seg, raw, piece = (os.path.join(tmp, n) for n in ("seg.wav", "new.mp3", "piece.wav"))
        ff("-ss", "%.3f" % start, "-to", "%.3f" % end, "-i", base, "-ac", "1", "-ar", "44100", seg)
        body = {"model_id": a.get("model") or ELEVEN_STS_MODEL}
        if a.get("remove_noise"):
            body["remove_background_noise"] = True
        with open(raw, "wb") as f:
            f.write(eleven_audio("/v1/speech-to-speech/%s" % vid, body, files={"audio": seg}))
        gain = 0.0
        a_db, b_db = mean_db(seg), mean_db(raw)
        if a_db is not None and b_db is not None:
            gain = max(-12.0, min(12.0, a_db - b_db))
        ff("-i", raw, "-af", "volume=%.2fdB" % gain, "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", piece)
        splice(base, piece, start, end, os.path.join(s, rel), end - start)
    note_model(s, rel, "ElevenLabs · " + vname)
    out = {"file": rel, "voice": vname, "start": round(start, 3), "end": round(end, 3),
           "audio": "the take's cleaned voice" if cleaned else "the file's own audio"}
    if media_kind(src) == "video":
        vrel = rel[:-4] + ".mp4"
        with_audio(src, os.path.join(s, rel), os.path.join(s, vrel), delay)
        note_model(s, vrel, "ElevenLabs · " + vname)
        out["video"] = vrel
    return out


# ---------- jobs: long work that Takes runs (2026-10-10, same format as Sources/Takes/Jobs.swift) ----------
#
# A render, Demucs, Whisper or matting ran as a background Bash job in the chat. A steer, a Stop, a
# compaction or a Takes quit ended the chat's process, and the render died with it. run_job starts
# the command in a runner that is not a child of anything in the chat (spawn_detached), so it goes
# on. The runner keeps <session>/.jobs/<id>.json up to date; the app shows it in the Jobs row and
# tells the chat when it ends. Higgsfield and Replicate jobs (generated/.jobs) read the same way.
#
#   .jobs/<id>.json      the job (run_job writes it first, then only its runner)
#   .jobs/<id>.log       what the command printed (<id>.log.1 is the older half)
#   .jobs/<id>.lock      exists only while the runner holds it (flock); free = the runner is gone
#   .jobs/<id>.told      the chat knows the job ended (made with O_EXCL by get_job or the app)
#   .jobs/<id>.stop      who asked to stop: "you" (the app) or "takes" (stop_job)
#   .jobs/<id>.partial/  what a failed or stopped job wrote, out of the session
#   <root>/.jobs.claims  flock for new ids and outputs

JOBS_DIR = ".jobs"
JOB_LOG_MAX = 5 * 1024 * 1024
JOB_WAIT_MAX = 50       # get_job's wait: the MCP loop is sequential, so a wait holds every other takes tool
JOB_PARTIAL_DAYS = 7
JOB_START_GRACE = 30    # a job that is "starting" this long without its runner is lost
JOB_LEGACY_LOST = 90 * 60  # a lockless generated/.jobs file: the CLI may run 40 min, plus upload and download
JOB_ENDED = ("done", "failed", "stopped", "lost")


def job_timeout():
    return float(os.environ.get("TAKES_JOB_TIMEOUT") or 2 * 3600)


def job_log_max():
    return int(os.environ.get("TAKES_JOB_LOG_MAX") or JOB_LOG_MAX)


def spawn_detached(argv):
    """Start `takes_mcp.py <argv>` so its parent is launchd at once: the chat's kill of its own
    process tree (ClaudeChat.end walks pgrep -P) cannot reach it. Returns the runner's pid."""
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--detach"] + [str(x) for x in argv],
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    line = p.stdout.readline()
    p.stdout.close()
    p.wait()
    try:
        return int(line.strip())
    except ValueError:
        return None


def detach_exec(argv):
    """`--detach`: fork; the parent prints the child's pid and exits, the child becomes argv."""
    pid = os.fork()
    if pid:
        sys.stdout.write("%d\n" % pid)
        sys.stdout.flush()
        os._exit(0)
    null = os.open(os.devnull, os.O_RDWR)
    os.dup2(null, 1)
    os.execv(sys.executable, [sys.executable, os.path.abspath(__file__)] + argv)


def job_lock(path):
    """Hold path's lock for as long as this process lives. The file appears only already held: a
    temp name is locked first, then renamed. Returns the fd (job_unlock lets it go)."""
    import fcntl
    tmp = "%s.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.rename(tmp, path)
    return fd


def job_unlock(fd, path):
    try:
        os.unlink(path)
    except OSError:
        pass
    os.close(fd)


def lock_held(path):
    import fcntl
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def jobs_dir(s):
    return os.path.join(s, JOBS_DIR)


def job_path(s, job_id, ext=".json", generate=False):
    return os.path.join(hf_jobs_dir(s) if generate else jobs_dir(s), job_id + ext)


def write_job(path, job):
    with open(path + ".tmp", "w") as f:
        json.dump(job, f, indent=2)
    os.replace(path + ".tmp", path)


def job_age(job, key="started"):
    t = parse_iso(job.get(key) or "")
    return (datetime.now(timezone.utc) - t).total_seconds() if t else None


def job_lost(s, job, generate=False):
    """The runner is gone though the file says it runs. Same rule as JobBoard.lost in Jobs.swift."""
    status = job.get("status")
    if status not in ("starting", "running"):
        return False
    lock = job_path(s, job["id"], ".lock", generate)
    if lock_held(lock):
        return False
    age = job_age(job)
    if generate:
        # A free lock file: its runner died before it could remove it. No lock file at all: a job
        # from before 2026-10-10, or a runner that has not started yet.
        return os.path.exists(lock) or (age is not None and age > JOB_LEGACY_LOST)
    return status == "running" or age is None or age > JOB_START_GRACE


def norm_job(s, job, generate):
    """One shape for both stores. Legacy "error" reads as failed; generate comes from the folder."""
    j = dict(job)
    if j.get("status") == "error":
        j["status"] = "failed"
    if generate:
        j["type"] = "generate"
        j["outputs"] = [j["file"]] if j.get("file") else []
        j["label"] = j.get("label") or os.path.splitext(os.path.basename(j.get("file") or j["id"]))[0]
    j.setdefault("outputs", [])
    j.setdefault("label", j["id"])
    return j


def read_job(s, job_id, generate=False):
    """The job, normalised and with the lost rule applied. A file that does not parse is never written over."""
    p = job_path(s, job_id, ".json", generate)
    try:
        with open(p) as f:
            raw = json.load(f)
        if not isinstance(raw, dict) or not raw.get("id"):
            raise ValueError
    except OSError:
        raise ValueError("No job %s in %s." % (job_id, s))
    except ValueError:
        raise ValueError("Takes cannot read the job file %s. It is left as it is. Start it again with run_job."
                         % os.path.relpath(p, s))
    if job_lost(s, raw, generate):
        # Read again: a runner that ended between the read and the lock check wrote its end first.
        try:
            with open(p) as f:
                raw = json.load(f)
        except (OSError, ValueError):
            pass
        if job_lost(s, raw, generate):
            raw["status"] = "lost"
            if not generate:  # the runner is dead, so nobody else writes this file now
                raw["ended"] = raw.get("ended") or now_iso()
                write_job(p, raw)
    return norm_job(s, raw, generate)


def all_jobs(s):
    """Every job of a session, both stores, oldest first. Prunes old partial folders."""
    out = []
    for generate, d in ((False, jobs_dir(s)), (True, hf_jobs_dir(s))):
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if not f.endswith(".json"):
                continue
            try:
                j = read_job(s, f[:-5], generate)
            except ValueError:
                continue
            out.append(j)
            age = job_age(j, "ended")
            part = job_path(s, j["id"], ".partial")
            if not generate and age is not None and age > JOB_PARTIAL_DAYS * 86400 and os.path.isdir(part):
                shutil.rmtree(part, ignore_errors=True)
    return sorted(out, key=lambda j: j.get("started") or "")


def job_files(job_id):
    """Every file with this id in the library, both stores."""
    if not re.fullmatch(r"[\w.\-]+", job_id or ""):
        raise ValueError("A job id looks like job-7f3a1c (from run_job, higgsfield or replicate).")
    r = root()
    return ([(p, False) for p in glob.glob(os.path.join(glob.escape(r), "*", "*", JOBS_DIR, job_id + ".json"))]
            + [(p, True) for p in glob.glob(os.path.join(glob.escape(r), "*", "*", GENERATED_DIR, JOBS_DIR, job_id + ".json"))])


def find_job(job_id, session=None):
    """(session folder, job). Without session the id must be unique in the library."""
    if session:
        s = resolve_session(session)
        for generate in (False, True):
            if os.path.exists(job_path(s, job_id, ".json", generate)):
                return s, read_job(s, job_id, generate)
        raise ValueError("No job %s in this session. get_job with session lists its jobs." % job_id)
    found = job_files(job_id)
    if not found:
        raise ValueError("No job %s. get_job with session lists a session's jobs." % job_id)
    if len(found) > 1:
        raise ValueError("Several jobs have the id %s. Give session." % job_id)
    p, generate = found[0]
    s = os.path.dirname(os.path.dirname(p))
    if generate:
        s = os.path.dirname(s)
    return s, read_job(s, job_id, generate)


def log_tail(s, job_id, n=20):
    lines = []
    for p in (job_path(s, job_id, ".log.1"), job_path(s, job_id, ".log")):
        try:
            with open(p, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 16384))
                lines += re.split(r"[\r\n]", f.read().decode("utf-8", "replace"))
        except OSError:
            pass
    lines = [ANSI.sub("", x).rstrip() for x in lines if x.strip()]
    return lines[-n:]


def job_brief(s, job, tail=20):
    """What get_job says about one job."""
    out = {"job": job["id"], "status": job["status"], "label": job.get("label")}
    if job.get("type") == "generate":
        out["type"] = "generate"
    started, ended = parse_iso(job.get("started") or ""), parse_iso(job.get("ended") or "")
    if started:
        out["elapsed_s"] = int(((ended or datetime.now(timezone.utc)) - started).total_seconds())
    if job["status"] in ("starting", "running"):
        for k in ("progress", "eta_s", "stage"):
            if job.get(k) is not None:
                out[k] = job[k]
    if job.get("exit") is not None:
        out["exit"] = job["exit"]
    if job.get("error"):
        out["error"] = job["error"]
    if job.get("stopped_by"):
        out["stopped_by"] = job["stopped_by"]
    if job.get("type") != "generate":
        out["cmd"] = job.get("cmd")  # what run_job needs to start it again, also after a compaction
        out["log_tail"] = log_tail(s, job["id"], tail)
    if job["status"] == "done":
        out["outputs"] = [{"path": o, "bytes": os.path.getsize(os.path.join(s, o)) if os.path.exists(os.path.join(s, o)) else 0}
                          for o in job.get("outputs") or []]
    else:
        out["outputs"] = job.get("outputs") or []
    part = job_path(s, job["id"], ".partial")
    if os.path.isdir(part):
        out["partial"] = [os.path.relpath(os.path.join(part, f), s) for f in sorted(os.listdir(part))]
    out["session"] = s
    result = next((o for o in job.get("outputs") or [] if o.startswith(WORK_DIR + os.sep) and o.endswith(".json")
                   and not o.endswith(".words.json")), None)
    render = next((o for o in job.get("outputs") or [] if o.startswith(RENDERS + os.sep)), None)
    if job["status"] == "done" and result and os.path.exists(os.path.join(s, result)):
        out["result"] = cut_view(s, result)  # a cut_take or rough_cut: the same result as the tool
        out["next"] = out["result"]["next"]
    elif render and job["status"] == "done":  # render_edit: the checks it ran, then publish_edit
        try:
            r = load_recipe(s, os.path.join(RENDERS, job["id"] + RECIPE_EXT))
        except ValueError:
            r = None
        if r and r.get("checks"):
            out["result"] = render_view(s, job["id"], r)
            out["next"] = out["result"]["next"]
        else:
            out["next"] = "This render is saved already: get_session shows the edit."
    elif render and job["status"] == "lost":
        out["next"] = ("The render stopped (the Mac restarted or the job quit). Call render_edit again with the same "
                       "base and changes.")
    elif render and job["status"] == "failed":
        out["next"] = "Fix the recipe and call render_edit again (base=<name> changes={...}). log_tail says why."
    elif job["status"] == "done" and any(media_kind(o) == "video" for o in job.get("outputs") or []):
        out["next"] = "Run check_edit on it, then open_in_app."
    elif job["status"] == "failed" and job.get("type") != "generate":
        out["next"] = "Fix the command and run_job again with a new path from next_path."
    elif job["status"] == "lost" and job.get("type") != "generate":
        out["next"] = "Run it again: run_job with this cmd and label, and new outputs from next_path."
    return out


def claim_told(s, job):
    """The chat knows this job ended: the app sends no note. True when this call made the file."""
    try:
        os.close(os.open(job_path(s, job["id"], ".told", job.get("type") == "generate"),
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644))
        return True
    except OSError:
        return False


def claimed_outputs(s):
    """Outputs of this session's starting or running jobs: {relative path: job id}."""
    out = {}
    for j in all_jobs(s):
        if j["status"] in ("starting", "running") and j.get("type") != "generate":
            for o in j.get("outputs") or []:
                out[os.path.normpath(o)] = j["id"]
    return out


def job_output(s, o):
    """One output of run_job as a path relative to the session, or an error that names the fix."""
    o = str(o or "").strip()
    if not o:
        raise ValueError("An output is empty. Give each file the job writes, relative to the session.")
    p = os.path.normpath(o if os.path.isabs(o) else os.path.join(s, o))
    if not p.startswith(s.rstrip(os.sep) + os.sep):
        raise ValueError("%s is outside the session. Get a path inside it from next_path." % o)
    rel = os.path.relpath(p, s)
    parts = rel.lower().split(os.sep)  # the Mac's volume ignores case: Stills/ is stills/
    top = os.sep.join(rel.split(os.sep)[:2 if parts[0] == GENERATED_DIR else 1])
    if top.lower() in ("stills", "assets", JOBS_DIR, os.path.join(GENERATED_DIR, JOBS_DIR)):
        raise ValueError("%s/ is read only for jobs. Write to edits/ or thumbnails/ (next_path gives the path)." % top)
    if top.lower() != WORK_DIR and re.match(r"take-\d+", os.path.basename(rel), re.I):
        raise ValueError("%s is a take file. Never write over a take: get a new path from next_path." % rel)
    if os.path.lexists(p):
        raise ValueError("%s exists. Get a new path from next_path." % rel)
    return rel


def new_job_id(s):
    while True:
        job_id = "job-" + secrets.token_hex(3)
        if not job_files(job_id) and not any(os.path.exists(job_path(s, job_id, ".json", g)) for g in (False, True)):
            return job_id


def from_chat():
    """A job the Takes chat of a session started: the app tells that chat when it ends. Board chats
    (TAKES_BOARD) and other agents get no note."""
    return os.environ.get("TAKES_CHAT") == "1" and not os.environ.get("TAKES_BOARD")


def start_job(s, cmd, outputs, label, estimate_s=None, job_id=None):
    """Start cmd in the session folder as a job. The internal API: run_job and later tools that
    run their own command call it. job_id: an id from new_job_id that the caller named files with.
    Returns the job as written."""
    import fcntl
    outputs = [job_output(s, o) for o in outputs]
    with open(os.path.join(root(), ".jobs.claims"), "a") as claims:
        fcntl.flock(claims, fcntl.LOCK_EX)
        busy = claimed_outputs(s)
        for o in outputs:
            if os.path.normpath(o) in busy:
                raise ValueError("A running job already writes %s (%s). Wait with get_job or use next_path."
                                 % (o, busy[os.path.normpath(o)]))
        if job_id and any(os.path.exists(job_path(s, job_id, ".json", g)) for g in (False, True)):
            raise ValueError("A job %s exists already. Try again." % job_id)
        job = {"v": 1, "id": job_id or new_job_id(s), "label": label, "cmd": cmd, "outputs": outputs,
               "from_chat": from_chat(), "status": "starting", "started": now_iso(), "updated": now_iso(),
               "ended": None, "pid": None, "progress": None, "eta_s": None, "estimate_s": estimate_s,
               "timeout_s": job_timeout(), "exit": None, "error": None, "stopped_by": None}
        os.makedirs(jobs_dir(s), exist_ok=True)
        write_job(job_path(s, job["id"]), job)
    spawn_detached(["--job-run", s, job["id"]])
    return job


def job_session(ref):
    """The session a job runs in: only a folder at <library>/<project>/<session>. The app and get_job
    look for jobs there and nowhere else."""
    ref = str(ref or "").strip()
    bad = "Give session: Project/folder or the session's path (list_sessions)."
    if not ref:
        raise ValueError(bad)
    try:
        s = resolve_session(ref)
    except ValueError as e:
        raise ValueError(bad) if str(e).startswith("Not a session") else e
    project = os.path.dirname(s)
    if (os.path.realpath(os.path.dirname(project)) != os.path.realpath(root())
            or os.path.basename(project).startswith((".", "_")) or os.path.basename(s).startswith((".", "_"))):
        raise ValueError(bad)
    return s


def job_cmd(s, cmd):
    """The runner works in the session folder by its inode: a path to it by name would break on a rename.
    Only '<session>/' and the whole word '<session>' change: a sibling such as '<session>-2' stays."""
    s = s.rstrip(os.sep)
    cmd = cmd.replace(s + os.sep, "")
    return re.sub(re.escape(s) + r"(?=$|[\s'\"`;|&)<>])", ".", cmd)


def t_run_job(a):
    s = job_session(a.get("session"))
    cmd = a.get("cmd")
    if not isinstance(cmd, str) or not cmd.strip():
        raise ValueError("Give cmd: the shell command, with paths relative to the session folder.")
    if len(cmd) > 8000:
        raise ValueError("cmd is longer than 8000 characters. Put the steps in a script file and run that.")
    cmd = job_cmd(s, cmd)
    outputs = a.get("outputs")
    if not isinstance(outputs, list):
        raise ValueError("Give outputs: the files the job writes, relative to the session ([] if none).")
    label = " ".join(str(a.get("label") or "").split())
    if not label:
        raise ValueError("Give a label: a few words the user sees, e.g. Render edit v3.")
    if len(label) > 60:
        raise ValueError("The label is longer than 60 characters. Use a few words, e.g. Render edit v3.")
    job = start_job(s, cmd, outputs, label)
    if job["from_chat"]:
        then = "Otherwise tell the user in one line what runs and end your turn: Takes sends you a note when it ends."
    else:  # only the Takes chat of a session gets a note: other agents must look
        then = ("Otherwise tell the user in one line what runs. No note comes to you when it ends: "
                "check later with get_job id=%s." % job["id"])
    return {"job": job["id"], "status": job["status"], "label": label, "outputs": job["outputs"],
            "note": "Takes runs it and shows it in the Jobs row. If it should end within about 2 min, wait with "
                    "get_job wait_s=50. " + then}


def t_get_job(a):
    if a.get("id"):
        s, job = find_job(a["id"], a.get("session"))
        try:
            wait = min(max(float(a.get("wait_s") or 0), 0), JOB_WAIT_MAX)
        except (TypeError, ValueError):
            raise ValueError("wait_s is seconds, 0 to %d." % JOB_WAIT_MAX)
        end = time.time() + wait
        while job["status"] in ("starting", "running") and time.time() < end:
            time.sleep(min(0.5, max(0.01, end - time.time())))
            s, job = find_job(a["id"], s if os.path.isdir(s) else None)
        if job["status"] in JOB_ENDED:
            claim_told(s, job)
        return job_brief(s, job)
    if not a.get("session"):
        raise ValueError("Give id (from run_job) for one job, or session for its jobs.")
    s = resolve_session(a["session"])
    jobs = all_jobs(s)
    live = [j for j in jobs if j["status"] in ("starting", "running")]
    ended = [j for j in jobs if j["status"] in JOB_ENDED and (job_age(j, "ended") or 0) < 86400][-10:]
    out = []
    for j in live + ended[::-1]:
        x = {"job": j["id"], "status": j["status"], "label": j.get("label")}
        for k in ("progress", "eta_s") if j["status"] in ("starting", "running") else ():
            if j.get(k) is not None:
                x[k] = j[k]
        if j.get("type") == "generate":
            x["type"] = "generate"
        out.append(x)
    return {"jobs": out}


def t_stop_job(a):
    s, job = find_job(a.get("id") or "", a.get("session"))
    if job.get("type") == "generate":
        raise ValueError("Higgsfield and Replicate charge for a clip when it starts, so Takes cannot stop it.")
    if job["status"] in JOB_ENDED:
        return dict(job_brief(s, job), note="It already ended.")
    with open(job_path(s, job["id"], ".stop") + ".tmp", "w") as f:
        f.write("takes")
    os.replace(job_path(s, job["id"], ".stop") + ".tmp", job_path(s, job["id"], ".stop"))
    # Only while the runner holds its lock: a pid alone may belong to another process by now.
    if job.get("pid") and lock_held(job_path(s, job["id"], ".lock")):
        try:
            os.kill(int(job["pid"]), signal.SIGTERM)
        except (OSError, ValueError):
            pass
    end, sent = time.time() + 8, bool(job.get("pid"))
    while job["status"] in ("starting", "running") and time.time() < end:
        time.sleep(0.2)
        job = read_job(s, job["id"])
        if not sent and job.get("pid") and lock_held(job_path(s, job["id"], ".lock")):
            sent = True  # it was starting: the runner holds its lock now
            try:
                os.kill(int(job["pid"]), signal.SIGTERM)
            except (OSError, ValueError):
                pass
    return job_brief(s, job)


ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
PROGRESS_LINES = (re.compile(r"TAKES_PROGRESS\s+([0-9.]+)\s*(%?)"),
                  re.compile(r"\bframe\s+(\d+)\s*/\s*(\d+)", re.I),
                  re.compile(r"\b(\d+)\s*/\s*(\d+)\s+frames\b", re.I))
FF_DURATION = re.compile(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)")
FF_TIME = re.compile(r"\btime=\s*(\d+):(\d+):(\d+(?:\.\d+)?)")
TRAILING_PCT = re.compile(r"(\d{1,3}(?:\.\d+)?)\s*%\s*(?:\||$)")


def ffmpeg_timed(cmd):
    """ffmpeg time= lines count only for one input and no -t/-to/-stream_loop: else Duration is not the
    output's."""
    words = cmd.split()
    return (len([w for w in words if w == "-i"]) == 1
            and not any(w in ("-t", "-to", "-stream_loop", "-loop") for w in words))


def raw_progress(line, state):
    m = PROGRESS_LINES[0].search(line)
    if m:
        v = float(m.group(1))
        return v / 100 if m.group(2) or v > 1 else v
    for r in PROGRESS_LINES[1:]:
        m = r.search(line)
        if m and int(m.group(2)) > 0:
            return int(m.group(1)) / int(m.group(2))
    m = FF_DURATION.search(line)
    if m:
        if state.get("duration") is None:
            state["duration"] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
        return None
    m = FF_TIME.search(line)
    if m and state.get("ffmpeg") and state.get("duration"):
        v = (int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))) / state["duration"]
        if v > 1.01:  # the output runs longer than Duration (a filter, a loop): time= says nothing
            state.update(ffmpeg=False, p=None)
            return None
        return v
    m = TRAILING_PCT.search(line)
    if m and float(m.group(1)) <= 100:
        return float(m.group(1)) / 100
    return None


def job_progress(line, state):
    """One log line -> the new progress 0..1, or None. Within one step it never goes back by more than
    0.02. After a step that reached 100% (a model download, a first pass) a lower value starts the next
    step, and the bar with it: else the bar reads 100% for the rest of the job. state keeps duration,
    ffmpeg, p (the bar, None when unknown) and step_t (when the step started)."""
    v = raw_progress(ANSI.sub("", line), state)
    if v is None:
        return None
    v = max(0.0, min(1.0, v))
    p = state.get("p")
    if p is not None and v < p - 0.02:
        if p < 0.99:
            return None
        state["step_t"] = time.time()
    state["p"] = v
    return v


def job_reason(lines):
    """The last line that says something, for a failed job."""
    for x in reversed(lines):
        x = ANSI.sub("", x).strip()
        if x and job_progress(x, {}) is None and not FF_TIME.search(x):
            return x[:160]
    return None


def job_env(s=None, job_id=None):
    """The command's environment: no variables of a Claude that started the chat, Homebrew first."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDECODE", "CLAUDE_CODE_"))}
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin" + (":" + env["PATH"] if env.get("PATH") else "")
    if job_id:
        env["TAKES_JOB_ID"] = job_id
    if s:
        env["TAKES_SESSION"] = s
    return env


def span(sec):
    sec = int(round(sec))
    if sec < 60:
        return "%d s" % sec
    if sec < 3600:
        return "%d min" % (sec // 60)
    return "1 hour" if sec < 7200 else "%d hours" % (sec // 3600)


class JobStopped(Exception):
    pass


def job_run(s, job_id):
    """`--job-run`: run one job to its end. Paths are relative to the session folder from here on: the
    working folder follows the folder's inode, so a rename during the job loses nothing."""
    import threading
    if not os.path.isdir(s):  # renamed between the start and this line: .moves.json knows where it went
        s = follow_moves(s, lib_root(s)) or s
    os.chdir(s)
    jp = os.path.join(JOBS_DIR, job_id + ".json")
    lock_path = os.path.join(JOBS_DIR, job_id + ".lock")
    lock = job_lock(lock_path)
    stop_file = os.path.join(JOBS_DIR, job_id + ".stop")
    with open(jp) as f:
        job = json.load(f)
    outputs = job.get("outputs") or []
    existed = {o for o in outputs if os.path.lexists(o)}
    t0 = time.time()
    stopping = {"by": None}
    signal.signal(signal.SIGTERM, lambda *_: stopping.update(by=stopping["by"] or "signal"))
    job.update(status="running", pid=os.getpid(), updated=now_iso())
    write_job(jp, job)
    child = None
    try:
        try:  # the Mac does not idle-sleep under a render once the chat's own sleep block ends
            subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(os.getpid())], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass
        if os.path.exists(stop_file):
            raise JobStopped
        child = subprocess.Popen(["/bin/zsh", "-c", job["cmd"]], cwd=".", start_new_session=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 env=job_env(os.getcwd(), job_id))
        state = {"ffmpeg": ffmpeg_timed(job["cmd"])}
        seen = {"p": None, "lines": [], "stage": None}
        log_name, cap = os.path.join(JOBS_DIR, job_id + ".log"), job_log_max()

        def read():
            log = open(log_name, "ab")
            rest = b""
            while True:
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    break
                log.write(chunk)
                log.flush()
                if log.tell() >= cap:
                    log.close()
                    os.replace(log_name, log_name + ".1")
                    log = open(log_name, "ab")
                parts = re.split(rb"[\r\n]", rest + chunk)
                rest = parts.pop()[-4096:]
                for raw in parts:
                    line = raw.decode("utf-8", "replace")
                    if not line.strip():
                        continue
                    if line.startswith("TAKES_STAGE "):  # what the job does now, for the Jobs row
                        seen["stage"] = line[len("TAKES_STAGE "):].strip()[:80] or None
                        continue
                    if job_progress(line, state) is None:
                        seen["lines"] = (seen["lines"] + [line])[-50:]
                    seen["p"] = state.get("p")
            if rest.strip():
                seen["lines"] = (seen["lines"] + [rest.decode("utf-8", "replace")])[-50:]
            log.close()

        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        deadline = t0 + float(job.get("timeout_s") or job_timeout())
        shown, last_write = None, 0
        timed_out = False
        while child.poll() is None:
            time.sleep(0.2)
            if stopping["by"] or time.time() > deadline:
                timed_out = not stopping["by"]
                for sig, wait in ((signal.SIGTERM, 5), (signal.SIGKILL, 2)):
                    try:
                        os.killpg(child.pid, sig)
                    except OSError:
                        pass
                    try:
                        child.wait(wait)
                        break
                    except subprocess.TimeoutExpired:
                        pass
                try:  # the command ended, but what it started in the background goes too
                    os.killpg(child.pid, signal.SIGKILL)
                except OSError:
                    pass
                break
            if (seen["p"] != shown or seen["stage"] != job.get("stage")) and time.time() - last_write >= 2:
                shown, last_write = seen["p"], time.time()
                job["stage"] = seen["stage"]
                elapsed, step = time.time() - t0, time.time() - state.get("step_t", t0)
                eta = None
                if shown and shown >= 0.05 and step >= 10:
                    eta = int(step * (1 - shown) / shown)
                elif job.get("estimate_s"):
                    eta = max(0, int(job["estimate_s"] - elapsed))
                job.update(progress=None if shown is None else round(shown, 4), eta_s=eta, updated=now_iso())
                write_job(jp, job)
        code = child.wait()
        reader.join(2)
        if seen["stage"]:
            job["stage"] = seen["stage"]
        if stopping["by"]:
            raise JobStopped
        if timed_out:
            job.update(status="failed", error="It ran over %s, so Takes stopped it." % span(job.get("timeout_s") or job_timeout()))
        elif code != 0:
            job.update(status="failed", exit=code,
                       error=job_reason(seen["lines"]) or "It ended with code %d." % code)
        else:
            missing = [o for o in outputs if not os.path.exists(o) or os.path.getsize(o) == 0]
            job["exit"] = 0
            if missing:
                job.update(status="failed", error="It ended but did not write %s." % missing[0])
            else:
                job.update(status="done", progress=1)
    except JobStopped:
        by = None
        try:
            with open(stop_file) as f:
                by = f.read().strip() or None
        except OSError:
            pass
        job.update(status="stopped", stopped_by=by if by in ("you", "takes") else "you")
    except Exception as e:  # the runner itself broke: say so, never leave "running"
        if child and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except OSError:
                pass
        job.update(status="failed", error=("Takes could not run it: %s" % e)[:160])
    if job["status"] in ("failed", "stopped"):
        # What it wrote leaves the session, so a half-written file never reads as a result.
        part = os.path.join(JOBS_DIR, job_id + ".partial")
        for o in outputs:
            if o not in existed and os.path.lexists(o):
                os.makedirs(part, exist_ok=True)
                dest = unique(os.path.join(part, os.path.basename(o)))
                try:
                    os.replace(o, dest)
                except OSError:
                    pass
    job.update(ended=now_iso(), updated=now_iso(), eta_s=None)
    write_job(jp, job)
    job_unlock(lock, lock_path)


# ---------- Higgsfield: AI video (2026-10-06) ----------
#
# Video only: images go to GPT Image directly (make_image), much cheaper. Takes runs the official `higgsfield` CLI (signed in once from Takes › Plugins › Higgsfield, the
# same browser sign-in as Higgsfield's own MCP, no API key). A job runs detached like the sketches:
# the tool returns at once, the file lands in <session>/generated/, and a storyboard shot plays it.

GENERATED_DIR = "generated"
HF_VIDEO_MODEL = "seedance_2_5"
HF_WORKFLOWS = ("reframe", "draw_to_video")
HF_SETUP = "Open Takes › Plugins › Higgsfield: Install, then Sign in."


def higgsfield_cli():
    """The CLI as an argv prefix, or None. Tests set TAKES_HIGGSFIELD_CMD to a stand-in."""
    if os.environ.get("TAKES_HIGGSFIELD_CMD"):
        return json.loads(os.environ["TAKES_HIGGSFIELD_CMD"])
    for d in (os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin"):
        exe = os.path.join(d, "higgsfield")
        if os.access(exe, os.X_OK):
            return [exe]
    found = shutil.which("higgsfield")
    return [found] if found else None


def hf_call(args, timeout=60):
    cli = higgsfield_cli()
    if not cli:
        raise ValueError("Higgsfield is not installed. " + HF_SETUP)
    try:
        r = subprocess.run(cli + args, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return False, "Higgsfield did not answer in %d s." % timeout
    return r.returncode == 0, (r.stdout + ("\n" + r.stderr if r.stderr.strip() else "")).strip()


def hf_problem(out):
    """The CLI's error in one line, with the fix when it is the sign-in."""
    lines = [x.strip() for x in out.splitlines() if x.strip()]
    err = next((x for x in lines if x.lower().startswith("error")), lines[-1] if lines else "Higgsfield failed.")
    low = out.lower()
    if any(k in low for k in ("not authenticated", "session expired", "no workspace selected", "401")):
        err += " " + HF_SETUP
    return err[:300]


def hf_jobs_dir(s):
    return os.path.join(s, GENERATED_DIR, ".jobs")


def hf_jobs(s):
    d = hf_jobs_dir(s)
    out = []
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if f.endswith(".json"):
            try:
                out.append(json.load(open(os.path.join(d, f))))
            except (OSError, ValueError):
                pass
    return out


def hf_save_job(s, job):
    os.makedirs(hf_jobs_dir(s), exist_ok=True)
    p = os.path.join(hf_jobs_dir(s), job["id"] + ".json")
    with open(p + ".tmp", "w") as f:
        json.dump(job, f, indent=2)
    os.replace(p + ".tmp", p)
    return p


def put_clip(x, f):
    """A new clip on a shot: it shows, and the one it replaces stays as a variant (2026-10-09)."""
    v = list(x.get("variants") or [])
    for c in (x.get("video"), f):
        if c and c not in v:
            v.append(c)
    if len(v) > 1:
        x["variants"] = v
    x["video"] = f


def edit_shot(s, shot_id, fn):
    """Change one shot under a lock, so a runner and the sketch writer do not drop each other's change."""
    import fcntl
    os.makedirs(os.path.join(s, STORYBOARD_DIR), exist_ok=True)
    with open(os.path.join(s, STORYBOARD_DIR, ".edit"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        d = read_storyboard(s)
        for x in d["shots"]:
            if x.get("id") == shot_id:
                fn(x)
                write_storyboard(s, d)
                return True
    return False


def hf_config_path():
    return os.path.join(root(), LIB, "higgsfield.json")


def hf_default_model():
    """The video model ✦ and the chat use, picked on Plugins › Higgsfield (seedance_2_5 until then)."""
    try:
        m = json.load(open(hf_config_path())).get("model")
        if isinstance(m, str) and re.fullmatch(r"[\w.\-]+", m):
            return m
    except (OSError, ValueError, AttributeError):
        pass
    return HF_VIDEO_MODEL


def hf_set_default(model):
    model = str(model or "").strip()
    if not re.fullmatch(r"[\w.\-]+", model):
        raise ValueError("A Higgsfield model is its job type, e.g. seedance_2_5: %r is not." % model)
    p = hf_config_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump({"model": model}, f)
    os.replace(p + ".tmp", p)
    return model


def t_higgsfield_status(a):
    """Installed, signed in, credits; and a session's jobs."""
    out = {"installed": higgsfield_cli() is not None, "default_model": hf_default_model()}
    if not out["installed"]:
        out["note"] = "Higgsfield is not installed. " + HF_SETUP
    else:
        ok, text = hf_call(["account", "status"], timeout=30)
        out["signed_in"] = ok
        out["account" if ok else "problem"] = text.splitlines()[0] if ok and text else hf_problem(text)
    if a.get("session"):
        s = resolve_session(a["session"])
        out["jobs"] = [{k: j.get(k) for k in ("id", "file", "status", "shot", "error", "started", "ended")}
                       for j in hf_jobs(s)][-10:]
    return out


def shot_seconds(x):
    if x.get("seconds"):
        return float(x["seconds"])
    return len((x.get("say") or "").split()) / 2.6


def t_higgsfield(a):
    """Start a Higgsfield job. The file lands in generated/ when it is done."""
    s = resolve_session(a["session"])
    if not higgsfield_cli():
        raise ValueError("Higgsfield is not installed. " + HF_SETUP)
    if (a.get("kind") or "video").strip().lower() != "video":
        raise ValueError("Higgsfield is for video only. Make or change an image with make_image (GPT Image, much cheaper).")
    kind = "video"
    workflow = (a.get("workflow") or "").strip() or None
    if workflow and workflow not in HF_WORKFLOWS:
        raise ValueError("workflow is reframe or draw_to_video.")
    if workflow:
        kind = "video"
    prompt = (a.get("prompt") or "").strip()
    if not prompt and workflow != "reframe":
        raise ValueError("Give a prompt: what the clip shows and how the camera moves.")

    shot = None
    board = read_storyboard(s)
    if a.get("shot"):
        shot = next((x for x in board["shots"] if x.get("id") == a["shot"]), None)
        if not shot:
            raise ValueError("No shot %s in the storyboard. get_session lists the ids." % a["shot"])

    def media(ref):
        ref = (ref or "").strip()
        if not ref:
            return None
        if ref == "sketch":
            if not shot or not shot.get("image"):
                raise ValueError("'sketch' needs a shot whose sketch is drawn.")
            return os.path.join(s, STORYBOARD_DIR, shot["image"])
        return session_file(s, ref)

    image, start, end, video = (media(a.get(k)) for k in ("image", "start_image", "end_image", "video"))
    if workflow and not video:
        raise ValueError("%s needs a video from the session." % workflow)

    if workflow:
        args = ["generate", "workflow", workflow]
    else:
        args = ["generate", "create", (a.get("model") or hf_default_model()).strip()]
    if prompt:
        args += ["--prompt", prompt]
    for flag, path in (("--image", image), ("--start-image", start), ("--end-image", end), ("--video", video)):
        if path:
            args += [flag, path]
    ratio = (a.get("aspect_ratio") or "").strip()
    if not ratio and shot:
        ratio = board.get("format") or DEFAULT_FORMAT
    if ratio:
        args += ["--aspect-ratio" if workflow == "reframe" else "--aspect_ratio", ratio]
    duration = a.get("duration")
    if not duration and shot and kind == "video" and not workflow:
        duration = max(4, min(15, round(shot_seconds(shot))))
    if duration and workflow != "reframe":
        args += ["--duration", str(int(round(float(duration))))]
    for k, v in (a.get("params") or {}).items():
        args += ["--" + str(k).lstrip("-"), str(v)]
    args += ["--wait", "--wait-timeout", "30m", "--json"]

    name = slug(a.get("name") or (shot and "shot-%s" % shot["id"]) or " ".join(prompt.split()[:5]) or "clip") or "clip"
    d = os.path.join(s, GENERATED_DIR)
    os.makedirs(d, exist_ok=True)
    have = versions_in(d, name)
    n = (have[-1] if have else 0) + 1
    rel = os.path.join(GENERATED_DIR, "%s-v%d%s" % (name, n, ".mp4" if kind == "video" else ".png"))
    job = {"id": "%s-v%d" % (name, n), "file": rel, "kind": kind, "args": args, "shot": shot and shot["id"],
           "status": "running", "started": now_iso(), "from_chat": from_chat()}
    job["label"] = clip_label(hf_label(job), shot)
    path = hf_save_job(s, job)
    if shot:
        def mark(x):
            x["generating"] = rel
            x.pop("clip_error", None)
        edit_shot(s, shot["id"], mark)
    start_higgsfield(s, path)
    return {"file": rel, "job": job["id"], "model": None if workflow else args[2], "workflow": workflow,
            "note": "Higgsfield works in the background (a video takes 1-5 min). The file "
                    "lands at %s and shows on the Assets tab%s. higgsfield_status shows how it went. Credits come "
                    "from the user's Higgsfield plan." % (rel, "; the shot plays it then" if shot else "")}


def start_higgsfield(s, job_path):
    spawn_detached(["--higgsfield-run", s, job_path])


MEDIA_EXT = {"video": (".mp4", ".mov", ".webm", ".m4v"), "image": (".png", ".jpg", ".jpeg", ".webp")}


def hf_result_url(out, kind):
    """The result's URL in the CLI's output (JSON or text): a file of the right kind first."""
    found = []

    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, str) and re.match(r"^(https?|file)://\S+$", v.strip()):
            found.append(v.strip())
    try:
        walk(json.loads(out))
    except ValueError:
        found = re.findall(r"(?:https?|file)://[^\s\"'<>]+", out)
    ext = lambda u: os.path.splitext(u.split("?")[0])[1].lower()
    for u in found:
        if ext(u) in MEDIA_EXT[kind]:
            return u
    return next((u for u in found if ext(u) not in (".html", ".json", "")), None)


def hf_label(job):
    """'seedance_2_5' -> 'Seedance 2.5', 'kling3_0' -> 'Kling 3.0'; a workflow -> 'Higgsfield reframe'."""
    a = job.get("args") or []
    if a[:2] == ["generate", "workflow"] and len(a) > 2:
        return "Higgsfield " + a[2].replace("_", " ")
    name = a[2] if len(a) > 2 else "higgsfield"
    m = re.fullmatch(r"([a-z_]*?[a-z])_?(\d+(?:_\d+)*)", name)  # kling3_0 -> kling, 3_0
    base, ver = (m.group(1), m.group(2).replace("_", ".")) if m else (name, "")
    return " ".join([w.capitalize() for w in base.split("_") if w] + ([ver] if ver else []))


def clip_label(model, shot):
    """What the Jobs row says: 'Seedance 2.5 clip for shot 3'."""
    return ("%s clip for shot %s" % (model, shot["id"]) if shot else "%s clip" % model)[:60]


def higgsfield_run(s, job_path):
    """Detached: run the job, download the result, put it on its shot."""
    import urllib.request
    lock = job_lock(job_path[:-5] + ".lock")  # held while it runs: get_job and the app read a free lock as lost
    job = json.load(open(job_path))
    cli = higgsfield_cli()
    try:
        if not cli:
            raise ValueError("Higgsfield is not installed. " + HF_SETUP)
        r = subprocess.run(cli + job["args"], capture_output=True, text=True, timeout=40 * 60, stdin=subprocess.DEVNULL)
        out = (r.stdout + "\n" + r.stderr).strip()
        if r.returncode != 0:
            raise ValueError(hf_problem(out))
        url = hf_result_url(r.stdout, job["kind"]) or hf_result_url(out, job["kind"])
        if not url:
            raise ValueError("Higgsfield finished but gave no file: " + hf_problem(out))
        if url.startswith("file://") and not os.environ.get("TAKES_HIGGSFIELD_CMD"):
            raise ValueError("Higgsfield gave a local path, not a download.")
        dest = os.path.join(s, job["file"])
        real = os.path.splitext(url.split("?")[0])[1].lower()
        if real in MEDIA_EXT[job["kind"]] and real != os.path.splitext(dest)[1]:
            dest = os.path.splitext(dest)[0] + real
            job["file"] = os.path.relpath(dest, s)
        with urllib.request.urlopen(url, timeout=600) as res, open(dest + ".part", "wb") as f:
            shutil.copyfileobj(res, f)
        os.replace(dest + ".part", dest)
        job.update(status="done", url=url, ended=now_iso(), model=hf_label(job))
        note_model(s, job["file"], job["model"])
        if job.get("shot"):
            def done(x):
                x.pop("generating", None)
                x.pop("clip_error", None)
                put_clip(x, job["file"])
            edit_shot(s, job["shot"], done)
    except Exception as e:
        job.update(status="error", error=str(e)[:300], ended=now_iso())
        if job.get("shot"):
            def failed(x):
                x.pop("generating", None)
                x["clip_error"] = job["error"]
            edit_shot(s, job["shot"], failed)
    hf_save_job(s, job)
    job_unlock(lock, job_path[:-5] + ".lock")


# ---------- Replicate: AI video, pay per clip (2026-10-09) ----------
#
# The same models as Higgsfield (Seedance 2.5 and the rest) at Replicate's price per second, with no
# plan. The API key sits in the login Keychain ("Takes Replicate"), saved from Takes › Plugins ›
# Replicate. The user keeps a short list of default models there (_library/replicate.json, first one
# is the default); everything else (length, shape, sound, reference images) the chat sets per job
# from the model's own inputs (replicate_model). A job runs detached like a Higgsfield one, in the
# same generated/.jobs folder.

REP_API = "https://api.replicate.com/v1"
REP_KEYCHAIN = "Takes Replicate"
REP_SETUP = "Open Takes › Plugins › Replicate and paste your Replicate API token."
REP_DEFAULT_MODELS = ["bytedance/seedance-2.5"]
REP_AGENT = "Takes (+https://gettakes.app)"
# Takes' own words for a job, and the input names models use for them, most usual first.
REP_INPUTS = {
    "image": ("image", "start_image", "first_frame_image", "first_frame", "input_image", "image_url"),
    "end_image": ("end_image", "last_frame_image", "last_frame", "end_frame", "tail_image"),
    "video": ("video", "input_video", "video_url"),
    "duration": ("duration", "seconds", "length"),
    "aspect_ratio": ("aspect_ratio", "ratio"),
    "resolution": ("resolution",),
    "audio": ("generate_audio", "with_audio", "audio"),
}


def rep_key():
    """REPLICATE_API_TOKEN, else the Keychain, else ~/.claude/.env."""
    if os.environ.get("REPLICATE_API_TOKEN"):
        return os.environ["REPLICATE_API_TOKEN"]
    if not os.environ.get("TAKES_NO_KEYCHAIN"):
        try:
            r = subprocess.run(["security", "find-generic-password", "-s", REP_KEYCHAIN, "-a", "api-key", "-w"],
                               capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
    try:
        for line in open(os.path.expanduser("~/.claude/.env")):
            k, _, v = line.strip().partition("=")
            if k.strip().removeprefix("export ").strip() == "REPLICATE_API_TOKEN":
                return v.strip().strip('"').strip("'") or None
    except OSError:
        pass
    return None


def rep_save_key(key):
    """Into the login Keychain through security's stdin, never its arguments. Empty removes it."""
    key = key.strip()
    if not key:
        cmd = 'delete-generic-password -s "%s" -a api-key\n' % REP_KEYCHAIN
    else:
        if not re.fullmatch(r"[A-Za-z0-9_\-]{20,200}", key):
            raise ValueError("That does not look like a Replicate API token (it starts with r8_).")
        cmd = 'add-generic-password -U -s "%s" -a api-key -w "%s"\n' % (REP_KEYCHAIN, key)
    r = subprocess.run(["security", "-i"], input=cmd, capture_output=True, text=True, timeout=20)
    if key and r.returncode != 0:
        raise ValueError("The Keychain did not take the token.")


def rep_problem(code, body):
    try:
        d = json.loads(body)
        why = d.get("detail") or d.get("title") or body
    except ValueError:
        why = body
    why = (why if isinstance(why, str) else json.dumps(why))[:300]
    if code == 401:
        return "Replicate said the token is wrong. " + REP_SETUP
    if code == 402:
        return "Replicate says the account has no credit left: add some at replicate.com/account/billing."
    if code == 404:
        return "Replicate has no such model (%s). Names look like owner/name, e.g. bytedance/seedance-2.5." % why
    return "Replicate: %s" % why


def rep_http(method, path, body=None, upload=None):
    """One Replicate call: a JSON body, or upload=<file path> for the files API. Returns the JSON."""
    import urllib.request
    import uuid
    key = rep_key()
    if not key:
        raise ValueError("No Replicate API token. " + REP_SETUP)
    # Cloudflare in front of Replicate turns away Python's own User-Agent ("error code: 1010", 2026-10-09).
    headers = {"Authorization": "Bearer " + key, "User-Agent": REP_AGENT}
    data = None
    if upload:
        b = uuid.uuid4().hex
        data = (b'--%s\r\nContent-Disposition: form-data; name="content"; filename="%s"\r\n'
                b'Content-Type: application/octet-stream\r\n\r\n' % (b.encode(), os.path.basename(upload).encode())
                + open(upload, "rb").read() + b"\r\n--%s--\r\n" % b.encode())
        headers["Content-Type"] = "multipart/form-data; boundary=" + b
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    url = path if path.startswith("https://") else REP_API + path
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise ValueError(rep_problem(e.code, e.read().decode(errors="replace")))
    except urllib.error.URLError as e:
        raise ValueError("Replicate did not answer: %s" % e.reason)


def rep_config_path():
    return os.path.join(root(), LIB, "replicate.json")


def rep_models():
    """The user's default video models, the first one is the default."""
    try:
        m = json.load(open(rep_config_path())).get("models")
        if isinstance(m, list) and m:
            return [str(x) for x in m]
    except (OSError, ValueError, AttributeError):
        pass
    return list(REP_DEFAULT_MODELS)


def rep_set_models(models):
    clean = []
    for m in models:
        m = str(m).strip().removeprefix("https://replicate.com/").strip("/")
        if not re.fullmatch(r"[\w.\-]+/[\w.\-]+(:[0-9a-f]{64})?", m):
            raise ValueError("A model is owner/name, e.g. bytedance/seedance-2.5: %r is not." % m)
        if m not in clean:
            clean.append(m)
    p = rep_config_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump({"models": clean}, f, indent=2)
    os.replace(p + ".tmp", p)
    return clean


def rep_model_info(model):
    """The model's page facts and its inputs (name -> schema), from its latest version."""
    name, _, version = model.partition(":")
    m = rep_http("GET", "/models/" + name)
    if version:
        v = rep_http("GET", "/models/%s/versions/%s" % (name, version))
    else:
        v = m.get("latest_version") or {}
    schemas = ((v.get("openapi_schema") or {}).get("components") or {}).get("schemas") or {}
    props = (schemas.get("Input") or {}).get("properties") or {}
    for p in props.values():  # enums sit in other schemas: {"allOf": [{"$ref": "#/components/schemas/x"}]}
        for ref in p.get("allOf") or []:
            target = schemas.get(str(ref.get("$ref", "")).rsplit("/", 1)[-1]) or {}
            for k in ("enum", "type"):
                if k in target:
                    p.setdefault(k, target[k])
    return {"model": model, "title": m.get("name") or name.split("/")[-1], "description": m.get("description"),
            "runs": m.get("run_count"), "official": bool(m.get("is_official")) or None,
            "version": version or v.get("id"), "inputs": props,
            "required": (schemas.get("Input") or {}).get("required") or []}


def rep_label(model):
    """'bytedance/seedance-2.5' -> 'Seedance 2.5'."""
    name = model.split("/")[-1].split(":")[0]
    # i2v, t2v, r2v read as I2V.
    return " ".join(w.upper() if re.fullmatch(r"[a-z]2[a-z]", w) else w if w[:1].isdigit() else w.capitalize()
                    for w in re.split(r"[-_]", name) if w)


def rep_is_file(schema):
    """A file input: a uri string, or a list of them."""
    if schema.get("format") == "uri":
        return True
    items = schema.get("items") or {}
    return schema.get("type") == "array" and items.get("format") == "uri"


def rep_input(s, info, a, shot):
    """The prediction's input: Takes' words mapped to the model's names, then params as they are.
    File inputs keep session refs ('sketch', a take number, a path); the runner uploads them."""
    props = info["inputs"]
    out, dropped = {}, []

    def put(word, value):
        if value is None or value == "":
            return
        name = next((n for n in REP_INPUTS[word] if n in props), None)
        if word == "audio" and name and props[name].get("type") != "boolean":
            name = None  # an 'audio' input that is a sound file, not a switch
        if not name:
            dropped.append(word)
            return
        out[name] = value

    if a.get("prompt") and "prompt" in props:
        out["prompt"] = a["prompt"].strip()
    put("image", a.get("image") or a.get("start_image"))
    put("end_image", a.get("end_image"))
    put("video", a.get("video"))
    if (a.get("aspect_ratio") or "").strip():
        put("aspect_ratio", a["aspect_ratio"].strip())
    elif shot and any(n in props for n in REP_INPUTS["aspect_ratio"]):  # the storyboard's shape
        ratio = read_storyboard(s).get("format") or DEFAULT_FORMAT
        enum = props.get(next(n for n in REP_INPUTS["aspect_ratio"] if n in props), {}).get("enum")
        # Seedance has no 4:5 (the default board): its "adaptive" follows the frame instead.
        if enum and ratio not in enum:
            ratio = "adaptive" if "adaptive" in enum else None
        put("aspect_ratio", ratio)
    duration = a.get("duration")
    if not duration and shot:
        duration = max(4, min(15, round(shot_seconds(shot))))
    put("duration", duration)
    put("resolution", a.get("resolution"))
    if a.get("audio") is not None:
        put("audio", bool(a["audio"]))
    for k, v in (a.get("params") or {}).items():
        if k not in props:
            raise ValueError("%s takes no input %r. Its inputs: %s." % (info["model"], k, ", ".join(sorted(props))))
        out[k] = v
    for k, v in list(out.items()):  # the types the model asks for
        t = props.get(k, {}).get("type")
        try:
            if t == "integer" and not isinstance(v, bool):
                out[k] = int(round(float(v)))
            elif t == "number" and not isinstance(v, bool):
                out[k] = float(v)
            elif t == "string" and isinstance(v, (int, float)) and not isinstance(v, bool):
                out[k] = str(int(v)) if float(v).is_integer() else str(v)
        except (TypeError, ValueError):
            raise ValueError("%s wants a %s for %s, not %r." % (info["model"], t, k, v))
        enum = props.get(k, {}).get("enum")
        if enum and out[k] not in enum:
            raise ValueError("%s for %s is one of %s." % (info["model"], k, ", ".join(map(str, enum))))
    missing = [r for r in info["required"] if r not in out]
    if missing:
        raise ValueError("%s needs %s." % (info["model"], ", ".join(missing)))
    return out, dropped


def t_replicate_model(a):
    """A model's inputs, so a job can set what the user asks for."""
    info = rep_model_info((a.get("model") or rep_models()[0]).strip())
    keep = ("type", "description", "default", "enum", "minimum", "maximum", "format")
    return {k: info[k] for k in ("model", "title", "description", "runs", "required")} | {
        "inputs": {n: {k: p[k] for k in keep if k in p} for n, p in info["inputs"].items()},
        "defaults": rep_models()}


def t_replicate_status(a):
    out = {"token": rep_key() is not None, "models": rep_models(), "default": rep_models()[0]}
    if not out["token"]:
        out["note"] = "No Replicate API token. " + REP_SETUP
    else:
        try:
            acc = rep_http("GET", "/account")
            out["account"] = acc.get("username") or acc.get("name")
        except ValueError as e:
            out["problem"] = str(e)
    if a.get("session"):
        s = resolve_session(a["session"])
        out["jobs"] = [{k: j.get(k) for k in ("id", "file", "status", "model", "shot", "error", "started", "ended")}
                       for j in hf_jobs(s) if j.get("provider") == "replicate"][-10:]
    return out


# The browser on Plugins › Replicate (2026-10-09): a short hand-picked list, then the most run video
# models from Replicate's two video collections. Only official models: they run by name and keep a
# steady price. Each one brings a preview (its cover, and its example output when that is a video).
REP_FEATURED = ["bytedance/seedance-2.5", "kwaivgi/kling-v3-omni-video", "wan-video/wan-2.7-i2v",
                "minimax/hailuo-2.3", "runwayml/gen-4.5", "luma/ray-3.2"]
REP_COLLECTIONS = ("image-to-video", "text-to-video")
REP_CATALOG_HOURS = 24


def rep_card(m):
    """One model for the browser: name, runs, words and preview files."""
    ex = (m.get("default_example") or {}).get("output")
    files = [m.get("cover_image_url")] + (ex if isinstance(ex, list) else [ex])
    files = [f for f in files if isinstance(f, str) and f.startswith("https://")]
    is_video = lambda f: urllib.parse.urlparse(f).path.lower().endswith((".mp4", ".mov", ".webm"))
    name = "%s/%s" % (m["owner"], m["name"])
    return {"model": name, "label": rep_label(name), "description": (m.get("description") or "").strip(),
            "runs": m.get("run_count") or 0, "url": m.get("url") or "https://replicate.com/" + name,
            "image": next((f for f in files if not is_video(f)), None),
            "video": next((f for f in files if is_video(f)), None)}


def t_replicate_catalog(a):
    """Featured and most popular video models on Replicate, kept a day in _library."""
    p = os.path.join(root(), LIB, "replicate-catalog.json")
    try:
        if not a.get("fresh") and time.time() - os.path.getmtime(p) < REP_CATALOG_HOURS * 3600:
            return json.load(open(p))
    except (OSError, ValueError):
        pass
    found = {}
    for slug in REP_COLLECTIONS:
        for m in rep_http("GET", "/collections/" + slug).get("models", []):
            if m.get("is_official"):
                found.setdefault("%s/%s" % (m["owner"], m["name"]), m)

    def one(name):
        try:
            return found.get(name) or rep_http("GET", "/models/" + name)
        except ValueError:
            return None  # gone from Replicate: the list goes on without it
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        featured = [rep_card(m) for m in pool.map(one, REP_FEATURED) if m]
    picked = {c["model"] for c in featured}
    popular = sorted((m for n, m in found.items() if n not in picked), key=lambda m: -(m.get("run_count") or 0))
    out = {"featured": featured, "popular": [rep_card(m) for m in popular[:12]], "updated": time.time()}
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump(out, f)
    os.replace(p + ".tmp", p)
    return out


# ---------- model details (2026-10-09): the card's sheet on Plugins › Replicate and › Higgsfield.
# One shape for both: price rows, speed, what the model takes, its settings, the user's own clips.

def secs_text(x):
    x = int(round(x))
    return "%d s" % x if x < 60 else "%d min %d s" % (x // 60, x % 60) if x % 60 else "%d min" % (x // 60)


def jobs_everywhere():
    """Every AI job in every session, newest last: for "your clips took about…"."""
    out = []
    for d in glob.glob(os.path.join(root(), "*", "*", GENERATED_DIR, ".jobs")):
        out += hf_jobs(os.path.dirname(os.path.dirname(d)))
    return sorted(out, key=lambda j: j.get("started") or "")


def yours(match):
    """'You made 3 clips with it: about 2 min 10 s each.' from the done jobs that match."""
    took = []
    for j in jobs_everywhere():
        if j.get("status") == "done" and match(j) and j.get("started") and j.get("ended"):
            try:
                t0, t1 = (datetime.strptime(j[k], "%Y-%m-%dT%H:%M:%SZ") for k in ("started", "ended"))
                took.append((t1 - t0).total_seconds())
            except ValueError:
                pass
    if not took:
        return None
    took.sort()
    n = len(took)
    return "You made %d clip%s with it: about %s each." % (n, "" if n == 1 else "s", secs_text(took[n // 2]))


def options_text(name, p):
    """A setting's choices in a few words: '480p, 720p', '4 to 15 s', 'on by default'."""
    if p.get("enum"):
        return ", ".join(str(x) for x in p["enum"] if x not in (None, ""))
    lo, hi = p.get("minimum"), p.get("maximum")
    unit = " s" if name == "duration" else ""
    if lo is not None and hi is not None:
        return "up to %s%s" % (hi, unit) if lo < 1 else "%s to %s%s" % (lo, hi, unit)  # -1 means "the model picks"
    if p.get("type") == "boolean":
        return "on by default" if p.get("default") else "off by default"
    if p.get("default") is not None:
        return "%s%s by default" % (p["default"], unit)
    return None


# Takes' words for a model's settings and media inputs, both providers.
DETAIL_SETTINGS = (("duration", "Length"), ("resolution", "Quality"), ("aspect_ratio", "Shape"))
DETAIL_TAKES = (("image", "Start frame"), ("end_image", "End frame"), ("video", "Video in"),
                ("image_references", "Reference images"), ("reference_images", "Reference images"),
                ("video_references", "Reference videos"), ("reference_videos", "Reference videos"),
                ("audio_references", "Reference sounds"), ("reference_audios", "Reference sounds"),
                ("audio", "Sound"))


def detail_from_inputs(inputs, name_of):
    """Settings and the media a model takes, from {input name: schema}. name_of maps Takes' word to
    the model's own input name (None when it has none)."""
    settings = []
    for word, title in DETAIL_SETTINGS:
        n = name_of(word)
        v = n and options_text(word, inputs[n])
        if v:
            settings.append({"name": title, "value": v})
    takes = []
    for word, title in DETAIL_TAKES:
        n = name_of(word)
        if n and title not in takes:
            takes.append(title)
    return settings, takes


def rep_page_prices(model):
    """The price rows from the model's replicate.com page (the API has no prices): [{when, price}]."""
    import urllib.request
    req = urllib.request.Request("https://replicate.com/" + model.split(":")[0], headers={"User-Agent": REP_AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        html = r.read().decode(errors="replace")
    key = '"billingConfig":'
    i = html.find(key)
    if i < 0:
        return []
    cfg, _ = json.JSONDecoder().raw_decode(html[i + len(key):].lstrip())
    rows = []
    for tier in (cfg or {}).get("current_tiers") or []:
        when = []
        for c in tier.get("criteria") or []:
            v, title = c.get("value"), (c.get("title") or "").strip()
            if isinstance(v, bool):
                when.append(title if v else title.replace("with ", "without ", 1) if title.startswith("with ") else "no " + title)
            else:
                when.append(str(v).replace("non_video_in", "no video in").replace("video_in", "video in").replace("_", " "))
        for pr in tier.get("prices") or []:
            title = pr.get("title") or ""
            unit = "a second" if "per second" in title else "a video" if "per output video" in title else title
            rows.append({"when": ", ".join(when) or "every run", "price": "%s %s" % (pr.get("price"), unit),
                         "per_second": "per second" in title, "dollars": float(re.sub(r"[^\d.]", "", pr.get("price") or "") or 0)})
    return rows


def t_replicate_details(a):
    """Price, speed, settings and inputs of one Replicate model, kept a day."""
    model = (a.get("model") or rep_models()[0]).strip()
    p = os.path.join(root(), LIB, "replicate-details.json")
    # v2: "up to 30 s" for a minimum of -1; an older copy is read again.
    try:
        cache = json.load(open(p))
    except (OSError, ValueError):
        cache = {}
    hit = cache.get(model)
    if hit and hit.get("v") == 2 and time.time() - hit.get("updated", 0) < REP_CATALOG_HOURS * 3600 and not a.get("fresh"):
        hit["yours"] = yours(lambda j: j.get("provider") == "replicate" and j.get("model") == model)
        return hit
    info = rep_model_info(model)
    m = rep_http("GET", "/models/" + model.split(":")[0])
    inputs = info["inputs"]

    def name_of(word):
        if word in REP_INPUTS:
            return next((n for n in REP_INPUTS[word] if n in inputs), None)
        return word if word in inputs else None
    settings, takes = detail_from_inputs(inputs, name_of)
    try:
        prices = rep_page_prices(model)
    except Exception:  # the page changed or did not answer: the sheet links to it instead
        prices = []
    clip = None
    per_s = [r["dollars"] for r in prices if r["per_second"] and r["dollars"]]
    if per_s:
        lo, hi = 5 * min(per_s), 5 * max(per_s)
        clip = "A 5 s clip costs $%.2f" % lo + (" to $%.2f, by its settings." % hi if hi > lo else ".")
    ex = m.get("default_example") or {}
    took = (ex.get("metrics") or {}).get("predict_time")
    speed = None
    if took:
        inp = ex.get("input") or {}
        what = ", ".join(x for x in ("%s s" % inp["duration"] if inp.get("duration") else "", inp.get("resolution") or "") if x)
        speed = "Replicate's example%s took %s." % (" (%s)" % what if what else "", secs_text(took))
    card = rep_card(m)
    out = {"model": model, "label": card["label"], "description": card["description"], "page": card["url"],
           "image": card["image"], "video": card["video"], "runs": card["runs"],
           "prices": [{"when": r["when"], "price": r["price"]} for r in prices], "price_note": clip,
           "speed": speed, "settings": settings, "takes": takes, "updated": time.time(), "v": 2}
    cache[model] = out
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump(cache, f)
    os.replace(p + ".tmp", p)
    return out | {"yours": yours(lambda j: j.get("provider") == "replicate" and j.get("model") == model)}


# Plugins › Higgsfield's browser. Higgsfield shares no previews or run counts, so Featured is a
# hand-picked list, each shown with the same model's example from Replicate (when Replicate is
# connected); the rest of its video models follow without pictures. Tools (upscale, background
# removal, ads) stay out: they make no new footage.
HF_FEATURED = [("seedance_2_5", "bytedance/seedance-2.5"), ("kling3_0", "kwaivgi/kling-v3-video"),
               ("kling_o3_image_reference", "kwaivgi/kling-v3-omni-video"), ("wan3_0", "alibaba/wan-3"),
               ("seedance_2_0", "bytedance/seedance-2.0"), ("happy_horse_video", "alibaba/happyhorse-1.1"),
               ("grok_video_v15", "xai/grok-imagine-video"), ("seedance1_5", "bytedance/seedance-1.5-pro")]
HF_NOT_FOOTAGE = re.compile(r"upscale|deflicker|background|depth|fps_boost|topaz|clipify|ad_multiplier|hf_mult|sam_3|edit")


def hf_video_models():
    ok, out = hf_call(["model", "list", "--video", "--json"], timeout=60)
    if not ok:
        raise ValueError(hf_problem(out))
    return {m["job_type"]: m.get("display_name") or m["job_type"] for m in json.loads(out)}


def t_higgsfield_catalog(a):
    p = os.path.join(root(), LIB, "higgsfield-catalog.json")
    try:
        if not a.get("fresh") and time.time() - os.path.getmtime(p) < REP_CATALOG_HOURS * 3600:
            return json.load(open(p)) | {"default": hf_default_model()}
    except (OSError, ValueError):
        pass
    names = hf_video_models()

    def card(job, rep_model=None):
        c = {"model": job, "label": names[job], "description": "", "runs": 0, "url": None, "image": None, "video": None}
        if rep_model and rep_key():
            try:
                r = rep_card(rep_http("GET", "/models/" + rep_model))
                c |= {"description": r["description"], "image": r["image"], "video": r["video"], "preview_from": rep_model}
            except ValueError:
                pass
        return c
    picks = [(j, r) for j, r in HF_FEATURED if j in names]
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        featured = list(pool.map(lambda x: card(*x), picks))
    taken = {j for j, _ in picks}
    more = [card(j) for j in sorted(names, key=lambda j: names[j].lower()) if j not in taken and not HF_NOT_FOOTAGE.search(j)]
    out = {"featured": featured, "more": more, "updated": time.time()}
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump(out, f)
    os.replace(p + ".tmp", p)
    return out | {"default": hf_default_model()}


def t_higgsfield_details(a):
    """Credits for a clip at each quality (Higgsfield's own estimate, free), settings, inputs."""
    job = (a.get("model") or hf_default_model()).strip()
    ok, out = hf_call(["model", "get", job, "--json"], timeout=60)
    if not ok:
        raise ValueError(hf_problem(out))
    m = json.loads(out)
    inputs = {x["name"]: x for x in m.get("params") or []}
    alias = {"image": ("start_image", "image", "first_frame"), "end_image": ("end_image", "last_frame"),
             "video": ("video",), "audio": ("generate_audio", "audio")}

    def name_of(word):
        return next((n for n in alias.get(word, (word,)) if n in inputs), None)
    settings, takes = detail_from_inputs(inputs, name_of)
    res = (inputs.get("resolution") or {}).get("enum") or [None]
    has_len = "duration" in inputs

    def cost(r):
        args = ["generate", "cost", job, "--prompt", "a calm shot", "--json"]
        if has_len:
            args += ["--duration", "5"]
        if r:
            args += ["--resolution", r]
        ok, out = hf_call(args, timeout=45)
        try:
            return {"when": ", ".join(x for x in ("5 s" if has_len else "", r or "") if x) or "one clip",
                    "price": "%s credits" % json.loads(out)["credits"]} if ok else None
        except (ValueError, KeyError):
            return None
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        prices = [x for x in pool.map(cost, res) if x]
    note = None
    ok, acct = hf_call(["account", "status"], timeout=30)
    left = re.search(r"([\d,]+) credits", acct or "") if ok else None
    if left and prices:
        n = int(left.group(1).replace(",", ""))
        cheapest = min(int(x["price"].split()[0]) for x in prices)
        note = "You have %d credits: about %d clips at %s." % (n, n // max(cheapest, 1),
                                                                 next(x["when"] for x in prices if int(x["price"].split()[0]) == cheapest))
    elif not prices:
        note = "Higgsfield gives no estimate without the model's media. Ask Takes for the price of a real clip."
    return {"model": job, "label": m.get("display_name") or job, "description": "", "page": None,
            "prices": prices, "price_note": note,
            "speed": None, "settings": settings, "takes": takes, "default": hf_default_model() == job,
            "yours": yours(lambda j: j.get("provider") != "replicate" and (j.get("args") or [None] * 3)[2:3] == [job])}


def t_replicate(a):
    """Start a Replicate job. The file lands in generated/ when it is done."""
    s = resolve_session(a["session"])
    if not rep_key():
        raise ValueError("No Replicate API token. " + REP_SETUP)
    model = (a.get("model") or rep_models()[0]).strip().removeprefix("https://replicate.com/").strip("/")
    shot = None
    if a.get("shot"):
        shot = next((x for x in read_storyboard(s)["shots"] if x.get("id") == a["shot"]), None)
        if not shot:
            raise ValueError("No shot %s in the storyboard. get_session lists the ids." % a["shot"])
    info = rep_model_info(model)
    inp, dropped = rep_input(s, info, a, shot)
    # Every file input must be a session file now, not when the runner gets to it.
    files = {}
    for k, v in inp.items():
        if rep_is_file(info["inputs"].get(k, {})):
            for ref in (v if isinstance(v, list) else [v]):
                if not str(ref).startswith(("http://", "https://", "data:")):
                    files[str(ref)] = rep_local(s, ref, shot)
    name = slug(a.get("name") or (shot and "shot-%s" % shot["id"]) or " ".join((a.get("prompt") or "").split()[:5]) or "clip") or "clip"
    d = os.path.join(s, GENERATED_DIR)
    os.makedirs(d, exist_ok=True)
    have = versions_in(d, name)
    n = (have[-1] if have else 0) + 1
    rel = os.path.join(GENERATED_DIR, "%s-v%d.mp4" % (name, n))
    job = {"id": "%s-v%d" % (name, n), "provider": "replicate", "file": rel, "kind": "video", "model": model,
           "version": info["version"] if ":" in model else None, "input": inp, "files": files,
           "shot": shot and shot["id"], "status": "running", "started": now_iso(),
           "label": clip_label(rep_label(model), shot), "from_chat": from_chat()}
    path = hf_save_job(s, job)
    if shot:
        def mark(x):
            x["generating"] = rel
            x.pop("clip_error", None)
        edit_shot(s, shot["id"], mark)
    start_replicate(s, path)
    note = ("Replicate works in the background (a video takes 1-5 min). The file lands at %s and shows on the "
            "Assets tab%s. replicate_status shows how it went. Replicate bills the user per second of video."
            % (rel, "; the shot plays it then" if shot else ""))
    if dropped:
        note += " %s takes no %s, so it was left out (replicate_model lists its inputs)." % (model, ", ".join(dropped))
    return {"file": rel, "job": job["id"], "model": model, "input": inp, "note": note}


def start_replicate(s, job_path):
    spawn_detached(["--replicate-run", s, job_path])


def rep_local(s, ref, shot):
    ref = str(ref).strip()
    if ref == "sketch":
        if not shot or not shot.get("image"):
            raise ValueError("'sketch' needs a shot whose sketch is drawn.")
        return os.path.join(s, STORYBOARD_DIR, shot["image"])
    p = session_file(s, ref)
    if not os.path.isfile(p):
        raise ValueError("No file %s in the session." % ref)
    return p


def rep_output_url(out):
    """The video in a prediction's output: a URL, a list of them, or a dict holding them."""
    found = []

    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, str) and re.match(r"^https?://\S+$", v.strip()):
            found.append(v.strip())
    walk(out)
    ext = lambda u: os.path.splitext(u.split("?")[0])[1].lower()
    return next((u for u in found if ext(u) in MEDIA_EXT["video"]), found[0] if found else None)


def rep_download(url, dest):
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": REP_AGENT})
    with urllib.request.urlopen(req, timeout=600) as res, open(dest + ".part", "wb") as f:
        shutil.copyfileobj(res, f)
    os.replace(dest + ".part", dest)


def replicate_run(s, job_path, poll=5):
    """Detached: upload the files, start the prediction, wait for it, download the video."""
    import time
    lock = job_lock(job_path[:-5] + ".lock")
    job = json.load(open(job_path))
    try:
        inp = dict(job["input"])
        uploaded = {}
        for ref, local in (job.get("files") or {}).items():
            uploaded[ref] = rep_http("POST", "/files", upload=local)["urls"]["get"]
        for k, v in inp.items():
            if isinstance(v, list):
                inp[k] = [uploaded.get(str(x), x) for x in v]
            elif str(v) in uploaded:
                inp[k] = uploaded[str(v)]
        if job.get("version"):
            p = rep_http("POST", "/predictions", {"version": job["version"], "input": inp})
        else:
            p = rep_http("POST", "/models/%s/predictions" % job["model"], {"input": inp})
        job["prediction"] = p.get("id")
        hf_save_job(s, job)
        deadline = time.time() + 40 * 60
        while p.get("status") not in ("succeeded", "failed", "canceled"):
            if time.time() > deadline:
                raise ValueError("Replicate did not finish in 40 min (prediction %s)." % p.get("id"))
            time.sleep(poll)
            p = rep_http("GET", (p.get("urls") or {}).get("get") or "/predictions/" + p["id"])
        if p["status"] != "succeeded":
            raise ValueError("Replicate: %s" % (p.get("error") or p["status"]))
        url = rep_output_url(p.get("output"))
        if not url:
            raise ValueError("Replicate finished but gave no file.")
        dest = os.path.join(s, job["file"])
        real = os.path.splitext(url.split("?")[0])[1].lower()
        if real in MEDIA_EXT["video"] and real != os.path.splitext(dest)[1]:
            dest = os.path.splitext(dest)[0] + real
            job["file"] = os.path.relpath(dest, s)
        rep_download(url, dest)
        secs = (p.get("metrics") or {}).get("predict_time")
        job.update(status="done", url=url, ended=now_iso(), seconds=secs)
        note_model(s, job["file"], rep_label(job["model"]) + " · Replicate")
        if job.get("shot"):
            def done(x):
                x.pop("generating", None)
                x.pop("clip_error", None)
                put_clip(x, job["file"])
            edit_shot(s, job["shot"], done)
    except Exception as e:
        job.update(status="error", error=str(e)[:300], ended=now_iso())
        if job.get("shot"):
            def failed(x):
                x.pop("generating", None)
                x["clip_error"] = job["error"]
            edit_shot(s, job["shot"], failed)
    hf_save_job(s, job)
    job_unlock(lock, job_path[:-5] + ".lock")


# ---------- the post (same format as Sources/Takes/Post.swift) ----------
#
# One post per platform in each session. LinkedIn keeps the first layout; X has its own folder.
#
#   posts/linkedin.md        posts/x.md              the post. Optional front matter:
#       media: edits/x-v3.mp4             the video or image; without it the app shows the newest edit
#       status: ready                     draft (no field) | ready | scheduled | posted
#       at: 2026-10-01T09:00:00-07:00     when the user wants it out (he sets it with [schedule] on the post tab)
#       tz: America/Los_Angeles           the time zone he picked for it
#       scheduled_at / scheduled_hash     what Claude scheduled: the time and the text's hash
#       url                               the live post
#   posts/variants/          posts/x/variants/       other versions (front matter name, author, note, created),
#                                                    shown as tabs. Only the main post goes out.
#   posts/hooks.json         posts/x/hooks.json      opening options. Picking one replaces the first paragraph.
#   posts/history/           posts/x/history/        every version: <stamp>-<linkedin|x|slug>.md
#                                                    (front matter author, note, created, draft)
#   posts/first-comment.md   (LinkedIn only)         the first comment under the live post
#
# An X post is one tweet, or a thread: tweets separated by a line with only '---'. With X Premium
# a tweet can run to 25,000 characters; the timeline cuts it after 280 with "Show more".

PLATFORMS = {
    "linkedin": {"name": "LinkedIn", "post": os.path.join("posts", "linkedin.md"), "dir": "posts",
                 "suffix": "linkedin", "limit": 3000},
    "x": {"name": "X", "post": os.path.join("posts", "x.md"), "dir": os.path.join("posts", "x"),
          "suffix": "x", "limit": 25000},
    # The long wide video. Front matter title; the text is the description.
    "youtube": {"name": "YouTube", "post": os.path.join("posts", "youtube.md"), "dir": os.path.join("posts", "youtube"),
                "suffix": "youtube", "limit": 5000},
    # One vertical video and caption for TikTok, Reels and Shorts. Front matter on (the places; none
    # means all three) and title (the Shorts title). Limit: Instagram's caption, the shortest.
    "vertical": {"name": "Vertical", "post": os.path.join("posts", "vertical.md"), "dir": os.path.join("posts", "vertical"),
                 "suffix": "vertical", "limit": 2200},
    # A post for the user's blog, later also a LinkedIn and an X article. Markdown with the
    # blog's MDX components. Front matter title, description, category (Tech | Life | Business), slug.
    "article": {"name": "Article", "post": os.path.join("posts", "article.md"), "dir": os.path.join("posts", "article"),
                "suffix": "article", "limit": 200000},
}
# The blog article is a private feature (2026-10-05), like Comments and Performance: the public copy
# sets BLOG = False (scripts/public/export.py) and has no article platform.
BLOG = False
if not BLOG:
    del PLATFORMS["article"]
# The comment copilot and the Performance board (Features.socialBoards in the app) are private too
# (2026-10-09): the public copy sets SOCIAL = False and its server lists none of their tools.
SOCIAL = False
SOCIAL_TOOLS = {"get_comment_context", "add_comment_suggestion", "redraft_comment", "list_comment_suggestions",
                "set_comment_posted", "set_comment_stats", "set_post_stats", "get_performance",
                # Ideas (2026-10-10): The user's own list, admin only for now.
                "add_idea", "list_ideas", "get_idea", "update_idea"}
ARTICLE_CATEGORIES = ["Tech", "Life", "Business"]
ARTICLE_SITE_REPO = "marvtub/personal-website"
# The blog's components (components/mdx on the site); the app's preview draws each the same way.
ARTICLE_COMPONENTS = (
    "Markdown as the blog renders it: # headings (## for sections), paragraphs, **bold**, *italic*, `code`, "
    "[links](url), > quotes, - and 1. lists, ``` fenced code (no syntax colours), ![alt](path) pictures (a path in "
    "the session such as thumbnails/x.png or stills/x.jpg, or /images/x.webp from the site, or a URL). No tables, "
    "no footnotes (the site has no GFM). The blog's components, one per block: "
    "<Callout type=\"tip|warning|note\">text</Callout>; <Terminal>$ commands</Terminal> (plain text, add command "
    "for a $ prompt); <TLDR>- bullet list</TLDR> (the posts put it at the end); <Prompt title=\"...\">a prompt</Prompt>; "
    "<Flowchart steps={[\"step\", {decision: \"q?\", yes: \"a\", no: \"b\"}]} caption=\"...\" />; "
    "<Steps><Step title=\"...\">text</Step></Steps>; <FileTree>{`tree`}</FileTree>; <Ascii caption=\"...\">{`art`}</Ascii>; "
    "<Collapse title=\"...\">text</Collapse>; <Tweet id=\"123\" />; <Video src=\"thumbnails/x.mp4\" poster=\"thumbnails/x.jpg\" title=\"...\" /> (a 16:9 video with sound, plays on click); inline <Tooltip text=\"meaning\">word</Tooltip>.")
VERTICAL_PLACES = ["tiktok", "reels", "shorts"]
VERTICAL_NAMES = {"tiktok": "TikTok", "reels": "Instagram Reels", "shorts": "YouTube Shorts"}
TITLE_LIMIT = 100
REELS_HASHTAGS = 5  # Instagram's limit per post since December 2025
X_FEED_CUT = 280
THREAD_BREAK = "\n\n---\n\n"

POST = PLATFORMS["linkedin"]["post"]
POST_LIMIT = PLATFORMS["linkedin"]["limit"]
POST_FIELDS = ["title", "media", "on", "status", "at", "tz", "scheduled_at", "scheduled_hash", "url"]
POST_VARIANTS = os.path.join("posts", "variants")
POST_HOOKS = os.path.join("posts", "hooks.json")
POST_HISTORY = os.path.join("posts", "history")
# posts/first-comment.md: plain text the user wants as the first comment under the live post. LinkedIn's
# scheduler cannot schedule it, so it goes on once the post is live (front matter first_comment_posted).
POST_FIRST_COMMENT = os.path.join("posts", "first-comment.md")


def post_rules(p):
    """The rule files a post for platform p follows."""
    return ["post-all"] + (["post-" + p] if "post-" + p in AREAS else [])


def platform_of(a):
    """linkedin, x, youtube or vertical from a tool's platform argument (default LinkedIn). TikTok,
    Reels, Instagram and Shorts all share the vertical post."""
    p = (a.get("platform") or "linkedin").strip().lower()
    p = {"twitter": "x", "x.com": "x", "li": "linkedin", "yt": "youtube", "tiktok": "vertical", "reels": "vertical",
         "instagram": "vertical", "ig": "vertical", "shorts": "vertical", "youtube_shorts": "vertical",
         "blog": "article", "blog_post": "article"}.get(p, p)
    if p not in PLATFORMS:
        raise ValueError("platform is linkedin, x, youtube, vertical (TikTok, Reels and Shorts)"
                         + (" or article (the blog post)." if BLOG else "."))
    return p


def pf(p, key):
    """A platform's file: post, variants, hooks, history."""
    c = PLATFORMS[p]
    return {"post": c["post"], "variants": os.path.join(c["dir"], "variants"),
            "hooks": os.path.join(c["dir"], "hooks.json"), "history": os.path.join(c["dir"], "history")}[key]


def tweets(text):
    """The tweets of an X post: the text split at lines that hold only '---'."""
    parts = re.split(r"\n[ \t]*---[ \t]*(?:\n|$)", "\n" + (text or "").strip("\n") + "\n")
    return [t.strip() for t in parts if t.strip()]


def first_comment(s, p="linkedin"):
    if p != "linkedin":
        return None
    path = os.path.join(s, POST_FIRST_COMMENT)
    t = read_text(path).strip() if os.path.exists(path) else ""
    return t or None


def post_hash(text):
    return hashlib.sha1(text.strip().encode("utf-8")).hexdigest()[:12]


def post_file(s, p="linkedin"):
    """(front matter dict, text) or None."""
    path = os.path.join(s, pf(p, "post"))
    if not os.path.exists(path):
        return None
    return parse_fm(read_text(path))


def write_post_file(s, fm, text, p="linkedin"):
    fields = [(k, fm[k]) for k in POST_FIELDS if fm.get(k)] + sorted(
        (k, v) for k, v in fm.items() if k not in POST_FIELDS and v)
    path = os.path.join(s, pf(p, "post"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_text(path, render_fm(fields, text) if fields else text)


def post_media(s, fm, p="linkedin"):
    """The picked media, else (X) the LinkedIn post's pick, else the newest edited video, else the newest
    thumbnail (as the app shows). YouTube and vertical skip the LinkedIn pick: it may be the wrong shape."""
    if fm.get("media") and os.path.exists(os.path.join(s, fm["media"])):
        return os.path.join(s, fm["media"])
    if p == "x":
        li = post_file(s)
        if li and li[0].get("media") and os.path.exists(os.path.join(s, li[0]["media"])):
            return os.path.join(s, li[0]["media"])
    for folder, kind in (("edits", "video"), ("thumbnails", "image")):
        d = os.path.join(s, folder)
        files = [os.path.join(d, f) for f in os.listdir(d)] if os.path.isdir(d) else []
        files = [f for f in files if not os.path.basename(f).startswith(".") and media_kind(f) == kind]
        if files:
            # The newest file's name, then its highest version: a version saved late (publish_edit) or
            # early (a Cover click) never hides a higher one.
            top = split_version(os.path.basename(max(files, key=os.path.getmtime)))[0]
            same = [f for f in files if split_version(os.path.basename(f))[0] == top]
            return max(same, key=lambda f: (split_version(os.path.basename(f))[1] or 0, os.path.getmtime(f)))
    return None


def when_view(iso, tz=None):
    """An ISO time as the scheduler needs it: in its own zone, on this Mac and in UTC."""
    if not iso:
        return None
    t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    fmt = "%a %b %d %Y, %I:%M %p %Z"
    out = {"iso": iso, "utc": t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "this_mac": t.astimezone().strftime(fmt)}
    if tz:
        try:
            from zoneinfo import ZoneInfo
            out["local"] = "%s (%s)" % (t.astimezone(ZoneInfo(tz)).strftime(fmt), tz)
        except Exception:
            out["local"] = iso
    return out


def mac_zone():
    """This Mac's IANA time zone, e.g. America/Los_Angeles."""
    try:
        link = os.path.realpath("/etc/localtime")
        return link.split("zoneinfo/", 1)[1]
    except Exception:
        return None


def post_time(iso, tz=None):
    """An ISO time with offset, as the app stores it (at, tz). A time with no offset is read in tz,
    else in this Mac's zone."""
    t = datetime.fromisoformat(iso.strip().replace("Z", "+00:00"))
    tz = tz or mac_zone()
    from zoneinfo import ZoneInfo
    zone = ZoneInfo(tz) if tz else None
    if t.tzinfo is None:
        if zone is None:
            raise ValueError("at needs a UTC offset, e.g. 2026-09-29T09:32:00-07:00.")
        t = t.replace(tzinfo=zone)
    if zone is not None:
        t = t.astimezone(zone)
    return t.replace(microsecond=0).isoformat(), tz


def post_action(fm, text, comment=None, p="linkedin"):
    where = PLATFORMS[p]["name"] + (" (Typefully)" if p == "x" else "")
    if p == "vertical":
        where = ", ".join(VERTICAL_NAMES[x] for x in vertical_places(fm)) or "no place (the user switched all off)"
    if p == "article":
        where = "the blog (a PR to %s adding content/blog/<slug>.mdx)" % ARTICLE_SITE_REPO
    status, at = fm.get("status") or "draft", fm.get("at")
    same_time = at and fm.get("scheduled_at") and \
        datetime.fromisoformat(at.replace("Z", "+00:00")) == datetime.fromisoformat(fm["scheduled_at"].replace("Z", "+00:00"))
    if status == "draft":
        return "draft: The user has not marked it ready (schedule it only when the user says so, and pass at)"
    if status == "posted":
        if comment and not fm.get("first_comment_posted"):
            return ("add first_comment as the first comment under the live post (url), then "
                    "set_post_status posted first_comment_posted=true")
        return "posted"
    if status == "ready":
        if p == "article" and not at:
            return "publish on %s, then set_post_status posted with the post's URL" % where
        return ("schedule on %s" % where) if at else "ready, no time yet: ask the user when, or schedule it and pass at"
    # scheduled
    if not at:
        return ("The user removed its time: delete the scheduled post on %s, then set_post_status ready"
                % where)
    todo = []
    if not same_time:
        todo.append("move the scheduled post on %s to the new time" % where)
    if fm.get("scheduled_hash") != post_hash(text):
        todo.append("replace its text on %s with the current text" % where)
    return ("update on %s: " % where + " and ".join(todo) + ", then set_post_status scheduled") if todo \
        else "scheduled, nothing to do"


def x_view(text):
    ts = tweets(text)
    return {"tweets": [{"n": i + 1, "text": t, "chars": len(t), "cut_in_feed": len(t) > X_FEED_CUT}
                       for i, t in enumerate(ts)],
            "thread": len(ts) > 1}


def read_post(s, p="linkedin"):
    f = post_file(s, p)
    if f is None:
        return None
    fm, body = f
    comment = first_comment(s, p)
    limit = PLATFORMS[p]["limit"]
    out = {"platform": PLATFORMS[p]["name"], "file": pf(p, "post"), "path": os.path.join(s, pf(p, "post")),
           "text": body, "media": fm.get("media") or None, "media_path": post_media(s, fm, p),
           "chars": len(body.strip()),
           "over_limit": (max((len(t) for t in tweets(body)), default=0) if p == "x" else len(body.strip())) > limit,
           "status": fm.get("status") or "draft", "at": when_view(fm.get("at"), fm.get("tz")),
           "tz": fm.get("tz"), "scheduled_at": fm.get("scheduled_at"), "url": fm.get("url"),
           "action": post_action(fm, body, comment, p)}
    if p == "linkedin":
        out.update(first_comment=comment, first_comment_posted=bool(fm.get("first_comment_posted")))
    elif p == "x":
        out.update(x_view(body))
    elif p == "article":
        out.update(article_view(fm, body))
    else:
        out.update(video_view(fm, body, p))
    return out


def article_slug(title):
    return "-".join(re.findall(r"[a-z0-9]+", (title or "").lower()))


def article_view(fm, body):
    words = len([w for w in body.split() if re.search(r"\w", w)])
    used = sorted(set(re.findall(r"<([A-Z][A-Za-z]*)\b", body)))
    return {"title": fm.get("title") or "", "description": fm.get("description") or "",
            "category": fm.get("category") or "", "slug": fm.get("slug") or article_slug(fm.get("title")),
            "words": words, "minutes": max(1, -(-words // 200)), "components": used}


def vertical_places(fm):
    raw = fm.get("on")
    if raw is None or not raw.strip():
        return list(VERTICAL_PLACES)
    on = {x.strip().lower() for x in raw.split(",")}
    return [x for x in VERTICAL_PLACES if x in on]


def video_view(fm, body, p):
    title = fm.get("title") or ""
    out = {"title": title, "title_over_limit": len(title) > TITLE_LIMIT}
    if p == "vertical":
        tags = len(re.findall(r"(?<![\w/#@])#[\w]+", body))
        places = vertical_places(fm)
        out.update(on=places, goes_to=[VERTICAL_NAMES[x] for x in places], hashtags=tags,
                   hashtags_over_reels_limit="reels" in places and tags > REELS_HASHTAGS)
    return out


def post_draft_text(s, draft, p="linkedin"):
    if draft == "main":
        f = post_file(s, p)
        return f[1] if f else None
    path = os.path.join(s, pf(p, "variants"), draft + ".md")
    return parse_fm(read_text(path))[1] if os.path.exists(path) else None


def post_variants(s, p="linkedin"):
    d = os.path.join(s, pf(p, "variants"))
    out = []
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if name.endswith(".md"):
            fm, body = parse_fm(read_text(os.path.join(d, name)))
            out.append({"variant": name[:-3], "name": fm.get("name", name[:-3]), "author": fm.get("author", ""),
                        "note": fm.get("note", ""), "created": fm.get("created", ""), "text": body,
                        "chars": len(body.strip())})
    return sorted(out, key=lambda v: (v["created"], v["variant"]))


def write_post_variant(s, slug_, name, author, note, created, text, p="linkedin"):
    d = os.path.join(s, pf(p, "variants"))
    os.makedirs(d, exist_ok=True)
    write_text(os.path.join(d, slug_ + ".md"), render_fm(
        [("name", name), ("author", author), ("note", note), ("created", created)], text))


def post_history(s, p="linkedin"):
    """Newest first. The file name starts with a sortable stamp."""
    d = os.path.join(s, pf(p, "history"))
    out = []
    for name in sorted(os.listdir(d), reverse=True) if os.path.isdir(d) else []:
        if name.endswith(".md"):
            fm, body = parse_fm(read_text(os.path.join(d, name)))
            out.append({"version": name[:-3], "draft": fm.get("draft") or "main", "author": fm.get("author", ""),
                        "note": fm.get("note", ""), "created": fm.get("created", ""), "_body": body})
    return out


def post_snapshot(s, author, note, draft="main", p="linkedin"):
    """Keeps the draft as it is now in history, unless its last copy there is the same."""
    text = post_draft_text(s, draft, p)
    if not text or not text.strip():
        return None
    last = next((v for v in post_history(s, p) if v["draft"] == draft), None)
    if last and last["_body"] == text:
        return None
    d = os.path.join(s, pf(p, "history"))
    os.makedirs(d, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")  # sorts by time
    path = os.path.join(d, "%s-%s.md" % (stamp, PLATFORMS[p]["suffix"] if draft == "main" else draft))
    write_text(path, render_fm([("author", author), ("note", note), ("created", now_iso_ms()), ("draft", draft)], text))
    return os.path.relpath(path, s)


def post_overview(s, p="linkedin"):
    """The post as get_session shows it: the main post plus its variants, hooks and history."""
    post = read_post(s, p)
    if post is None:
        return None
    hooks = read_hooks_file(os.path.join(s, pf(p, "hooks"))).get("hooks", [])
    post.update(variants=post_variants(s, p), hooks=hooks,
                hook_in_post=next((h["id"] for h in hooks if h["text"].strip() == first_paragraph(post["text"])), None),
                history_versions=len(post_history(s, p)))
    return post


def set_post_text(s, text, author, note, p="linkedin"):
    """Main post text with history on both sides. Keeps the front matter."""
    f = post_file(s, p)
    fm = f[0] if f else {}
    post_snapshot(s, "user", "Before %s's change" % author.capitalize(), p=p)
    write_post_file(s, fm, text, p)
    post_snapshot(s, author, note, p=p)


def write_first_comment(s, text):
    path = os.path.join(s, POST_FIRST_COMMENT)
    if not text.strip():
        if os.path.exists(path):
            os.remove(path)
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_text(path, text.strip("\n") + "\n")


def post_text_arg(a, p):
    """text, or for X a list of tweets joined into a thread."""
    if p == "x" and a.get("tweets"):
        return THREAD_BREAK.join(t.strip() for t in a["tweets"] if t and t.strip())
    return a.get("text")


def t_set_post(a):
    """Write the session's post for LinkedIn (default) or X. The app shows it as a feed preview."""
    s = resolve_session(a["session"])
    p = platform_of(a)
    need_rules(*post_rules(p))
    if a.get("first_comment") is not None:
        if p != "linkedin":
            raise ValueError("first_comment is for LinkedIn. On X, put the follow-up in the thread (tweets).")
        write_first_comment(s, a["first_comment"])
    if a.get("variant"):
        return set_post_variant(s, a, p)
    old = read_post(s, p)
    text = post_text_arg(a, p)
    text = text if text is not None else (old["text"] if old else None)
    if text is None:
        raise ValueError("Give text%s." % (" or tweets" if p == "x" else ""))
    text = text.strip("\n") + "\n"
    f = post_file(s, p)
    fm = f[0] if f else {}
    media = a.get("media", fm.get("media"))
    if media:
        rel = os.path.relpath(media, s) if os.path.isabs(media) else media
        if not os.path.exists(os.path.join(s, rel)):
            raise ValueError("media %s does not exist in %s." % (rel, s))
        media = rel
    if a.get("media") is not None:  # Takes picked it: publish_edit may move it to the next version
        fm["media_by"] = "takes" if media else None
    fm["media"] = media
    if a.get("title") is not None:
        if p not in ("youtube", "vertical", "article"):
            raise ValueError("title is for youtube, vertical (the Shorts title) and article.")
        fm["title"] = a["title"].strip()
    for key in ("description", "category", "slug"):
        if a.get(key) is not None:
            if p != "article":
                raise ValueError("%s is for the article (platform=article)." % key)
            v = a[key].strip()
            if key == "category" and v and v not in ARTICLE_CATEGORIES:
                raise ValueError("category is one of %s." % ", ".join(ARTICLE_CATEGORIES))
            if key == "slug" and v:
                v = article_slug(v)
            fm[key] = v or None
    if a.get("on") is not None:
        if p != "vertical":
            raise ValueError("on is for the vertical post: which of tiktok, reels, shorts it goes to.")
        bad = [x for x in a["on"] if x not in VERTICAL_PLACES]
        if bad:
            raise ValueError("on takes tiktok, reels, shorts; not %s." % ", ".join(bad))
        fm["on"] = None if set(a["on"]) == set(VERTICAL_PLACES) else (", ".join(x for x in VERTICAL_PLACES if x in a["on"]) or "none")
    post_snapshot(s, "user", "Before Takes' change", p=p)
    write_post_file(s, fm, text, p)
    post_snapshot(s, "claude", a.get("note") or "Edited by Takes", p=p)
    out = read_post(s, p)
    if p == "x":
        long = [t["n"] for t in out["tweets"] if t["cut_in_feed"]]
        out["note"] = ("The user sees it as an X post (a thread when it has several tweets) in the app's post tab, "
                       "X side. The user edits it there and comments on selected text (get_comments file='%s'). "
                       % pf(p, "post")) + \
            ("Tweets %s run over %d characters: the timeline cuts them with 'Show more' (fine with Premium)."
             % (", ".join(map(str, long)), X_FEED_CUT) if long else "")
    elif p == "article":
        out["note"] = ("The user sees it as a post on the blog (Satoshi, the orange accent, the blog's "
                       "components) in the post tab, Article side, and writes in it there (markdown beside the page). "
                       "The user comments on selected text (get_comments file='%s'); the quote may be the page's words "
                       "without markdown marks. Components you used: %s." % (pf(p, "post"), ", ".join(out["components"]) or "none"))
    elif p == "youtube":
        out["note"] = ("The user sees it as a YouTube watch page (player, title, description) in the post tab, YouTube "
                       "side. Title max %d characters; description max %d; chapters as '0:00 Intro' lines. "
                       "Use a wide (16:9) edit as media." % (TITLE_LIMIT, PLATFORMS[p]["limit"]))
    elif p == "vertical":
        out["note"] = ("The user sees it on a phone as %s shows it, post tab, Vertical side. One caption for all of them: "
                       "hook in the first line, max %d characters (Instagram), at most %d hashtags (Instagram). "
                       "Use a vertical (9:16) edit as media." % (", ".join(out["goes_to"]) or "none of the places",
                                                                 PLATFORMS[p]["limit"], REELS_HASHTAGS))
    else:
        out["note"] = ("The user sees it as a LinkedIn post in the app's post tab, edits it there and comments on "
                       "selected text (get_comments file='%s'). Over %d characters LinkedIn cuts it." % (POST, POST_LIMIT))
    return out


def set_post_variant(s, a, p="linkedin"):
    v = next((x for x in post_variants(s, p) if x["variant"] == a["variant"]), None)
    if not v:
        raise ValueError("No %s post variant '%s'. Make one with create_post_variants."
                         % (PLATFORMS[p]["name"], a["variant"]))
    text = post_text_arg(a, p)
    text = v["text"] if text is None else text.strip("\n") + "\n"
    post_snapshot(s, "user", "Before Takes' change", v["variant"], p)
    write_post_variant(s, v["variant"], a.get("name") or v["name"], v["author"] or "claude",
                       a.get("note") if a.get("note") is not None else v["note"], v["created"], text, p)
    post_snapshot(s, "claude", a.get("note") or "Edited by Takes", v["variant"], p)
    return {"platform": PLATFORMS[p]["name"], "updated": v["variant"], "chars": len(text.strip())}


def t_create_post_variants(a):
    """Other versions of the post, as tabs above the preview."""
    s = resolve_session(a["session"])
    p = platform_of(a)
    need_rules(*post_rules(p))
    if read_post(s, p) is None:
        raise ValueError("Write the main %s post with set_post first; variants sit next to it." % PLATFORMS[p]["name"])
    d = os.path.join(s, pf(p, "variants"))
    made = []
    for v in a["variants"]:
        name = v.get("name", "").strip() or "Variant"
        base = slug(name) or "variant"
        sl, n = base, 2
        while os.path.exists(os.path.join(d, sl + ".md")):
            sl, n = "%s-%d" % (base, n), n + 1
        text = THREAD_BREAK.join(v["tweets"]) if p == "x" and v.get("tweets") else v["text"]
        write_post_variant(s, sl, name, "claude", v.get("note", ""), now_iso(), text.strip("\n") + "\n", p)
        post_snapshot(s, "claude", v.get("note") or "Created by Claude", sl, p)
        made.append(sl)
    return {"platform": PLATFORMS[p]["name"], "created_variants": made,
            "note": "They show as tabs above the post in the app's post tab. Only the main post is scheduled: "
                    "The user picks one with 'Use as main' (or you call use_post_variant when the user asks)."}


def t_use_post_variant(a):
    s = resolve_session(a["session"])
    p = platform_of(a)
    v = next((x for x in post_variants(s, p) if x["variant"] == a["variant"]), None)
    if not v:
        raise ValueError("No %s post variant '%s'." % (PLATFORMS[p]["name"], a["variant"]))
    set_post_text(s, v["text"], v["author"] or "claude", "Used “%s” as main" % v["name"], p)
    trash([os.path.join(s, pf(p, "variants"), v["variant"] + ".md")])
    return {"main_post_now_from": v["name"], "note": "The old main post is in post history."}


def t_delete_post_variants(a):
    s = resolve_session(a["session"])
    p = platform_of(a)
    paths = []
    for v in a["variants"]:
        post_snapshot(s, "user", "Before deleting the variant", v, p)
        path = os.path.join(s, pf(p, "variants"), v + ".md")
        if os.path.exists(path):
            paths.append(path)
    trash(paths)
    return {"trashed": [os.path.basename(x)[:-3] for x in paths]}


def t_set_post_hooks(a):
    s = resolve_session(a["session"])
    p = platform_of(a)
    need_rules(*post_rules(p))
    if read_post(s, p) is None:
        raise ValueError("Write the %s post with set_post first." % PLATFORMS[p]["name"])
    hooks = write_hooks(os.path.join(s, pf(p, "hooks")), a["hooks"])
    where = "the first tweet's opening" if p == "x" else "the lines above '…more'"
    return {"hooks": hooks, "note": "They show above the post in the app. Picking one replaces the post's first "
                                    "paragraph (%s)." % where}


def t_post_history(a):
    s = resolve_session(a["session"])
    p = platform_of(a)
    vs = post_history(s, p)
    if a.get("version"):
        v = next((x for x in vs if x["version"] == a["version"]), None)
        if not v:
            raise ValueError("No version '%s'. Call post_history without version." % a["version"])
        v["text"] = v.pop("_body")
        return v
    for v in vs:
        v["preview"] = v.pop("_body").strip().replace("\n", " ")[:120]
    return {"platform": PLATFORMS[p]["name"], "versions": vs}


def t_restore_post_version(a):
    s = resolve_session(a["session"])
    p = platform_of(a)
    v = next((x for x in post_history(s, p) if x["version"] == a["version"]), None)
    if not v:
        raise ValueError("No version '%s'." % a["version"])
    draft = v["draft"] if post_draft_text(s, v["draft"], p) is not None else "main"
    note = "Restored %s" % v["created"]
    if draft == "main":
        set_post_text(s, v["_body"], "claude", note, p)
    else:
        set_post_variant(s, {"variant": draft, "text": v["_body"], "note": note}, p)
    return {"restored": v["version"], "into": draft}


def t_set_post_status(a):
    """Record what happened on the platform: scheduled (at the post's time, with its current text) or posted."""
    s = resolve_session(a["session"])
    p = platform_of(a)
    f = post_file(s, p)
    if f is None:
        raise ValueError("No %s post in %s. Write one with set_post." % (PLATFORMS[p]["name"], s))
    fm, text = f
    status = a["status"]
    if status not in ("draft", "ready", "scheduled", "posted"):
        raise ValueError("status is draft, ready, scheduled or posted.")
    if a.get("at"):
        fm["at"], fm["tz"] = post_time(a["at"], a.get("tz") or fm.get("tz"))
    elif status == "posted" and not fm.get("at"):
        fm["at"], fm["tz"] = post_time(datetime.now().astimezone().isoformat(timespec="seconds"), fm.get("tz"))
    fm["status"] = status
    if status == "scheduled":
        if not fm.get("at"):
            raise ValueError("The post has no time. Pass at: the time you scheduled it for.")
        fm["scheduled_at"], fm["scheduled_hash"] = fm["at"], post_hash(text)
    elif status in ("draft", "ready"):
        fm.pop("scheduled_at", None)
        fm.pop("scheduled_hash", None)
    if a.get("url"):
        fm["url"] = a["url"]
    if a.get("first_comment_posted") is not None:
        fm["first_comment_posted"] = "true" if a["first_comment_posted"] else None
    write_post_file(s, fm, text, p)
    if status == "posted":
        t_set_published({"session": s, "platform": PLATFORMS[p]["name"], "url": a.get("url")})
    return read_post(s, p)


def t_get_post_queue(a):
    """Every post that is ready, scheduled or (with posted=true) posted, across all projects and platforms,
    by time."""
    want = {"ready", "scheduled"} | ({"posted"} if a.get("posted") else set()) | ({"draft"} if a.get("drafts") else set())
    only = platform_of(a) if a.get("platform") else None
    out = []
    r = root()
    for proj in sorted(os.listdir(r)) if os.path.isdir(r) else []:
        pdir = os.path.join(r, proj)
        if proj.startswith((".", "_")) or not os.path.isdir(pdir):
            continue
        for name in os.listdir(pdir):
            sdir = os.path.join(pdir, name)
            if not os.path.isdir(sdir):
                continue
            for p in ([only] if only else PLATFORMS):
                post = read_post(sdir, p)
                pending = post and post["status"] == "posted" and post.get("first_comment") and \
                    not post.get("first_comment_posted")
                if not post or (post["status"] not in want and not pending):
                    continue
                post.update(session=os.path.relpath(sdir, r), title=read_meta(sdir).get("title", name),
                            variants=len(post_variants(sdir, p)))
                out.append(post)
    out.sort(key=lambda p: (p["at"] is None, p["at"]["utc"] if p["at"] else ""))
    return {"posts": out, "mac_timezone": datetime.now().astimezone().tzname(),
            "note": "For each post do what 'action' says, on its platform. LinkedIn's scheduler (Start a post > "
                    "clock icon) takes the time in this Mac's time zone: use at.this_mac. Upload media_path, "
                    "paste text exactly. X posts go through Typefully (social-posting skill): one tweet per "
                    "entry in 'tweets', media on the first. Ask the user before you click Schedule. Then "
                    "set_post_status scheduled with platform. first_comment (LinkedIn) cannot be scheduled: "
                    "once the post is live, post it as the first comment (a posted post with one still to "
                    "add is always listed)."}


# ---------- Posting plan (<root>/_library/plan.json) ----------
# The days the user wants to post (2026-10-09). Each day is a slot; a ready, scheduled or posted post with
# a time on that day fills it. The chat uses the empty slots to say what a new take is good for.
# The Plan board (2026-10-10) also holds video cards: sessions put on a day ("videos", in order),
# by plan_video or by the user dragging them, and shows "weeks" weeks (2 to 12).

PLAN_DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
PLAN_WEEKS = (2, 12)


def plan_file():
    return os.path.join(root(), LIB, "plan.json")


def read_plan_file():
    try:
        with open(plan_file()) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def write_plan_file(d):
    path = plan_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


def plan_weeks(d):
    try:
        n = int(d.get("weeks") or 2)
    except (TypeError, ValueError):
        n = 2
    return min(max(n, PLAN_WEEKS[0]), PLAN_WEEKS[1])


def read_plan():
    d = read_plan_file()
    if d.get("off"):  # the Plan plugin is off in the app
        return None
    days = [x for x in PLAN_DAYS if x in (d.get("days") or [])]
    if not days:
        return None
    plats = [x for x in d.get("platforms") or ["linkedin"] if x in PLATFORMS] or ["linkedin"]
    return {"days": days, "time": d.get("time") or "09:00", "platforms": plats, "weeks": plan_weeks(d),
            "videos": [v for v in d.get("videos") or [] if isinstance(v, dict) and v.get("session") and v.get("day")]}


def plan_view(today=None):
    """The plan's weeks of slots, which are empty, how many covered slots come before the first
    empty one (the buffer), and the video cards. A card covers its day's slot as planned; a post
    with a time fills it."""
    plan = read_plan()
    if not plan:
        return None
    names = {PLATFORMS[p]["name"] for p in plan["platforms"]}
    today = today or datetime.now().astimezone().date()
    by_day, unplanned, state = {}, [], {}
    for post in t_get_post_queue({"posted": True})["posts"]:
        if post["platform"] not in names:
            continue
        if post["status"] in ("posted", "scheduled") and state.get(post["session"]) != "posted":
            state[post["session"]] = post["status"]
        if not post["at"]:
            if post["status"] == "ready":
                unplanned.append(post["title"])
            continue
        day = datetime.fromisoformat(post["at"]["utc"].replace("Z", "+00:00")).astimezone().date()
        by_day.setdefault(day, []).append("%s (%s, %s)" % (post["title"], post["platform"], post["status"]))
    videos = []
    for v in plan["videos"]:
        path = os.path.join(root(), v["session"])
        if not os.path.isfile(os.path.join(path, "session.json")):
            continue
        try:
            d = datetime.strptime(v["day"], "%Y-%m-%d").date()
        except ValueError:
            continue
        videos.append({"session": v["session"], "title": read_meta(path).get("title") or title_from_folder(os.path.basename(path)),
                       "day": d.strftime("%a %b %d"), "date": v["day"],
                       **({"post": state[v["session"]]} if v["session"] in state else {}),
                       **({"passed": True} if d < today else {}),
                       **({"after_last_week": True} if d >= today + timedelta(days=plan["weeks"] * 7) else {})})
    # A card from a passed day sits on today, as on the board.
    on_day = {}
    for v in videos:
        on_day.setdefault(max(datetime.strptime(v["date"], "%Y-%m-%d").date(), today), []).append(v["title"])
    slots = []
    for i in range(plan["weeks"] * 7):
        d = today + timedelta(days=i)
        if PLAN_DAYS[d.weekday()] in plan["days"]:
            slots.append({"day": d.strftime("%a %b %d"), "date": d.isoformat(), "filled_by": by_day.get(d) or None,
                          "planned": on_day.get(d) or None})
    covered = lambda x: x["filled_by"] or x["planned"]
    buffer = next((i for i, x in enumerate(slots) if not covered(x)), len(slots))
    gaps = [x["day"] for x in slots if not covered(x)]
    return dict(plan, slots=slots, empty_slots=gaps, next_gap=gaps[0] if gaps else None,
                buffer=buffer, buffer_ready=sum(1 for x in slots[:buffer] if x["filled_by"]),
                ready_without_time=unplanned, videos=videos)


def plan_brief():
    """The plan in a line or two, for get_session."""
    v = plan_view()
    if not v:
        return None
    return {"next_gap": v["next_gap"], "buffer": v["buffer"], "ready_without_time": len(v["ready_without_time"]),
            "note": "Details: get_plan."}


def t_get_plan(a):
    v = plan_view()
    if not v:
        return {"plan": None,
                "note": "No posting days yet. Ask the user which days to post (recommend two a week, "
                        "for example Tue and Thu, at a time the audience is online), then call set_plan."}
    v["note"] = ("videos = the cards on the Plan board, in order (plan_video adds or moves one; the user drags "
                 "them). A slot is filled by a ready, scheduled or posted post with a time on that day (filled_by); "
                 "a card on that day covers it as planned (planned). buffer = covered slots before the first "
                 "empty one; buffer_ready = how many of those have a post. When the user records a take or an edit is done, say in one "
                 "positive line which empty slot it can fill (\"great one for the gap on Fri\"). Praise the "
                 "buffer when it grows. Never nag about a gap, never block anything.")
    return v


def t_set_plan(a):
    days = [x.strip().lower()[:3] for x in a.get("days") or []]
    bad = [x for x in days if x not in PLAN_DAYS]
    if bad or not days:
        raise ValueError("days: a list of weekdays, e.g. [\"tue\", \"thu\"].")
    time_ = (a.get("time") or "09:00").strip()
    if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", time_):
        raise ValueError("time: HH:MM, 24-hour, e.g. 08:02.")
    plats = a.get("platforms") or ["linkedin"]
    if any(p not in PLATFORMS for p in plats):
        raise ValueError("platforms: any of " + ", ".join(PLATFORMS))
    old = read_plan_file()
    d = {"days": [x for x in PLAN_DAYS if x in days], "time": time_, "platforms": plats,
         "since": old.get("since") or datetime.now().astimezone().date().isoformat()}
    if a.get("weeks") is not None:
        d["weeks"] = plan_weeks({"weeks": a["weeks"]})
    elif old.get("weeks"):
        d["weeks"] = old["weeks"]
    if old.get("videos"):
        d["videos"] = old["videos"]
    write_plan_file(d)
    return t_get_plan({})


def t_plan_video(a):
    """Puts a session's video card on a day of the Plan board, moves it, or takes it off."""
    d = read_plan_file()
    if not read_plan():
        raise ValueError("No posting plan yet (or the Plan plugin is off). Ask the user for the days, then set_plan.")
    path = resolve_session(a["session"])
    if not os.path.isfile(os.path.join(path, "session.json")):
        raise ValueError("Not a session: %s" % a["session"])
    rel = os.path.relpath(path, root())
    if rel.startswith(".."):
        raise ValueError("The session is not in the library.")
    videos = [v for v in d.get("videos") or [] if isinstance(v, dict) and v.get("session") != rel]
    day = (a.get("day") or "").strip()
    if day:
        try:
            when = datetime.strptime(day, "%Y-%m-%d").date()
        except ValueError:
            raise ValueError("day: YYYY-MM-DD, e.g. 2026-10-13. Empty takes the card off the plan.")
        today = datetime.now().astimezone().date()
        weeks_out = (when - today).days // 7 + 1
        if weeks_out > PLAN_WEEKS[1]:
            raise ValueError("The board plans %d weeks ahead at most." % PLAN_WEEKS[1])
        if weeks_out > plan_weeks(d):
            d["weeks"] = weeks_out  # show the week the card is on
        card = {"session": rel, "day": day}
        before = a.get("before")
        if before:
            before = os.path.relpath(resolve_session(before), root())
        i = next((i for i, v in enumerate(videos) if before and v["session"] == before and v["day"] == day), None)
        if i is None:
            i = max((i + 1 for i, v in enumerate(videos) if v["day"] == day), default=len(videos))
        videos.insert(i, card)
    d["videos"] = videos
    write_plan_file(d)
    return t_get_plan({})


def t_create_session(a):
    pdir = os.path.join(root(), project_name(a.get("project") or "Inbox"))
    os.makedirs(pdir, exist_ok=True)
    title = a.get("title", "").strip()
    date = datetime.now().strftime("%Y-%m-%d")
    folder = free_session_path(os.path.join(pdir, "%s-%s" % (date, slug(title) or "untitled")))
    os.makedirs(folder)
    meta = {"title": title or "Untitled", "createdAt": now_iso(), "named": bool(title), "takes": []}
    write_meta(folder, meta)
    write_text(os.path.join(folder, "script.md"), a.get("script", ""))
    snapshot(folder, "main", a.get("author", "claude"), "First draft")
    for v in a.get("variants", []):
        t_create_variants({"session": folder, "variants": [v]})
    if a.get("open", True):
        open_in_app(folder)
    return session_summary(folder)


def t_update_session(a):
    s = old = resolve_session(a["session"])
    meta = read_meta(s)
    if "script" in a:
        need_rules("script")
    if "script" in a:
        set_main_script(s, a["script"], a.get("author", "claude"), a.get("note", ""))
    if a.get("title", "").strip():
        meta["title"] = a["title"].strip()
        meta["named"] = True
        target = os.path.join(os.path.dirname(s), "%s-%s" % (meta["createdAt"][:10], slug(meta["title"])))
        if target != s:
            meta.setdefault("id", session_id(s, meta))
            target = free_session_path(target, meta["id"])
            os.rename(s, target)
            record_move(s, target)
            s = target
    write_meta(s, meta)
    # The new path first: the agent keeps the path it read first and must see the change (2026-10-11).
    summary = session_summary(s)
    out = {"path": s}
    if s != old:
        out["moved_from"] = old
    out["id"] = summary.pop("id")
    out.update((k, v) for k, v in summary.items() if k != "path")
    if s != old:
        out["note"] = "The folder has a new name. Use this path or the id from now on; the old path still works."
    return out


def t_rename_take(a):
    s = resolve_session(a["session"])
    meta = read_meta(s)
    n, name = int(a["take"]), a.get("name", "").strip()
    found = False
    for t in meta["takes"]:
        if t["number"] != n:
            continue
        found = True
        sl = slug(name)
        new = take_file(n, sl, t["kind"], os.path.splitext(t["file"])[1] or ".mov")
        if new != t["file"] and os.path.exists(os.path.join(s, t["file"])):
            os.rename(os.path.join(s, t["file"]), os.path.join(s, new))
            words = os.path.join(s, os.path.splitext(t["file"])[0] + ".words.json")
            if os.path.exists(words):  # the transcript keeps the video's name
                os.rename(words, os.path.join(s, os.path.splitext(new)[0] + ".words.json"))
            t["file"] = new
        if name:
            t["name"] = name
        else:
            t.pop("name", None)
    if not found:
        raise ValueError("No take %d in this session." % n)
    write_meta(s, meta)
    return t_get_session({"session": s})


def take_said(s, t, takes):
    """What a take says, from the transcript Takes writes next to it (Apple's speech model on the Mac).
    One per take: the camera file's, or the screen file's when the take has no camera file."""
    if t["kind"] == "screen" and any(o["number"] == t["number"] and o["kind"] == "camera" for o in takes):
        return {}
    path = os.path.join(s, t["file"])
    try:
        words = transcript_words(path)
    except Exception:  # a broken transcript loses its text, not the session
        words = None
    if words is None:
        return {"said": None, "said_note": "No transcript yet. Takes writes one in the background (macOS 26)."}
    text = " ".join(w for _, _, w in words)
    return {"said": text[:1500] + ("…" if len(text) > 1500 else ""),
            "transcript": os.path.splitext(path)[0] + ".words.json"}


def take_file(n, sl, kind, ext=".mov"):
    return "take-%02d-%s%s%s" % (n, sl + "-" if sl else "", kind, ext.lower())


def media_duration(path):
    """Seconds, from ffprobe, else Spotlight. None if neither knows."""
    for probe in ("ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"):
        try:
            out = subprocess.run([probe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                                 capture_output=True, text=True, timeout=30).stdout.strip()
            return float(out)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            continue
    try:
        out = subprocess.run(["mdls", "-raw", "-name", "kMDItemDurationSeconds", path],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        return float(out)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def t_import_take(a):
    """Add existing recordings to a session as takes: named, numbered and listed in session.json."""
    s = resolve_session(a["session"])
    meta = read_meta(s)
    takes = a.get("takes") or [{k: a[k] for k in ("path", "screen_path", "name", "keeper") if k in a}]
    plan = []
    for t in takes:
        files = [(t.get("path"), t.get("kind") or "camera")]
        if t.get("screen_path"):
            files.append((t["screen_path"], "screen"))
        for f, kind in files:
            if not f:
                raise ValueError("Each take needs path (the camera or main recording).")
            if not os.path.isfile(os.path.expanduser(f)):
                raise ValueError("No file at %s." % f)
            if kind not in ("camera", "screen"):
                raise ValueError("kind is camera or screen.")
            if media_kind(f) != "video":
                raise ValueError("%s is not a video." % f)
        if len({k for _, k in files}) != len(files):
            raise ValueError("A take has at most one camera and one screen file.")
        plan.append((t, files))
    done = []
    for t, files in plan:
        n = max([x["number"] for x in meta["takes"]] + [0]) + 1
        sl = slug(t.get("name") or "")
        for f, kind in files:
            src = os.path.abspath(os.path.expanduser(f))
            ext = os.path.splitext(src)[1] or ".mov"
            dst = os.path.join(s, take_file(n, sl, kind, ext))
            if os.path.exists(dst):
                raise ValueError("%s already exists." % dst)
            st = os.stat(src)
            started = datetime.fromtimestamp(getattr(st, "st_birthtime", st.st_mtime), timezone.utc)
            inside = os.path.dirname(src) == os.path.normpath(s) or src.startswith(os.path.normpath(s) + os.sep)
            if inside or a.get("move"):
                os.rename(src, dst)          # already in the session (or asked to move): rename, no copy
            else:
                with open(src, "rb") as fi, open(dst, "wb") as fo:
                    while True:
                        chunk = fi.read(1 << 22)
                        if not chunk:
                            break
                        fo.write(chunk)
            take = {"number": n, "kind": kind, "file": os.path.basename(dst), "keeper": bool(t.get("keeper")),
                    "startedAt": started.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")}
            d = media_duration(dst)
            if d:
                take["duration"] = d
            if t.get("name"):
                take["name"] = t["name"].strip()
            meta["takes"].append(take)
            done.append({"take": n, "kind": kind, "file": take["file"], "from": src,
                         "copied": not (inside or a.get("move")), "duration": d})
    write_meta(s, meta)
    try:  # word times for the cut, in the background (a job in the Jobs row)
        start_prepare(s, sorted({d["take"] for d in done}))
    except Exception:
        pass
    return {"session": os.path.relpath(s, root()), "imported": done,
            "note": "The takes show in the app's take list. The originals stay unless move=true "
                    "(files already inside the session folder are renamed in place)."}


# ---------- Ideas (<root>/_library/ideas/, same format as Sources/Takes/Plugins/Private/Ideas.swift) ----------
# The user's idea list (2026-10-10, admin only): one markdown file per idea with frontmatter, and
# INDEX.md, a list that the app and this server write again after every change. He talks ideas into
# any chat (often from the phone on a walk); the chat files them here.

IDEA_STATUSES = ["new", "exploring", "doing", "done", "dropped"]
IDEA_HEADINGS = {"new": "New", "exploring": "Exploring", "doing": "Doing", "done": "Done", "dropped": "Dropped"}
IDEA_FIELDS = ["title", "status", "tags", "created", "updated", "source", "session"]
IDEA_INDEX = "INDEX.md"


def ideas_dir():
    return os.path.join(root(), LIB, "ideas")


def idea_now():
    return datetime.now().strftime("%Y-%m-%d %H:%M")


def idea_tags(v):
    if isinstance(v, list):
        items = v
    else:
        items = str(v or "").split(",")
    out = []
    for x in items:
        x = str(x).strip().lstrip("#").strip().lower()
        if x and x not in out:
            out.append(x)
    return out


def idea_path(idea_id):
    idea_id = str(idea_id or "").strip()
    if idea_id.endswith(".md"):
        idea_id = idea_id[:-3]
    if not idea_id or "/" in idea_id or idea_id.startswith(".") or idea_id.lower() == "index":
        raise ValueError("No such idea: %r. Use an id from list_ideas." % idea_id)
    return os.path.join(ideas_dir(), idea_id + ".md")


def read_idea(path):
    fields, body = parse_fm(read_text(path))
    status = fields.get("status", "new").lower()
    return {"id": os.path.basename(path)[:-3], "title": fields.get("title") or os.path.basename(path)[:-3],
            "status": status if status in IDEA_STATUSES else "new", "tags": idea_tags(fields.get("tags")),
            "created": fields.get("created", ""), "updated": fields.get("updated") or fields.get("created", ""),
            "source": fields.get("source", ""), "session": fields.get("session", ""), "body": body.strip("\n")}


def all_ideas():
    d = ideas_dir()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    out = []
    for n in names:
        if n.endswith(".md") and n != IDEA_INDEX and not n.startswith("."):
            try:
                out.append(read_idea(os.path.join(d, n)))
            except (OSError, UnicodeDecodeError):
                continue
    return out


def idea_index(ideas):
    """INDEX.md. Ideas.swift writes the same text, so the app and the server never fight over it."""
    lines = ["# Ideas", "", "Takes writes this list from the idea files. Change an idea in its own file.", ""]
    if not ideas:
        lines.append("No ideas yet.")
    for st in IDEA_STATUSES:
        group = sorted((i for i in ideas if i["status"] == st), key=lambda i: (i["created"], i["id"]), reverse=True)
        if not group:
            continue
        lines += ["## %s (%d)" % (IDEA_HEADINGS[st], len(group)), ""]
        for i in group:
            line = "- [%s](%s.md)" % (i["title"].replace("]", ")").replace("[", "("), i["id"])
            if i["created"]:
                line += " · " + i["created"][:10]
            if i["tags"]:
                line += " · " + ", ".join(i["tags"])
            lines.append(line)
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def write_safely(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def write_idea_index():
    path = os.path.join(ideas_dir(), IDEA_INDEX)
    text = idea_index(all_ideas())
    try:
        if read_text(path) == text:
            return
    except OSError:
        pass
    write_safely(path, text)


def render_idea(i):
    fields = [(k, ", ".join(i[k]) if k == "tags" else i[k]) for k in IDEA_FIELDS if i.get(k)]
    return render_fm(fields, "\n" + i["body"].strip("\n") + "\n" if i["body"].strip() else "")


def idea_out(i, body=True):
    o = {k: i[k] for k in ["id", "title", "status", "tags", "created", "updated", "source", "session"] if i.get(k)}
    o["file"] = os.path.join(ideas_dir(), i["id"] + ".md")
    thumb, state = idea_thumb(i["id"]), idea_thumb_state(i["id"])
    if thumb:
        o["thumbnail"] = os.path.join(ideas_dir(), thumb)
    if state:
        o["thumbnail_state"] = state
    if body:
        o["body"] = i["body"]
    else:
        first = next((l.strip() for l in i["body"].split("\n") if l.strip() and not l.startswith("#")), "")
        o["summary"] = first[:160]
    return o


def t_add_idea(a):
    title = str(a.get("title") or "").strip().replace("\n", " ")
    if not title:
        raise ValueError("An idea needs a title.")
    status = str(a.get("status") or "new").lower()
    if status not in IDEA_STATUSES:
        raise ValueError("status is one of %s" % ", ".join(IDEA_STATUSES))
    base = slug(title) or "idea"
    os.makedirs(ideas_dir(), exist_ok=True)
    n, idea_id = 1, base
    while os.path.exists(os.path.join(ideas_dir(), idea_id + ".md")) or idea_id.lower() == "index":
        n += 1
        idea_id = "%s-%d" % (base, n)
    now = idea_now()
    i = {"id": idea_id, "title": title, "status": status, "tags": idea_tags(a.get("tags")), "created": now,
         "updated": now, "source": str(a.get("source") or "agent").strip(), "session": "",
         "body": str(a.get("text") or "").strip()}
    write_safely(idea_path(idea_id), render_idea(i))
    write_idea_index()
    start_idea_thumb(idea_id, a.get("thumbnail_prompt"))
    out = idea_out(i)
    if not me_photos():
        out["note"] = ("No photos of the user in %s yet, so no thumbnail. Tell him once: add 3-6 photos there "
                       "(or from the phone's Ideas screen)." % me_dir())
    return out


# ---------- Idea thumbnails (2026-10-11) ----------
# Every new idea gets a 16:9 thumbnail of the user, drawn in the background by GPT Image 2.5 Sunburst
# (best quality with reference photos; Flare when Sunburst fails) from the photos of him in
# <root>/_library/me/. The chat writes the prompt when it files an idea (add_idea thumbnail_prompt);
# for an idea typed in the app, Gemini writes it from the idea and his thumbnail rules. Files:
#   ideas/thumbnails/<id>-vN.png    the drawings, newest last (Ideas.swift shows the newest)
#   ideas/thumbnails/.prompts.json  id -> the prompt it was drawn from (Redraw starts from it)
#   ideas/thumbnails/.status.json   id -> {"state": "drawing" | "error" | "nophotos", "error", "since"}
#   ideas/thumbnails/.models.json   file -> the model that drew it, as everywhere in Takes

ME_DIR = "me"
IDEA_THUMBS = "thumbnails"
IDEA_THUMB_MODELS = ("sunburst", "flare")
IDEA_THUMB_REFS = 4
PHOTO_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif")
IDEA_THUMB_ASK = ("A 16:9 YouTube thumbnail for a video about the idea below. The man in it is the man in the "
                  "reference photos: keep his face, hair, skin and build exactly as in them, a real photo of him, "
                  "not a drawing. ")
IDEA_PROMPT_SYSTEM = (
    "You write one image prompt for a 16:9 YouTube thumbnail of the user, a creator who makes videos about AI "
    "agents and building software. An image model draws it with photos of him as references, so describe "
    "him only by pose, expression, clothes and place, never his face. One scene that shows the idea at a "
    "glance: where he is, what he holds or does, one clear proof element, the light, the framing (his face "
    "on one third, space on the other for a short title), and a two-word title line in bold text. Bright, "
    "uncluttered, photographic. Follow his thumbnail rules. Answer with the prompt only, 60-120 words.")


def me_dir():
    return os.path.join(root(), LIB, ME_DIR)


def me_photos():
    """Photos of the user, newest first."""
    d = me_dir()
    try:
        names = [n for n in os.listdir(d) if n.lower().endswith(PHOTO_EXTS) and not n.startswith(".")]
    except OSError:
        return []
    return sorted((os.path.join(d, n) for n in names), key=lambda f: os.path.getmtime(f), reverse=True)


def idea_thumbs_dir():
    return os.path.join(ideas_dir(), IDEA_THUMBS)


def idea_thumb(idea_id):
    """The newest thumbnail of an idea, as "thumbnails/<id>-vN.png", or ""."""
    have = versions_in(idea_thumbs_dir(), idea_id)
    return "%s/%s-v%d.png" % (IDEA_THUMBS, idea_id, have[-1]) if have else ""


def idea_json(name):
    try:
        with open(os.path.join(idea_thumbs_dir(), name)) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def set_idea_json(name, idea_id, value):
    """One key of a thumbnails/.*.json file; None removes it. Locked: several drawings can end at once."""
    import fcntl
    os.makedirs(idea_thumbs_dir(), exist_ok=True)
    with open(os.path.join(idea_thumbs_dir(), ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        d = idea_json(name)
        if value is None:
            d.pop(idea_id, None)
        else:
            d[idea_id] = value
        write_safely(os.path.join(idea_thumbs_dir(), name), json.dumps(d, indent=2, ensure_ascii=False))


def idea_thumb_state(idea_id):
    """"drawing", "error: ...", "nophotos" or "". A drawing that ran 15 min is lost."""
    st = idea_json(".status.json").get(idea_id) or {}
    state = st.get("state") or ""
    if state == "drawing" and time.time() - float(st.get("since") or 0) > 15 * 60:
        return "error: The drawing stopped. Try again."
    if state == "error":
        return "error: " + (st.get("error") or "The drawing failed.")
    return state


def gemini_text(system, ask, temperature=0.7, images=None):
    """One short text answer from Gemini. A judge asks at temperature 0, so the same draft gets the same verdict.
    images: PNG bytes sent before the text (the page judge's screenshots)."""
    import base64
    import urllib.request
    key = gemini_key()
    if not key:
        raise ValueError("No Gemini key.")
    pics = [{"inline_data": {"mime_type": "image/png", "data": base64.b64encode(b).decode()}} for b in images or []]
    body = {"contents": [{"parts": pics + [{"text": ask}]}], "system_instruction": {"parts": [{"text": system}]},
            "generationConfig": {"temperature": temperature}}
    req = urllib.request.Request("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % DESCRIBE_MODEL,
                                 method="POST", data=json.dumps(body).encode(),
                                 headers={"x-goog-api-key": key, "Content-Type": "application/json"})
    try:
        out = json.load(urllib.request.urlopen(req, timeout=120))
    except urllib.error.HTTPError as e:
        raise ValueError("Gemini said %s" % e.code)
    return "".join(p.get("text", "") for p in out["candidates"][0]["content"]["parts"]).strip()


def idea_thumb_prompt(i):
    """A thumbnail prompt for an idea that has none: Gemini writes it from the idea and his thumbnail
    rules; without Gemini, a plain one from the title."""
    rules = [r["text"] for r in read_lessons()["rules"] if r.get("on", True) and r.get("area") == "thumbnail"]
    ask = "Idea: %s\n\n%s\n\nHis thumbnail rules:\n%s" % (i["title"], i["body"][:2000], "\n".join("- " + r for r in rules))
    if not os.environ.get("TAKES_IMAGE_CMD"):
        try:
            text = gemini_text(IDEA_PROMPT_SYSTEM, ask)
            if len(text) > 40:
                return text
        except (ValueError, OSError, KeyError, IndexError):
            pass
    return ("The user, waist up, looking into the lens with a calm, natural closed-mouth smile, in a bright, "
            "uncluttered place that fits the idea \"%s\", one clear object that shows it, soft daylight. His "
            "face on the right third, space on the left for a bold two-word title about the idea." % i["title"])


def start_idea_thumb(idea_id, prompt=None):
    """Draw an idea's thumbnail in the background (a new version). False when switched off (tests)."""
    idea_path(idea_id)
    if prompt and str(prompt).strip():
        set_idea_json(".prompts.json", idea_id, str(prompt).strip())
    if os.environ.get("TAKES_IDEA_THUMBS") == "0":
        return False
    if not me_photos() and not os.environ.get("TAKES_IMAGE_CMD"):
        set_idea_json(".status.json", idea_id, {"state": "nophotos"})
        return False
    set_idea_json(".status.json", idea_id, {"state": "drawing", "since": time.time()})
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "--idea-thumb", idea_id],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    return True


def idea_refs(photos, tmp):
    """The photos as JPEGs of at most 1536 px (HEIC from the iPhone too), for GPT Image."""
    out = []
    for n, f in enumerate(photos):
        dst = os.path.join(tmp, "me-%d.jpg" % n)
        r = subprocess.run(["sips", "-s", "format", "jpeg", "-Z", "1536", f, "--out", dst], capture_output=True)
        out.append(dst if r.returncode == 0 and os.path.exists(dst) else f)
    return out


def idea_thumb_run(idea_id):
    """The background drawing of one idea's thumbnail (--idea-thumb)."""
    import fcntl
    import tempfile
    os.makedirs(idea_thumbs_dir(), exist_ok=True)
    lock = open(os.path.join(idea_thumbs_dir(), ".drawing-" + idea_id), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.close()
        return  # it draws already
    tmp = tempfile.mkdtemp(prefix="takes-idea-")
    try:
        p = idea_path(idea_id)
        if not os.path.exists(p):
            set_idea_json(".status.json", idea_id, None)
            return
        photos = me_photos()[:IDEA_THUMB_REFS]
        if not photos and not os.environ.get("TAKES_IMAGE_CMD"):
            set_idea_json(".status.json", idea_id, {"state": "nophotos"})
            return
        i = read_idea(p)
        prompt = idea_json(".prompts.json").get(idea_id)
        if not prompt:
            prompt = idea_thumb_prompt(i)
            set_idea_json(".prompts.json", idea_id, prompt)
        have = versions_in(idea_thumbs_dir(), idea_id)
        rel = "%s/%s-v%d.png" % (IDEA_THUMBS, idea_id, (have[-1] if have else 0) + 1)
        label = draw_image(IDEA_THUMB_ASK + "\n\nIdea: %s\n\n%s" % (i["title"], prompt), os.path.join(ideas_dir(), rel),
                           "16:9", images=idea_refs(photos, tmp), quality="high", models=IDEA_THUMB_MODELS)
        note_model(ideas_dir(), rel, label)
        set_idea_json(".status.json", idea_id, None)
    except Exception as e:  # the app shows it, with Try again
        set_idea_json(".status.json", idea_id, {"state": "error", "error": str(e)[:300]})
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            os.remove(lock.name)
        except OSError:
            pass
        lock.close()


def ideas_call(name, a):
    """The app's side (takes_mcp.py --ideas draw '{"id", "prompt"?}'): a new thumbnail in the background."""
    if name == "draw":
        return {"drawing": start_idea_thumb(a.get("id"), a.get("prompt"))}
    raise ValueError("Which call?")


def t_list_ideas(a):
    status = str(a.get("status") or "").lower()
    tag = str(a.get("tag") or "").strip().lstrip("#").lower()
    q = str(a.get("query") or "").strip().lower()
    out = []
    for i in all_ideas():
        if status and status != "all" and i["status"] != status:
            continue
        if not status and i["status"] == "dropped":
            continue
        if tag and tag not in i["tags"]:
            continue
        if q and q not in (i["title"] + "\n" + i["body"] + "\n" + " ".join(i["tags"])).lower():
            continue
        out.append(i)
    out.sort(key=lambda i: (i["updated"], i["id"]), reverse=True)
    return {"ideas": [idea_out(i, body=False) for i in out], "index": os.path.join(ideas_dir(), IDEA_INDEX),
            "statuses": IDEA_STATUSES}


def t_get_idea(a):
    p = idea_path(a.get("id"))
    if not os.path.exists(p):
        raise ValueError("No such idea: %s. Use an id from list_ideas." % a.get("id"))
    out = idea_out(read_idea(p))
    prompt = idea_json(".prompts.json").get(out["id"])
    if prompt:
        out["thumbnail_prompt"] = prompt
    return out


def t_update_idea(a):
    p = idea_path(a.get("id"))
    if not os.path.exists(p):
        raise ValueError("No such idea: %s. Use an id from list_ideas." % a.get("id"))
    i = read_idea(p)
    if a.get("title") is not None:
        title = str(a["title"]).strip().replace("\n", " ")
        if not title:
            raise ValueError("The title cannot be empty.")
        i["title"] = title
    if a.get("status") is not None:
        st = str(a["status"]).lower()
        if st not in IDEA_STATUSES:
            raise ValueError("status is one of %s" % ", ".join(IDEA_STATUSES))
        i["status"] = st
    if a.get("tags") is not None:
        i["tags"] = idea_tags(a["tags"])
    if a.get("session") is not None:
        i["session"] = str(a["session"]).strip()
    if a.get("body") is not None:
        i["body"] = str(a["body"]).strip()
    if str(a.get("append") or "").strip():
        note = "**%s**\n%s" % (idea_now(), str(a["append"]).strip())
        i["body"] = (i["body"].rstrip() + "\n\n" + note) if i["body"].strip() else note
    i["updated"] = idea_now()
    write_safely(p, render_idea(i))
    write_idea_index()
    if a.get("redraw") or str(a.get("thumbnail_prompt") or "").strip():
        start_idea_thumb(i["id"], a.get("thumbnail_prompt"))
    return idea_out(i)











SFX_TOOLS = {"sfx_sounds", "make_sfx", "design_sfx"}
SFX_RECIPES = {}  # recipe -> its default target, read once from earshot forge --list


def sfx_python():
    if os.environ.get("TAKES_EARSHOT"):
        return os.environ["TAKES_EARSHOT"]
    return next((p for p in SFX_PYS if os.path.exists(p)), SFX_PYS[0])


def sfx_on():
    """Plugins › Sound FX is on and earshot is installed."""
    if not os.path.exists(sfx_python()):
        return False
    try:
        off = subprocess.run(["defaults", "read", "de.marvinaziz.takes", "pluginsRemoved"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        off = ""
    return "sfx" not in [x.strip() for x in off.split(",")]


def sfx_need():
    if not os.path.exists(sfx_python()):
        raise ValueError("Sound FX is not installed. Ask the user to press Install in Takes (Plugins › Sound FX); "
                         "it takes about a minute.")
    if not sfx_on():
        raise ValueError("Sound FX is off in Takes (Plugins › Sound FX). Ask the user to turn it on.")


def sfx_env():
    env = dict(os.environ, EARSHOT_OFFLINE="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
               PYTHONWARNINGS="ignore")
    if sfx_python().startswith(SFX_DIR + os.sep):
        env.setdefault("EARSHOT_HOME", os.path.join(SFX_DIR, "home"))  # its model cache, where the card fetched it
    return env


def sfx_can_design():
    """Sound design needs torch, the second install on the Sound FX card; the bank runs without it."""
    lib = os.path.join(os.path.dirname(os.path.dirname(sfx_python())), "lib")
    try:
        return any(os.path.isdir(os.path.join(lib, v, "site-packages", "torch")) for v in os.listdir(lib))
    except OSError:
        return False


def sfx_run(args, timeout=120):
    """earshot <args> --json in its venv: the parsed JSON, or an error with its last line."""
    r = subprocess.run([sfx_python(), "-m", "earshot"] + args + ["--json"], capture_output=True, text=True,
                       timeout=timeout, env=sfx_env())
    if r.returncode != 0:
        err = [x for x in (r.stderr or "").splitlines() if x.strip()]
        raise ValueError("earshot: %s" % (err[-1] if err else "it ended with code %d" % r.returncode))
    return json.loads(r.stdout)


SFX_BANK = []


def sfx_bank():
    if not SFX_BANK:
        SFX_BANK.extend(sfx_run(["sfx", "list"])["sounds"])
    return SFX_BANK


def sfx_recipes():
    if not SFX_RECIPES:
        r = subprocess.run([sfx_python(), "-m", "earshot", "forge", "--list"], capture_output=True, text=True,
                           timeout=60, env=sfx_env())
        for line in r.stdout.splitlines():
            m = re.match(r"\s+(\w+): (.+?)(?:\s+\[refset [\w ]+\])?$", line)
            if m:
                SFX_RECIPES[m.group(1)] = m.group(2)
    return SFX_RECIPES


def sfx_row(x):
    pitch = (x.get("knobs") or {}).get("pitch")
    return {"id": x["id"], "seconds": round(x["dur_s"], 3), "peak_s": round(x["peak_s"], 3),
            "kinds": x.get("kinds") or [], "what": x.get("notes") or "",
            "from": "a real recording, as code" if x.get("type") == "fit" else "made in code",
            "pitch": pitch.get("note") if isinstance(pitch, dict) else None,
            "apex": bool((x.get("knobs") or {}).get("apex"))}


def t_sfx_sounds(a):
    sfx_need()
    q = (a.get("query") or "").lower().split()
    rows = []
    for x in sfx_bank():
        hay = " ".join([x["id"], x.get("notes") or ""] + (x.get("kinds") or [])).lower()
        if all(w in hay for w in q):
            rows.append(sfx_row(x))
    return {"sounds": rows, "count": len(rows), "recipes": sfx_recipes(),
            "note": "make_sfx renders one by id in about a second (dur, apex, pitch, takes). design_sfx makes new "
                    "ones from a recipe and a description in a few minutes. 'a real recording, as code' sounds "
                    "read as real; 'made in code' ones can sound synthetic: pick those only when that fits."}


def sfx_num(a, k, lo, hi):
    if a.get(k) is None:
        return None
    try:
        v = float(a[k])
    except (TypeError, ValueError):
        raise ValueError("%s is seconds, a number." % k)
    if not lo <= v <= hi:
        raise ValueError("%s must be %g to %g." % (k, lo, hi))
    return v


SFX_RENDER = r"""
import json, sys
from earshot.forge import sfx
jobs = json.loads(sys.argv[1])
out = []
for j in jobs:
    r = sfx.sfx_render(j.pop("sound"), j.pop("out"), **j)
    m = r["meta"]
    out.append({"seed": m.get("seed"), "onset_s": m.get("onset_s"), "peak_s": m.get("peak_s"),
                "end_s": m.get("end_s"), "seconds": m.get("dur_s"), "lufs_max": m.get("lufs_m_max"),
                "edits": m.get("edits"), "checks": (m.get("checks") or {}).get("summary"),
                "clean": (m.get("checks") or {}).get("ok")})
print(json.dumps(out))
"""


def t_make_sfx(a):
    """Render a bank sound into generated/<name>-vN.wav, one file per take."""
    sfx_need()
    s = resolve_session(a["session"])
    sound = (a.get("sound") or "").strip()
    known = {x["id"]: x for x in sfx_bank()}
    if sound not in known:
        close = [i for i in known if sound and (sound in i or i.split("/")[0] == sound.split("/")[0])][:8]
        raise ValueError("No sound %r. %s" % (sound, ("Close: " + ", ".join(close)) if close else
                                              "sfx_sounds lists them (query whoosh, click, ...)."))
    takes = int(a.get("takes") or 1)
    if not 1 <= takes <= 12:
        raise ValueError("takes is 1 to 12.")
    knobs = {"dur": sfx_num(a, "dur", 0.02, 10), "apex": sfx_num(a, "apex", 0, 10)}
    if a.get("pitch") not in (None, ""):
        knobs["pitch"] = str(a["pitch"])
    if knobs["apex"] is not None and not known[sound].get("knobs", {}).get("apex"):
        raise ValueError("%s has no peak to aim (apex): only whooshes, risers and swells do." % sound)
    name = slug(a.get("name") or sound.replace("/", "-")) or "sfx"
    seed = int(a["seed"]) if a.get("seed") is not None else random.randrange(1, 1 << 30)  # earshot's own is 0
    jobs, rels = [], []
    for i in range(takes):
        rel = next_generated(s, name, ".wav")
        open(os.path.join(s, rel), "wb").close()  # hold the version while the next is picked
        rels.append(rel)
        j = dict({k: v for k, v in knobs.items() if v is not None}, sound=sound, out=os.path.join(s, rel))
        j["seed"] = seed + i
        jobs.append(j)
    try:
        r = subprocess.run([sfx_python(), "-I", "-c", SFX_RENDER, json.dumps(jobs)], capture_output=True,
                           text=True, timeout=60 + 10 * takes, env=sfx_env())
        if r.returncode != 0:
            err = [x for x in (r.stderr or "").splitlines() if x.strip()]
            raise ValueError("earshot: %s" % (err[-1] if err else "it ended with code %d" % r.returncode))
        made = json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        for rel in rels:
            p = os.path.join(s, rel)
            if os.path.exists(p) and os.path.getsize(p) == 0:
                os.remove(p)
        raise
    files = []
    for rel, m in zip(rels, made):
        note_model(s, rel, "earshot · " + sound)
        files.append(dict(m, file=rel))
    return {"sound": sound, "from": sfx_row(known[sound])["from"], "files": files,
            "note": "On the Assets tab. 48 kHz 24-bit, peak -1 dBFS. In render_edit put each in sfx with "
                    "at = the cut time minus its peak_s (a hit or click: minus onset_s), and gain_db."}


def sfx_ref(s, f):
    """A reference recording for design_sfx: a session file, a name from list_music (SFX/...), or @library/..."""
    f = str(f or "").strip()
    if f.startswith(LIB_REF):
        p = lib_path(f)
    else:
        p = next((c for c in (f if os.path.isabs(f) else os.path.join(s, f), os.path.join(audio_dir(), f),
                              os.path.join(audio_dir(), "SFX", f)) if os.path.isfile(c)), None)
    if not p or not os.path.isfile(p):
        raise ValueError("No file %r. Give a session file, a list_music file (SFX/...), or @library/..." % f)
    return p


def t_design_sfx(a):
    """earshot forge as a job: new sounds from a recipe and a description, into generated/."""
    sfx_need()
    if not sfx_can_design():
        raise ValueError("Sound design is not installed. Ask the user to press Add next to Sound design in Takes "
                         "(Plugins › Sound FX, about 1.5 GB); make_sfx works now.")
    s = job_session(a.get("session"))
    recipes = sfx_recipes()
    recipe = (a.get("recipe") or "").strip()
    if recipe not in recipes:
        raise ValueError("No recipe %r. Recipes: %s." % (recipe, ", ".join(sorted(recipes))))
    target = " ".join(str(a.get("describe") or recipes[recipe]).split())
    budget = int(a.get("budget") or 96)
    if not 24 <= budget <= 400:
        raise ValueError("budget is 24 to 400 candidates (96 takes about a minute).")
    keep = int(a.get("variants") or 3)
    if not 1 <= keep <= 6:
        raise ValueError("variants is 1 to 6.")
    refs = [sfx_ref(s, f) for f in a.get("like") or []]
    alts = [" ".join(str(x).split()) for x in a.get("not_like") or [] if str(x).strip()]
    name = slug(a.get("name") or recipe) or recipe
    first = next_generated(s, name, ".wav")
    job_id = new_job_id(s)
    work = os.path.join(WORK_DIR, "sfx-" + job_id)
    q = shlex.quote
    cmd = [q(sfx_python()), "-m", "earshot", "forge", q(recipe), "--target", q(target), "--budget", str(budget),
           "--variants", str(keep), "--dir", q(work)]
    if alts:
        cmd += ["--alts"] + [q(x) for x in alts]
    if refs:
        cmd += ["--refs"] + [q(x) for x in refs]
    home = sfx_env().get("EARSHOT_HOME")
    cmd = ("export EARSHOT_OFFLINE=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 PYTHONWARNINGS=ignore%s; "
           % (" EARSHOT_HOME=" + q(home) if home else "") + " ".join(cmd) + " && " + " ".join(q(x) for x in [sys.executable, os.path.abspath(__file__),
                                                             "--sfx-finish", work, name, recipe, first]))
    job = start_job(s, cmd, [first], "Design %s" % name, estimate_s=30 + budget // 2, job_id=job_id)
    return {"job": job["id"], "status": job["status"], "recipe": recipe, "describe": target, "first": first,
            "work": work,
            "note": "Up to %d new sounds land as %s and the next versions in generated/. %s/report.md says what "
                    "each one sounds like and how far it is from the references: read it, then run again with "
                    "a sharper describe, not_like or like if they are off. Wait with get_job wait_s=50."
                    % (keep, first, work)}


def sfx_finish(work, name, recipe, first):
    """End of a design_sfx job (cwd: the session): copy the picks into generated/, best first."""
    s = os.getcwd()
    rep = json.load(open(os.path.join(work, "report.json")))
    picks = [os.path.join(work, os.path.basename(p["file"])) for p in rep.get("picks") or []]
    picks = [p for p in picks if os.path.exists(p)]
    if not picks:
        sys.exit("earshot kept no sound. Read %s/report.md." % work)
    os.makedirs(os.path.join(s, GENERATED_DIR), exist_ok=True)
    for i, p in enumerate(picks):
        rel = first if i == 0 else next_generated(s, name, ".wav")
        shutil.copyfile(p, os.path.join(s, rel))
        note_model(s, rel, "earshot · designed %s" % recipe)
        print("%s <- %s" % (rel, os.path.basename(p)))
# </private>


# ---------- phone videos (AirDropped into Downloads) ----------

def airdropped(path):
    """True when the file came by AirDrop: macOS tags it with sharingd in its quarantine flag."""
    try:
        out = subprocess.run(["xattr", "-p", "com.apple.quarantine", path],
                             capture_output=True, text=True, timeout=5).stdout
        return "sharingd" in out
    except (OSError, subprocess.TimeoutExpired):
        return False


def video_tags(path):
    """The phone's own tags: model and the time it began recording."""
    for probe in ("ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"):
        try:
            out = subprocess.run([probe, "-v", "error", "-show_entries", "format_tags", "-of", "json", path],
                                 capture_output=True, text=True, timeout=30).stdout
            return (json.loads(out or "{}").get("format") or {}).get("tags") or {}
        except (OSError, ValueError, subprocess.TimeoutExpired):
            continue
    return {}


def first_words(path, seconds=40):
    """What is said in the first seconds, from Whisper. None when Whisper is missing or fails."""
    whisper = shutil.which("whisper") or "/opt/homebrew/bin/whisper"
    ffmpeg = find_tool("ffmpeg")
    if not os.path.exists(whisper) or not ffmpeg:
        return None
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "start.wav")
        try:
            subprocess.run([ffmpeg, "-v", "error", "-y", "-i", path, "-t", str(seconds), "-vn", "-ac", "1",
                            "-ar", "16000", wav], check=True, timeout=120)
            subprocess.run([whisper, wav, "--model", "small.en", "--language", "en", "--output_format", "txt",
                            "--output_dir", d, "--fp16", "False"], capture_output=True, check=True, timeout=300)
            return re.sub(r"\s+", " ", read_text(os.path.join(d, "start.txt"))).strip()
        except (OSError, subprocess.SubprocessError):
            return None


def recent_sessions(n=15):
    """The newest sessions of the whole library, with the start of each script, to match videos to."""
    r = root()
    out = []
    for name in os.listdir(r) if os.path.isdir(r) else []:
        p = os.path.join(r, name)
        if os.path.isdir(p) and not name.startswith((".", "_")):
            out += sessions_in(p)
    out.sort(key=lambda x: x["created"], reverse=True)
    view = []
    for x in out[:n]:
        script = read_text(os.path.join(x["path"], "script.md")) if x["has_script"] else ""
        view.append({"session": x["session"], "title": x["title"], "created": x["created"], "takes": x["takes"],
                     "script_start": re.sub(r"\s+", " ", script).strip()[:200]})
    return view


def t_phone_videos(a):
    """The videos the user AirDropped (or recorded on an iPhone) that wait in Downloads, oldest first."""
    folder = os.path.expanduser(a.get("folder") or "~/Downloads")
    days = a.get("days") or 14
    since = datetime.now().timestamp() - days * 86400
    found = []
    for name in os.listdir(folder) if os.path.isdir(folder) else []:
        f = os.path.join(folder, name)
        if name.startswith(".") or media_kind(name) != "video" or not os.path.isfile(f):
            continue
        st = os.stat(f)
        if max(st.st_mtime, getattr(st, "st_birthtime", 0)) < since:
            continue
        tags = video_tags(f)
        model = tags.get("com.apple.quicktime.model") or ""
        drop = airdropped(f)
        if not (drop or "iPhone" in model or a.get("all")):
            continue
        v = {"path": f, "name": name, "mb": round(st.st_size / 1e6, 1), "duration": media_duration(f),
             "recorded": tags.get("com.apple.quicktime.creationdate") or tags.get("creation_time"),
             "device": model or None, "airdrop": drop}
        if a.get("listen"):
            v["first_words"] = first_words(f)
        found.append(v)
    found.sort(key=lambda v: v["recorded"] or "")
    return {"folder": folder, "videos": found, "recent_sessions": recent_sessions(),
            "note": "Match each video to a session by what is said (listen=true) against script_start and "
                    "titles, and by when it was recorded. Then import_take with move=true, several in one "
                    "call in recording order. When a video fits no session, create_session first. Ask the user "
                    "only when a match is a guess."}


def t_set_keeper(a):
    s = resolve_session(a["session"])
    meta = read_meta(s)
    n, on = int(a["take"]), bool(a.get("keeper", True))
    for t in meta["takes"]:
        if t["number"] == n:
            t["keeper"] = on
    write_meta(s, meta)
    return {"session": os.path.relpath(s, root()), "take": n, "keeper": on}


def add_post(posts, post):
    """Same rule as the app: one entry per platform; a real platform replaces 'somewhere'.
    Marking a platform again keeps its first date, its link and its numbers."""
    plat = (post.get("platform") or "").lower()
    old = next((p for p in posts if (p.get("platform") or "").lower() == plat), None)
    if old:
        post = dict(post, at=old.get("at", post["at"]))
        for k in ("url", "stats"):
            if old.get(k) and not post.get(k):
                post[k] = old[k]
    out = [p for p in posts if (p.get("platform") or "").lower() != plat]
    if plat:
        out = [p for p in out if p.get("platform")]
    return out + [post]


def mark_post_live(s, plat, url=None, at=None):
    """A platform marked published means its post is live: the post file says posted too, so the plan
    never lists a live post as draft or ready (2026-10-09). Same rule as the app's markPublished."""
    p = next((k for k, v in PLATFORMS.items() if v["name"].lower() == (plat or "").lower()), None)
    f = post_file(s, p) if p else None
    if f is None or f[0].get("status") == "posted":
        return
    fm, text = f
    fm["status"] = "posted"
    fm.pop("scheduled_at", None)
    fm.pop("scheduled_hash", None)
    if not fm.get("at"):
        fm["at"], fm["tz"] = post_time(at or now_iso(), fm.get("tz"))
    if url and not fm.get("url"):
        fm["url"] = url
    write_post_file(s, fm, text, p)


def t_set_published(a):
    s = resolve_session(a["session"])
    meta = read_meta(s)
    if a.get("published", True) is False:
        plat = (a.get("platform") or "").lower()
        posts = [p for p in meta.get("published") or [] if plat and (p.get("platform") or "").lower() != plat]
    else:
        post = {"at": now_iso()}
        for k in ("platform", "url"):
            if a.get(k):
                post[k] = a[k]
        posts = add_post(meta.get("published") or [], post)
        live = next((x for x in posts if (x.get("platform") or "").lower() == (a.get("platform") or "").lower()), None)
        if live:
            mark_post_live(s, live.get("platform"), live.get("url"), live.get("at"))
    if posts:
        meta["published"] = posts
    else:
        meta.pop("published", None)
    write_meta(s, meta)
    return {"session": os.path.relpath(s, root()), "published": posts or False,
            "note": "The user cleans up the session in the app (Mark published menu > Clean Up Session)."}


STAT_KEYS = ("impressions", "views", "likes", "comments", "reposts")


def t_set_post_stats(a):
    """Adds one reading of a published post's numbers. Marks the platform published if it is not."""
    s = resolve_session(a["session"])
    plat = (a.get("platform") or "").strip()
    if not plat:
        raise ValueError("platform is required: LinkedIn, X, YouTube, Instagram, TikTok, …")
    reading = {"at": now_iso()}
    for k in STAT_KEYS:
        if a.get(k) is not None:
            reading[k] = int(a[k])
    if len(reading) == 1:
        raise ValueError("Pass at least one number: " + ", ".join(STAT_KEYS))
    meta = read_meta(s)
    posts = meta.get("published") or []
    post = next((p for p in posts if (p.get("platform") or "").lower() == plat.lower()), None)
    if post is None:
        post = {"platform": plat, "at": now_iso()}
        posts = add_post(posts, post)
        post = posts[-1]
    if a.get("url"):
        post["url"] = a["url"]
    post["stats"] = (post.get("stats") or []) + [reading]
    meta["published"] = posts
    write_meta(s, meta)
    mark_post_live(s, post.get("platform"), post.get("url"), post.get("at"))
    return {"session": os.path.relpath(s, root()), "platform": post.get("platform"), "url": post.get("url"),
            "readings": len(post["stats"]), "latest": reading}


def social_freshness(today=None):
    """How far the Signal dashboard data (_library/social.json) reaches, per source."""
    try:
        with open(os.path.join(root(), LIB, "social.json")) as f:
            src = json.load(f).get("sources") or {}
    except (OSError, ValueError):
        src = {}
    today = today or datetime.now().date()
    out, stale = {}, []
    for key in ("linkedin", "followers", "x"):
        day = src.get(key) or ""
        try:
            age = (today - datetime.strptime(day[:10], "%Y-%m-%d").date()).days
        except ValueError:
            age = None
        out[key] = {"through": day or None, "days_old": age}
        if age is None or age > 2:
            stale.append(key)
    out["stale"] = stale
    out["refresh"] = ("In your notes repo run python3 tracking/scripts/refresh_social.py. It loads every LinkedIn and X "
                      "analytics export in ~/Downloads, syncs these posts, rebuilds the board and says which "
                      "export is still missing.") if stale else None
    return out


def t_get_performance(a):
    """Every published post across all projects with its latest numbers, and which need a new reading."""
    stale_h = float(a.get("stale_hours") or 24)
    now = datetime.now(timezone.utc)
    out = []
    r = root()
    for proj in sorted(os.listdir(r)) if os.path.isdir(r) else []:
        pdir = os.path.join(r, proj)
        if proj.startswith((".", "_")) or not os.path.isdir(pdir):
            continue
        for name in os.listdir(pdir):
            sdir = os.path.join(pdir, name)
            if not os.path.isdir(sdir):
                continue
            meta = read_meta(sdir)
            for p in meta.get("published") or []:
                stats = p.get("stats") or []
                last = stats[-1] if stats else None
                age = None
                if last:
                    age = (now - datetime.fromisoformat(last["at"].replace("Z", "+00:00"))).total_seconds() / 3600
                out.append({"session": os.path.relpath(sdir, r), "title": meta.get("title", name),
                            "platform": p.get("platform"), "url": p.get("url"), "published_at": p.get("at"),
                            "latest": last, "readings": len(stats),
                            "needs_reading": bool(p.get("url")) and (age is None or age >= stale_h),
                            "needs_url": not p.get("url")})
    if a.get("platform"):
        out = [p for p in out if (p["platform"] or "").lower() == a["platform"].lower()]
    out.sort(key=lambda p: p["published_at"] or "", reverse=True)
    return {"posts": out, "dashboard": social_freshness(),
            "note": "For each post with needs_reading, open its url in the user's Chrome, in your one tab (create it "
                    "once, navigate it from post to post, close it at the end unless it is the group's last tab; "
                    "never a tab per post), read "
                    "the numbers the platform shows (LinkedIn: impressions, reactions, comments, reposts; "
                    "YouTube/TikTok/Instagram: views, likes, comments) and save them with set_post_stats. "
                    "needs_url: find the post on the user's profile and pass url to set_post_stats. Only read; "
                    "never like, comment or post."}


# ---------- Music and sound effects ----------
# <root>/_library/audio/<Group>/<file>: Music/, SFX/, ... copied from a source folder (default
# ~/Documents/Epidemic Sound; the app's "soundSource" setting). The app never plays sound over a
# video: the agent mixes music and effects into a new version of the file (2026-10-09). Until then
# set_music and set_sfx stored picks the app played live, and the song was heard twice.

AUDIO_EXTS = (".mp3", ".m4a", ".wav", ".aif", ".aiff", ".aac", ".flac")


def audio_dir():
    return os.path.join(root(), LIB, "audio")


def sound_source():
    if os.environ.get("TAKES_SOUND_SOURCE"):
        return os.environ["TAKES_SOUND_SOURCE"]
    try:
        out = subprocess.run(["defaults", "read", "de.marvinaziz.takes", "soundSource"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    return out or os.path.expanduser("~/Documents/Epidemic Sound")


def sync_audio():
    """Copy new audio files from the source folder, keeping folders. Same rule as the app."""
    src, dst, copied = sound_source(), audio_dir(), 0
    if not os.path.isdir(src):
        return 0
    for dirpath, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.startswith(".") or not f.lower().endswith(AUDIO_EXTS):
                continue
            target = os.path.join(dst, os.path.relpath(os.path.join(dirpath, f), src))
            if not os.path.exists(target):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(os.path.join(dirpath, f), target)
                copied += 1
    return copied


def song_title(name):
    return re.sub(r"^\d+_", "", os.path.splitext(os.path.basename(name))[0])


def audio_tags(path):
    for probe in ("ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"):
        try:
            out = subprocess.run([probe, "-v", "error", "-show_entries", "format=duration:format_tags",
                                  "-of", "json", path], capture_output=True, text=True, timeout=30).stdout
            fmt = json.loads(out).get("format", {})
            tags = {k.lower(): v for k, v in fmt.get("tags", {}).items()}
            info = {"duration": round(float(fmt["duration"]), 1)} if fmt.get("duration") else {}
            for key, name in (("artist", "artist"), ("genre", "genre"), ("tbpm", "bpm"), ("bpm", "bpm")):
                if tags.get(key):
                    info[name] = int(float(tags[key])) if name == "bpm" else tags[key]
            return info
        except (OSError, ValueError, subprocess.TimeoutExpired):
            continue
    return {}


def t_list_music(a):
    copied = sync_audio()
    d, q, group = audio_dir(), (a.get("query") or "").lower(), a.get("group")
    out = []
    for dirpath, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if not x.startswith(".")]
        for f in sorted(files):
            if f.startswith(".") or not f.lower().endswith(AUDIO_EXTS):
                continue
            rel = os.path.relpath(os.path.join(dirpath, f), d)
            g = rel.split(os.sep)[0] if os.sep in rel else ""
            if (group and g.lower() != group.lower()) or (q and q not in f.lower()):
                continue
            out.append(dict({"file": rel, "group": g, "title": song_title(f), "path": os.path.join(d, rel)},
                            **audio_tags(os.path.join(d, rel))))
    return {"library": d, "source": sound_source(), "copied_new": copied, "sounds": out}


# ---------- B-roll ----------
# <root>/_library/broll/<N Folder>/<YYYY-MM Shot name (V|H)>.mov: The user's own b-roll. Each clip carries
# its description and keywords in its metadata (title, description, keywords). The app's B-roll tab
# shows the folders; add_broll clones a clip into <session>/broll/ (APFS clone, no extra space).

VIDEO_EXTS = (".mov", ".mp4", ".m4v")


def broll_dir():
    return os.path.join(root(), LIB, "broll")


def broll_tags(path):
    """Duration and the description tags, cached by size and date in _library/broll/.index.json."""
    cache_file = os.path.join(broll_dir(), ".index.json")
    try:
        cache = json.load(open(cache_file))
    except (OSError, ValueError):
        cache = {}
    st = os.stat(path)
    key = "%s|%d|%d" % (os.path.relpath(path, broll_dir()), st.st_size, int(st.st_mtime))
    if key in cache:
        return cache[key]
    info = {}
    for probe in ("ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"):
        try:
            out = subprocess.run([probe, "-v", "error", "-show_entries", "format=duration:format_tags",
                                  "-of", "json", path], capture_output=True, text=True, timeout=30).stdout
            fmt = json.loads(out).get("format", {})
            tags = {k.lower(): v for k, v in fmt.get("tags", {}).items()}
            if fmt.get("duration"):
                info["duration"] = round(float(fmt["duration"]), 1)
            for k in ("description", "keywords"):
                if tags.get(k):
                    info[k] = tags[k]
            break
        except (OSError, ValueError, subprocess.TimeoutExpired):
            continue
    cache[key] = info
    try:
        with open(cache_file, "w") as fh:
            json.dump(cache, fh)
    except OSError:
        pass
    return info


def broll_clips():
    d = broll_dir()
    out = []
    if not os.path.isdir(d):
        return out
    for folder in sorted(os.listdir(d)):
        fd = os.path.join(d, folder)
        if folder.startswith(".") or not os.path.isdir(fd):
            continue
        for f in sorted(os.listdir(fd), reverse=True):
            if f.startswith(".") or not f.lower().endswith(VIDEO_EXTS):
                continue
            stem = os.path.splitext(f)[0]
            m = re.match(r"^(\d{4}-\d{2}) (.*?)(?: \((V|H)\))?$", stem)
            out.append(dict({"file": os.path.join(folder, f), "folder": re.sub(r"^\d+\s+", "", folder),
                             "title": m.group(2) if m else stem, "filmed": m.group(1) if m else None,
                             "orientation": {"V": "vertical", "H": "horizontal"}.get(m.group(3)) if m else None,
                             "path": os.path.join(fd, f)}, **broll_tags(os.path.join(fd, f))))
    return out


def t_list_broll(a):
    q, folder = (a.get("query") or "").lower(), (a.get("folder") or "").lower()
    out = []
    for c in broll_clips():
        if folder and folder not in c["folder"].lower():
            continue
        if q and not all(w in " ".join([c["title"], c.get("description", ""), c.get("keywords", "")]).lower()
                         for w in q.split()):
            continue
        if a.get("orientation") and c.get("orientation") != a["orientation"]:
            continue
        out.append(c)
    return {"library": broll_dir(), "clips": out}



# ---------- search by meaning ----------
#
# The app's ⌘K search (Sources/Takes/Search.swift): EmbeddingGemma 2 on this Mac, in the takes-embed
# helper inside Takes.app. Takes downloads the model in the background and keeps the index in
# <root>/_library/search/index.json. This tool asks the same helper.

def embed_helper():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.environ.get("TAKES_EMBED"), os.path.join(here, "..", "MacOS", "takes-embed"),
              os.path.expanduser("~/Applications/Takes.app/Contents/MacOS/takes-embed"),
              "/Applications/Takes.app/Contents/MacOS/takes-embed"):
        if p and os.access(p, os.X_OK):
            return os.path.realpath(p)
    return None


def embed_models():
    return os.environ.get("TAKES_EMBED_MODELS") or os.path.expanduser(
        "~/Library/Application Support/Takes/Models/embeddinggemma-2-q8")


def t_search_media(a):
    q = (a.get("query") or "").strip()
    if not q:
        return {"error": "Say what to look for."}
    helper = embed_helper()
    if not helper:
        return {"error": "This Takes build has no search helper. Use list_broll or get_session instead."}
    if not os.path.exists(os.path.join(embed_models(), "text-q8", "model.safetensors")):
        return {"error": "The search model is still downloading (Takes > Settings > Search). Use list_broll for now."}
    cmd = [helper, "search", "--models", embed_models(), "--root", root(), "--limit", str(int(a.get("limit") or 12))]
    if a.get("kinds"):
        cmd += ["--kind", ",".join(a["kinds"])]
    try:
        out = subprocess.run(cmd + [q], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return {"error": "The search took too long."}
    if out.returncode != 0:
        return {"error": (out.stderr.strip() or "The search failed.")[-400:]}
    data = json.loads(out.stdout)
    hits = []
    for r in data.get("results", []):
        h = {"path": r["path"], "kind": r["kind"]}
        if r["kind"] in ("video", "speech"):
            h["at"] = round(r.get("start", 0), 1)
        if r.get("text"):
            h["text"] = r["text"]
        if r.get("about"):
            h["about"] = r["about"]
        hits.append(h)
    out = {"results": hits, "indexed_files": (data.get("status") or {}).get("files")}
    if not hits:
        out["note"] = "Nothing indexed yet. Takes indexes the library in the background once the model is downloaded."
    return out


def t_add_broll(a):
    s = resolve_session(a["session"])
    dst = os.path.join(s, "broll")
    os.makedirs(dst, exist_ok=True)
    added = []
    for f in a["files"]:
        src = f if os.path.isabs(f) else os.path.join(broll_dir(), f)
        if not os.path.isfile(src) or not os.path.normpath(src).startswith(os.path.normpath(broll_dir()) + os.sep):
            raise ValueError("No clip at _library/broll/%s. Use a file from list_broll." % f)
        target = os.path.join(dst, os.path.basename(src))
        if not os.path.exists(target):
            # cp -c: an APFS clone, so the copy costs no space.
            if subprocess.run(["cp", "-c", src, target]).returncode != 0:
                shutil.copy2(src, target)
        added.append(target)
    return {"session": os.path.relpath(s, root()), "added": added}


def t_trash_takes(a):
    s = resolve_session(a["session"])
    meta = read_meta(s)
    if a.get("non_keepers"):
        numbers = {t["number"] for t in meta["takes"] if not t.get("keeper")}
    else:
        numbers = {int(x) for x in a.get("takes", [])}
    doomed = [t for t in meta["takes"] if t["number"] in numbers]
    files = [os.path.join(s, t["file"]) for t in doomed]
    files += [os.path.splitext(f)[0] + ".words.json" for f in files]
    trash([f for f in files if os.path.exists(f)])
    meta["takes"] = [t for t in meta["takes"] if t["number"] not in numbers]
    write_meta(s, meta)
    return {"trashed_takes": sorted(numbers), "note": "Moved to the macOS Trash."}


def t_trash_sessions(a):
    paths = [resolve_session(x) for x in a["sessions"]]
    trash(paths)
    return {"trashed": [os.path.relpath(p, root()) for p in paths], "note": "Moved to the macOS Trash."}


def t_move_sessions(a):
    dest = os.path.join(root(), project_name(a["project"]))
    os.makedirs(dest, exist_ok=True)
    moved = []
    for x in a["sessions"]:
        s = resolve_session(x)
        if os.path.dirname(s) == dest:
            continue
        sid = session_id(s)
        target = free_session_path(os.path.join(dest, os.path.basename(s)), sid)
        os.rename(s, target)
        record_move(s, target)
        moved.append({"from": os.path.relpath(s, root()), "to": os.path.relpath(target, root()), "id": sid})
    return {"moved": moved}


def t_create_variants(a):
    s = resolve_session(a["session"])
    need_rules("script")
    d = os.path.join(s, "variants")
    os.makedirs(d, exist_ok=True)
    made = []
    for v in a["variants"]:
        name = v.get("name", "").strip() or "Variant"
        base = slug(name) or "variant"
        sl, n = base, 2
        while os.path.exists(os.path.join(d, sl + ".md")):
            sl = "%s-%d" % (base, n)
            n += 1
        write_text(os.path.join(d, sl + ".md"), render_fm(
            [("name", name), ("author", a.get("author", "claude")), ("note", v.get("note", "")), ("created", now_iso())],
            v["script"]))
        made.append(sl)
    return {"session": os.path.relpath(s, root()), "created_variants": made,
            "note": "They show up as tabs above the teleprompter within 2 seconds."}


def t_update_variant(a):
    s = resolve_session(a["session"])
    p = os.path.join(s, "variants", a["variant"] + ".md")
    if not os.path.exists(p):
        raise ValueError("No variant '%s'. See get_session." % a["variant"])
    fm, body = parse_fm(read_text(p))
    snapshot(s, a["variant"], fm.get("author") or "user", "Before %s's change" % a.get("author", "claude").capitalize())
    if a.get("name"):
        fm["name"] = a["name"]
    if a.get("note") is not None:
        fm["note"] = a.get("note", fm.get("note", ""))
    order = [(k, fm.get(k, "")) for k in ("name", "author", "note", "created")]
    write_text(p, render_fm(order, a.get("script", body)))
    snapshot(s, a["variant"], a.get("author", "claude"), a.get("note") or "Edited by Takes")
    return {"updated": a["variant"]}


def t_set_favorite_script(a):
    s = resolve_session(a["session"])
    meta = read_meta(s)
    draft = a.get("draft")
    if draft and draft != "main" and draft_text(s, draft) is None:
        raise ValueError("No variant '%s'." % draft)
    if draft:
        meta["favorite"] = draft
    else:
        meta.pop("favorite", None)
    write_meta(s, meta)
    return {"favorite_script": draft}


def t_promote_variant(a):
    s = resolve_session(a["session"])
    v = next((x for x in variants(s) if x["variant"] == a["variant"]), None)
    if not v:
        raise ValueError("No variant '%s'." % a["variant"])
    set_main_script(s, v["script"], v["author"] or "claude", "Used “%s” as main" % v["name"])
    trash([os.path.join(s, "variants", a["variant"] + ".md")])
    meta = read_meta(s)
    if meta.get("favorite") == a["variant"]:
        meta["favorite"] = "main"
        write_meta(s, meta)
    return {"main_script_now_from": v["name"], "note": "The old main script is in history."}


def t_delete_variants(a):
    s = resolve_session(a["session"])
    paths = []
    for v in a["variants"]:
        snapshot(s, v, "user", "Before deleting the variant")
        p = os.path.join(s, "variants", v + ".md")
        if os.path.exists(p):
            paths.append(p)
    trash(paths)
    return {"trashed": [os.path.basename(p)[:-3] for p in paths]}


def t_script_history(a):
    s = resolve_session(a["session"])
    out = []
    for v in history(s):
        body = v.pop("_body")
        v["preview"] = body.strip().replace("\n", " ")[:120]
        out.append(v)
    return {"versions": out}


def t_get_script_version(a):
    s = resolve_session(a["session"])
    v = next((x for x in history(s) if x["version"] == a["version"]), None)
    if not v:
        raise ValueError("No version '%s'. See script_history." % a["version"])
    return {"version": v["version"], "draft": v["draft"], "author": v["author"], "note": v["note"],
            "created": v["created"], "script": v["_body"]}


def t_restore_script_version(a):
    s = resolve_session(a["session"])
    v = next((x for x in history(s) if x["version"] == a["version"]), None)
    if not v:
        raise ValueError("No version '%s'." % a["version"])
    draft = v["draft"]
    if draft != "main" and draft_text(s, draft) is None:
        draft = "main"
    if draft == "main":
        set_main_script(s, v["_body"], a.get("author", "claude"), "Restored %s" % v["created"])
    else:
        t_update_variant({"session": s, "variant": draft, "script": v["_body"], "note": "Restored %s" % v["created"]})
    return {"restored": v["version"], "into": draft}


# ---------- clean voice ----------
# The voice cleanup of the user's voice-cleanup skill, run on a take's raw audio. Files, per take file,
# in <session>/voice/ (the app hides the folder; get_session shows them under each take):
#   take-01-camera.json       state and settings: strength, loudness, on
#   take-01-camera.clean.wav  ClearVoice + voice chain (the script's plan)
#   take-01-camera.dry.wav    the same voice chain without the model (strength 0 %)
#   take-01-camera.wav        the mix edits use: clean and dry blended at `strength`, at `loudness`
# All WAVs are 48 kHz mono float. "clock": "video" (2026-10-11 on): second 0 is frame 0 of the take, so
# cut them with the take's times. Without it the WAV starts at the take's first sound: see voice_offset.

VOICE_LOUDNESS = {"normal": 0.0, "quiet": -4.0}  # dB from the script's -14 LUFS: -14 or -18 LUFS
VOICE_DEFAULTS = {"strength": 1.0, "loudness": "normal", "on": True}


def voice_script():
    """The cleanup script: the copy that ships next to this file (build.sh puts both in the app)."""
    if os.environ.get("TAKES_VOICE_SCRIPT"):
        return os.environ["TAKES_VOICE_SCRIPT"]
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "clean_voice.py")


def ensure_uv():
    """uv runs the cleanup with its Python packages. A new Mac has none: get it once with
    Astral's installer into ~/.local/bin, where Takes also puts ffmpeg."""
    uv = find_tool("uv")
    if uv:
        return uv
    env = dict(os.environ, UV_INSTALL_DIR=os.path.expanduser("~/.local/bin"), UV_NO_MODIFY_PATH="1")
    r = subprocess.run(["/bin/sh", "-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
                       env=env, capture_output=True, text=True, timeout=300)
    uv = find_tool("uv")
    if not uv:
        raise ValueError("Could not install uv (%s). Install it from https://docs.astral.sh/uv and try again."
                         % ((r.stderr or r.stdout).strip().splitlines() or ["no output"])[-1][:120])
    return uv


def find_tool(name):
    for p in (shutil.which(name), "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name,
              os.path.expanduser("~/.local/bin/" + name)):
        if p and os.path.exists(p):
            return p
    return None


def voice_key(n, kind):
    return "take-%02d-%s" % (int(n), kind)


def voice_files(s, key):
    d = os.path.join(s, "voice")
    return {"json": os.path.join(d, key + ".json"), "mix": os.path.join(d, key + ".wav"),
            "clean": os.path.join(d, key + ".clean.wav"), "dry": os.path.join(d, key + ".dry.wav")}


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def read_voice(s, key):
    try:
        with open(voice_files(s, key)["json"]) as f:
            v = json.load(f)
    except (OSError, ValueError):
        return None
    if v.get("state") == "running" and not alive(v.get("pid")):
        v.update(state="failed", error="The cleanup stopped before it finished.")
    return v


def write_voice(s, key, v):
    p = voice_files(s, key)["json"]
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as f:
        json.dump(v, f, indent=2, sort_keys=True)
    os.replace(p + ".tmp", p)


def voice_take(s, n, kind=None):
    """The take file with the voice: the camera file unless kind says otherwise."""
    g = [t for t in read_meta(s).get("takes", []) if t["number"] == int(n)]
    if not g:
        raise ValueError("No take %s in this session." % n)
    t = next((t for t in g if t["kind"] == (kind or "camera")), None) or (None if kind else g[0])
    if not t:
        raise ValueError("Take %s has no %s file." % (n, kind))
    return t


def voice_view(s, t):
    """What get_session shows under a take, or None when the voice was never cleaned."""
    key = voice_key(t["number"], t["kind"])
    v = read_voice(s, key)
    if not v:
        return None
    f = voice_files(s, key)
    out = {k: v.get(k) for k in ("state", "strength", "loudness", "on", "steps", "error") if v.get(k) is not None}
    for k in ("echo_before_db", "echo_after_db", "snr_db"):
        if v.get(k) is not None:
            out[k] = v[k]
    if v.get("state") == "done" and v.get("on") and os.path.exists(f["mix"]):
        out["file"] = f["mix"]
        late = 0.0 if v.get("clock") == "video" else voice_offset(s, key)
        if late > 0.0005:
            # Cleaned before 2026-10-11: the WAV starts at the take's first sound. No old file is rewritten.
            out["starts_at_s"] = round(late, 3)
            out["use"] = ("This WAV starts at the take's first sound, %.3f s after the video starts. cut_take puts it "
                          "in place; by hand, delay it %.3f s (adelay=%d)." % (late, late, round(late * 1000)))
        else:
            out["use"] = ("Use this WAV as the voice of this take in edits: second 0 is frame 0 of the take. "
                          "cut_take uses it for you.")
    return out


def voice_mix(s, key):
    """Blend clean and dry at the take's strength and loudness into the mix WAV (a second or two)."""
    v, f = read_voice(s, key) or {}, voice_files(s, key)
    if not v.get("on", True):
        if os.path.exists(f["mix"]):
            os.remove(f["mix"])
        return
    k = max(0.0, min(1.0, float(v.get("strength", 1.0))))
    g = VOICE_LOUDNESS.get(v.get("loudness"), 0.0)
    ffmpeg = find_tool("ffmpeg")
    if not ffmpeg:
        raise ValueError("ffmpeg is not installed. Open Takes and click Finish setup, or run brew install ffmpeg.")
    subprocess.run([ffmpeg, "-v", "error", "-y", "-i", f["clean"], "-i", f["dry"], "-filter_complex",
                    "[0:a][1:a]amerge=inputs=2,pan=mono|c0=%.4f*c0+%.4f*c1,volume=%.1fdB" % (k, 1 - k, g),
                    "-ar", "48000", "-c:a", "pcm_f32le", f["mix"] + ".tmp.wav"], check=True, timeout=600)
    os.replace(f["mix"] + ".tmp.wav", f["mix"])


def voice_run(s, n, kind):
    """The whole cleanup of one take file. Runs detached (see start_voice); writes its state as it goes."""
    t = voice_take(s, n, kind)
    key = voice_key(t["number"], t["kind"])
    f = voice_files(s, key)
    src = os.path.join(s, t["file"])
    old = read_voice(s, key) or {}
    v = {k: old.get(k, d) for k, d in VOICE_DEFAULTS.items()}
    v.update(state="running", pid=os.getpid(), started=now_iso(), source=t["file"],
             seconds=t.get("duration") or media_duration(src))
    write_voice(s, key, v)
    os.environ["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
    wav = os.path.join(s, "voice", key + ".src.wav")
    try:
        # The cleanup gets the take's sound on the video clock, so its WAVs are too (2026-10-11).
        os.makedirs(os.path.dirname(wav), exist_ok=True)
        extract_voice(src, wav)
        src = wav
        if os.environ.get("TAKES_VOICE_CMD"):  # tests: a stand-in for the script
            base = json.loads(os.environ["TAKES_VOICE_CMD"]) + [src]
        else:
            uv, script = ensure_uv(), voice_script()  # the first run also downloads Python 3.11 and the model
            if not os.path.exists(script):
                raise ValueError("The voice-cleanup script is missing: %s" % script)
            base = [uv, "run", "-q", "--python", "3.11", "--with", "clearvoice", "--with", "soundfile",
                    "--with", "numpy", script, src]

        def run(out, *extra):
            r = subprocess.run(base + [out] + list(extra), capture_output=True, text=True)
            if r.returncode != 0:
                raise ValueError((r.stderr or r.stdout).strip().splitlines()[-1] if (r.stderr or r.stdout).strip()
                                 else "The cleanup failed.")

        run(f["clean"])
        with open(f["clean"][:-4] + ".report.json") as fh:
            rep = json.load(fh)
        pre = [x for x in rep.get("steps", []) if x in ("declip", "dehum")]
        run(f["dry"], "--steps", ",".join(pre) or "none")
        d = rep.get("diagnosis", {})
        v.update(steps=rep.get("steps", []), echo_before_db=d.get("echo_tail_db"),
                 echo_after_db=rep.get("echo_after_db"), snr_db=d.get("snr_db"),
                 clipped=bool(d.get("clipped_runs", 0) > 20))
        write_voice(s, key, v)
        voice_mix(s, key)
        v.update(state="done", finished=now_iso(), clock="video")
        v.pop("error", None)
    except Exception as e:
        v.update(state="failed", error=str(e)[:400])
    finally:
        if os.path.exists(wav):
            os.remove(wav)
    v.pop("pid", None)
    write_voice(s, key, v)


def start_voice(s, t):
    """Start voice_run in the background (it takes about 15-60 s per minute of audio)."""
    key = voice_key(t["number"], t["kind"])
    v = read_voice(s, key)
    if v and v.get("state") == "running":
        return
    pid = spawn_detached(["--voice-run", s, str(t["number"]), t["kind"]])
    try:
        with open(voice_files(s, key)["json"]) as f:
            now = json.load(f)
    except (OSError, ValueError):
        now = {}
    if pid and now.get("pid") != pid:  # the runner has not written yet
        write_voice(s, key, dict(now or VOICE_DEFAULTS, state="running", pid=pid, started=now_iso()))


def t_clean_voice(a):
    s = resolve_session(a["session"])
    t = voice_take(s, a["take"], a.get("kind"))
    key = voice_key(t["number"], t["kind"])
    v = read_voice(s, key)
    settings = {k: a[k] for k in ("strength", "loudness", "on") if k in a}
    if "strength" in settings:
        settings["strength"] = max(0.0, min(1.0, float(settings["strength"])))
    if settings.get("loudness") not in (None, *VOICE_LOUDNESS):
        raise ValueError("loudness is normal (-14 LUFS) or quiet (-18 LUFS).")
    if not v or a.get("rerun") or v.get("state") == "failed":
        write_voice(s, key, {**VOICE_DEFAULTS, **(v or {}), **settings, "state": "idle"})
        start_voice(s, t)
        view = voice_view(s, t) or {}
        est = max(20, (t.get("duration") or 60) * 0.5 + 10)
        view["note"] = ("Cleaning in the background, about %s. Call get_session later: the take's voice.file "
                        "is the result." % ("%d s" % est if est < 90 else "%d min" % round(est / 60)))
        return dict(view, take=t["number"], kind=t["kind"])
    v.update(settings)
    write_voice(s, key, v)
    if v.get("state") == "done":
        voice_mix(s, key)
    return dict(voice_view(s, t) or {}, take=t["number"], kind=t["kind"])


def open_in_app(path):
    # -g: never bring Takes to the front. The user may be working in another app or another session;
    # Takes never shows it at once: it waits as a notice until he clicks it.
    url = "takes://open?path=" + urllib.parse.quote(path)
    subprocess.run(["open", "-g", url], capture_output=True)


def t_open_in_app(a):
    ref = a["path"]
    path = ref if os.path.isabs(ref) else os.path.join(root(), ref)
    open_in_app(os.path.normpath(path))
    return {"opened": path}


# ---------- Saving to the b-roll library ----------
# The user saves a take or an asset of a session into _library/broll/<folder>/ (an APFS clone). A video
# model (Gemini) watches it once; its description, keywords and a short name go into the clip's own
# metadata, the same tags list_broll reads for the clips he sorted himself.

DESCRIBE_MODEL = "gemini-3.8-flash"


def session_file(s, ref):
    """A file in the session: a take number, 'take-03-camera.mov', 'assets/drone.mp4', or an absolute path."""
    ref = str(ref).strip()
    if ref.isdigit():
        t = voice_take(s, ref)
        return os.path.join(s, t["file"])
    path = os.path.normpath(ref if os.path.isabs(ref) else os.path.join(s, ref))
    if not path.startswith(os.path.normpath(s) + os.sep):
        raise ValueError("%s is not inside the session." % ref)
    if not os.path.isfile(path):
        raise ValueError("No file %s in the session." % ref)
    return path


def broll_name(month, name, w, h, ext):
    """'2026-10 Desk Typing Closeup (V).mov'"""
    name = re.sub(r'[/:\\]+', " ", name).strip() or "Clip"
    o = "" if not (w and h) or w == h else " (V)" if h > w else " (H)"
    return "%s %s%s%s" % (month, name, o, ext.lower())


def free_broll(d, month, name, w, h, ext):
    """A file name in d no clip has: 'Snow Walk (V)', then 'Snow Walk 2 (V)', ..."""
    path, n = os.path.join(d, broll_name(month, name, w, h, ext)), 2
    while os.path.exists(path):
        path, n = os.path.join(d, broll_name(month, "%s %d" % (name, n), w, h, ext)), n + 1
    return path


def save_broll(src, folder, name=None, describe=True):
    """Clones src into _library/broll/<folder>/. Without a name, the description names it."""
    folder = re.sub(r'[/:\\]+', " ", folder or "").strip()
    if not folder:
        raise ValueError("Give a folder (from list_broll, or a new one).")
    d = os.path.join(broll_dir(), folder)
    os.makedirs(d, exist_ok=True)
    w, h = video_size(src)
    month = datetime.fromtimestamp(os.path.getmtime(src)).strftime("%Y-%m")
    stem = name or os.path.splitext(os.path.basename(src))[0]
    target = free_broll(d, month, stem, w, h, os.path.splitext(src)[1] or ".mov")
    if subprocess.run(["cp", "-c", src, target], capture_output=True).returncode != 0:
        shutil.copy2(src, target)
    if describe:
        spawn_detached(["--broll-describe", target] + ([] if name else ["--rename"]))
    return target


def t_save_broll(a):
    s = resolve_session(a["session"])
    src = session_file(s, a["file"])
    if media_kind(src) != "video":
        raise ValueError("Only videos go into the b-roll library.")
    target = save_broll(src, a["folder"], (a.get("name") or "").strip() or None)
    return {"saved": target, "note_for_you": "Gemini describes it in the background (about 20-60 s); "
            "list_broll shows the description then."}


def gemini_key():
    for k in ("GEMINI_API_KEY", "GOOGLE_AI_API_KEY", "GOOGLE_API_KEY"):
        if os.environ.get(k):
            return os.environ[k]
    # ~/.claude/.env: Takes › Settings › Gemini saves GEMINI_API_KEY there; it wins over an older GOOGLE_AI_API_KEY.
    found = {}
    try:
        for line in open(os.path.expanduser("~/.claude/.env")):
            k, _, v = line.strip().partition("=")
            k = k.strip().removeprefix("export ").strip()
            v = v.strip().strip('"').strip("'")
            if k in ("GEMINI_API_KEY", "GOOGLE_AI_API_KEY") and v:
                found[k] = v
    except OSError:
        pass
    return found.get("GEMINI_API_KEY") or found.get("GOOGLE_AI_API_KEY")


DESCRIBE_PROMPT = """You describe one B-roll video for a video editor's library. The person in it (if any) is \
The user, who makes short talking videos about AI agents for LinkedIn and X. Another AI agent will pick B-roll \
from these descriptions without watching the video, so be concrete and visual: what is on screen, the \
camera, the light, the motion. Times are seconds from the start. Do not guess names of other people. \
If there is speech, give the gist, not a transcript."""

DESCRIBE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "name": {"type": "STRING", "description": "A name of at most 3 words, Title Case, for what the clip "
                 "shows, so it is easy to find: 'Golden Gate Drone', 'Desk Typing Closeup'."},
        "summary": {"type": "STRING", "description": "One sentence: what the clip shows."},
        "shots": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
            "start": {"type": "NUMBER"}, "end": {"type": "NUMBER"},
            "what": {"type": "STRING", "description": "What is on screen and how the camera moves."}},
            "required": ["start", "end", "what"]}},
        "tags": {"type": "ARRAY", "items": {"type": "STRING"}, "description": "5-12 short search words."},
        "setting": {"type": "STRING", "description": "Where: place, indoor/outdoor, time of day."},
        "people": {"type": "STRING", "description": "Who is visible and what they do, or 'none'."},
        "camera": {"type": "STRING", "description": "Framing and motion: handheld, static, drone, close-up..."},
        "light": {"type": "STRING", "description": "Light and colour: golden hour, office light, dark..."},
        "mood": {"type": "STRING"},
        "speech": {"type": "STRING", "description": "Gist of what is said, or 'none'."},
        "text_on_screen": {"type": "STRING", "description": "Readable text, logos, screens, or 'none'."},
        "best_uses": {"type": "ARRAY", "items": {"type": "STRING"},
                      "description": "2-5 moments in a talking video where this clip fits as a cutaway."},
        "best_moments": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
            "start": {"type": "NUMBER"}, "end": {"type": "NUMBER"}, "why": {"type": "STRING"}},
            "required": ["start", "end", "why"]}, "description": "The strongest 2-6 s ranges to cut in."},
        "quality": {"type": "STRING", "description": "Focus, shake, exposure problems, or 'good'."},
    },
    "required": ["name", "summary", "shots", "tags", "setting", "people", "camera", "mood", "best_uses", "best_moments"],
}


def video_size(path):
    probe = find_tool("ffprobe")
    if not probe:
        return None, None
    try:
        out = subprocess.run([probe, "-v", "error", "-select_streams", "v:0", "-show_entries",
                              "stream=width,height:stream_side_data=rotation", "-of", "json", path],
                             capture_output=True, text=True, timeout=30).stdout
        st = json.loads(out)["streams"][0]
        w, h = int(st["width"]), int(st["height"])
        rot = next((abs(int(d.get("rotation", 0))) for d in st.get("side_data_list", []) if "rotation" in d), 0)
        return (h, w) if rot in (90, 270) else (w, h)
    except Exception:
        return None, None


def gemini_call(path_or_bytes, mime, key, prompt=None, schema=None, ask="Describe this clip.", model=None, fps=None,
                usage=None):
    """Send one small video to Gemini and return its JSON answer. Inline under 18 MB, else the Files API."""
    import base64
    import urllib.request
    base = "https://generativelanguage.googleapis.com"
    hdr = {"x-goog-api-key": key}
    data = open(path_or_bytes, "rb").read()
    if len(data) < 18 * 1024 * 1024:
        part = {"inline_data": {"mime_type": mime, "data": base64.b64encode(data).decode()}}
    else:
        start = urllib.request.Request(base + "/upload/v1beta/files", method="POST", headers=dict(hdr, **{
            "X-Goog-Upload-Protocol": "resumable", "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(len(data)), "X-Goog-Upload-Header-Content-Type": mime,
            "Content-Type": "application/json"}), data=json.dumps({"file": {"display_name": "broll"}}).encode())
        up = urllib.request.urlopen(start, timeout=60).headers["X-Goog-Upload-URL"]
        put = urllib.request.Request(up, method="POST", data=data, headers={
            "X-Goog-Upload-Command": "upload, finalize", "X-Goog-Upload-Offset": "0"})
        f = json.load(urllib.request.urlopen(put, timeout=600))["file"]
        import time
        for _ in range(120):
            if f.get("state") == "ACTIVE":
                break
            time.sleep(2)
            f = json.load(urllib.request.urlopen(urllib.request.Request(base + "/v1beta/" + f["name"], headers=hdr),
                                                 timeout=30))
        part = {"file_data": {"mime_type": mime, "file_uri": f["uri"]}}
    if fps:
        part["video_metadata"] = {"fps": fps}
    body = {"contents": [{"parts": [part, {"text": ask}]}],
            "system_instruction": {"parts": [{"text": prompt or DESCRIBE_PROMPT}]},
            "generationConfig": {"response_mime_type": "application/json", "response_schema": schema or DESCRIBE_SCHEMA,
                                 "temperature": 0.2}}
    req = urllib.request.Request(base + "/v1beta/models/%s:generateContent" % (model or DESCRIBE_MODEL), method="POST",
                                 data=json.dumps(body).encode(), headers=dict(hdr, **{"Content-Type": "application/json"}))
    try:
        out = json.load(urllib.request.urlopen(req, timeout=600))
    except urllib.error.HTTPError as e:
        raise ValueError("Gemini said %s: %s" % (e.code, e.read().decode(errors="replace")[:300]))
    if usage is not None:
        usage.update(out.get("usageMetadata") or {})
    text = "".join(p.get("text", "") for p in out["candidates"][0]["content"]["parts"] if not p.get("thought"))
    return json.loads(text)


def describe_video(src, prompt=None, schema=None, ask="Describe this clip.", fps=5, model=None):
    """Gemini's JSON answer about one video: its description (DESCRIBE_SCHEMA) unless told otherwise."""
    import tempfile
    if os.environ.get("TAKES_DESCRIBE_CMD"):  # tests: a stand-in that prints the JSON answer
        r = subprocess.run(json.loads(os.environ["TAKES_DESCRIBE_CMD"]) + [src], capture_output=True, text=True)
        if r.returncode != 0:
            raise ValueError(r.stderr.strip() or "The description failed.")
        return json.loads(r.stdout)
    key = gemini_key()
    if not key:
        raise ValueError("No Gemini key. Add one in Takes › Settings › Gemini.")
    ffmpeg = find_tool("ffmpeg")
    if not ffmpeg:
        raise ValueError("ffmpeg is not installed. Open Takes and click Finish setup, or run brew install ffmpeg.")
    tmp = tempfile.mkdtemp(prefix="takes-describe-")
    try:
        # A small copy: Gemini looks at about 1 frame a second, so 480 px and a low bitrate lose nothing.
        proxy = os.path.join(tmp, "proxy.mp4")
        subprocess.run([ffmpeg, "-v", "error", "-y", "-i", src, "-t", "1200",
                        "-vf", "scale='if(gt(iw,ih),-2,480)':'if(gt(iw,ih),480,-2)',fps=%d" % fps,
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "32",
                        "-c:a", "aac", "-ac", "1", "-b:a", "48k", "-movflags", "+faststart", proxy],
                       check=True, capture_output=True, timeout=1800)
        return gemini_call(proxy, "video/mp4", key, prompt, schema, ask, model)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def broll_text(info):
    """The description tag: the summary, then where it fits and the best ranges."""
    out = [info.get("summary", "").strip()]
    if info.get("best_uses"):
        out.append("Use for: " + "; ".join(info["best_uses"]) + ".")
    if info.get("best_moments"):
        out.append("Best: " + "; ".join("%.1f-%.1f s %s" % (m["start"], m["end"], m.get("why", ""))
                                        for m in info["best_moments"]) + ".")
    return " ".join(x for x in out if x)


def tag_broll(path, title, description, keywords):
    """Writes the tags into the clip (stream copy into a new file, then swap). Returns the file."""
    ffmpeg = find_tool("ffmpeg")
    if not ffmpeg:
        raise ValueError("ffmpeg is not installed. Open Takes and click Finish setup, or run brew install ffmpeg.")
    d, f = os.path.split(path)
    tmp = os.path.join(d, ".tagging-" + f)  # hidden: list_broll and the tab skip it
    subprocess.run([ffmpeg, "-v", "error", "-y", "-i", path, "-map", "0", "-c", "copy",
                    "-movflags", "use_metadata_tags", "-metadata", "title=" + title,
                    "-metadata", "description=" + description, "-metadata", "keywords=" + keywords, tmp],
                   check=True, capture_output=True, timeout=600)
    os.replace(tmp, path)
    return path


def broll_describe(path, rename=False):
    """Describes a library clip and writes the tags into it; with rename, the short name becomes its file name."""
    os.environ["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
    info = describe_video(path)
    name = short_name(info.get("name", ""))
    stem = os.path.splitext(os.path.basename(path))[0]
    m = re.match(r"^(\d{4}-\d{2}) (.*?)(?: \((V|H)\))?$", stem)
    title = name if rename and name else (m.group(2) if m else stem)
    tag_broll(path, title, broll_text(info), ", ".join(info.get("tags", [])))
    if rename and name and m:
        w, h = video_size(path)
        new = free_broll(os.path.dirname(path), m.group(1), name, w, h, os.path.splitext(path)[1])
        os.rename(path, new)
        return new
    return path


# ---------- The best cut of a storyboard take (same file as Sources/Takes/Storyboard.swift reads) ----------
# A take recorded for a storyboard shot: Gemini watches it next to the shot's lines and picks where
# the clean delivery starts and ends. <session>/cuts.json, keyed by take number (file names change):
#   {"3": {"state": "done", "start": 2.4, "end": 9.8, "clean": true, "why": "...", "shot": "s2", "by": "gemini"}}
# Gemini's pick is only a first suggestion: the editing agent checks it and changes it with
# set_best_cut ("by": "agent"; Gemini's range stays under "gemini").

CUT_PROMPT = """You pick the best cut of one video take for an editor. The person records short talking videos. In this take the person tries to say the given lines, often more than once, with false starts, pauses and retakes. Find the single best full delivery of the lines: clear, confident, no stumble, every word there. Give its start and end in seconds from the start of the video, tight: start just before the first word, end just after the last word (keep a natural breath, about 0.2 s). If no delivery has every word, pick the best one and set clean to false. If the shot has no lines (b-roll), pick the steadiest, best-looking stretch of about the given length."""

CUT_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "start": {"type": "NUMBER"}, "end": {"type": "NUMBER"},
        "clean": {"type": "BOOLEAN", "description": "Every word of the lines is there, without a stumble."},
        "why": {"type": "STRING", "description": "One short sentence: why this one, and what was wrong with others."},
        "said": {"type": "STRING", "description": "What the person says in the picked range, word for word."},
        "attempts": {"type": "INTEGER", "description": "How many times the person started the lines."},
    },
    "required": ["start", "end", "clean", "why"],
}


def cuts_path(s):
    return os.path.join(s, "cuts.json")


def read_cuts(s):
    try:
        d = json.load(open(cuts_path(s)))
    except (OSError, ValueError):
        return {}
    for e in d.values():
        if e.get("state") == "running" and not alive(e.get("pid")):
            e.update(state="failed", error="The cut stopped before it finished.")
    return d


def write_cut(s, n, **kw):
    d = read_cuts(s)
    e = d.setdefault(str(n), {})
    e.update(kw)
    for k in [k for k, v in kw.items() if v is None]:
        e.pop(k, None)
    with open(cuts_path(s) + ".tmp", "w") as f:
        json.dump(d, f, indent=2, sort_keys=True, ensure_ascii=False)
    os.replace(cuts_path(s) + ".tmp", cuts_path(s))


CUT_MODEL = "gemini-4-argon"  # since 2026-10-13: sharper on timing than Flash; about 1-2 cents a take
TRANSCRIPT_WAIT = 90  # s: a take just recorded gets its transcript from the app in the background


def norm_words(text):
    return [w for w in re.sub(r"[^a-z0-9' ]+", " ", (text or "").lower().replace("’", "'")).split() if w]


def transcript_cut(words, say, secs, dur):
    """The best delivery of the lines from the take's transcript alone (no key needed): every place he
    starts the lines is an attempt; the one that says the most of them with the fewest extra words wins,
    the later one on a tie (his last try is usually his best). words: [(start, end, word)]. Returns the
    best_cut fields, or None when the transcript has none of the lines."""
    want = norm_words(say)
    if not want:
        # A b-roll shot: no words to find. The middle stretch of the asked length, away from the
        # start and stop of the recording.
        secs = min(float(secs or 4), dur)
        start = max(0.0, (dur - secs) / 2)
        return {"start": round(start, 2), "end": round(start + secs, 2), "clean": True,
                "why": "No lines: the middle %.1f s of the take." % secs}
    import difflib
    got = [(a, b, w) for a, b, x in words for w in norm_words(x)]
    toks = [w for _, _, w in got]
    span = int(len(want) * 1.6) + 4
    best = None
    for i, w in enumerate(toks):
        if w not in want[:3]:
            continue
        m = difflib.SequenceMatcher(None, want, toks[i:i + span], autojunk=False)
        blocks = [b for b in m.get_matching_blocks() if b.size]
        if not blocks or blocks[0].b != 0:
            continue
        hit = sum(b.size for b in blocks)
        last = i + blocks[-1].b + blocks[-1].size - 1
        extra = (last - i + 1) - hit  # repeats, stumbles and ums inside the attempt
        score = hit / len(want) - 0.03 * extra
        if best is None or score >= best[0] - 0.001:
            best = (score, i, last, hit, extra)
    if best is None:
        return None
    _, i, last, hit, extra = best
    tries = sum(1 for k, w in enumerate(toks) if w == want[0] and (k == 0 or toks[k - 1] != w))
    clean = hit == len(want) and extra == 0
    start, end = snap_cut(words, got[i][0], got[last][1], dur)
    why = "From the transcript: %d of %d words%s, attempt %d of %d." % (
        hit, len(want), "" if not extra else ", %d extra" % extra,
        1 + sum(1 for k in range(i) if toks[k] == want[0] and (k == 0 or toks[k - 1] != toks[k])), max(tries, 1))
    return {"start": round(start, 2), "end": round(end, 2), "clean": clean, "why": why,
            "said": " ".join(x for a, b, x in words if a >= got[i][0] - 0.01 and b <= got[last][1] + 0.01),
            "attempts": tries or None}


def snap_cut(words, start, end, dur):
    """Moves a cut's edges onto the transcript's word times: 0.08 s before the first word in the range,
    0.2 s after the last, never into the word next to it. Gemini sees about one frame a second, so its
    edges often fell inside a word (2026-10-13 test: most picks of Flash and Argon). words: [(start, end, word)]."""
    inside = [i for i, (a, b, _) in enumerate(words) if start <= (a + b) / 2 <= end]
    if not inside:
        return start, end
    i, j = inside[0], inside[-1]
    lo = words[i - 1][1] + 0.02 if i > 0 else 0.0
    hi = words[j + 1][0] - 0.02 if j + 1 < len(words) else dur
    new_start = max(0.0, min(words[i][0], max(lo, words[i][0] - 0.08)))
    new_end = min(dur, max(words[j][1], min(hi, words[j][1] + 0.2)))
    return round(new_start, 2), round(new_end, 2)


def take_cut(s, n):
    """Picks the best cut of take n against its storyboard shot's lines. Runs detached. Gemini (CUT_MODEL)
    watches the take when there is a key; without one, or when Gemini fails, the take's transcript picks
    it, so a user without a key still gets a first cut (2026-10-13: "don't run them into walls")."""
    os.environ["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
    t = voice_take(s, n)
    shot = next((x for x in read_storyboard(s)["shots"] if x.get("id") == t.get("shot")), None)
    write_cut(s, n, state="running", pid=os.getpid(), shot=t.get("shot"), error=None)
    try:
        src = os.path.join(s, t["file"])
        say = (shot or {}).get("say", "").strip()
        secs = (shot or {}).get("seconds") or (round(len(say.split()) / 2.6, 1) if say else 4)
        dur = media_duration(src)
        gemini_error = None
        if gemini_key() or os.environ.get("TAKES_DESCRIBE_CMD"):
            ask = ("The lines:\n%s\n\nAbout %s s when said well." % (say, secs)) if say else \
                  ("No lines: a b-roll shot. %s. About %s s." % ((shot or {}).get("how") or "", secs))
            try:
                out = describe_video(src, CUT_PROMPT, CUT_SCHEMA, ask, fps=10, model=CUT_MODEL)
                d = float(dur or out["end"])
                start, end = max(0.0, float(out["start"])), min(d, float(out["end"]))
                if end <= start:
                    raise ValueError("Gemini gave no usable range.")
                if say:
                    start, end = snap_cut(transcript_words(src) or [], start, end, d)
                write_cut(s, n, state="done", start=round(start, 2), end=round(end, 2), clean=bool(out.get("clean")),
                          why=out.get("why"), said=out.get("said"), attempts=out.get("attempts"),
                          model=CUT_MODEL, at=now_iso(), pid=None, by="gemini", gemini=None)
                return
            except Exception as e:
                gemini_error = str(e)[:200]
        # No key, or Gemini failed: the transcript. The app writes it in the background after a take,
        # so a take recorded in the last few minutes is worth a wait.
        fresh = time.time() - os.path.getmtime(src) < 300
        wait = time.time() + (TRANSCRIPT_WAIT if say and fresh else 0)
        words = transcript_words(src) if say else []
        while say and words is None and time.time() < wait:
            time.sleep(3)
            words = transcript_words(src)
        if say and not words:
            raise ValueError((gemini_error + ". " if gemini_error else "No Gemini key, and ") +
                             "the take has no transcript yet. Try Find the Best Cut again in a minute.")
        out = transcript_cut(words or [], say, secs, float(dur or (words[-1][1] if words else secs)))
        if out is None:
            raise ValueError("The take's transcript has none of the shot's lines.")
        if gemini_error:
            out["why"] += " Gemini failed: %s" % gemini_error
        write_cut(s, n, state="done", at=now_iso(), pid=None, by="transcript", gemini=None, model=None,
                  said=out.pop("said", None), attempts=out.pop("attempts", None), **out)
    except Exception as e:
        msg = str(e)
        if isinstance(e, subprocess.CalledProcessError) and e.stderr:
            msg = e.stderr.decode(errors="replace").strip().splitlines()[-1]
        write_cut(s, n, state="failed", error=msg[:400], pid=None)


def t_set_best_cut(a):
    s = resolve_session(a["session"])
    n = int(a["take"])
    t = voice_take(s, n)
    start, end = float(a["start"]), float(a["end"])
    dur = media_duration(os.path.join(s, t["file"])) or t.get("duration") or end
    start, end = max(0.0, start), min(float(dur), end)
    if end <= start:
        raise ValueError("end must come after start, inside the take (%.1f s long)." % dur)
    old = read_cuts(s).get(str(n)) or {}
    first = old.get("gemini") or ({k: old.get(k) for k in ("start", "end", "clean", "why")}
                                  if old.get("by", "gemini") in ("gemini", "transcript") and old.get("state") == "done" else None)
    write_cut(s, n, state="done", start=round(start, 2), end=round(end, 2), why=a["why"].strip(),
              clean=a.get("clean", True), said=a.get("said"), attempts=None, by="agent", gemini=first,
              shot=t.get("shot") or old.get("shot"), at=now_iso(), error=None, pid=None)
    return {"take": n, "best_cut": read_cuts(s)[str(n)]}


# ---------- edit-ready takes (2026-10-11) ----------
# A take is ready to edit when Takes saves it: prepare_take finds its words with faster-whisper (free,
# on the Mac, mcp/prepare_take.py through uv) and writes them on the video clock next to the take:
#
#   take-03-camera.words.json  {"v": 2, "clock": "video", "source": "faster-whisper small", "language",
#                               "audio_offset_s", "fps", "fps_mode", "duration", "prepared",
#                               "words": [{word, start, end, filler?}], "sounds": [[start, end]],
#                               "before": <the file that was there: Apple's words>}
#
# The app starts it when it saves a take (--prepare), import_take after an import, and cut_take and
# rough_cut before they cut. One Whisper at a time on the Mac (<root>/.prepare.lock), and none while a
# take records (<root>/.recording, written by the app).
#
# cut_take renders segments [{take, in, out, kind?}] (seconds of the take, video clock) into one clip
# at a constant frame rate with the voice in sync. rough_cut finds the segments: each script line once
# (the last full try), without false starts, stutters, ums and long pauses. Both write to the session's
# _work/ folder (hidden on the Assets tab), the newest 5 versions per name:
#   _work/<name>-vN.mp4         video + voice
#   _work/<name>-vN.wav         the voice alone, 48 kHz 24-bit, same timing
#   _work/<name>-vN.words.json  words in clip time, plus made_from: {session_id, cut: [{take, kind, in, out, at}]}
#   _work/<name>-vN.json        {cut, moved, notes, length_s, fps, takes, voice_source} (+ dropped, missing, gap)
# "cuts" (cuts.json, set_best_cut) keeps its own meaning: the best range of a take.

PREP_MODEL = "small"
PREP_LOCK = ".prepare.lock"
PREP_OFFLINE = ".prepare-offline"
PREP_OFFLINE_S = 3600
PREP_WAIT_S = 2
RECORDING = ".recording"
# Korean ums too (2026-10-18). Not 그 or 저: they are also words ("that", "I").
FILLERS = {"um", "uh", "uhm", "umm", "uhh", "erm", "er", "ah", "hmm", "mm", "mhm",
           "음", "음음", "으음", "으", "어", "어어", "아", "흠"}
WORK_DIR = "_work"
WORK_KEEP = 5
CUT_MAX = 200
CUT_WAIT = 25
DOWNLOAD_ERROR = ("Takes could not download the speech model. Connect to the internet. "
                  "Takes tries again at the next cut.")
MODEL_LABEL = "Getting the speech model (one time, about 500 MB)"
ENCODERS = {}


class PrepareError(ValueError):
    pass


def prep_model():
    return os.environ.get("TAKES_PREP_MODEL") or PREP_MODEL


def prep_script():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "prepare_take.py")


def model_cached(model=None):
    """The Hugging Face cache has the model (faster-whisper downloads it there on its first run)."""
    hub = os.environ.get("HF_HUB_CACHE") or os.path.join(
        os.environ.get("HF_HOME") or os.path.expanduser("~/.cache/huggingface"), "hub")
    pattern = os.path.join(glob.escape(hub), "models--Systran--faster-whisper-" + (model or prep_model()),
                           "snapshots", "*", "model.bin")
    return bool(glob.glob(pattern))


def is_ready(doc, clock=None):
    """A prepared words file (video clock). With clock: also made from this file (same length)."""
    if not isinstance(doc, dict) or doc.get("clock") != "video" or not isinstance(doc.get("words"), list):
        return False
    d, c = doc.get("duration"), (clock or {}).get("duration")
    return clock is None or d is None or c is None or abs(float(d) - float(c)) <= 0.05


def voice_file(s, t):
    return os.path.join(s, t["file"])


def prepare_jobs(s):
    """[(job, take numbers)] of the session's prepare jobs, oldest first."""
    out = []
    for j in all_jobs(s):
        try:
            argv = shlex.split(j.get("cmd") or "")
        except ValueError:
            continue
        if "--prepare-run" in argv:
            nums = set()
            for x in argv[argv.index("--prepare-run") + 2:]:
                if x.isdigit():
                    nums.add(int(x))
            out.append((j, nums))
    return out


def prepare_state(s, n, jobs=None):
    """'ready', 'running', ('failed', reason) or 'missing'."""
    if is_ready(words_doc(voice_file(s, voice_take(s, n)))):
        return "ready"
    mine = [j for j, nums in (prepare_jobs(s) if jobs is None else jobs) if int(n) in nums]
    if any(j["status"] in ("starting", "running") for j in mine):
        return "running"
    if mine and mine[-1]["status"] in ("failed", "lost"):
        return ("failed", mine[-1].get("error") or "It stopped before it finished.")
    return "missing"


def script_hints(s):
    """Names and long words of the script, so Whisper spells them (same rule as VoiceFollow.hints)."""
    seen, out, p = set(), [], os.path.join(s, "script.md")
    for w in re.findall(r"[^\W_][\w'’-]*", read_text(p) if os.path.exists(p) else ""):
        if (len(w) >= 7 or (w[0].isupper() and len(w) >= 3)) and w.lower() not in seen:
            seen.add(w.lower())
            out.append(w)
    return out[:30]


def say(line):
    print(line, flush=True)


def stop_now(*_):
    """SIGTERM (stop_job) on a prepare or cut job: exit through the finally blocks, which remove its
    scratch files. A SIGKILL skips them: sweep_work removes those at the next cut."""
    sys.exit(143)


def wait_for_recording(lib):
    """While the app records a take, Whisper waits: its load could drop frames."""
    told = False
    while True:
        try:
            with open(os.path.join(lib, RECORDING)) as f:
                pid = int(f.read().strip() or 0)
        except (OSError, ValueError):
            return
        if not pid or not alive(pid):
            return  # a marker of an app that is gone
        if not told:
            say("Waits for the recording to end.")
            told = True
        time.sleep(PREP_WAIT_S)


def prepare_take(s, n, kind=None):
    """Find the words of take n (its camera file, or kind's) and write them on the video clock.
    Idempotent: a ready take is left as it is. Returns 'ready' or 'done'; raises PrepareError."""
    import fcntl
    voice_take(s, n, kind)
    lib = lib_root(s)
    here = os.path.basename(os.path.abspath(s))
    fd = os.open(os.path.join(lib, PREP_LOCK), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            other = os.pread(fd, 512, 0).decode(errors="replace").strip().split(" ", 1)
            where = " of %s" % other[1] if len(other) > 1 and other[1] != here else ""
            say("Waits for take %s%s." % (other[0], where) if other[0] else "Waits for another take.")
            fcntl.flock(fd, fcntl.LOCK_EX)
        os.ftruncate(fd, 0)
        os.pwrite(fd, ("%d %s" % (int(n), here)).encode(), 0)
        # After the lock: a take may have started to record while this one waited.
        wait_for_recording(lib)
        return prepare_locked(s, int(n), kind)
    finally:
        os.close(fd)


def run_lines(cmd):
    """Run cmd, print what it prints (the Jobs row reads it). (exit code, last plain line, a
    TAKES_PROGRESS line came: the script itself ran, not only uv before it)."""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True,
                         errors="replace")
    last, started = None, False
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        x = line.strip()
        if x.startswith("TAKES_PROGRESS"):
            started = True
        elif x:
            last = x
    return p.wait(), last, started


def prep_offline(s):
    """No speech model and no download: the app's saved takes stay quiet for an hour."""
    with open(os.path.join(lib_root(s), PREP_OFFLINE), "w") as f:
        f.write(now_iso())
    return PrepareError(DOWNLOAD_ERROR)


def prepare_locked(s, n, kind):
    t = voice_take(s, n, kind)
    src = voice_file(s, t)
    name = os.path.splitext(t["file"])[0] + ".words.json"
    if not os.path.exists(src):
        raise PrepareError("Take %d has no file %s. Takes cannot find words in it." % (n, t["file"]))
    clock = take_clock(src)
    doc = words_doc(src)
    if doc is None:
        raise PrepareError("Takes cannot read %s. Takes did not change it. Move it out of the session folder, "
                           "then try again: Takes finds the words again." % name)
    if is_ready(doc, clock):
        return "ready"
    if not clock or clock.get("audio_offset_s") is None:
        raise PrepareError("Take %d has no sound. Takes cannot find words in it." % n)
    before = doc.get("before") if doc.get("v") == 2 else (doc or None)
    m = re.match(r"apple ([a-z]{2})", str((doc if doc.get("v") != 2 else (before or {})).get("source") or ""))
    lang = m.group(1) if m else None
    hints = script_hints(s)
    with tempfile.TemporaryDirectory() as tmp:
        wav, out = os.path.join(tmp, "voice.wav"), os.path.join(tmp, "words.json")
        extract_voice(src, wav, rate=16000, codec="pcm_s16le")
        args = [wav, out] + (["--language", lang] if lang else []) + (["--hints", ",".join(hints)] if hints else []) \
            + ["--model", prep_model()]
        if os.environ.get("TAKES_PREP_CMD"):  # tests: a stand-in for the script
            cmd = json.loads(os.environ["TAKES_PREP_CMD"]) + args
        else:
            cmd = ["/usr/sbin/taskpolicy", "-c", "utility"] if os.path.exists("/usr/sbin/taskpolicy") else []
            try:
                uv = ensure_uv()
            except ValueError as e:
                say(str(e))
                raise prep_offline(s)
            cmd += [uv, "run", "-q", "--python", "3.11", "--with", "faster-whisper", "--with", "numpy",
                    prep_script()] + args
        code, last, started = run_lines(cmd)
        if code != 0:
            # uv stops before the script when it cannot get the packages (offline, a proxy): the same fix.
            if code == 3 or last == DOWNLOAD_ERROR or not started:
                raise prep_offline(s)
            raise PrepareError(last or "Takes could not find the words in take %d." % n)
        with open(out) as f:
            res = json.load(f)
    words = []
    for w in res.get("words") or []:
        text = str(w.get("word") or "").strip()
        if not text:
            continue
        e = {"word": text, "start": round(float(w["start"]), 3), "end": round(float(w["end"]), 3)}
        if norm_word(text) in FILLERS:
            e["filler"] = True
        words.append(e)
    new = {"v": 2, "clock": "video", "source": "faster-whisper " + prep_model(), "language": res.get("language"),
           "audio_offset_s": clock["audio_offset_s"], "fps": clock["fps"], "fps_mode": clock["fps_mode"],
           "duration": clock["duration"], "prepared": now_iso(), "onsets": 1, "words": words,
           "sounds": [[round(float(a), 3), round(float(b), 3)] for a, b in res.get("sounds") or []]}
    # Apple's Transcripts may have written its words while Whisper ran: they go under before too.
    now = words_doc(src)
    if isinstance(now, dict) and now.get("v") != 2 and now.get("words") and now != doc:
        before = now
    if before:
        new["before"] = before
    # Renamed while Whisper ran: the words go next to the take's new name.
    try:
        t = voice_take(s, n, kind)
    except ValueError:
        return "done"  # trashed meanwhile
    path = os.path.join(s, os.path.splitext(t["file"])[0] + ".words.json")
    with open(path + ".tmp", "w") as f:
        json.dump(new, f, indent=1, ensure_ascii=False)
    os.replace(path + ".tmp", path)
    try:
        os.remove(os.path.join(lib_root(s), PREP_OFFLINE))
    except OSError:
        pass
    return "done"


PREP_MOD = []


def prep_mod():
    """prepare_take.py as a module, for its onsets() pass (it needs no numpy)."""
    if not PREP_MOD:
        import importlib.util
        spec = importlib.util.spec_from_file_location("prepare_take", prep_script())
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        PREP_MOD.append(m)
    return PREP_MOD[0]


def wav_voiced(path, hop_s, over_db):
    """prepare_take.voiced_frames without numpy: a 16-bit mono WAV, 10 ms loudness frames, a frame
    over_db above the 20th percentile is voiced."""
    with wave.open(path, "rb") as f:
        sr, width, ch, raw = f.getframerate(), f.getsampwidth(), f.getnchannels(), f.readframes(f.getnframes())
    if width != 2 or ch != 1:
        raise ValueError("needs a 16-bit mono WAV")
    x = array.array("h")
    x.frombytes(raw[:len(raw) // 2 * 2])
    if sys.byteorder == "big":
        x.byteswap()
    hop = max(1, int(sr * hop_s))
    db = []
    for i in range(0, len(x) // hop * hop, hop):
        seg = x[i:i + hop]
        db.append(20 * math.log10(math.sqrt(sum(v * v for v in seg) / hop) / 32768.0 + 1e-9))
    if not db:
        return []
    q = sorted(db)
    pos = 0.2 * (len(q) - 1)  # numpy's linear percentile
    lo = int(pos)
    floor = q[lo] + (q[min(lo + 1, len(q) - 1)] - q[lo]) * (pos - lo)
    return [d > floor + over_db for d in db]


def ensure_onsets(s, t):
    """A words file prepared before 2026-10-11 has first words after a pause 0.2 to 1 s early. The first
    time Takes reads it for a cut, it runs only prepare_take's onsets() pass (no Whisper) on the take's
    voice and marks the file "onsets": 1. No voice, or any failure: the file stays as it is."""
    src = voice_file(s, t)
    doc = words_doc(src)
    if not is_ready(doc) or doc.get("onsets") or not os.path.exists(src):
        return doc
    c = take_clock(src)
    if not c or c.get("audio_offset_s") is None:
        return doc
    try:
        m = prep_mod()
        with tempfile.TemporaryDirectory() as tmp:
            wav = os.path.join(tmp, "voice.wav")
            extract_voice(src, wav, rate=16000, codec="pcm_s16le")
            voiced = wav_voiced(wav, m.HOP, m.VOICED_DB)
        words = m.onsets([dict(w) for w in doc["words"]], voiced)
        for w in words:
            w["start"] = round(float(w["start"]), 3)
        new = dict(doc, words=words, onsets=1)
        path = os.path.splitext(src)[0] + ".words.json"
        if words_doc(src) != doc:
            return words_doc(src)  # changed while this ran: leave it
        with open(path + ".tmp", "w") as f:
            json.dump(new, f, indent=1, ensure_ascii=False)
        os.replace(path + ".tmp", path)
        return new
    except Exception:  # an old words file never fails the cut
        return doc


def start_prepare(s, numbers):
    """One job that prepares these takes, one after the other."""
    meta = read_meta(s)
    numbers = sorted({int(n) for n in numbers})
    cmd = "%s %s --prepare-run . %s" % (shlex.quote(sys.executable), shlex.quote(os.path.abspath(__file__)),
                                        " ".join(str(n) for n in numbers))
    cached = model_cached()
    if not cached:
        label = MODEL_LABEL
    elif len(numbers) == 1:
        label = "Finding words in take %d" % numbers[0]
    else:
        label = "Finding words in takes " + ", ".join(str(n) for n in numbers)
        if len(label) > 60:
            label = "Finding words in %d takes" % len(numbers)
    secs = sum(next((t.get("duration") or 60 for t in meta.get("takes", []) if t["number"] == n), 60) for n in numbers)
    return start_job(s, cmd, [], label, estimate_s=int(max(5, secs / 6) + (0 if cached else 120)))


def app_prepare(session, n):
    """`--prepare <session> <take>`: the app saved a take. Starts a job and returns at once. An offline
    Mac without the model gets one failed row, then quiet for an hour (the next cut tries again)."""
    s = resolve_session(session)
    if not model_cached():
        try:
            if time.time() - os.path.getmtime(os.path.join(lib_root(s), PREP_OFFLINE)) < PREP_OFFLINE_S:
                return None
        except OSError:
            pass
    if prepare_state(s, n) in ("ready", "running"):
        return None
    return start_prepare(s, [n])


def prepare_run(numbers):
    """`--prepare-run . <take>...`: the prepare job's command, in the session folder."""
    failed = None
    for n in numbers:
        try:
            prepare_take(".", int(n))
        except ValueError as e:
            failed = str(e)
            say(failed)
        except Exception as e:  # the runner never ends on a traceback: the Jobs row shows the last line
            failed = "Takes could not find the words in take %s: %s" % (n, e)
            say(failed)
    if failed:
        say(failed)
        sys.exit(1)


# Cuts

def frames(sec, fps):
    return int(round(sec * fps))


def snap_point(words, x, edge):
    """A cut point inside a word moves to the nearer edge of that word, never into a neighbour word.
    (new x, the word) or (x, None)."""
    for k, w in enumerate(words):
        if w["start"] < x < w["end"]:
            prev_end = words[k - 1]["end"] if k else 0.0
            next_start = words[k + 1]["start"] if k + 1 < len(words) else float("inf")
            # A tie keeps the word: in goes to its start, out to its end.
            near_start = (x - w["start"] <= w["end"] - x + 1e-6) if edge == "in" else (x - w["start"] < w["end"] - x - 1e-6)
            if edge == "in":
                y = max(w["start"] - 0.04, prev_end) if near_start else min(w["end"] + 0.02, next_start)
            else:
                y = max(w["start"] - 0.02, prev_end) if near_start else min(w["end"] + 0.06, next_start)
            return y, w["word"]
    return x, None


def check_segments(s, segs):
    """The segments as cut_take takes them, or an error that names the fix."""
    shape = 'e.g. [{"take": 3, "in": 1.2, "out": 6.8}], seconds of the take'
    if not isinstance(segs, list) or not segs:
        raise ValueError("Give segments: the parts to keep, in order, %s." % shape)
    if len(segs) > CUT_MAX:
        raise ValueError("At most %d segments in one cut. Cut it in parts, or keep longer pauses." % CUT_MAX)
    out = []
    for i, g in enumerate(segs, 1):
        if not isinstance(g, dict) or "in" not in g or "out" not in g or "take" not in g:
            raise ValueError("Segment %d needs take, in and out, %s." % (i, shape))
        try:
            n = int(g["take"])
        except (TypeError, ValueError):
            raise ValueError("Segment %d: take is a take number, e.g. 3. get_session lists the takes." % i)
        try:
            t = voice_take(s, n, g.get("kind"))
        except (TypeError, ValueError) as e:
            raise ValueError("Segment %d: %s get_session lists the takes." % (i, e))
        src = os.path.join(s, t["file"])
        c = take_clock(src) if os.path.exists(src) else None
        if not c:
            raise ValueError("Segment %d: take %d has no video file Takes can read (%s)." % (i, t["number"], t["file"]))
        dur = c.get("duration") or t.get("duration") or 0
        try:
            a, b = float(g["in"]), float(g["out"])
        except (TypeError, ValueError):
            raise ValueError("Segment %d: in and out are seconds, e.g. 1.24." % i)
        if not (0 <= a < b <= dur + 0.001):
            raise ValueError("Segment %d: take %d is %.3f s long. Give 0 <= in < out <= %.3f." % (i, t["number"], dur, dur))
        if frames(b - a, c["fps"]) < 2:
            raise ValueError("Segment %d is shorter than 2 frames. Make it longer or leave it out." % i)
        g = dict(g)
        g.update({"take": t["number"], "kind": t["kind"], "in": a, "out": min(b, dur)})
        out.append(g)
    return out


def takes_label(verb, nums):
    nums = list(dict.fromkeys(nums))
    label = "%s take %d" % (verb, nums[0]) if len(nums) == 1 else "%s takes %s" % (verb, ", ".join(map(str, nums)))
    return label if len(label) <= 60 else "%s %d takes" % (verb, len(nums))


def work_files(name, n):
    return [os.path.join(WORK_DIR, "%s-v%d%s" % (name, n, ext)) for ext in (".mp4", ".wav", ".words.json", ".json")]


def prune_work(s, name, newest):
    """Keep the newest WORK_KEEP versions of a name in _work/; older ones go to the Trash."""
    d = os.path.join(s, WORK_DIR)
    busy = {os.path.normpath(o) for o in claimed_outputs(s)}
    have = sorted(set(versions_in(d, name)) | {newest})
    old = []
    for v in have[:-WORK_KEEP]:
        files = [f for f in os.listdir(d) if f.startswith("%s-v%d." % (name, v))]
        if any(os.path.normpath(os.path.join(WORK_DIR, f)) in busy for f in files):
            continue
        old += [os.path.join(d, f) for f in files]
    if old:
        try:
            trash(old)
        except (OSError, subprocess.CalledProcessError):
            pass  # a full Trash never fails the cut


def sweep_work(s):
    """Leftovers of a cut that was stopped or killed: its hidden parts (.<name>-vN.cut/, .part.mp4,
    .part.wav) and its claim (<name>-vN.request.json, with any output but the .json). A running
    cut's files stay; a claim stays for a minute (its job may not be on the list yet)."""
    d = os.path.join(s, WORK_DIR)
    busy = {os.path.normpath(o) for o in claimed_outputs(s)}
    try:
        names = os.listdir(d)
    except OSError:
        return
    for f in names:
        m = re.match(r"^\.(.+-v\d+)\.(cut|part\.mp4|part\.wav)$", f) or re.match(r"^(.+-v\d+)\.request\.json$", f)
        if not m or os.path.join(WORK_DIR, m.group(1) + ".mp4") in busy:
            continue
        p, stem = os.path.join(d, f), os.path.join(d, m.group(1))
        try:
            if f.startswith("."):
                shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
            elif time.time() - os.path.getmtime(p) > 60:
                for x in [p] + ([stem + ext for ext in (".mp4", ".wav", ".words.json")]
                                if not os.path.exists(stem + ".json") else []):
                    if os.path.exists(x):
                        os.remove(x)
        except OSError:
            pass


def start_cut(s, segs, name, extra=None):
    """Claim the next version of _work/<name> and start the cut job. (job, version)."""
    d = os.path.join(s, WORK_DIR)
    os.makedirs(d, exist_ok=True)
    sweep_work(s)
    n = (versions_in(d, name) or [0])[-1] + 1
    length = sum(frames(g["out"] - g["in"], 30) / 30 for g in segs)
    big = any(min((take_clock(os.path.join(s, voice_take(s, g["take"], g["kind"])["file"])) or {}).get(k) or 0
                  for k in ("width", "height")) > 1080 for g in segs[:1])
    label = takes_label("Cutting", [g["take"] for g in segs])
    for _ in range(100):
        busy = claimed_outputs(s)
        rels = work_files(name, n)
        req = os.path.join(WORK_DIR, "%s-v%d.request.json" % (name, n))
        if any(os.path.lexists(os.path.join(s, r)) or os.path.normpath(r) in busy for r in rels):
            n += 1
            continue
        try:  # the request file claims the version: a second caller at the same moment takes the next one
            fd = os.open(os.path.join(s, req), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            n += 1
            continue
        with os.fdopen(fd, "w") as f:
            json.dump({"name": name, "version": n, "segments": segs, "extra": extra or {}}, f, ensure_ascii=False)
        cmd = "%s %s --cut-run . %s" % (shlex.quote(sys.executable), shlex.quote(os.path.abspath(__file__)),
                                        shlex.quote(req))
        try:
            job = start_job(s, cmd, rels, label, estimate_s=int(5 + length * (1.0 if big else 0.5)))
        except ValueError as e:
            os.remove(os.path.join(s, req))
            if "already writes" in str(e) or "exists" in str(e):
                n += 1
                continue
            raise
        prune_work(s, name, n)
        return job, n
    raise ValueError("Takes could not find a free version in %s/. Try again." % WORK_DIR)


def cut_view(s, rel):
    """What cut_take, rough_cut and get_job say about a finished cut (_work/<name>-vN.json)."""
    with open(os.path.join(s, rel)) as f:
        r = json.load(f)
    stem = os.path.join(s, rel[:-len(".json")])
    out = {"video": stem + ".mp4", "voice": stem + ".wav", "words": stem + ".words.json",
           "length_s": r.get("length_s"), "fps": r.get("fps"), "cut": r.get("cut"), "moved": r.get("moved") or []}
    if r.get("rough"):
        out["dropped"] = r.get("dropped") or []
        out["missing"] = r.get("missing") or []
    out["voice_source"] = r.get("voice_source")
    out["notes"] = r.get("notes") or []
    if r.get("rough"):
        out["next"] = ("Show the user the clip (open_in_app with its path) and tell them, in plain words, what you "
                       "dropped and which lines are missing. It is a first draft: improve it freely "
                       "(edit cut, call cut_take).")
    else:
        out["next"] = "Look at a frame at each cut before you build on it."
    return out


def cut_result(s, job_id, name, n):
    b = t_get_job({"id": job_id, "session": s, "wait_s": CUT_WAIT})
    if b["status"] in ("starting", "running"):
        return {"status": "running", "job": job_id,
                "note": "Takes is still working. get_job with wait_s gives the result."}
    if b["status"] != "done":
        raise ValueError("The cut %s: %s" % (b["status"], b.get("error") or "see get_job id=%s." % job_id))
    return cut_view(b["session"], os.path.join(WORK_DIR, "%s-v%d.json" % (name, n)))


def t_cut_take(a):
    s = job_session(a.get("session"))
    if "segments" not in a and any(k in a for k in ("take", "start", "end", "in", "out")):
        raise ValueError('cut_take takes segments: [{"take": 3, "in": 1.2, "out": 6.8}], seconds of the take.')
    segs = check_segments(s, a.get("segments"))
    nums = list(dict.fromkeys(g["take"] for g in segs))
    name = "take-%02d" % nums[0] if len(nums) == 1 else "cut"
    job, n = start_cut(s, segs, name)
    return cut_result(s, job["id"], name, n)


def has_encoder(name):
    if name not in ENCODERS:
        r = subprocess.run([need_ffmpeg(), "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=30)
        ENCODERS[name] = (" %s " % name) in (r.stdout or "")
    return ENCODERS[name]


def apple_silicon():
    """VideoToolbox takes -q:v (constant quality) and encodes ProRes only on Apple silicon."""
    return sys.platform == "darwin" and platform.machine() == "arm64"


def video_codec(c):
    """A cut's clip. Up to 1080p: VideoToolbox at constant quality on Apple silicon, else libx264;
    above 1080p VideoToolbox (HEVC 10-bit for a 10-bit or HDR source).
    2026-10-13 speed audit, a 40 s 1080p take: libx264 crf16 medium took 87 CPU-s on ~13 cores,
    h264_videotoolbox q72 took 12.8 CPU-s at VMAF 96.8 (x264: 97.3), the file +10%."""
    big = min(c.get("width") or 0, c.get("height") or 0) > 1080
    ten = "10" in (c.get("pix_fmt") or "") or c.get("color_transfer") in ("arib-std-b67", "smpte2084")
    if not big and apple_silicon() and has_encoder("h264_videotoolbox"):
        args = ["-c:v", "h264_videotoolbox", "-q:v", "72", "-pix_fmt", "yuv420p"]
    elif not big and has_encoder("libx264"):
        args = ["-c:v", "libx264", "-crf", "16", "-preset", "medium", "-pix_fmt", "yuv420p"]
    elif not big:
        args = ["-c:v", "h264_videotoolbox", "-b:v", "20M", "-pix_fmt", "yuv420p"]
    elif ten:
        args = ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-tag:v", "hvc1", "-b:v", "40M",
                "-pix_fmt", "p010le"]
    else:
        args = ["-c:v", "h264_videotoolbox", "-b:v", "40M", "-pix_fmt", "yuv420p"]
    for k, flag in (("color_primaries", "-color_primaries"), ("color_transfer", "-color_trc"),
                    ("color_space", "-colorspace")):
        if c.get(k):
            args += [flag, c[k]]
    return args


CUT_BATCH = 8  # segments per video pass: each input holds a decoder (about 70 MB up to 1080p)
# ... above 1080p or 10-bit, each decoder on 4 threads: a 4K HEVC Main10 take, 150 segments, peaked at
# 2.5 GB with 8 and all threads, 1.0 GB with 3 and 4 threads, in the same time (2026-10-11).
CUT_BATCH_BIG = 3


def cut_batch(c):
    big = min(c.get("width") or 0, c.get("height") or 0) > 1080
    return CUT_BATCH_BIG if big or "10" in (c.get("pix_fmt") or "") else CUT_BATCH


def run_ff(cmd, total, lo=0.0, hi=1.0):
    """Run ffmpeg with -progress on stdout; print TAKES_PROGRESS from lo to hi of the whole job."""
    if RUN_LOG is not None:
        RUN_LOG.append([str(x) for x in cmd])
    with tempfile.TemporaryFile("w+") as err:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=err, text=True)
        for line in p.stdout:
            if line.startswith("out_time_us=") and total:
                try:
                    say("TAKES_PROGRESS %.3f" % (lo + (hi - lo) * min(1.0, int(line.split("=")[1]) / 1e6 / total)))
                except ValueError:
                    pass
        if p.wait() != 0:
            err.seek(0)
            raise ValueError("ffmpeg: " + ((err.read().strip().splitlines() or ["failed"])[-1]))


def render_cut(segs, files, clocks, voices, mp4, wav, vargs=None):
    """The clip: one seeked input per segment, each trimmed to whole frames at one fps. The sound goes
    in one pass (from the same input as the picture, so the take's audio offset stays, or from the
    clean voice). The picture goes in passes of a few segments (cut_batch), joined without a new encode: a
    long cut never holds 150 decoders at once. vargs: the parts' codec (render_edit: ProRes, so its one
    picture pass is the only lossy encode)."""
    first = clocks[0]
    fps, W, H = first["fps"], first["width"], first["height"]
    layout = "mono" if all(voices) else "stereo"
    lens = [max(2, frames(g["out"] - g["in"], fps)) / float(fps) for g in segs]
    total = sum(lens)
    base = [need_ffmpeg(), "-nostdin", "-v", "error", "-y", "-progress", "pipe:1", "-nostats"]
    # Relative, like every path of the job: the session folder may get a new name while it runs.
    # .<name>-vN.cut: sweep_work finds it when a stopped job leaves it.
    tmp = mp4[:-len(".part.mp4")] + ".cut" if mp4.endswith(".part.mp4") else mp4 + ".cut"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    try:
        # Sound: every segment in one graph (sound decoders are small).
        args, parts, n_in = [], [], 0
        for k, g in enumerate(segs):
            c, L = clocks[k], lens[k]
            if voices[k]:
                path, late = voices[k]
                ss = g["in"] - late
                pad = max(0.0, -ss)
                args += ["-ss", "%.3f" % max(0.0, ss), "-t", "%.3f" % (L + 0.3), "-i", path]
                a = "[%d:a]" % n_in + ("adelay=%d:all=1," % round(pad * 1000) if pad > 0.0005 else "")
                n_in += 1
            elif c.get("audio_offset_s") is not None:
                args += ["-ss", "%.3f" % g["in"], "-t", "%.3f" % (L + 0.3), "-i", files[k]]
                a = "[%d:a]%s," % (n_in, VIDEO_CLOCK)  # pads the take's late start
                n_in += 1
            else:
                a = "anullsrc=r=48000:cl=%s," % layout
            parts.append(a + "aresample=48000,atrim=0:%.6f,asetpts=PTS-STARTPTS,afade=t=in:d=0.008,"
                         "afade=t=out:st=%.6f:d=0.008,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=%s[a%d]"
                         % (L, max(0, L - 0.008), layout, k))
        parts.append("".join("[a%d]" % k for k in range(len(segs))) + "concat=n=%d:v=0:a=1[aout]" % len(segs))
        voice = os.path.join(tmp, "voice.wav")
        run_ff(base + args + ["-filter_complex", ";".join(parts), "-map", "[aout]", "-c:a", "pcm_s24le",
                              "-ar", "48000", voice], total, 0.0, 0.1)
        # Picture, a batch of segments at a time, each part in the final codec.
        names, step = [], min(cut_batch(c) for c in clocks)
        for b in range(0, len(segs), step):
            args, parts = [], []
            for k in range(b, min(b + step, len(segs))):
                g, c, n = segs[k], clocks[k], int(round(lens[k] * fps))
                big = cut_batch(c) == CUT_BATCH_BIG  # 4 decoder threads: same speed, half the memory
                args += (["-threads", "4"] if big else []) + ["-ss", "%.3f" % g["in"], "-t", "%.3f" % (lens[k] + 0.3),
                                                             "-i", files[k]]
                v = "[%d:v]fps=%d,trim=end_frame=%d,setpts=PTS-STARTPTS" % (k - b, fps, n)
                if (c["width"], c["height"]) != (W, H):
                    v += ",scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2" % (W, H, W, H)
                parts.append(v + ",setsar=1[v%d]" % (k - b))
            m = len(parts)
            parts.append("".join("[v%d]" % k for k in range(m)) + "concat=n=%d:v=1:a=0[vout]" % m)
            names.append("%03d.%s" % (b // step, "mov" if vargs else "mp4"))
            done = sum(lens[:b])
            run_ff(base + args + ["-filter_complex", ";".join(parts), "-map", "[vout]"] + (vargs or video_codec(first))
                   + ["-r", str(fps), "-an", os.path.join(tmp, names[-1])], sum(lens[b:b + step]),
                   0.1 + 0.85 * done / total, 0.1 + 0.85 * (done + sum(lens[b:b + step])) / total)
        with open(os.path.join(tmp, "parts.txt"), "w") as f:
            f.write("".join("file '%s'\n" % n for n in names))
        # A render's cut.mov (vargs) needs no sound: the render mixes voice.wav itself.
        sound = [] if vargs else ["-i", voice, "-map", "1:a", "-c:a", "aac", "-b:a", "256k", "-ar", "48000"]
        run_ff(base + ["-f", "concat", "-safe", "0", "-i", os.path.join(tmp, "parts.txt")] + sound[:2]
               + ["-map", "0:v"] + sound[2:] + ["-c:v", "copy", "-movflags", "+faststart", mp4], total, 0.95, 1.0)
        os.replace(voice, wav)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return total


def cut_run(req):
    """`--cut-run . _work/<name>-vN.request.json`: the cut job, in the session folder."""
    s = "."
    with open(req) as f:
        r = json.load(f)
    name, n, segs, extra = r["name"], r["version"], r["segments"], r.get("extra") or {}
    stem = os.path.join(WORK_DIR, "%s-v%d" % (name, n))
    notes, words, clocks, files, voices, moved = [], {}, [], [], [], []
    for g in segs:
        key = (g["take"], g["kind"])
        if key in words:
            continue
        t = voice_take(s, g["take"], g["kind"])
        doc = words_doc(t["file"])
        if not is_ready(doc, take_clock(t["file"])):
            try:
                prepare_take(s, g["take"], g["kind"])
            except ValueError as e:
                notes.append("Take %d has no word times, so its cut points stay where you put them. %s" % (g["take"], e))
            t = voice_take(s, g["take"], g["kind"])
            doc = words_doc(t["file"])
        doc = ensure_onsets(s, t) if is_ready(doc) else doc
        words[key] = doc.get("words") if is_ready(doc) else None
    say("Cuts the clip.")
    for g in segs:
        t = voice_take(s, g["take"], g["kind"])
        c = take_clock(t["file"])
        files.append(t["file"])
        clocks.append(c)
        fps, dur = c["fps"], c.get("duration") or g["out"]
        ws = words[(g["take"], g["kind"])]
        for edge in ("in", "out"):
            was = g[edge]
            x, word = snap_point(ws, was, edge) if ws else (was, None)
            # An in-point goes to the frame at or before it: rounding up could clip the word's onset.
            f = math.floor(x * fps + 1e-6) if edge == "in" else round(x * fps)
            x = min(max(0.0, f / float(fps)), math.floor(dur * fps + 1e-6) / float(fps))
            if word:
                moved.append({"was": round(was, 3), "now": round(x, 3), "why": "inside '%s'" % word})
            g[edge] = round(x, 3)
        if frames(g["out"] - g["in"], fps) < 2:
            g["out"] = round(min(g["in"] + 2.0 / fps, dur), 3)
        key = voice_key(t["number"], t["kind"])
        v, f = read_voice(s, key) or {}, voice_files(s, key)["mix"]
        voices.append((f, voice_offset(s, key)) if v.get("state") == "done" and v.get("on", True)
                      and os.path.exists(f) else None)
    mp4, wav = os.path.join(WORK_DIR, ".%s-v%d.part.mp4" % (name, n)), os.path.join(WORK_DIR, ".%s-v%d.part.wav" % (name, n))
    try:
        render_cut(segs, files, clocks, voices, mp4, wav)
        os.replace(mp4, stem + ".mp4")
        os.replace(wav, stem + ".wav")
    finally:
        for p in (mp4, wav):
            if os.path.exists(p):
                os.remove(p)
    fps = clocks[0]["fps"]
    at, cut, clip_words = 0.0, [], []
    for g in segs:
        L = max(2, frames(g["out"] - g["in"], fps)) / float(fps)
        cut.append(dict(g, at=round(at, 3)))
        for w in words[(g["take"], g["kind"])] or []:
            if w["end"] > g["in"] and w["start"] < g["in"] + L:
                e = {"word": w["word"], "start": round(at + max(w["start"], g["in"]) - g["in"], 3),
                     "end": round(at + min(w["end"], g["in"] + L) - g["in"], 3)}
                if w.get("filler"):
                    e["filler"] = True
                clip_words.append(e)
        at += L
    on = [bool(x) for x in voices]
    source = "clean voice" if all(on) else "take sound" if not any(on) else "%s, take sound for the rest" \
        % takes_label("clean voice for", [g["take"] for g, x in zip(segs, on) if x])
    made = {"session_id": session_id(s),
            "cut": [{k: g[k] for k in ("take", "kind", "in", "out", "at")} for g in cut]}
    with open(stem + ".words.json.tmp", "w") as f:
        json.dump({"v": 2, "clock": "video", "source": "cut_take", "fps": fps, "duration": round(at, 3),
                   "words": clip_words, "made_from": made}, f, indent=1, ensure_ascii=False)
    os.replace(stem + ".words.json.tmp", stem + ".words.json")
    out = dict(extra, cut=cut, moved=moved, notes=notes, length_s=round(at, 3), fps=fps, voice_source=source,
               takes={str(g["take"]): c for g, c in zip(segs, clocks)})
    with open(stem + ".json.tmp", "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    os.replace(stem + ".json.tmp", stem + ".json")
    try:
        os.remove(req)
    except OSError:
        pass


# Rough cut

def script_plain(text):
    """script.md as said: no headings, [stage notes], markdown marks or links."""
    text = re.sub(r"^---\n.*?\n---\n", "", text, flags=re.S)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[[^\]]*\]", " ", text)
    lines = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
    return re.sub(r"[*_`>~]|^\s*[-+]\s+|^\s*\d+\.\s+", "", "\n".join(lines), flags=re.M)


def script_tokens(text):
    """(tokens, sentence index of each token, sentences as text)."""
    toks, sent, sentences = [], [], []
    for piece in re.split(r"(?<=[.!?])\s+|\n+", text or ""):
        tk = [norm_word(w) for w in piece.split() if norm_word(w)]
        if tk:
            sentences.append(piece.strip())
            toks += tk
            sent += [len(sentences) - 1] * len(tk)
    return toks, sent, sentences


def match_phrase(items, stoks, pos):
    """Give each word the script index it says, near pos (else anywhere). The longest run matched."""
    from difflib import SequenceMatcher
    for it in items:
        it["si"] = None
    p = [it["tok"] for it in items]

    def blocks(lo, hi):
        sm = SequenceMatcher(None, p, stoks[lo:hi], autojunk=False)
        bs = sorted(((b.a, b.b + lo, b.size) for b in sm.get_matching_blocks() if b.size), key=lambda b: -b[2])
        if not bs or (bs[0][2] < 2 and len(p) > 2):
            return []
        keep = [bs[0]]  # the longest run; a shorter one only close to what is kept (no stray "in the")
        for b in bs[1:]:
            near = any(abs(b[1] - (k[1] + k[2])) <= 4 or abs(k[1] - (b[1] + b[2])) <= 4 for k in keep)
            if b[2] >= 3 or near:
                keep.append(b)
        return keep
    found = blocks(max(0, pos - 40), min(len(stoks), pos + 200))
    if max([x[2] for x in found] or [0]) < 3 and len(p) >= 3:
        # Not near the last line (a take that starts later in the script): anywhere, but only a real run.
        wide = blocks(0, len(stoks))
        if max([x[2] for x in wide] or [0]) >= 3:
            found = wide
    for a, b, size in found:
        for k in range(size):
            items[a + k]["si"] = b + k
    return max([x[2] for x in found] or [0])


def said_between(items, sent_of, k):
    """3+ words between the script words of the lines before and after line k: the line in other words."""
    lines = [sent_of[x["si"]] if x["si"] is not None else None for x in items]
    before = [i for i, ln in enumerate(lines) if ln is not None and ln < k]
    after = [i for i, ln in enumerate(lines) if ln is not None and ln > k]
    return bool(before and after) and after[0] - before[-1] > 3


def whole_line(items, sent_of):
    """The phrase says every script word of a line of 2+ words."""
    si = {x["si"] for x in items if x["si"] is not None}
    for k in {sent_of[i] for i in si}:
        line = [i for i, sk in enumerate(sent_of) if sk == k]
        if len(line) >= 2 and si.issuperset(line):
            return True
    return False


def phrase_place(items):
    """(start, length) of the longest run of words that say consecutive script words."""
    best, run, prev = [], [], None
    for x in items:
        si = x["si"]
        run = run + [si] if si is not None and prev is not None and si == prev + 1 else ([si] if si is not None else [])
        prev = si
        if len(run) > len(best):
            best = run
    return (best[0], len(best)) if best else (None, 0)


def in_range(w, lo, hi):
    """The word belongs to the range lo..hi: its end is inside, or most of it is."""
    a, b = float(w["start"]), float(w.get("end") or w["start"])
    return lo < b <= hi or min(b, hi) - max(a, lo) >= 0.5 * max(b - a, 1e-6)


def plan_rough(words_by_take, script_text, gap=0.25):
    """The thinking of rough_cut, without media: which words to keep, in which order, as segments.
    words_by_take: {take: {"words": [...], "sounds": [[s, e]]}}, takes in the order to use. A word with
    outside=True (not in the take's best_cut) is never kept: it goes to dropped.
    Returns {"cut_list": [{take, in, out, text}], "dropped": [...], "missing": [...], "kept_text"}."""
    stoks, sent_of, sentences = script_tokens(script_text)
    sdouble = " " + " ".join(stoks) + " "
    allw, sounds, units, dropped = {}, {}, [], []
    for n, d in words_by_take.items():
        ws = sorted((w for w in d.get("words") or [] if w.get("start") is not None),
                    key=lambda w: float(w["start"]))
        items = []
        for i, w in enumerate(ws):
            text = str(w.get("word") or "").strip()
            tok = norm_word(text) or text.lower()  # "%" is said ("percent"): a word, never a filler
            items.append({"take": n, "i": i, "word": text, "start": float(w["start"]),
                          "end": float(w.get("end") or w["start"]), "tok": tok, "si": None,
                          "why": "outside best_cut" if w.get("outside") else
                          "filler" if w.get("filler") or tok in FILLERS else None})
        allw[n] = items
        sounds[n] = sorted([float(a), float(b)] for a, b in d.get("sounds") or [])
        cur = []
        for it in items:
            if it["why"]:
                if cur:
                    units.append(cur)
                cur = []
                continue
            if cur and (it["start"] - cur[-1]["end"] > 0.6
                        or any(cur[-1]["end"] <= a and b <= it["start"] for a, b in sounds[n])):
                units.append(cur)
                cur = []
            cur.append(it)
        if cur:
            units.append(cur)
    # Stutters: 1-3 words said twice back to back; the first copy goes (unless the script says it twice).
    for u in units:
        i = 0
        while i < len(u):
            for k in (3, 2, 1):
                a, b = [x["tok"] for x in u[i:i + k]], [x["tok"] for x in u[i + k:i + 2 * k]]
                if len(a) == k and a == b and (" %s " % " ".join(a + b)) not in sdouble:
                    for x in u[i:i + k]:
                        x["why"] = "stutter"
                    i += k
                    break
            else:
                i += 1
    units = [[x for x in u if not x["why"]] for u in units]
    units = [u for u in units if u]
    # A restart glued to the end of a try ("... came out of every | single video"): the phrase ends
    # with the words it began with. Those words start the next phrase of the take.
    for k in range(len(units) - 1):
        u, nxt = units[k], units[k + 1]
        for n in (3, 2, 1):
            if (len(u) > 2 * n and [x["tok"] for x in u[-n:]] == [x["tok"] for x in u[:n]]
                    and nxt[0]["take"] == u[0]["take"] and nxt[0]["start"] - u[-1]["end"] <= 2.0):
                units[k + 1] = u[-n:] + nxt
                units[k] = u[:-n]
                break
    if stoks:
        # Map each phrase to the script; a run of 3+ unmatched words inside a phrase is a restart: its own phrase.
        out, pos, last = [], 0, None
        for u in units:
            if u[0]["take"] != last:
                pos, last = 0, u[0]["take"]
            match_phrase(u, stoks, pos)
            pieces, cur, run = [], [], []
            for x in u:
                if x["si"] is None:
                    run.append(x)
                    continue
                if len(run) >= 3:
                    pieces += [p for p in (cur, run) if p]
                    cur = []
                else:
                    cur += run
                run = []
                cur.append(x)
            if len(run) >= 3:
                pieces += [p for p in (cur, run) if p]
            else:
                pieces.append(cur + run)
            pieces = [p for p in pieces if p]
            if len(pieces) > 1:
                for p in pieces:
                    if match_phrase(p, stoks, pos) < 3:  # not a restart: words off the script
                        for x in p:
                            x["si"] = None
            for p in pieces:
                start, longest = phrase_place(p)
                out.append((p, longest))
                if start is not None:
                    pos = start + longest  # the next phrase looks near the end of this one
        # Tries: the phrases of a take in order, until one goes back in the script (a retake of those
        # lines). Going back needs a run of 4+ script words or a whole line: a shorter run ("look at
        # the") is common words, so that phrase stays off the script, after the one it followed.
        tries, hi = [], -1
        for k, (p, _) in enumerate(out):
            start, longest = phrase_place(p)
            back = start is not None and start < hi
            nxt = out[k + 1][0] if k + 1 < len(out) and out[k + 1][0][0]["take"] == p[0]["take"] else None
            n_start, n_longest = phrase_place(nxt) if nxt else (None, 0)
            # "Every", a pause, "single video I posted": the next phrase goes on, so this one starts the try.
            goes_on = n_start is not None and 0 <= n_start - (start or 0) - longest <= 3 and longest + n_longest >= 4
            if back and longest < 4 and not goes_on and not whole_line(p, sent_of):
                for x in p:
                    x["si"] = None
                back = False
            if not tries or p[0]["take"] != tries[-1][0]["take"] or back:
                tries.append([])
                hi = -1
                if back:  # "Okay. So," before a retake: words of the restart, not of the line
                    lead = next((i for i, x in enumerate(p) if x["si"] is not None), 0)
                    for x in p[:lead] if lead <= 3 else ():
                        x["why"] = x["why"] or "retake"
            # Inside the phrase too: a short run of words back in the script is common words.
            run = []
            for x in p + [{"si": None}]:
                if x["si"] is not None and (not run or x["si"] == run[-1]["si"] + 1):
                    run.append(x)
                    continue
                if run and run[0]["si"] < hi and len(run) < 4:
                    for y in run:
                        y["si"] = None
                elif run:
                    hi = max(hi, run[-1]["si"])
                run = [x] if x["si"] is not None else []
            tries[-1] += p
        # Each word belongs to a line: the line of its script word, else of the script word before it
        # in the try (else after it).
        cover = {}
        for ti, q in enumerate(tries):
            k = next((sent_of[x["si"]] for x in q if x["si"] is not None), None)
            for x in q:
                if x["si"] is not None:
                    k = sent_of[x["si"]]
                    cover.setdefault(k, {}).setdefault(ti, set()).add(x["si"])
                x["line"], x["try"] = k, ti
        # Retakes: each line once, from the last try that says most of it (60% of the script words of
        # the best try of that line). The same line in the other tries goes.
        # A try that stops inside its last line ("Takes is free and", then nothing or "okay so") is no
        # full try of that line.
        stopped = set()
        for ti, q in enumerate(tries):
            m = [i for i, x in enumerate(q) if x["si"] is not None]
            if m and len(q) - 1 - m[-1] < 3:
                last = max(x["si"] for x in q if x["si"] is not None)
                if last < max(i for i, sk in enumerate(sent_of) if sk == sent_of[last]) - 1:
                    stopped.add((ti, sent_of[last]))
        strong = {}
        for k, by_try in cover.items():
            full = {ti: v for ti, v in by_try.items() if (ti, k) not in stopped} or by_try
            best = max(len(v) for v in full.values())
            strong[k] = max(ti for ti, v in full.items() if len(v) >= 0.6 * best)
        # A try owns the lines it says best, and every line between them that it says in some words:
        # an ad-lib of a line in a later full try beats a closer wording in an earlier one (one flow).
        owner = {}
        for ti in reversed(range(len(tries))):
            mine = [k for k, o in strong.items() if o == ti]
            for k in range(min(mine), max(mine) + 1) if mine else ():
                if k not in owner and (ti in cover.get(k, {}) or said_between(tries[ti], sent_of, k)):
                    owner[k] = ti
        for k, o in strong.items():
            owner.setdefault(k, o)
        for q in tries:
            for x in q:
                if x["line"] is not None and owner[x["line"]] != x["try"] and not x["why"]:
                    x["why"] = "retake"
        # A kept piece of 1-2 words of a line kept elsewhere in 3+ words is a leftover of a retake.
        # (An um or a stutter inside a piece does not split it.)
        runs, cut = [], True
        for q in tries:
            cut = True
            for x in q:
                if x["why"]:
                    cut = cut or x["why"] == "retake"
                    continue
                if cut:
                    runs.append([])
                runs[-1].append(x)
                cut = False
        big = {x["line"] for r in runs if len(r) >= 3 for x in r}
        for r in runs:
            if len(r) <= 2 and all(x["line"] is not None and x["line"] in big for x in r):
                for x in r:
                    x["why"] = "retake"
        # Order: by line; in a line, the words of its try in the order said.
        ordered, last = [], -1
        for q in tries:
            for x in q:
                last = x["line"] if x["line"] is not None else last
                ordered.append(((last, x["try"], x["i"]), x))
        ordered = [[x for _, x in sorted(ordered, key=lambda e: e[0])]]
    else:
        for i, p in enumerate(units):
            pt = [x["tok"] for x in p]
            if len(pt) < 3:
                continue
            for q in units[i + 1:]:
                if q[0]["take"] != p[0]["take"] or q[0]["start"] - p[-1]["end"] > 15:
                    continue
                if [x["tok"] for x in q[:3]] == pt[:3]:
                    for x in p:
                        x["why"] = x["why"] or "retake"
                    break
        ordered = units
    # Segments: kept words next to each other in one take, with pauses up to gap.
    kept = [x for u in ordered for x in u if not x["why"]]
    groups = []
    for x in kept:
        g = groups[-1] if groups else None
        if (g and g[-1]["take"] == x["take"] and x["i"] == g[-1]["i"] + 1 and x["start"] - g[-1]["end"] <= gap
                and not any(g[-1]["end"] <= a and b <= x["start"] for a, b in sounds[x["take"]])):
            g.append(x)
        else:
            groups.append([x])
    cut_list = []
    for g in groups:
        n, first, last = g[0]["take"], g[0], g[-1]
        ws = allw[n]
        prev_end = max([ws[first["i"] - 1]["end"]] if first["i"] else [0.0])
        prev_end = max([prev_end] + [b for a, b in sounds[n] if b <= first["start"]])
        nxt = [ws[last["i"] + 1]["start"]] if last["i"] + 1 < len(ws) else []
        nxt += [a for a, b in sounds[n] if a >= last["end"]]
        a = first["start"] - 0.08
        if first["i"] or any(b <= first["start"] for _, b in sounds[n]):
            a = max(a, prev_end + 0.02)  # never into the word or sound before
        a = max(0.0, min(first["start"], a))
        b = max(last["end"], min(last["end"] + 0.12, (min(nxt) - 0.02) if nxt else float("inf")))
        cut_list.append({"take": n, "in": round(a, 3), "out": round(b, 3), "text": " ".join(x["word"] for x in g)})
    # What went, grouped: consecutive words of one take with the same reason.
    gone = sorted((x for n in allw for x in allw[n] if x["why"]), key=lambda x: (list(allw).index(x["take"]), x["i"]))
    for x in gone:
        d = dropped[-1] if dropped else None
        if d and d["take"] == x["take"] and d["why"] == x["why"] and d["_i"] == x["i"] - 1:
            d.update(end=x["end"], text=d["text"] + " " + x["word"], _i=x["i"])
        else:
            dropped.append({"take": x["take"], "start": x["start"], "end": x["end"], "text": x["word"], "why": x["why"],
                            "_i": x["i"]})
    for n in allw:
        for a, b in sounds[n]:
            dropped.append({"take": n, "start": a, "end": b, "text": "", "why": "sound", "_i": -1})
    dropped.sort(key=lambda d: (list(allw).index(d["take"]), d["start"]))
    for d in dropped:
        d.pop("_i")
        d["start"], d["end"] = round(d["start"], 3), round(d["end"], 3)
    missing = []
    if stoks:
        kept_si = {x["si"] for x in kept if x["si"] is not None}
        for k, text in enumerate(sentences):
            idx = [i for i, sk in enumerate(sent_of) if sk == k]
            if sum(1 for i in idx if i in kept_si) < 0.6 * len(idx):
                said_in = sorted({x["take"] for n in allw for x in allw[n] if x["si"] is not None and sent_of[x["si"]] == k},
                                 key=list(allw).index)
                missing.append({"text": text, "said_in": said_in})
    return {"cut_list": cut_list, "dropped": dropped, "missing": missing,
            "kept_text": " ".join(x["word"] for x in kept)}


def t_rough_cut(a):
    s = job_session(a.get("session"))
    meta = read_meta(s)
    numbers = sorted({t["number"] for t in meta.get("takes", [])})
    if not numbers:
        raise ValueError("This session has no takes yet.")
    if a.get("takes"):
        try:
            if not isinstance(a["takes"], list):
                raise TypeError
            takes = [int(x) for x in a["takes"]]
        except (TypeError, ValueError):
            raise ValueError("takes is a list of take numbers, e.g. [3, 5].")
        bad = [n for n in takes if n not in numbers]
        if bad:
            raise ValueError("No take %d in this session. get_session lists the takes." % bad[0])
    else:
        keepers = sorted({t["number"] for t in meta.get("takes", []) if t.get("keeper")})
        takes = keepers or numbers
    takes = list(dict.fromkeys(takes))
    try:
        gap = float(a.get("gap", 0.25))
    except (TypeError, ValueError):
        raise ValueError("gap is seconds, 0.1 to 1.0.")
    if not 0.1 <= gap <= 1.0:
        raise ValueError("gap is seconds, 0.1 to 1.0.")
    jobs = prepare_jobs(s)
    waiting = [n for n in takes if not is_ready(words_doc(voice_file(s, voice_take(s, n))))]
    if waiting:
        running = [j for j, nums in jobs if j["status"] in ("starting", "running") and set(waiting) & nums]
        job = running[-1] if running else start_prepare(s, waiting)
        b = t_get_job({"id": job["id"], "session": s, "wait_s": CUT_WAIT})
        if b["status"] in ("starting", "running"):
            return {"status": "running", "job": job["id"],
                    "note": "Takes is still working. Call get_job with wait_s, then call rough_cut again."}
        still = [n for n in takes if not is_ready(words_doc(voice_file(s, voice_take(s, n))))]
        if still:
            raise ValueError("Takes has no word times for take %d: %s" % (still[0], b.get("error") or "the job %s." % b["status"]))
    cuts, words_by_take = read_cuts(s), {}
    for n in takes:
        doc = ensure_onsets(s, voice_take(s, n))
        ws, snd = doc.get("words") or [], doc.get("sounds") or []
        bc = cuts.get(str(n)) or {}
        if bc.get("state") == "done" and bc.get("start") is not None and bc.get("end") is not None:
            lo, hi = float(bc["start"]), float(bc["end"])
            # A word Whisper starts a bit before the range stays (its end is inside), and so does a word
            # mostly inside. The rest stays in the list, marked: plan_rough drops it and says why.
            ws = [w if in_range(w, lo, hi) else dict(w, outside=True) for w in ws]
            snd = [x for x in snd if x[1] > lo - 1.0 and x[0] < hi + 1.0]
        words_by_take[n] = {"words": ws, "sounds": snd}
    sp = os.path.join(s, "script.md")
    plan = plan_rough(words_by_take, script_plain(read_text(sp) if os.path.exists(sp) else ""), gap)
    if not plan["cut_list"]:
        raise ValueError("Takes found no words to keep in take %s." % ", ".join(map(str, takes)))
    if len(plan["cut_list"]) > CUT_MAX:
        raise ValueError("The rough cut has %d parts, more than %d. Use a larger gap or fewer takes."
                         % (len(plan["cut_list"]), CUT_MAX))
    for c in plan["cut_list"]:  # the last word's tail never runs past the take's end
        dur = (take_clock(voice_file(s, voice_take(s, c["take"]))) or {}).get("duration")
        if dur:
            c["out"] = min(c["out"], dur)
    segs = check_segments(s, plan["cut_list"])
    job, n = start_cut(s, segs, "rough", extra={"rough": True, "dropped": plan["dropped"],
                                                "missing": plan["missing"], "gap": gap})
    return cut_result(s, job["id"], "rough", n)


def short_name(text):
    """At most three words, Title Case."""
    words = re.findall(r"[\w'&+-]+", text or "")[:3]
    return " ".join(w if w.isupper() else w[:1].upper() + w[1:] for w in words)


# ---------- edit recipes (2026-10-11) ----------
# An edit is a recipe, not a chat's memory. render_edit builds a recipe into a video as a job and
# checks it; publish_edit saves the checked render as the next version with its recipe beside it.
# The next version starts from that recipe (render_edit base + changes): never from a script in /tmp.
# Only takes, the clean voice, music and sfx files and picture layers go in. A finished edit never
# does, so music cannot stack and the voice is cleaned once. Same files as Sources/Takes/EditRecipe.swift.
#
#   edits/<name>-vN.recipe.json      the recipe of edits/<name>-vN.mp4. Written once, never changed.
#                                    A recipe with no video yet is a claim: that N is taken.
#   _edit/<name>/                    the edit's sources (a HyperFrames composition, layer renders), the
#                                    steps' cwd; words.json = the final edit's word times
#   _edit/<name>/.versions/vN/       a frozen copy, made by publish_edit
#   _edit/renders/<job>.mp4          a render that waits for publish_edit, with <job>.recipe.json and
#                                    <job>.words.json; <job>.tmp/ holds its parts while it runs
#
# Paths in a recipe: session files relative to the session, library files as @library/<path under
# <root>/_library>. No absolute paths, so a recipe survives a moved library.
#
# Field             who sets it          default when the recipe leaves it out
# name              agent                required on a first recipe; from base after
# cut               agent                required: [{take, in, out, kind?}] (rough_cut's cut), whole frames
# frame             agent                {"shape": "source"}: the first take's size and fps; crop: none
# over              agent                []: picture layers {file, at, in?, out?, alpha?}; their sound is never used
# music, sfx        agent                []: music {file, at 0, in 0, out?, gain_db -18, duck_db 8, fade_out 1.5},
#                                        sfx {file, at, gain_db -10}
# style             render_edit          the session's style, params {}
# steps             agent                []: [{run: [argv], cwd: _edit/<name>, makes: [files]}]
# cover             agent                from the base; null takes it off: {image, seconds 0.1}
# loudness          agent (LUFS)         null = the voice's own setting: normal -14, quiet -18
# takes, voice, inputs, parent, made, by, host, commands, render_id, job, started, src, src_skipped,
# edit, checks, length_s, rendered, mix (the loudness it reached): Takes. note, fixed, accepted: publish_edit.
# Times in over, music and sfx are seconds of the cut: a cover adds its seconds before them by itself.

RECIPE_EXT = ".recipe.json"
EDIT_DIR = "_edit"
RENDERS = os.path.join(EDIT_DIR, "renders")
LIB_REF = "@library/"
NOTE_MAX = 60
RENDER_WAIT_MAX = 120
RENDER_KEEP_DAYS = 7
FREEZE_MAX = 1 << 30
FREEZE_SKIP = {".versions", "node_modules", ".cache"}
SHAPES = {"9:16": (1080, 1920), "16:9": (1920, 1080), "1:1": (1080, 1080), "4:5": (1080, 1350)}
AGENT_FIELDS = ("name", "cut", "frame", "over", "music", "sfx", "style", "steps", "cover", "loudness")
MUSIC_DEFAULTS = {"at": 0.0, "in": 0.0, "gain_db": -18, "duck_db": 8, "fade_out": 1.5}
SFX_DEFAULTS = {"gain_db": -10}
MUSIC_LUFS = -14.0
TRUE_PEAK = -1.0
LOUDNESS_TARGET = {"normal": -14.0, "quiet": -18.0}
RENDER_STAGES = {"cut": "Cutting the takes", "steps": "Making the graphics", "picture": "Making the picture",
                 "sound": "Mixing the sound", "check": "Checking the edit"}
RENDER_DONE = "Ready. Takes checks it before it saves it."
def prores():
    """The render's cut.mov: ProRes 422 10-bit, a picture pass decodes it once more.
    VideoToolbox on Apple silicon: 14.5 CPU-s for a 40 s take against 99 for prores_ks (speed audit 2026-10-13)."""
    if apple_silicon() and has_encoder("prores_videotoolbox"):
        return ["-c:v", "prores_videotoolbox", "-profile:v", "standard", "-pix_fmt", "p210le"]
    return ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le"]



RUN_LOG = None  # the render job's list of every argv it ran (run_ff and render_run add to it)
LOUD_CACHE = {}  # (path, size, mtime) -> (integrated LUFS, true peak dBTP)


class RenderStop(Exception):
    """A render that cannot go on: the reason is one of the plain reasons the Jobs row shows."""


def step_timeout():
    return float(os.environ.get("TAKES_STEP_TIMEOUT") or 30 * 60)


def host_id():
    """A random id of this Mac, saved once: steps of a recipe made on another Mac do not run by themselves."""
    if os.environ.get("TAKES_HOST_ID"):
        return os.environ["TAKES_HOST_ID"]
    p = os.path.expanduser("~/Library/Application Support/Takes/host-id")
    try:
        with open(p) as f:
            v = f.read().strip()
        if v:
            return v
    except OSError:
        pass
    v = secrets.token_hex(8)
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(v)
    except OSError:
        pass
    return v


def recipe_path(video):
    """edits/x-v5.mp4 -> edits/x-v5.recipe.json"""
    return os.path.splitext(video)[0] + RECIPE_EXT


def lib_path(p):
    """@library/music/x.mp3 -> <root>/_library/music/x.mp3; anything else as it is."""
    return os.path.join(root(), LIB, p[len(LIB_REF):]) if isinstance(p, str) and p.startswith(LIB_REF) else p


def unlib_path(p):
    """An absolute path under <root>/_library -> @library/...; None when it is not there."""
    base = os.path.realpath(os.path.join(root(), LIB))
    rp = os.path.realpath(p)
    return LIB_REF + os.path.relpath(rp, base) if rp.startswith(base + os.sep) else None


def ref_of(s, p, what, later=None):
    """A file as a recipe stores it: relative to the session, or @library/... Else an error. later: a folder
    (relative to the session) where the file may not exist yet: a step of the recipe makes it."""
    if not isinstance(p, str) or not p.strip():
        raise ValueError("%s needs file: a path in the session or @library/..." % what)
    p = p.strip()
    if p.startswith(LIB_REF):
        full = lib_path(p)
    else:
        full = os.path.normpath(p if os.path.isabs(p) else os.path.join(s, p))
    sr = os.path.realpath(s)
    if os.path.realpath(full).startswith(sr + os.sep):
        rel = os.path.relpath(os.path.realpath(full), sr)
    else:
        rel = unlib_path(full)
        if not rel:
            raise ValueError("%s: %s is outside the session and the library. Copy it into the session or the "
                             "library first." % (what, p))
    if not os.path.isfile(full) and not (later and rel.startswith(later + os.sep)):
        raise ValueError("%s is gone. Pick another file for %s." % (os.path.basename(p), what))
    return rel


def ref_abs(s, ref):
    return lib_path(ref) if ref.startswith(LIB_REF) else os.path.join(s, ref)


def edit_name_of(f):
    """'hook-v4.recipe.json' / 'hook-v4.mp4' / 'hook-v4.words.json' -> ('hook', 4)."""
    for ext in (RECIPE_EXT, ".words.json"):
        if f.endswith(ext):
            f = f[:-len(ext)] + ".x"
    b, v, _ = split_version(f)
    return b, v


def edit_versions(s, name=None):
    """{name: {N: {"video": rel or None, "recipe": rel or None}}} of edits/."""
    d = os.path.join(s, "edits")
    out = {}
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if f.startswith("."):
            continue
        b, v = edit_name_of(f)
        if v is None or (name and b != name):
            continue
        e = out.setdefault(b, {}).setdefault(v, {"video": None, "recipe": None})
        if f.endswith(RECIPE_EXT):
            e["recipe"] = os.path.join("edits", f)
        elif media_kind(f) == "video":
            e["video"] = os.path.join("edits", f)
    return out


def load_recipe(s, rel):
    """The recipe file at rel (relative to the session), None when there is none. A file that does not
    parse is an error, and is never written over."""
    p = os.path.join(s, rel)
    if not os.path.exists(p):
        return None
    try:
        with open(p) as f:
            r = json.load(f)
        if not isinstance(r, dict):
            raise ValueError
    except (OSError, ValueError):
        raise ValueError("Takes cannot read %s. It is left as it is. Fix the file or move it out of the session."
                         % rel)
    return r


def newest_recipe(s, name=None):
    """The recipe of the highest version (by number) of name that has a video and a recipe. None if none."""
    best = None
    for b, vs in edit_versions(s, name).items():
        for v, e in vs.items():
            if e["video"] and e["recipe"] and (best is None or (b == best[0] and v > best[1])):
                best = (b, v, e["recipe"])
    return load_recipe(s, best[2]) if best else None


def recipe_names(s):
    """Edit names that have at least one version with a recipe."""
    return sorted(b for b, vs in edit_versions(s).items() if any(e["video"] and e["recipe"] for e in vs.values()))


def edit_ref(s, ref):
    """'edits/hook-v4.mp4', 'hook-v4' or 'hook' -> (name, version or None)."""
    ref = str(ref or "").strip()
    f = os.path.basename(ref)
    if f.endswith(RECIPE_EXT) or media_kind(f) == "video":
        b, v = edit_name_of(f)
        return b, v
    b, v, _ = split_version(f + ".x")
    return (b, v) if v is not None else (f, None)


def read_recipe(s, ref):
    """The recipe for a ref: 'edits/hook-v4.mp4', 'hook-v4' or 'hook' (its newest version by number).
    None when there is none."""
    name, v = edit_ref(s, ref)
    if v is None:
        return newest_recipe(s, name)
    return load_recipe(s, os.path.join("edits", "%s-v%d%s" % (name, v, RECIPE_EXT)))


def recipe_lineage(s, r):
    """The parent chain: [{edit, note, made}], newest first. (lineage, missing parents)."""
    out, missing, seen = [], [], set()
    cur = r
    while cur and cur.get("parent") and len(out) < 20:
        p = cur["parent"]
        if p in seen:
            break
        seen.add(p)
        try:
            cur = load_recipe(s, recipe_path(p))
        except ValueError:
            cur = None
        if not cur:
            missing.append(p)
            break
        out.append({"edit": p, "note": cur.get("note"), "made": cur.get("made")})
    return out, missing


def merge_patch(base, changes):
    """RFC 7386 JSON merge patch: dicts merge, null deletes, anything else (lists too) replaces."""
    if not isinstance(changes, dict):
        return changes
    out = dict(base) if isinstance(base, dict) else {}
    for k, v in changes.items():
        if v is None:
            out.pop(k, None)
        else:
            out[k] = merge_patch(out.get(k), v)
    return out


def flat(x, at=""):
    """{"music[0].in": 14.0, ...} of a JSON value."""
    out = {}
    if isinstance(x, dict) and x:
        for k, v in x.items():
            out.update(flat(v, "%s.%s" % (at, k) if at else k))
    elif isinstance(x, list) and x:
        for i, v in enumerate(x):
            out.update(flat(v, "%s[%d]" % (at, i)))
    else:
        out[at] = x
    return out


def recipe_diff(a, b):
    """Every value that differs: {"music[0].in": [14.0, 0.0]}; a missing value is None."""
    fa, fb = flat(a), flat(b)
    return {k: [fa.get(k), fb.get(k)] for k in sorted(set(fa) | set(fb)) if fa.get(k) != fb.get(k)}


def unnamed_changes(changed, changes):
    """Changed values that `changes` did not name: a list it replaced without them. An index the new
    list does not have any more was dropped on purpose."""
    named = set(flat(changes))
    out = []
    for k, (old, new) in changed.items():
        if k in named or any(k.startswith(n + ".") or k.startswith(n + "[") for n in named if changes_null(changes, n)):
            continue
        m = re.match(r"^(\w+)\[(\d+)\]", k)
        if not m or m.group(1) not in changes:
            continue
        lst = changes.get(m.group(1))
        if isinstance(lst, list) and int(m.group(2)) >= len(lst):
            continue
        out.append("%s went from %s to %s because the %s list was replaced. Repeat the whole entry to keep it."
                   % (k, json.dumps(old), "nothing" if new is None else json.dumps(new), m.group(1)))
    return out


def changes_null(changes, path):
    v = flat(changes).get(path, 0)
    return v is None or v == [] or v == {}


def agent_part(r):
    return {k: r[k] for k in AGENT_FIELDS if k in r}


def num(x, what, lo=None, hi=None):
    try:
        v = float(x)
    except (TypeError, ValueError):
        raise ValueError("%s is a number of seconds or dB, e.g. 1.5." % what)
    if (lo is not None and v < lo) or (hi is not None and v > hi) or v != v:
        raise ValueError("%s is %g; it must be %s." % (what, v, "from %g to %g" % (lo, hi) if hi is not None
                                                        else "%g or more" % lo))
    return v


def norm_recipe(s, r):
    """The agent's fields of a recipe in one shape, every file as a recipe path. Errors name the field."""
    if not isinstance(r, dict):
        raise ValueError('recipe is an object, e.g. {"name": "hook", "cut": [...]}.')
    out = {}
    name = slug(str(r.get("name") or ""))
    if not name:
        raise ValueError('Give name: a short slug for the edit, e.g. "hook".')
    out["name"] = name
    cut = r.get("cut")
    if not isinstance(cut, list) or not cut:
        raise ValueError("Give cut: the parts to keep, in order, [{take, in, out}] in seconds of the take "
                         "(rough_cut's cut).")
    for i, g in enumerate(cut):
        if isinstance(g, dict) and g.get("crop"):
            raise ValueError("cut[%d].crop: a crop per part is not possible yet. Use frame.crop." % i)
        if isinstance(g, dict) and "take" in g:
            try:
                t = voice_take(s, int(g["take"]), g.get("kind"))
            except (TypeError, ValueError):
                t = None
            if t and not os.path.isfile(os.path.join(s, t["file"])):
                raise ValueError("%s is gone. Pick another take in cut." % t["file"])
    segs = check_segments(s, [{k: g[k] for k in ("take", "in", "out", "kind") if k in g} if isinstance(g, dict) else g
                              for g in cut])
    out["cut"] = [{"take": g["take"], "kind": g["kind"], "in": round(g["in"], 4), "out": round(g["out"], 4)} for g in segs]
    frame = r.get("frame") or {}
    if not isinstance(frame, dict):
        raise ValueError("frame is an object: {shape: '9:16'|'16:9'|'1:1'|'4:5'|'source', crop}.")
    shape = frame.get("shape") or "source"
    if shape not in SHAPES and shape != "source":
        raise ValueError("frame.shape is 9:16, 16:9, 1:1, 4:5 or source.")
    f = {"shape": shape}
    for k in ("w", "h", "fps"):
        if frame.get(k) is not None:
            f[k] = int(num(frame[k], "frame." + k, 2, 8192))
    if frame.get("crop"):
        c = frame["crop"]
        if not isinstance(c, dict) or not all(k in c for k in ("x", "y", "w", "h")):
            raise ValueError("frame.crop is {x, y, w, h} in pixels of the take.")
        f["crop"] = {k: int(num(c[k], "frame.crop." + k, 0, 16384)) for k in ("x", "y", "w", "h")}
    out["frame"] = f
    over = []
    for i, o in enumerate(r.get("over") or []):
        what = "over[%d]" % i
        if not isinstance(o, dict):
            raise ValueError("%s is {file, at, in?, out?, alpha?}." % what)
        e = {"file": ref_of(s, o.get("file"), what, later=os.path.join(EDIT_DIR, name)),
             "at": num(o.get("at", 0), what + ".at", 0)}
        for k in ("in", "out"):
            if o.get(k) is not None:
                e[k] = num(o[k], "%s.%s" % (what, k), 0)
        if "out" in e and e["out"] <= e.get("in", 0):
            raise ValueError("%s.out must be after its in." % what)
        if o.get("alpha"):
            e["alpha"] = True
        over.append(e)
    out["over"] = over
    music = []
    for i, m in enumerate(r.get("music") or []):
        what = "music[%d]" % i
        if not isinstance(m, dict):
            raise ValueError("%s is {file, at, in, gain_db, duck_db, fade_out}." % what)
        e = dict(MUSIC_DEFAULTS)
        e["file"] = ref_of(s, m.get("file"), what)
        for k in ("at", "in", "out", "gain_db", "duck_db", "fade_out"):
            if m.get(k) is not None:
                e[k] = num(m[k], "%s.%s" % (what, k), *({"gain_db": (-60, 12), "duck_db": (0, 40)}.get(k, (0, None))))
        music.append(e)
    out["music"] = music
    sfx = []
    for i, x in enumerate(r.get("sfx") or []):
        what = "sfx[%d]" % i
        if not isinstance(x, dict) or x.get("at") is None:
            raise ValueError("%s is {file, at, gain_db}." % what)
        e = dict(SFX_DEFAULTS, file=ref_of(s, x.get("file"), what), at=num(x["at"], what + ".at", 0))
        if x.get("gain_db") is not None:
            e["gain_db"] = num(x["gain_db"], what + ".gain_db", -60, 12)
        sfx.append(e)
    out["sfx"] = sfx
    if r.get("style") is not None:
        st = r["style"]
        if not isinstance(st, dict):
            raise ValueError("style is {name, template?, params?}.")
        out["style"] = {k: st[k] for k in ("name", "template", "params") if st.get(k) is not None}
    steps = []
    for i, x in enumerate(r.get("steps") or []):
        what = "steps[%d]" % i
        run = x.get("run") if isinstance(x, dict) else None
        if not isinstance(run, list) or not run or not all(isinstance(w, str) and w for w in run):
            raise ValueError("%s.run is a list of words (argv), e.g. [\"npx\", \"hyperframes\", \"render\"], "
                             "not a shell line." % what)
        cwd = os.path.normpath(x.get("cwd") or os.path.join(EDIT_DIR, name))
        mine = os.path.join(EDIT_DIR, name)
        if os.path.isabs(cwd) or not (cwd == mine or cwd.startswith(mine + os.sep)):
            raise ValueError("%s.cwd must be inside %s/." % (what, mine))
        makes = []
        for m in x.get("makes") or []:
            p = os.path.normpath(os.path.join(cwd, str(m)))
            if os.path.isabs(str(m)) or not p.startswith(mine + os.sep):
                raise ValueError("%s.makes: %s must be inside %s/." % (what, m, mine))
            makes.append(str(m))
        steps.append({"run": list(run), "cwd": cwd, "makes": makes})
    out["steps"] = steps
    if r.get("cover"):
        c = r["cover"]
        if isinstance(c, str):
            c = {"image": c}
        if not isinstance(c, dict):
            raise ValueError("cover is {image, seconds} or null.")
        img = ref_of(s, c.get("image"), "cover")
        if media_kind(img) != "image":
            raise ValueError("cover.image must be an image (a thumbnail from next_path kind=thumbnail).")
        out["cover"] = {"image": img, "seconds": num(c.get("seconds", 0.1), "cover.seconds", 0.04, 3)}
    if r.get("loudness") is not None:
        if isinstance(r["loudness"], bool) or not isinstance(r["loudness"], (int, float)):
            raise ValueError("loudness is a number in LUFS, e.g. -14.")
        out["loudness"] = num(r["loudness"], "loudness", -30, -8)
    return out


def check_music(s, music):
    """At most one song plays at a time: an entry may follow another, not overlap it."""
    spans = []
    for i, m in enumerate(music):
        end = m.get("out")
        if end is None:
            end = media_seconds(ref_abs(s, m["file"]))
        spans.append((m["at"], m["at"] + max(0.0, end - m["in"]), i))
    spans.sort()
    for (a0, a1, i), (b0, _, j) in zip(spans, spans[1:]):
        if b0 < a1 - 0.01:
            raise ValueError("music[%d] starts at %.2f s while music[%d] still plays (to %.2f s). One song at a time: "
                             "give music[%d] an out, or start music[%d] later." % (j, b0, i, a1, i, j))


def check_recipe(s, r):
    """The hard rules before a render starts. Each error names the field and the fix."""
    for what in ("music", "sfx"):
        for i, m in enumerate(r.get(what) or []):
            parts = m["file"].split(os.sep)
            if parts[0] == "edits" or m["file"].startswith(RENDERS + os.sep) or (parts[0] == EDIT_DIR and ".versions" in parts):
                raise ValueError("%s[%d]: the final mix is never an input: use the song file itself (list_music) "
                                 "and the clean voice." % (what, i))
    check_music(s, r.get("music") or [])


def take_files(s, r):
    """{(take, kind): take dict} of the cut, resolved by number and kind now (a renamed take still resolves)."""
    out = {}
    for g in r["cut"]:
        key = (g["take"], g["kind"])
        if key not in out:
            out[key] = voice_take(s, g["take"], g["kind"])
    return out


def fill_recipe(s, r, base=None):
    """Takes' fields: takes, frame size, voice, style, inputs. warnings: what changed under the base."""
    warns = []
    first = None
    takes, keys, chains, srcs = [], {}, {}, []
    for (n, kind), t in take_files(s, r).items():
        c = take_clock(os.path.join(s, t["file"])) or {}
        first = first or c
        takes.append({"take": n, "kind": kind, "file": t["file"], "audio_offset_s": c.get("audio_offset_s"),
                      "fps_mode": c.get("fps_mode")})
        key = voice_key(n, kind)
        v, f = read_voice(s, key) or {}, voice_files(s, key)["mix"]
        if v.get("state") == "done" and v.get("on", True) and os.path.exists(f):
            keys[key] = os.path.relpath(f, s)
            chains[key] = {"steps": v.get("steps") or [], "strength": v.get("strength", 1.0),
                           "loudness": v.get("loudness") or "normal"}
            srcs.append("clean")
        else:
            srcs.append("take")
    r["takes"] = takes
    r["voice"] = {"source": "clean" if all(x == "clean" for x in srcs) else "take" if all(x == "take" for x in srcs)
                  else "mixed", "keys": keys, "chain": chains}
    f = r["frame"]
    c, tw, th = f.get("crop"), first.get("width"), first.get("height")
    if c and tw and th and (c["x"] + c["w"] > tw or c["y"] + c["h"] > th or c["w"] < 2 or c["h"] < 2):
        raise ValueError("frame.crop is larger than the take (%dx%d). Give x+w <= %d, y+h <= %d." % (tw, th, tw, th))
    fps = f.get("fps") or first.get("fps") or 30
    if f["shape"] == "source":
        w, h = first.get("width") or 1920, first.get("height") or 1080
    else:
        w, h = SHAPES[f["shape"]]
    f.update(w=int(f.get("w") or w) // 2 * 2, h=int(f.get("h") or h) // 2 * 2, fps=int(fps))
    if not r.get("style"):
        name = style_pick(os.path.dirname(s), s)[0]
        r["style"] = {"name": name, "params": {}} if name else {}
    if r["style"].get("name") and "template" not in r["style"]:
        tpl = os.path.join(styles_dir(), r["style"]["name"], "src", "template")
        if os.path.isdir(tpl):
            r["style"]["template"] = unlib_path(tpl)
    r["style"].setdefault("params", {})
    inputs = {}
    for t in takes:
        inputs[t["file"]] = None
    for p in list(keys.values()) + [x["file"] for k in ("over", "music", "sfx") for x in r.get(k) or []] + \
            ([r["cover"]["image"]] if r.get("cover") else []):
        inputs[p] = None
    for p in inputs:
        try:
            st = os.stat(ref_abs(s, p))
            inputs[p] = [st.st_size, int(st.st_mtime)]
        except OSError:
            inputs[p] = None
    r["inputs"] = inputs
    if base:
        bname = os.path.splitext(os.path.basename(base.get("edit") or ""))[0] or "the base"
        for p, was in (base.get("inputs") or {}).items():
            if p in inputs and was and inputs[p] and was != inputs[p] and not p.startswith("voice" + os.sep):
                if any(t["file"] == p for t in takes):
                    warns.append("%s changed since %s. Check that the cut times still fit before you publish."
                                 % (p, bname))
        old = (base.get("voice") or {}).get("chain") or {}
        for key, ch in chains.items():
            o = old.get(key)
            what = None
            if not o:
                what = "now cleaned" if key not in old and (base.get("voice") or {}).get("keys") is not None else None
            else:
                diff = [k for k in ("strength", "loudness", "steps") if o.get(k) != ch.get(k)]
                what = "new " + " and ".join(diff) if diff else None
            if what:
                warns.append("The clean voice changed since %s (%s). This version uses the new one." % (bname, what))
    return warns


def recipe_target(r):
    """The final loudness: the recipe's number, else the voice's own setting."""
    if r.get("loudness") is not None:
        return float(r["loudness"])
    chains = list(((r.get("voice") or {}).get("chain") or {}).values())
    return LOUDNESS_TARGET.get(chains[0].get("loudness") if chains else "normal", -14.0)


def picture_codec():
    if has_encoder("libx264"):
        # fast: the same size and VMAF (96.6) as medium on a 40 s take, 10% less CPU (2026-10-13).
        return ["-c:v", "libx264", "-crf", "18", "-preset", "fast"]
    return ["-c:v", "h264_videotoolbox", "-b:v", "20M"]


def fill_frame(w, h):
    return "scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1" % (w, h, w, h)


def render_plan(s, r, tmp, out, meas=None):
    """The picture, sound and mux commands of a render, as argv lists. Pure: no disk writes, no probes.
    meas: what the job measured ({"length": cut seconds, "music": {file: LUFS}, "voice": LUFS,
    "over": {file: seconds}, "gain": dB}); a missing value is 0, so a test can call it alone.
    tmp holds cut.mov and voice.wav (the cut stage) and gets picture.mp4 and mix.wav."""
    meas = meas or {}
    f = r["frame"]
    W, H, F = f["w"], f["h"], f["fps"]
    cover = r.get("cover")
    lead = float(cover["seconds"]) if cover else 0.0
    L = float(meas.get("length") or 0.0)
    total = L + lead
    ff_ = need_ffmpeg() if meas.get("real") else "ffmpeg"
    base = [ff_, "-nostdin", "-v", "error", "-y", "-progress", "pipe:1", "-nostats"]
    # Picture: one pass, the only lossy video encode.
    args = ["-i", os.path.join(tmp, "cut.mov")]
    chain = "[0:v]" + ("crop=%d:%d:%d:%d," % (f["crop"]["w"], f["crop"]["h"], f["crop"]["x"], f["crop"]["y"])
                       if f.get("crop") else "") + fill_frame(W, H) + ",fps=%d,format=yuv420p" % F
    graph, k = [], 1
    if cover:
        args += ["-loop", "1", "-framerate", str(F), "-t", "%.3f" % lead, "-i", ref_abs(s, cover["image"])]
        graph.append("[%d:v]%s,fps=%d,format=yuv420p,trim=duration=%.3f,setpts=PTS-STARTPTS[cv]" % (k, fill_frame(W, H), F, lead))
        graph.append(chain + ",setpts=PTS-STARTPTS[cb]")
        graph.append("[cv][cb]concat=n=2:v=1:a=0[b0]")
        k += 1
    else:
        graph.append(chain + "[b0]")
    cur = "b0"
    for i, o in enumerate(r.get("over") or []):
        p = ref_abs(s, o["file"])
        a = o.get("in", 0.0)
        if media_kind(p) == "image":
            dur = (o.get("out") or a + 3.0) - a
            args += ["-loop", "1", "-framerate", str(F), "-t", "%.3f" % dur, "-i", p]
            a = 0.0
        else:
            dur = (o["out"] - a) if o.get("out") is not None else max(0.0, float((meas.get("over") or {}).get(o["file"]) or 0) - a)
            args += ["-i", p]
        at = o["at"] + lead
        fmt = "yuva420p" if o.get("alpha") else "yuv420p"
        graph.append("[%d:v]trim=start=%.3f:end=%.3f,setpts=PTS-STARTPTS+%.3f/TB,%s,fps=%d,format=%s[o%d]"
                     % (k, a, a + dur, at, fill_frame(W, H), F, fmt, i))
        graph.append("[%s][o%d]overlay=enable='between(t,%.3f,%.3f)':eof_action=pass:format=auto[b%d]"
                     % (cur, i, at, at + dur, i + 1))
        cur = "b%d" % (i + 1)
        k += 1
    graph.append("[%s]trim=duration=%.3f,format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
                 "[vout]" % (cur, total))
    picture = base + args + ["-filter_complex", ";".join(graph), "-map", "[vout]", "-an", "-sn", "-dn",
                             "-map_chapters", "-1"] + picture_codec() + [
        "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-r", str(F), os.path.join(tmp, "picture.mp4")]
    # Sound: the voice as it is (no compressor, EQ, denoise or loudnorm), music and sfx under it.
    args = ["-i", os.path.join(tmp, "voice.wav")]
    st = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"
    music, sfx = r.get("music") or [], r.get("sfx") or []
    graph = ["[0:a]%s%s,apad=whole_dur=%.3f,atrim=0:%.3f[vo]"
             % (st, ",adelay=%d:all=1" % round(lead * 1000) if lead else "", total, total)]
    if music:
        graph[0] = graph[0].replace("[vo]", ",asplit=%d[vo]%s" % (len(music) + 1, "".join("[vk%d]" % i for i in range(len(music)))))
    mixed, k = ["[vo]"], 1
    voice_db = float(meas.get("voice") or -20.0)
    ends = sorted(m["at"] for m in music)
    for i, m in enumerate(music):
        nxt = [x for x in ends if x > m["at"] + 1e-6]
        stop = min([L] + nxt[:1])
        if m.get("out") is not None:
            stop = min(stop, m["at"] + m["out"] - m["in"])
        n = max(0.05, stop - m["at"])
        g = MUSIC_LUFS - float((meas.get("music") or {}).get(m["file"]) or MUSIC_LUFS) + float(m["gain_db"])
        fade = min(float(m["fade_out"]), n)
        args += ["-ss", "%.3f" % m["in"], "-i", ref_abs(s, m["file"])]
        # Ducked under the voice: the compressor's threshold sits duck_db under the voice's level, ratio 20.
        thr = 10 ** (max(-60.0, min(0.0, voice_db - float(m["duck_db"]) / 0.95)) / 20.0)
        graph.append("[%d:a]%s,atrim=0:%.3f,asetpts=PTS-STARTPTS,volume=%.2fdB%s,adelay=%d:all=1[m%d]"
                     % (k, st, n, g, ",afade=t=out:st=%.3f:d=%.3f" % (n - fade, fade) if fade > 0 else "",
                        round((m["at"] + lead) * 1000), i))
        graph.append("[m%d][vk%d]sidechaincompress=threshold=%.6f:ratio=20:attack=20:release=300:detection=rms[md%d]"
                     % (i, i, max(0.000976563, thr), i) if m["duck_db"] > 0 else "[m%d]anull[md%d]" % (i, i))
        if m["duck_db"] <= 0:
            graph.append("[vk%d]anullsink" % i)
        mixed.append("[md%d]" % i)
        k += 1
    for i, x in enumerate(sfx):
        args += ["-i", ref_abs(s, x["file"])]
        graph.append("[%d:a]%s,volume=%.2fdB,adelay=%d:all=1[x%d]" % (k, st, float(x["gain_db"]), round((x["at"] + lead) * 1000), i))
        mixed.append("[x%d]" % i)
        k += 1
    if len(mixed) > 1:
        graph.append("".join(mixed) + "amix=inputs=%d:duration=first:normalize=0:dropout_transition=0,atrim=0:%.3f[aout]"
                     % (len(mixed), total))
    else:
        graph.append("[vo]anull[aout]")
    sound = base + args + ["-filter_complex", ";".join(graph), "-map", "[aout]", "-c:a", "pcm_f32le", "-ar", "48000",
                           os.path.join(tmp, "mix.wav")]
    # Mux: one static gain to the target loudness (lowered when the true peak would pass -1 dBTP). No limiter.
    mux = [ff_, "-nostdin", "-v", "error", "-y", "-i", os.path.join(tmp, "picture.mp4"), "-i", os.path.join(tmp, "mix.wav"),
           "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-af", "volume=%.2fdB" % float(meas.get("gain") or 0.0),
           "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-map_chapters", "-1", "-dn", "-movflags", "+faststart",
           "-f", "mp4", out + ".part"]
    return {"picture": picture, "sound": sound, "mux": mux, "total": total}


def loudness_of(path):
    """(integrated LUFS, true peak dBTP) from one ebur128 read, cached per file and mtime."""
    st = os.stat(path)
    key = (path, st.st_size, st.st_mtime)
    if key not in LOUD_CACHE:
        cmd = [need_ffmpeg(), "-hide_banner", "-nostats", "-i", path, "-vn", "-af", "ebur128=peak=true", "-f", "null", "-"]
        if RUN_LOG is not None:
            RUN_LOG.append(cmd)
        err = subprocess.run(cmd, capture_output=True, text=True, timeout=3600).stderr
        tail = err.rsplit("Summary:", 1)[-1]
        i = re.search(r"I:\s*(-?[\d.]+|-inf)\s*LUFS", tail)
        p = re.search(r"Peak:\s*(-?[\d.]+|-inf)\s*dBFS", tail)
        val = lambda m: float("-inf") if not m or m.group(1) == "-inf" else float(m.group(1))  # noqa: E731
        LOUD_CACHE[key] = (val(i), val(p))
    return LOUD_CACHE[key]


def final_gain(target, lufs, peak):
    """One static gain to the target; lowered until the true peak is at most -1 dBTP."""
    if lufs == float("-inf"):
        return 0.0
    g = target - lufs
    if peak != float("-inf") and peak + g > TRUE_PEAK:
        g = TRUE_PEAK - peak
    return round(g, 2)


def need_disk(s, r, length):
    """Bytes a render needs: the ProRes parts of the cut, the picture and the mix, then the final."""
    f = r["frame"]
    sizes = [take_clock(os.path.join(s, t["file"])) or {} for t in r["takes"]]
    src = max(1, max((c.get("width") or 1920) * (c.get("height") or 1080) for c in sizes))
    prores = 18e6 * src * f["fps"] / (1920 * 1080 * 30.0)  # ProRes 422 at 1080p30: about 18 MB a second
    final = 1.2e6 * f["w"] * f["h"] / (1920 * 1080.0)
    return int(length * (prores + 3 * final + 48000 * 4 * 2 * 2))


def gb(n):
    return "%d GB" % max(1, round(n / 1e9)) if n >= 1e9 else "%d MB" % max(1, round(n / 1e6))


def run_step(x, timeout):
    """One step of the recipe: argv, no shell, in its cwd. Raises RenderStop with the plain reason."""
    say("TAKES_STAGE " + RENDER_STAGES["steps"])
    os.makedirs(x["cwd"], exist_ok=True)
    if RUN_LOG is not None:
        RUN_LOG.append(list(x["run"]))
    try:
        p = subprocess.Popen(x["run"], cwd=x["cwd"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True, env=job_env())
    except OSError as e:
        say("%s: %s" % (x["run"][0], e))
        raise RenderStop("the graphics step failed")
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.wait()
        raise RenderStop("the graphics step took more than %s" % span(timeout))
    for line in (out or b"").decode("utf-8", "replace").splitlines()[-20:]:
        say(line)
    if p.returncode != 0 or any(not os.path.exists(os.path.join(x["cwd"], m)) for m in x.get("makes") or []):
        raise RenderStop("the graphics step failed")


def render_words(s, r, cut, lead):
    """The final edit's words, from the takes' word times, and made_from for check_edit."""
    at, ws, made = lead, [], []
    for g in cut:
        doc = words_doc(os.path.join(s, voice_take(s, g["take"], g["kind"])["file"])) or {}
        for w in doc.get("words") or [] if is_ready(doc) else []:
            if w["end"] > g["in"] and w["start"] < g["in"] + g["len"]:
                e = {"word": w["word"], "start": round(at + max(w["start"], g["in"]) - g["in"], 3),
                     "end": round(at + min(w["end"], g["in"] + g["len"]) - g["in"], 3)}
                if w.get("filler"):
                    e["filler"] = True
                ws.append(e)
        made.append({"take": g["take"], "kind": g["kind"], "in": g["in"], "out": round(g["in"] + g["len"], 4),
                     "at": round(at, 4)})
        at += g["len"]
    return {"v": 2, "clock": "video", "source": "render_edit", "fps": r["frame"]["fps"], "duration": round(at, 3),
            "words": ws, "made_from": {"session_id": session_id(s), "cut": made}}


def write_json(path, d):
    with open(path + ".tmp", "w") as f:
        json.dump(d, f, indent=1, ensure_ascii=False)
    os.replace(path + ".tmp", path)


def render_run(job_id):
    """`--render-run . <job>`: the render job, in the session folder. Cut, steps, picture, sound, mux,
    check. Every intermediate goes as soon as the next stage used it."""
    global RUN_LOG
    s = "."
    rp = os.path.join(RENDERS, job_id + RECIPE_EXT)
    with open(rp) as f:
        r = json.load(f)
    tmp = os.path.join(RENDERS, job_id + ".tmp")
    out = os.path.join(RENDERS, job_id + ".mp4")
    RUN_LOG = []
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    try:
        # 1. Cut: each part on whole frames, ProRes parts, the voice of the same length.
        say("TAKES_STAGE " + RENDER_STAGES["cut"])
        files, clocks, voices, cut = [], [], [], []
        for g in r["cut"]:
            try:
                t = voice_take(s, g["take"], g["kind"])
            except ValueError:
                raise RenderStop("a take file is gone")
            if not os.path.isfile(t["file"]):
                raise RenderStop("a take file is gone")
            c = take_clock(t["file"])
            fps = c["fps"]
            a, b = round(g["in"] * fps) / float(fps), round(g["out"] * fps) / float(fps)
            cut.append({"take": g["take"], "kind": g["kind"], "in": a, "out": b,
                        "len": max(2, int(round((b - a) * fps))) / float(fps)})
            files.append(t["file"])
            clocks.append(c)
            key = voice_key(g["take"], g["kind"])
            mix = (r.get("voice") or {}).get("keys", {}).get(key)
            voices.append((mix, voice_offset(s, key)) if mix and os.path.exists(mix) else None)
        segs = [{"take": g["take"], "kind": g["kind"], "in": g["in"], "out": g["out"]} for g in cut]
        length = render_cut(segs, files, clocks, voices, os.path.join(tmp, "cut.mov"), os.path.join(tmp, "voice.wav"),
                            vargs=prores())
        lead = float(r["cover"]["seconds"]) if r.get("cover") else 0.0
        words = render_words(s, r, cut, lead)
        name_dir = os.path.join(EDIT_DIR, r["name"])
        os.makedirs(name_dir, exist_ok=True)
        write_json(os.path.join(name_dir, "words.json"), words)
        write_json(os.path.join(RENDERS, job_id + ".words.json"), words)
        # 2. Steps: the commands that make the picture layers.
        for x in r.get("steps") or []:
            run_step(x, step_timeout())
        for o in r.get("over") or []:
            if not os.path.isfile(ref_abs(s, o["file"])):
                raise RenderStop("a picture layer is missing (%s)" % o["file"])
        # 3. Picture, 4. sound, 5. mux.
        meas = {"length": length, "real": True,
                "over": {o["file"]: media_seconds(ref_abs(s, o["file"])) for o in r.get("over") or []
                         if o.get("out") is None and media_kind(o["file"]) != "image"},
                "music": {m["file"]: loudness_of(ref_abs(s, m["file"]))[0] for m in r.get("music") or []},
                "voice": loudness_of(os.path.join(tmp, "voice.wav"))[0]}
        if meas["voice"] == float("-inf"):
            meas["voice"] = -20.0
        for k, v in list(meas["music"].items()):
            if v == float("-inf"):
                meas["music"][k] = MUSIC_LUFS
        plan = render_plan(s, r, tmp, out, meas)
        say("TAKES_STAGE " + RENDER_STAGES["picture"])
        run_ff(plan["picture"], plan["total"])
        os.remove(os.path.join(tmp, "cut.mov"))
        say("TAKES_STAGE " + RENDER_STAGES["sound"])
        run_ff(plan["sound"], plan["total"])
        os.remove(os.path.join(tmp, "voice.wav"))
        lufs, peak = loudness_of(os.path.join(tmp, "mix.wav"))
        meas["gain"] = final_gain(recipe_target(r), lufs, peak)
        if lufs != float("-inf"):
            r["mix"] = {"target": recipe_target(r), "lufs": round(lufs + meas["gain"], 1),
                        "true_peak": round(peak + meas["gain"], 1) if peak != float("-inf") else None}
        plan = render_plan(s, r, tmp, out, meas)
        RUN_LOG.append(plan["mux"])
        mx = subprocess.run(plan["mux"], capture_output=True, text=True)
        if mx.returncode != 0:
            raise ValueError("ffmpeg: " + ((mx.stderr or "").strip().splitlines() or ["failed"])[-1])
        os.replace(out + ".part", out)
        shutil.rmtree(tmp, ignore_errors=True)
        # 6. Check: check_edit's checks, with this recipe's parent for the line of versions.
        say("TAKES_STAGE " + RENDER_STAGES["check"])
        entry = check_file(s, os.path.relpath(out, s), out, as_rel=lineage_rel(r))
        try:
            start_review(s, out)  # Gemini watches it while the agent reads the checks; publish_edit returns it
        except (ValueError, OSError):
            pass
        r.update(checks={"passed": entry["passed"], "known": entry["known"], "source": entry["source"],
                         "results": entry["results"]},
                 commands=[[str(x) for x in c] for c in RUN_LOG], length_s=round(plan["total"], 3),
                 rendered=now_iso())
        write_json(rp, r)
        say("TAKES_PROGRESS 1")
        say("TAKES_STAGE " + RENDER_DONE)
    finally:
        RUN_LOG = None
        shutil.rmtree(tmp, ignore_errors=True)
        for p in (out + ".part",):
            if os.path.exists(p):
                os.remove(p)


def render_failed(e):
    """The line the Jobs row shows for a render that stopped."""
    if isinstance(e, RenderStop):
        why = str(e)
    elif isinstance(e, OSError) and getattr(e, "errno", None) == 28 or "No space left" in str(e):
        why = "the disk is full"
    else:
        why = "Takes could not make it (%s)" % str(e)[:100]
    return "Stopped: %s. Nothing was saved. Ask Takes in the chat to try again." % why


def lineage_rel(r):
    """The path the version after the recipe's parent would have: check_edit's regression check reads
    the line of versions from it."""
    p = r.get("parent")
    if not p:
        return None
    b, v = edit_name_of(os.path.basename(p))
    return os.path.join("edits", "%s-v%d.mp4" % (b, (v or 0) + 1)) if b == r.get("name") else None


def renders_dir(s):
    return os.path.join(s, RENDERS)


def sweep_renders(s):
    """Renders never published, older than 7 days, go to the Trash. A running one stays, and so does one
    a claimed recipe in edits/ names."""
    d = renders_dir(s)
    if not os.path.isdir(d):
        return
    busy = set(claimed_outputs(s).values())
    for f in os.listdir(d):
        # A render that stopped (a crash, a restart) leaves its ProRes parts: they go now, not in 7 days.
        rid = f[:-len(".tmp")] if f.endswith(".tmp") else f[:-len(".mp4.part")] if f.endswith(".mp4.part") else None
        if rid and rid not in busy:
            p = os.path.join(d, f)
            shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.remove(p)
    claimed = set()
    for vs in edit_versions(s).values():
        for e in vs.values():
            if e["recipe"]:
                try:
                    claimed.add((load_recipe(s, e["recipe"]) or {}).get("render_id"))
                except ValueError:
                    pass
    old = []
    for f in os.listdir(d):
        if not f.endswith(RECIPE_EXT):
            continue
        rid = f[:-len(RECIPE_EXT)]
        p = os.path.join(d, f)
        if rid in busy or rid in claimed or time.time() - os.path.getmtime(p) < RENDER_KEEP_DAYS * 86400:
            continue
        old += [os.path.join(d, x) for x in os.listdir(d) if x == f or x.startswith(rid + ".")]
    if old:
        try:
            trash(sorted(set(old)))
        except (OSError, subprocess.CalledProcessError):
            pass


def find_render(s, ref):
    """(job id, render recipe) for a job id or a render path."""
    ref = str(ref or "").strip()
    rid = os.path.basename(ref)
    for ext in (".mp4", RECIPE_EXT):
        if rid.endswith(ext):
            rid = rid[:-len(ext)]
    if not re.fullmatch(r"[\w.\-]+", rid or ""):
        raise ValueError("render is the job id from render_edit, e.g. job-7f3a1c.")
    r = load_recipe(s, os.path.join(RENDERS, rid + RECIPE_EXT))
    if r is None:
        for vs in edit_versions(s).values():
            for e in vs.values():
                try:
                    if e["recipe"] and e["video"] and (load_recipe(s, e["recipe"]) or {}).get("render_id") == rid:
                        raise ValueError("This render is saved already as %s." % e["video"])
                except ValueError as x:
                    if "saved already" in str(x):
                        raise
        raise ValueError("No render %s in this session. render_edit gives the job id." % ref)
    return rid, r


def check_brief(c, accepted=()):
    """{passed, results: how many, failed: [...], accepted: [...]}: a fail the agent accepted is not a fail."""
    ok = {str(x.get("rule")) for x in accepted or []}
    fails = [x for x in (c or {}).get("results") or [] if x.get("pass") is False]
    kept = [x for x in fails if str(x.get("rule") or "") in ok or str(x.get("check") or "") in ok]
    fails = [x for x in fails if x not in kept]
    return {"passed": not fails, "results": len((c or {}).get("results") or []),
            **({"failed": [check_line(x) for x in fails]} if fails else {}),
            **({"accepted": [check_line(x) for x in kept]} if kept else {})}


def check_line(x):
    return "%s (%s)" % (x.get("rule") or x.get("check"), x.get("say") or x.get("label") or x.get("text") or "failed")


def render_view(s, rid, r):
    """What render_edit and get_job say about a finished render."""
    out = {"job": rid, "render": os.path.join(RENDERS, rid + ".mp4"), "name": r.get("name"),
           "length_s": r.get("length_s"), "checks": check_brief(r.get("checks"))}
    mix = r.get("mix") or {}
    if mix.get("lufs") is not None and mix["lufs"] < mix["target"] - 1:
        # No limiter on purpose: a peak holds the whole mix down. A clean voice has its peaks evened out.
        out["warnings"] = ["The edit is at %g LUFS, not %g: its loudest peaks hold it down (Takes adds no limiter). "
                           "%s" % (mix["lufs"], mix["target"],
                                   "Clean the voice with clean_voice, then render again." if (r.get("voice") or {}).get("source") != "clean"
                                   else "Lower the loudest sound effect, then render again.")]
    out["next"] = ("Grab 3 to 5 frames of the render and look at them. Then publish_edit render=%s note=... "
                   "(one line, what the viewer notices)." % rid)
    if not out["checks"]["passed"]:
        out["next"] += (" Checks failed: fix them with render_edit base=%s changes={...}, or pass "
                        "accept=[{rule, why}] if you meant it." % r.get("name"))
    return out


def pick_base(s, a):
    """(base recipe or None, warnings) for render_edit's base, or an error that names the fix."""
    names = recipe_names(s)
    ref = a.get("base")
    if not ref:
        if len(names) > 1:
            raise ValueError("This session has %d edits: %s. Say which one with base=<name>."
                             % (len(names), ", ".join(names)))
        if not names:
            raise ValueError("No edit here has a recipe yet. Give recipe={name, cut, ...}: cut is rough_cut's "
                             "cut.")
        ref = names[0]
    name, v = edit_ref(s, ref)
    vs = edit_versions(s, name).get(name) or {}
    with_video = sorted(n for n, e in vs.items() if e["video"])
    if v is None:
        base = newest_recipe(s, name)
        if base is None:
            raise ValueError("%s has no recipe. Build it with render_edit recipe={name, cut, ...}." % name)
        v = edit_name_of(os.path.basename(base["edit"]))[1]
    else:
        if not vs.get(v, {}).get("video"):
            raise ValueError("No edit %s-v%d. get_session lists the edits." % (name, v))
        base = load_recipe(s, vs[v]["recipe"]) if vs[v]["recipe"] else None
        if base is None:
            raise ValueError("%s-v%d has no recipe. Build it with render_edit recipe={name, cut, ...}." % (name, v))
    warns = []
    newer = [n for n in with_video if n > v]
    if newer:
        top = newer[-1]
        if vs[top]["recipe"]:
            if not a.get("go_back"):
                raise ValueError("%s-v%d is old: %s-v%d is the newest. Use base=%s to build on %s-v%d, or add "
                                 "go_back=true to build on %s-v%d on purpose." % (name, v, name, top, name, name, top, name, v))
        else:
            warns.append("%s-v%d has no recipe: its changes are not in this base." % (name, top))
    return base, warns


def start_render(s, r, label, length):
    """Writes the render's recipe and starts its job: the job id. Call it under the name's lock in _edit/renders/.
    A render of the same name that runs is refused: both would use _edit/<name>/ (words.json, the steps'
    files), and each would get the other's word times and layers."""
    for o, j in claimed_outputs(s).items():
        if os.path.dirname(o) != RENDERS:
            continue
        try:
            other = load_recipe(s, os.path.join(RENDERS, j + RECIPE_EXT)) or {}
        except ValueError:
            other = {}
        if other.get("name") == r["name"]:
            raise ValueError("A render of %s runs now (%s). Wait for it with get_job id=%s wait_s=50, or stop it "
                             "with stop_job id=%s. Then call render_edit again." % (r["name"], j, j, j))
    for _ in range(20):
        rid = new_job_id(s)
        r.update(render_id=rid, job=rid)
        rp = os.path.join(renders_dir(s), rid + RECIPE_EXT)
        try:
            fd = os.open(rp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            continue
        with os.fdopen(fd, "w") as f:
            json.dump(r, f, indent=1, ensure_ascii=False)
        cmd = "%s %s --render-run . %s" % (shlex.quote(sys.executable), shlex.quote(os.path.abspath(__file__)), rid)
        try:
            start_job(s, cmd, [os.path.join(RENDERS, rid + ".mp4")], label,
                      estimate_s=int(10 + length * 1.5), job_id=rid)
        except ValueError:
            os.remove(rp)
            raise
        return rid
    raise ValueError("Takes could not start the render. Try again.")


def t_render_edit(a):
    s = job_session(a.get("session"))
    if a.get("recipe") is not None and a.get("base"):
        raise ValueError("Give recipe (a whole recipe) or base with changes, not both.")
    try:
        wait = min(max(float(a.get("wait_s") or 0), 0), RENDER_WAIT_MAX)
    except (TypeError, ValueError):
        raise ValueError("wait_s is seconds, 0 to %d." % RENDER_WAIT_MAX)
    warns, base, changed = [], None, {}
    if a.get("recipe") is not None:
        given = norm_recipe(s, a["recipe"])
        top = newest_recipe(s, given["name"])
        vids = sorted(n for n, e in (edit_versions(s, given["name"]).get(given["name"]) or {}).items() if e["video"])
        parent = os.path.join("edits", "%s-v%d.mp4" % (given["name"], vids[-1])) if vids else None
        base = top if top and parent and top.get("edit") == parent else None
    else:
        if a.get("changes") is not None and not isinstance(a["changes"], dict):
            raise ValueError('changes is a JSON merge patch, e.g. {"music": [{...whole entry...}]}.')
        base, warns = pick_base(s, a)
        changes = a.get("changes") or {}
        merged = merge_patch(agent_part(base), changes)
        given = norm_recipe(s, merged)
        parent = base["edit"]
        steps_given = "steps" in changes
        try:
            was = norm_recipe(s, agent_part(base))
        except ValueError:
            was = agent_part(base)  # a file of the base is gone: only the merged recipe must be whole
        changed = recipe_diff(was, given)
        warns += unnamed_changes(changed, changes)
        if base.get("steps") and not steps_given and base.get("host") != host_id():
            raise ValueError("%s came from another Mac. Its steps did not run. Pass steps again to run them."
                             % os.path.splitext(os.path.basename(base["edit"]))[0])
    r = dict(given)
    check_recipe(s, r)
    warns += fill_recipe(s, r, base)
    length = sum(max(2, frames(g["out"] - g["in"], r["frame"]["fps"])) / float(r["frame"]["fps"]) for g in r["cut"])
    sweep_renders(s)
    need = need_disk(s, r, length)
    free = shutil.disk_usage(s).free
    if free < need:
        raise ValueError("Not enough free disk: this render needs about %s, %s is free." % (gb(need), gb(free)))
    if not r.get("cover"):
        covered = [PLATFORMS[p]["name"] for p in ("linkedin", "x", "youtube", "vertical")
                   if (post_file(s, p) or ({}, ""))[0].get("cover")]
        if covered:
            warns.append("The %s post has a cover, and this version has none. Add cover to the recipe to keep it."
                         % " and ".join(covered))
    os.makedirs(renders_dir(s), exist_ok=True)
    os.makedirs(os.path.join(s, EDIT_DIR, r["name"]), exist_ok=True)
    r.update(recipe=1, parent=parent, by="render_edit", host=host_id(), started=now_iso())
    label = ("New version of %s" % r["name"])[:60]
    import fcntl
    with open(os.path.join(renders_dir(s), ".%s.lock" % r["name"]), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rid = start_render(s, r, label, length)
    out = {"job": rid, "render": os.path.join(RENDERS, rid + ".mp4"), "base": parent, "name": r["name"],
           "length_s": round(length + (r["cover"]["seconds"] if r.get("cover") else 0), 3), "changed": changed,
           "runs": [x["run"] for x in r.get("steps") or []], "warnings": warns}
    end = time.time() + wait
    status = "running"
    while wait and time.time() < end:
        b = t_get_job({"id": rid, "session": s, "wait_s": min(JOB_WAIT_MAX, max(0.0, end - time.time()))})
        status = b["status"]
        if status not in ("starting", "running"):
            break
    if status == "done":
        r2 = load_recipe(s, os.path.join(RENDERS, rid + RECIPE_EXT))
        view = render_view(s, rid, r2)
        warns += view.pop("warnings", [])
        out.update(view, status="done", warnings=warns)
    elif status in ("starting", "running"):
        out.update(status="running", next="get_job id=%s wait_s=50 until it is done. Then grab 3 to 5 frames of the "
                                          "render and look at them. Then publish_edit render=%s note=..." % (rid, rid))
    else:
        b = t_get_job({"id": rid, "session": s})
        out.update(status=b["status"], error=b.get("error"), log_tail=b.get("log_tail"),
                   next=b.get("next") or "Fix the recipe and call render_edit again.")
    return with_rules(out, *EDIT_AREAS)


def link_noclobber(src, dst):
    """Move src to dst, never over a file that is there (FileExistsError). A hard link first; on another
    volume: create dst exclusively, copy, then remove src."""
    try:
        os.link(src, dst)
    except FileExistsError:
        raise
    except OSError:
        fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        os.close(fd)
        try:
            shutil.copyfile(src, dst)
        except BaseException:
            os.remove(dst)
            raise
    os.unlink(src)


def freeze_sources(s, name, n):
    """A copy of _edit/<name>/ as it was for version n: a clone per file where the disk can, else a copy.
    Returns (frozen folder, files over 1 GB that were left out)."""
    src = os.path.join(s, EDIT_DIR, name)
    dst = os.path.join(src, ".versions", "v%d" % n)
    skipped = []
    if not os.path.isdir(src):
        return None, skipped
    for dirpath, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in FREEZE_SKIP]
        rel = os.path.relpath(dirpath, src)
        for f in files:
            p = os.path.join(dirpath, f)
            r = os.path.normpath(os.path.join(rel, f))
            if os.path.islink(p) or f.startswith("._"):  # ._ files: macOS's own on exFAT and network disks
                continue
            if os.path.getsize(p) > FREEZE_MAX:
                skipped.append(os.path.join(EDIT_DIR, name, r))
                continue
            q = os.path.join(dst, r)
            os.makedirs(os.path.dirname(q), exist_ok=True)
            if not clone_file(p, q):
                shutil.copy2(p, q)
    return os.path.relpath(dst, s), skipped


def clone_file(src, dst):
    """An APFS clone (cp -c): no space until one side changes. False when the disk cannot clone."""
    try:
        return subprocess.run(["/bin/cp", "-c", src, dst], capture_output=True, timeout=120).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def move_check(s, old, new, mtime):
    """checks.json: the render's entry goes to the new version's path."""
    import fcntl
    cp = os.path.join(s, "checks.json")
    with open(os.path.join(s, ".checks.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            try:
                with open(cp) as fh:
                    saved = json.load(fh)
                if not isinstance(saved, dict):
                    return
            except (OSError, ValueError):
                return
            e = saved.pop(old, None)
            if not isinstance(e, dict):
                return
            saved[new] = dict(e, mtime=mtime)
            tmp = os.path.join(s, ".checks.json.tmp")
            with open(tmp, "w") as fh:
                json.dump(saved, fh, indent=2, ensure_ascii=False)
            os.replace(tmp, cp)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def video_shape(path):
    """-1 tall, 1 wide, 0 square (same bands as Cover.shape), None when it cannot tell."""
    c = take_clock(path) if path and media_kind(path) == "video" else None
    if not c or not c.get("width") or not c.get("height"):
        return None
    r = c["width"] / float(c["height"])
    return -1 if r < 0.85 else 1 if r > 1.18 else 0


def set_post_media(s, p, rel, cover=None):
    """A post's media, written by Takes (media_by: takes): publish_edit may move it on later. cover: the
    recipe's cover image, or False to remove it. The text stays."""
    f = post_file(s, p)
    if f is None:
        return
    fm, body = f
    fm["media"], fm["media_by"] = rel, "takes"
    if cover is not None:
        fm["cover"] = cover or None
        fm.pop("cover_from", None)
        fm.pop("cover_video", None)
    write_post_file(s, fm, body, p)


def posts_before(s):
    """{platform: (front matter, the file it shows now)} for each post with a file. A vertical post with no
    pick shows the newest tall edit, as the app does (PostFile.newestPortrait)."""
    out = {}
    for p in ("linkedin", "x", "youtube", "vertical"):
        f = post_file(s, p)
        if f is None:
            continue
        fm = f[0]
        if p == "vertical" and not (fm.get("media") and os.path.exists(os.path.join(s, fm["media"]))):
            d = os.path.join(s, "edits")
            tall = sorted((os.path.join(d, x) for x in os.listdir(d) if media_kind(x) == "video" and not x.startswith("."))
                          if os.path.isdir(d) else [], key=os.path.getmtime, reverse=True)
            out[p] = (fm, next((x for x in tall if video_shape(x) == -1), None))
        else:
            out[p] = (fm, post_media(s, fm, p))
    return out


def move_posts(s, before, name, new_rel, recipe):
    """Puts the new version on the posts that follow this edit. A post the user starred stays."""
    out = {}
    new_abs = os.path.join(s, new_rel)
    shape = video_shape(new_abs)
    cover = (recipe.get("cover") or {}).get("image") or False
    for p, (fm, shows) in before.items():
        shows_rel = os.path.relpath(shows, s) if shows else None
        mine = not fm.get("media") or fm.get("media_by") == "takes"
        li = before.get("linkedin", ({}, None))[0]
        if p == "x" and not fm.get("media") and li.get("media") and li.get("media_by") != "takes":
            mine = False  # X shows the LinkedIn post's pick: The user's star there holds X too
        if not mine:
            out[p] = "%s (kept: The user picked it)" % (fm.get("media") or shows_rel)
            continue
        b, v = edit_name_of(os.path.basename(shows_rel)) if shows_rel else (None, None)
        same_line = shows_rel and os.path.dirname(shows_rel) == "edits" and b == name
        fits = {"vertical": shape == -1, "youtube": shape == 1}.get(p, True)
        if same_line or (not shows_rel and fits):
            if not fits and p in ("vertical", "youtube"):
                out[p] = "%s (kept: other shape)" % shows_rel
                continue
            set_post_media(s, p, new_rel, cover)
            out[p] = new_rel
        elif shows_rel:
            if not fm.get("media"):  # no pick: it would jump to the newest file, so it keeps what it showed
                set_post_media(s, p, shows_rel)
            out[p] = "%s (kept: %s)" % (shows_rel, "other shape" if not fits else "another edit")
        else:
            out[p] = "nothing (kept: other shape)"
    return out


def t_publish_edit(a):
    s = resolve_session(a.get("session"))
    note = " ".join(str(a.get("note") or "").split())
    if not note:
        raise ValueError("Give note: one short line the user reads under the edit, e.g. 'Music softer. Cut the "
                         "restart at 0:41.'")
    if len(note) > NOTE_MAX:
        raise ValueError("note is too long: at most %d characters." % NOTE_MAX)
    d = renders_dir(s)
    if not os.path.isdir(d):
        find_render(s, a.get("render"))  # no render here: its error names the fix
    import fcntl
    with open(os.path.join(d, ".publish.lock"), "a") as lock:
        # One publish at a time: a retry of the same render waits, then finds it saved.
        fcntl.flock(lock, fcntl.LOCK_EX)
        return publish_render(s, a, note)


def publish_render(s, a, note):
    """publish_edit after its note checks, under the session's publish lock."""
    rid, r = find_render(s, a.get("render"))
    render = os.path.join(s, RENDERS, rid + ".mp4")
    name = r["name"]
    vs = edit_versions(s, name).get(name) or {}
    done = next((n for n, e in vs.items() if e["recipe"] and e["video"]
                 and (load_recipe(s, e["recipe"]) or {}).get("render_id") == rid), None)
    if done is not None:
        raise ValueError("This render is saved already as edits/%s-v%d.mp4." % (name, done))
    if not r.get("checks") or not os.path.isfile(render):
        try:
            _, job = find_job(rid, s)
        except ValueError:
            job = {"status": "lost"}
        if job["status"] in ("starting", "running"):
            raise ValueError("The render is not done. get_job id=%s wait_s=50, then call again." % rid)
        raise ValueError("The render %s did not finish (%s). Render again with render_edit."
                         % (rid, job.get("error") or job["status"]))
    # Checks: the render ran them; a fail must be fixed or accepted.
    accept = a.get("accept") or []
    if not isinstance(accept, list) or not all(isinstance(x, dict) and x.get("rule") and str(x.get("why") or "").strip()
                                               for x in accept):
        raise ValueError("accept is [{rule, why}]: the check or rule id, and why you keep it.")
    ok = {str(x["rule"]) for x in accept}
    fails = [x for x in r["checks"].get("results") or [] if x.get("pass") is False
             and str(x.get("rule") or "") not in ok and str(x.get("check") or "") not in ok]
    if fails:
        raise ValueError("%d check%s fail%s on the render: %s. Fix %s with render_edit base=%s changes={...}, or pass "
                         "accept=[{rule, why}] if you meant it. Nothing was saved."
                         % (len(fails), "" if len(fails) == 1 else "s", "s" if len(fails) == 1 else "",
                            ", ".join(check_line(x) for x in fails), "it" if len(fails) == 1 else "them", name))
    # A version saved while this render ran: its fixes are not in it.
    pv = edit_name_of(os.path.basename(r["parent"]))[1] if r.get("parent") and \
        edit_name_of(os.path.basename(r["parent"]))[0] == name else 0
    started = parse_iso(r.get("started") or "")
    if not a.get("go_back") and started:
        for n in sorted(vs):
            e = vs[n]
            if n <= (pv or 0) or not e["video"]:
                continue
            made = None
            if e["recipe"]:
                try:
                    made = parse_iso((load_recipe(s, e["recipe"]) or {}).get("made") or "")
                except ValueError:
                    made = None
            if made is None:
                made = datetime.fromtimestamp(os.path.getmtime(os.path.join(s, e["video"])), timezone.utc)
            if made >= started:
                raise ValueError("%s-v%d was saved while this render ran, and its changes are not in it. Render again "
                                 "with base=%s." % (name, n, name))
    replies = a.get("replies") or []
    if not isinstance(replies, list):
        raise ValueError("replies is a list: [{id, text, lesson, rule?}], as in reply_comment.")
    if replies:
        by_id = {c["id"]: c for c in read_comments(s)["comments"]}
        bad = [str(x.get("id")) for x in replies if not isinstance(x, dict) or x.get("id") not in by_id]
        if bad:
            raise ValueError("No comment %s. Use get_comments. Nothing was saved." % ", ".join(bad))
        bare = [x["id"] for x in replies if not x.get("lesson") and by_id[x["id"]].get("status") != "resolved"]
        if bare:
            raise ValueError("Give each reply a lesson (%s): a rule id from get_rules, 'new' with rule={area, text}, "
                             "or 'one-off'. Nothing was saved." % ", ".join(bare))
    before = posts_before(s)
    d = os.path.join(s, "edits")
    os.makedirs(d, exist_ok=True)
    rec = dict(r, note=note, fixed=[x["id"] for x in replies], accepted=[{"rule": x["rule"], "why": x["why"]} for x in accept])
    rec.pop("job", None)
    # Claim the version (a recipe with no video), then move the render in without overwriting anything.
    claim = next((n for n, e in vs.items() if e["recipe"] and not e["video"]
                  and (load_recipe(s, e["recipe"]) or {}).get("render_id") == rid), None)
    n = claim
    for _ in range(100):
        mine = n is None
        if n is None:
            used = set(versions_in(d, name)) | {edit_name_of(os.path.basename(o))[1] for o in claimed_outputs(s)
                                                 if os.path.dirname(o) == "edits" and edit_name_of(os.path.basename(o))[0] == name}
            n = max([0] + [x for x in used if x]) + 1
            rec.update(edit=os.path.join("edits", "%s-v%d.mp4" % (name, n)), made=now_iso())
            try:
                fd = os.open(os.path.join(d, "%s-v%d%s" % (name, n, RECIPE_EXT)), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            except FileExistsError:
                n = None
                continue
            with os.fdopen(fd, "w") as f:
                json.dump(rec, f, indent=1, ensure_ascii=False)
        else:
            rec.update(edit=os.path.join("edits", "%s-v%d.mp4" % (name, n)), made=now_iso())
        try:
            link_noclobber(render, os.path.join(d, "%s-v%d.mp4" % (name, n)))
            break
        except FileNotFoundError:
            if os.path.exists(render):
                raise
            if mine:  # the render went (another publish took it): no claim stays behind
                os.remove(os.path.join(d, "%s-v%d%s" % (name, n, RECIPE_EXT)))
            raise ValueError("The render %s is gone. get_session shows the edits; render again with render_edit."
                             % rid)
        except FileExistsError:
            # Another writer (the app's Cover, a next_path render) took this N: our claim goes, N+1.
            try:
                os.remove(os.path.join(d, "%s-v%d%s" % (name, n, RECIPE_EXT)))
            except OSError:
                pass
            n = None
    else:
        raise ValueError("Takes could not find a free version for %s. Try again." % name)
    new_rel = os.path.join("edits", "%s-v%d.mp4" % (name, n))
    new_abs = os.path.join(s, new_rel)
    os.utime(new_abs, None)
    wsrc = os.path.join(s, RENDERS, rid + ".words.json")
    if os.path.exists(wsrc):
        shutil.copyfile(wsrc, os.path.join(d, "%s-v%d.words.json" % (name, n)))
    frozen, skipped = freeze_sources(s, name, n)
    rec.update(src=frozen, src_skipped=skipped)
    write_json(os.path.join(d, "%s-v%d%s" % (name, n, RECIPE_EXT)), rec)
    move_check(s, os.path.join(RENDERS, rid + ".mp4"), new_rel, os.path.getmtime(new_abs))
    for p in (os.path.join(s, RENDERS, rid + RECIPE_EXT), wsrc):
        try:
            os.remove(p)
        except OSError:
            pass
    posts = move_posts(s, before, name, new_rel, rec)
    out = {"edit": new_rel, "version": n, "recipe": recipe_path(new_rel), "checks": check_brief(rec["checks"], accept),
           "posts": posts}
    try:
        out["review"] = review_result(s, new_abs, start_review(s, new_abs), time.time() + 45)
    except (ValueError, OSError, subprocess.SubprocessError):
        pass
    if replies:
        try:
            t_reply_comment({"session": s, "replies": [dict(x, fixed_in=new_rel, resolve=True) for x in replies]})
            out["replied"] = [x["id"] for x in replies]
        except ValueError as e:
            out["replies_error"] = "%s The version is saved: answer them with reply_comment." % e
    out["open_comments"] = sum(1 for c in read_comments(s)["comments"] if c.get("status") != "resolved")
    open_in_app(new_abs)
    out["note"] = "The user sees %s-v%d in the app now." % (name, n)
    return with_rules(out, *EDIT_AREAS)


def t_get_edit_recipe(a):
    s = resolve_session(a["session"])
    ref = a.get("edit")
    if not ref:
        names = recipe_names(s)
        if not names:
            raise ValueError("No edit here has a recipe yet. render_edit + publish_edit make one.")
        newest = max(((newest_recipe(s, n) or {}) for n in names), key=lambda x: x.get("made") or "")
        ref = newest.get("edit")
    r = read_recipe(s, ref)
    if r is None:
        raise ValueError("%s has no recipe. Edits made before recipes have none: render_edit recipe={...} builds "
                         "the next version with one." % ref)
    lineage, missing = recipe_lineage(s, r)
    name, v = edit_name_of(os.path.basename(r.get("edit") or ""))
    newer = sorted((e["video"] for n, e in (edit_versions(s, name).get(name) or {}).items()
                    if e["video"] and n > (v or 0)), key=lambda x: edit_name_of(os.path.basename(x))[1])
    return {"recipe": r, "lineage": lineage, "missing": missing, "newer": newer}


def recipe_short(r):
    """get_session's form: only the fields the agent sets, the cut as a count."""
    out = {k: r.get(k) for k in ("name", "edit", "note", "frame", "over", "music", "sfx", "steps", "cover", "loudness")}
    out["cut"] = "%d parts" % len(r.get("cut") or [])
    out["full"] = "get_edit_recipe edit=%s" % os.path.splitext(os.path.basename(r.get("edit") or ""))[0]
    return out


def session_recipes(s):
    """get_session's edit_recipe, edit_log and note. {} without edits."""
    vers = edit_versions(s)
    if not any(e["video"] for vs in vers.values() for e in vs.values()):
        return {}
    shorts, log = [], []
    for name in sorted(vers):
        try:
            r = newest_recipe(s, name)
        except ValueError as e:
            shorts.append({"name": name, "error": str(e)})
            continue
        if r:
            shorts.append(recipe_short(r))
        for n, e in vers[name].items():
            if e["video"] and e["recipe"]:
                try:
                    x = load_recipe(s, e["recipe"]) or {}
                except ValueError:
                    continue
                log.append({"edit": e["video"], "note": x.get("note"), "made": x.get("made")})
    if not shorts:
        return {"edit_recipe": None,
                "edit_recipe_note": "No recipe yet. Build the next version with render_edit recipe={...}: from then "
                                    "on each version starts from the one before."}
    log.sort(key=lambda x: x.get("made") or "", reverse=True)
    return {"edit_recipe": shorts[0] if len(shorts) == 1 else shorts, "edit_log": log[:5]}


def recipe_note(video):
    """The note of an edit's recipe, or None."""
    try:
        with open(recipe_path(video)) as f:
            n = json.load(f).get("note")
        return n if isinstance(n, str) else None
    except (OSError, ValueError, AttributeError):
        return None


# ---------- export to Resolve / Premiere (2026-10-18) ----------
# export_edit (and the app's "Export for Resolve / Premiere…" on an edit) turns a version's recipe into
# a timeline other editors open: edits/<name>-vN.fcpxml (FCPXML 1.10: DaVinci Resolve, Final Cut Pro),
# edits/<name>-vN.premiere.xml (Final Cut Pro 7 XML: Premiere Pro, Resolve) and edits/<name>-vN.edl
# (CMX3600, the picture cut only). They sit next to the version like its recipe, and an export again
# writes them again (they are made from the recipe, never edited by hand).
# Tracks: V1 the cut (each part's take file, picture only), V2+ the picture layers, A1 the voice, A2 the
# music, A3 the sfx. The voice is a WAV on the video clock, so Resolve needs no audio offset: the clean
# voice when the recipe used it, else the take's own sound, written once to _edit/.audio/<take>.wav with
# extract_voice (a NLE may not apply the camera's 0.16-0.24 s audio start). The cover, the crop, the loudness,
# music ducking and fades, and the steps that made the layers stay out: the result lists them.
# Times: the cut on whole frames of the edit, as render_run cuts it. The timeline starts at 01:00:00:00.

from fractions import Fraction  # noqa: E402
import xml.etree.ElementTree as ET  # noqa: E402

EXPORT_EXTS = (".fcpxml", ".premiere.xml", ".edl")
EXPORT_AUDIO = os.path.join(EDIT_DIR, ".audio")
EXPORT_TC_HOURS = 1


def export_paths(video):
    """edits/x-v5.mp4 -> {".fcpxml": edits/x-v5.fcpxml, ...}"""
    stem = os.path.splitext(video)[0]
    return {ext: stem + ext for ext in EXPORT_EXTS}


def take_wav(s, t, clock):
    """The take's own sound as a WAV on the video clock, made once (again when the take changed)."""
    out = os.path.join(s, EXPORT_AUDIO, os.path.splitext(os.path.basename(t["file"]))[0] + ".wav")
    src = os.path.join(s, t["file"])
    if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
        return out
    os.makedirs(os.path.dirname(out), exist_ok=True)
    part = out[:-4] + ".part.wav"
    extract_voice(src, part, channels=min(2, int(clock.get("channels") or 1)), codec="pcm_s24le")
    os.replace(part, out)
    return out


def layer_file(s, r, ref):
    """A layer's file as this version used it: the frozen copy of _edit/<name>/ when publish_edit made one."""
    mine = os.path.join(EDIT_DIR, r.get("name") or "", "")
    if r.get("src") and ref.startswith(mine):
        frozen = os.path.join(s, r["src"], ref[len(mine):])
        if os.path.exists(frozen):
            return frozen
    return ref_abs(s, ref)


def export_plan(s, r, clock=None, seconds=None, wav=None):
    """The edit as tracks: {name, fps, w, h, frames, media, video: [track], audio: [track], left_out,
    warnings}. A clip is {media, at, len} in frames of the edit, with src (seconds of its file, a Fraction)
    and gain_db. clock/seconds/wav: take_clock, media_seconds and take_wav, swapped in tests."""
    clock, seconds, wav = clock or take_clock, seconds or media_seconds, wav or take_wav
    f = r.get("frame") or {}
    media, ids = {}, {}
    left, warns = [], []

    def add(path, **kw):
        path = os.path.abspath(path)
        if path not in ids:
            ids[path] = "m%d" % (len(ids) + 1)
            media[ids[path]] = dict({"path": path, "name": os.path.basename(path)}, **kw)
        return ids[path]

    # V1 and A1: the cut, on whole frames as render_run and render_cut cut it.
    cut, voices = [], []
    first = None
    for i, g in enumerate(r.get("cut") or []):
        try:
            t = voice_take(s, g["take"], g.get("kind"))
        except ValueError:
            t = None
        p = os.path.join(s, t["file"]) if t else None
        c = clock(p) if p and os.path.isfile(p) else None
        if not c:
            raise ValueError("cut[%d]: take %s is gone, so this edit cannot be exported." % (i, g.get("take")))
        first = first or c
        fs = c["fps"]
        a, b = Fraction(round(g["in"] * fs), fs), Fraction(round(g["out"] * fs), fs)
        n = max(2, frames(float(b - a), first["fps"]))
        vid = add(p, video=True, audio=c.get("audio_offset_s") is not None, fps=fs, w=c.get("width"),
                  h=c.get("height"), channels=c.get("channels") or 0, seconds=c.get("duration"))
        cut.append({"media": vid, "src": a, "secs": Fraction(n, first["fps"]), "take": t, "clock": c,
                    "kind": t["kind"]})
    F = int(f.get("fps") or first["fps"])
    W, H = int(f.get("w") or first.get("width") or 1920), int(f.get("h") or first.get("height") or 1080)
    at = Fraction(0)
    keys = (r.get("voice") or {}).get("keys") or {}
    for g in cut:
        g["at"], g["len"] = int(round(at * F)), max(1, int(round((at + g["secs"]) * F)) - int(round(at * F)))
        at += g["secs"]
        key = voice_key(g["take"]["number"], g["kind"])
        mix = keys.get(key)
        if mix and os.path.isfile(os.path.join(s, mix)):
            late = Fraction(round(voice_offset(s, key) * 48000), 48000)
            path, start = os.path.join(s, mix), g["src"] - late
        elif mix:
            raise ValueError("The clean voice %s is gone, so this edit cannot be exported. Clean the voice "
                             "again (clean_voice) or render a new version." % mix)
        elif g["clock"].get("audio_offset_s") is not None:
            path, start = wav(s, g["take"], g["clock"]), g["src"]
        else:
            continue  # no sound in this part: render_cut puts silence there
        pad = 0
        if start < 0:
            pad = int(math.ceil(-start * F))
            start += Fraction(pad, F)
        if pad >= g["len"]:
            continue
        aid = add(path, audio=True, channels=1 if mix else min(2, int(g["clock"].get("channels") or 1)),
                  seconds=None)
        voices.append({"media": aid, "at": g["at"] + pad, "len": g["len"] - pad, "src": start})
    for c in voices:
        m = media[c["media"]]
        if m["seconds"] is None:
            m["seconds"] = seconds(m["path"])
    total = sum(g["len"] for g in cut)
    L = Fraction(total, F)
    video = [[{k: g[k] for k in ("media", "at", "len", "src")} for g in cut]]
    # V2+: picture layers, each on the lowest track where it fits.
    for i, o in enumerate(r.get("over") or []):
        p = layer_file(s, r, o["file"])
        if not os.path.isfile(p):
            left.append("over[%d] (%s): the file is gone" % (i, o["file"]))
            continue
        src = Fraction(o.get("in") or 0).limit_denominator(48000)
        if media_kind(p) == "image":
            dur = (o.get("out") or float(src) + 3.0) - float(src)
            mid, src = add(p, video=True, still=True, w=None, h=None, fps=F, seconds=None), Fraction(0)
        else:
            dur = (o["out"] - float(src)) if o.get("out") is not None else max(0.0, seconds(p) - float(src))
            c = clock(p) or {}
            mid = add(p, video=True, audio=False, fps=c.get("fps") or F, w=c.get("width"), h=c.get("height"),
                      seconds=c.get("duration"))
        a0 = int(round(o["at"] * F))
        n = min(int(round((o["at"] + dur) * F)), total) - a0
        if n <= 0:
            left.append("over[%d] (%s): it starts after the cut ends" % (i, o["file"]))
            continue
        clip = {"media": mid, "at": a0, "len": n, "src": src}
        for tr in video[1:]:
            if all(x["at"] + x["len"] <= a0 or x["at"] >= a0 + n for x in tr):
                tr.append(clip)
                break
        else:
            video.append([clip])
    # A2: music, cut as render_plan cuts it (one song at a time, to the next song or the end).
    music, sfx = r.get("music") or [], r.get("sfx") or []
    starts = sorted(m["at"] for m in music)
    mtrack = []
    for i, m in enumerate(music):
        p = ref_abs(s, m["file"])
        if not os.path.isfile(p):
            left.append("music[%d] (%s): the file is gone" % (i, m["file"]))
            continue
        nxt = [x for x in starts if x > m["at"] + 1e-6]
        stop = min([float(L)] + nxt[:1])
        if m.get("out") is not None:
            stop = min(stop, m["at"] + m["out"] - m["in"])
        a0 = int(round(m["at"] * F))
        n = int(round(stop * F)) - a0
        if n > 0:
            mtrack.append({"media": add(p, audio=True, channels=2, seconds=seconds(p)), "at": a0, "len": n,
                           "src": Fraction(m.get("in") or 0).limit_denominator(48000), "gain_db": m.get("gain_db")})
    xtrack = []
    for i, x in enumerate(sfx):
        p = ref_abs(s, x["file"])
        if not os.path.isfile(p):
            left.append("sfx[%d] (%s): the file is gone" % (i, x["file"]))
            continue
        a0 = int(round(x["at"] * F))
        n = min(int(round((x["at"] + seconds(p)) * F)), total) - a0
        if n > 0:
            xtrack.append({"media": add(p, audio=True, channels=2, seconds=seconds(p)), "at": a0, "len": n,
                           "src": Fraction(0), "gain_db": x.get("gain_db")})
    audio = [voices] + [tr for tr in (mtrack, xtrack) if tr]
    if r.get("cover"):
        left.append("the cover (%s): it shows %gs before the cut in the mp4; the timeline starts at the cut"
                    % (r["cover"]["image"], r["cover"]["seconds"]))
    if f.get("crop"):
        left.append("the crop (frame.crop): the takes fill the frame from the centre; set the crop in the editor")
    elif f.get("shape") not in (None, "source") and (W, H) != (first.get("width"), first.get("height")):
        warns.append("The takes fill the %dx%d frame from the centre, as in the mp4." % (W, H))
    if music:
        left.append("the music's loudness match, ducking under the voice and fade-out: the music sits at its "
                    "own level plus gain_db")
    left.append("the final loudness (%g LUFS in the mp4)" % recipe_target(r))
    if r.get("steps"):
        left.append("the steps that made the picture layers: their renders are on V2 and up")
    if r.get("over"):
        warns.append("Picture layers are their rendered files (captions, motion graphics): they are not editable text.")
    for p, was in (r.get("inputs") or {}).items():
        try:
            st = os.stat(ref_abs(s, p))
            now = [st.st_size, int(st.st_mtime)]
        except OSError:
            continue
        if was and now != was and not p.startswith(EDIT_DIR + os.sep):
            warns.append("%s changed since this version was made: the timeline uses the file as it is now." % p)
    return {"name": os.path.splitext(os.path.basename(r.get("edit") or r.get("name") or "edit"))[0],
            "fps": F, "w": W // 2 * 2, "h": H // 2 * 2, "frames": total, "media": media, "video": video,
            "audio": audio, "left_out": left, "warnings": warns}


def fx_time(x):
    """A time as FCPXML writes it: '0s', '3s', '1001/30000s'."""
    x = Fraction(x)
    return "%ds" % x.numerator if x.denominator == 1 else "%d/%ds" % (x.numerator, x.denominator)


def file_url(path):
    return "file://" + urllib.parse.quote(os.path.abspath(path))


def fcpxml_of(tl):
    """FCPXML 1.10 of an export_plan timeline: a library > event > project > sequence. V1 is the spine; every
    other clip is anchored to the V1 clip under its start (lane 2+ picture, -1 voice, -2 music, -3 sfx)."""
    F = tl["fps"]
    fr = lambda n: Fraction(n, F)  # noqa: E731
    root = ET.Element("fcpxml", version="1.10")
    res = ET.SubElement(root, "resources")
    ET.SubElement(res, "format", id="r0", name="Takes %dx%d %dp" % (tl["w"], tl["h"], F),
                  frameDuration=fx_time(Fraction(1, F)), width=str(tl["w"]), height=str(tl["h"]),
                  colorSpace="1-1-1 (Rec. 709)")
    fmts = {}
    for mid, m in tl["media"].items():
        if m.get("video") and not m.get("still"):
            key = (m.get("w") or tl["w"], m.get("h") or tl["h"], m.get("fps") or F)
            if key not in fmts:
                fmts[key] = "r%d" % (len(fmts) + 1)
                ET.SubElement(res, "format", id=fmts[key], frameDuration=fx_time(Fraction(1, key[2])),
                              width=str(key[0]), height=str(key[1]))
    heard = {c["media"] for tr in tl["audio"] for c in tr}
    for mid, m in tl["media"].items():
        a = {"id": mid, "name": m["name"], "start": "0s"}
        if m.get("seconds"):
            grid = m.get("fps") or F if m.get("video") else 48000
            a["duration"] = fx_time(Fraction(int(m["seconds"] * grid), grid))
        if m.get("video"):
            a["hasVideo"] = "1"
            a["videoSources"] = "1"
            if not m.get("still"):
                a["format"] = fmts[(m.get("w") or tl["w"], m.get("h") or tl["h"], m.get("fps") or F)]
        # A take used only for picture says it has no sound: Resolve ignores srcEnable="video" and lays the
        # camera's sound on A1 beside the voice WAV, a doubled voice 0.2 s apart (seen in Resolve 21, 2026-10-18).
        if m.get("audio") and mid in heard:
            a.update(hasAudio="1", audioSources="1", audioChannels=str(m.get("channels") or 2), audioRate="48000")
        el = ET.SubElement(res, "asset", a)
        ET.SubElement(el, "media-rep", kind="original-media", src=file_url(m["path"]))
    lib = ET.SubElement(root, "library")
    ev = ET.SubElement(lib, "event", name="Takes")
    pr = ET.SubElement(ev, "project", name=tl["name"])
    seq = ET.SubElement(pr, "sequence", format="r0", duration=fx_time(fr(tl["frames"])),
                        tcStart=fx_time(EXPORT_TC_HOURS * 3600), tcFormat="NDF", audioLayout="stereo", audioRate="48k")
    spine = ET.SubElement(seq, "spine")
    parents = []
    t0 = EXPORT_TC_HOURS * 3600  # the spine's time starts at the sequence's timecode, as Final Cut writes it
    for c in tl["video"][0]:
        el = ET.SubElement(spine, "asset-clip", ref=c["media"], name=tl["media"][c["media"]]["name"],
                           offset=fx_time(t0 + fr(c["at"])), start=fx_time(c["src"]), duration=fx_time(fr(c["len"])),
                           srcEnable="video", tcFormat="NDF")
        ET.SubElement(el, "adjust-conform", type="fill")
        parents.append((c, el))

    def anchor(c, lane, kind):
        p, el = next(((p, e) for p, e in reversed(parents) if p["at"] <= c["at"]), parents[0])
        off = p["src"] + fr(c["at"] - p["at"])  # in the parent's own time: its start is its first frame
        m = tl["media"][c["media"]]
        attrs = {"ref": c["media"], "lane": str(lane), "offset": fx_time(off), "name": m["name"],
                 "start": fx_time(c["src"]), "duration": fx_time(fr(c["len"]))}
        if kind == "still":
            ET.SubElement(ET.SubElement(el, "video", attrs), "adjust-conform", type="fill")
            return
        x = ET.SubElement(el, "asset-clip", dict(attrs, srcEnable="video" if kind == "video" else "audio"))
        if kind == "video":
            ET.SubElement(x, "adjust-conform", type="fill")
        elif c.get("gain_db"):
            ET.SubElement(x, "adjust-volume", amount="%gdB" % c["gain_db"])

    # Anchored items go after a clip's own adjustments: the DTD wants the conform first.
    for n, tr in enumerate(tl["video"][1:]):
        for c in tr:
            anchor(c, n + 2, "still" if tl["media"][c["media"]].get("still") else "video")
    for n, tr in enumerate(tl["audio"]):
        for c in tr:
            anchor(c, -(n + 1), "audio")
    return fcp_doc(root, "fcpxml")


def fcp_doc(root, doctype):
    ET.indent(root, "  ")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE %s>\n' % doctype
            + ET.tostring(root, encoding="unicode") + "\n")


def xmeml_of(tl):
    """Final Cut Pro 7 XML (xmeml 5) of an export_plan timeline: the format Premiere Pro imports. Times
    are frames of the edit."""
    F = tl["fps"]
    root = ET.Element("xmeml", version="5")
    seq = ET.SubElement(root, "sequence", id="sequence-1")

    def rate(el, fps=F):
        r = ET.SubElement(el, "rate")
        ET.SubElement(r, "timebase").text = str(fps)
        ET.SubElement(r, "ntsc").text = "FALSE"

    def sub(el, tag, text):
        ET.SubElement(el, tag).text = str(text)

    sub(seq, "name", tl["name"])
    sub(seq, "duration", tl["frames"])
    rate(seq)
    tc = ET.SubElement(seq, "timecode")
    rate(tc)
    sub(tc, "string", "%02d:00:00:00" % EXPORT_TC_HOURS)
    sub(tc, "frame", EXPORT_TC_HOURS * 3600 * F)
    sub(tc, "displayformat", "NDF")
    med = ET.SubElement(seq, "media")
    vid, aud = ET.SubElement(med, "video"), ET.SubElement(med, "audio")
    sc = ET.SubElement(ET.SubElement(vid, "format"), "samplecharacteristics")
    rate(sc)
    sub(sc, "width", tl["w"])
    sub(sc, "height", tl["h"])
    sub(sc, "anamorphic", "FALSE")
    sub(sc, "pixelaspectratio", "square")
    sub(sc, "fielddominance", "none")
    asc = ET.SubElement(ET.SubElement(aud, "format"), "samplecharacteristics")
    sub(asc, "depth", 24)
    sub(asc, "samplerate", 48000)
    seen, n = set(), [0]

    def clipitem(track, c, kind):
        m = tl["media"][c["media"]]
        n[0] += 1
        it = ET.SubElement(track, "clipitem", id="clipitem-%d" % n[0])
        sub(it, "name", m["name"])
        sub(it, "enabled", "TRUE")
        full = int(round((m.get("seconds") or 0) * F)) or None
        src = int(round(c["src"] * F))
        sub(it, "duration", full or src + c["len"])
        rate(it)
        sub(it, "start", c["at"])
        sub(it, "end", c["at"] + c["len"])
        sub(it, "in", src)
        sub(it, "out", src + c["len"])
        fid = "file-" + c["media"][1:]
        fe = ET.SubElement(it, "file", id=fid)
        if fid not in seen:
            seen.add(fid)
            sub(fe, "name", m["name"])
            sub(fe, "pathurl", file_url(m["path"]))
            rate(fe)
            sub(fe, "duration", full or src + c["len"])
            fm = ET.SubElement(fe, "media")
            if m.get("video"):
                s = ET.SubElement(ET.SubElement(fm, "video"), "samplecharacteristics")
                rate(s)
                if m.get("w"):
                    sub(s, "width", m["w"])
                    sub(s, "height", m["h"])
            if m.get("audio"):
                fa = ET.SubElement(fm, "audio")
                sub(ET.SubElement(fa, "samplecharacteristics"), "samplerate", 48000)
                sub(fa, "channelcount", m.get("channels") or 2)
        if kind == "audio":
            st = ET.SubElement(it, "sourcetrack")
            sub(st, "mediatype", "audio")
            sub(st, "trackindex", 1)
            if c.get("gain_db"):
                flt = ET.SubElement(ET.SubElement(it, "filter"), "effect")
                sub(flt, "name", "Audio Levels")
                sub(flt, "effectid", "audiolevels")
                sub(flt, "effectcategory", "audiolevels")
                sub(flt, "effecttype", "audiolevels")
                sub(flt, "mediatype", "audio")
                p = ET.SubElement(flt, "parameter")
                sub(p, "parameterid", "level")
                sub(p, "name", "Level")
                sub(p, "valuemin", 0)
                sub(p, "valuemax", 3.98109)
                sub(p, "value", "%.5f" % (10 ** (c["gain_db"] / 20.0)))

    for tr in tl["video"]:
        t = ET.SubElement(vid, "track")
        for c in tr:
            clipitem(t, c, "video")
    for tr in tl["audio"]:
        t = ET.SubElement(aud, "track")
        for c in tr:
            clipitem(t, c, "audio")
    return fcp_doc(root, "xmeml")


def tc_of(n, fps, hours=0):
    n += hours * 3600 * fps
    return "%02d:%02d:%02d:%02d" % (n // (3600 * fps), n // (60 * fps) % 60, n // fps % 60, n % fps)


def edl_of(tl):
    """CMX3600 of the cut (V1 only, the picture): one event per part, the source file in a comment."""
    F = tl["fps"]
    lines = ["TITLE: %s" % tl["name"][:70], "FCM: NON-DROP FRAME", ""]
    for i, c in enumerate(tl["video"][0]):
        m = tl["media"][c["media"]]
        reel = re.sub(r"[^A-Z0-9]", "", os.path.splitext(m["name"])[0].upper().replace("CAMERA", "C")
                      .replace("SCREEN", "S").replace("TAKE", "T"))[:8] or "AX"
        src = int(round(c["src"] * F))
        lines.append("%03d  %-8s V     C        %s %s %s %s" % (
            i + 1, reel, tc_of(src, F), tc_of(src + c["len"], F),
            tc_of(c["at"], F, EXPORT_TC_HOURS), tc_of(c["at"] + c["len"], F, EXPORT_TC_HOURS)))
        lines.append("* FROM CLIP NAME: %s" % m["name"])
        lines.append("* SOURCE FILE: %s" % m["path"])
        lines.append("")
    return "\n".join(lines)


def write_text(path, text):
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.replace(path + ".tmp", path)


def export_edit(s, ref):
    """Writes the three files of an edit version. Returns the tool's result."""
    name, v = edit_ref(s, ref)
    vs = edit_versions(s, name).get(name) or {}
    if v is None:
        v = max((n for n, e in vs.items() if e["video"] and e["recipe"]), default=None)
    e = vs.get(v) if v is not None else None
    if not e or not e["video"]:
        raise ValueError("No edit %s here. get_session lists the edits." % (ref or name))
    if not e["recipe"]:
        raise ValueError("%s has no recipe, so Takes does not know its cut. Edits made before recipes have none: "
                         "render_edit + publish_edit make a version with one." % e["video"])
    r = load_recipe(s, e["recipe"])
    tl = export_plan(s, r)
    tl["name"] = os.path.splitext(os.path.basename(e["video"]))[0]
    paths = export_paths(os.path.join(s, e["video"]))
    for ext, text in ((".fcpxml", fcpxml_of(tl)), (".premiere.xml", xmeml_of(tl)), (".edl", edl_of(tl))):
        write_text(paths[ext], text)
    rel = lambda p: os.path.relpath(p, s)  # noqa: E731
    out = {"edit": e["video"], "fcpxml": rel(paths[".fcpxml"]), "premiere": rel(paths[".premiere.xml"]),
           "edl": rel(paths[".edl"]), "fps": tl["fps"], "size": "%dx%d" % (tl["w"], tl["h"]),
           "length": tc_of(tl["frames"], tl["fps"]),
           "tracks": {"video": len(tl["video"]), "audio": len(tl["audio"])},
           "left_out": tl["left_out"],
           "next": "Resolve: File > Import > Timeline > the .fcpxml. Premiere: File > Import > the .premiere.xml. "
                   "Keep the session folder where it is: the timeline links the take files by path."}
    if tl["warnings"]:
        out["warnings"] = tl["warnings"]
    return out


def t_export_edit(a):
    s = resolve_session(a["session"])
    ref = a.get("edit")
    if not ref:
        names = recipe_names(s)
        if not names:
            raise ValueError("No edit here has a recipe yet. render_edit + publish_edit make one.")
        ref = max(((newest_recipe(s, n) or {}) for n in names), key=lambda x: x.get("made") or "").get("edit")
    return export_edit(s, ref)


# ---------- LinkedIn comment copilot (same format as Sources/Takes/Copilot.swift) ----------


def post_lines(text):
    """The post's text with its line breaks: trailing spaces off each line, at most one empty line."""
    lines = [l.rstrip() for l in text.replace("\r\n", "\n").replace("\u2028", "\n").split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


# <root>/_library/comments/suggestions/<id>.json holds one suggested comment: the post, the agent's
# drafts, the user's feedback and decision, and later the posted link and its numbers. lessons.md holds
# the rules in the user's words. The app shows them on the Comments board; agents add drafts here.

COMMENT_STATUSES = ["review", "feedback", "redraft", "approved", "posted", "declined"]

LESSONS_SEED = """# Comment lessons

Short rules for drafting your LinkedIn comments. Edit them in Takes (Comments > Library).
Every draft run reads this file. Newest lessons go at the top.

- Sound like a person, not a post. Fragments are fine.
- Vary the length: one line is often best.
- Pick up the author's own words and push them one step further.
- A real question or a clear disagreement beats agreement.
- No praise openers ("Love this", "So true").
"""


def life_dir():
    if os.environ.get("TAKES_LIFE"):
        return os.environ["TAKES_LIFE"]
    return os.path.expanduser("~/Documents/Takes Notes")


def comments_dir():
    return os.path.join(root(), LIB, "comments")


def suggestions_dir():
    return os.path.join(comments_dir(), "suggestions")


def lessons_path():
    """The comment copilot's lessons: rules/comments.md, with the other rules (comments/lessons.md before 2026-10-09)."""
    p = os.path.join(rules_dir(), "comments.md")
    old = os.path.join(comments_dir(), "lessons.md")
    if not os.path.exists(p):
        os.makedirs(rules_dir(), exist_ok=True)
        try:
            os.replace(old, p)
        except FileNotFoundError:
            write_text(p, LESSONS_SEED)
    elif os.path.exists(old):
        # A chat on the old server finds no lessons.md, seeds a new one and may add a lesson to it:
        # keep its new lines.
        try:
            have = read_text(p)
            new = [l for l in read_text(old).splitlines()
                   if l.strip() and l not in have.splitlines() and l not in LESSONS_SEED.splitlines()]
            if new:
                write_text(p, have.rstrip("\n") + "\n" + "\n".join(new) + "\n")
            os.remove(old)
        except OSError:
            pass
    return p


def linkedin_ref(name):
    return os.path.join(life_dir(), "reference-docs", "communication", "linkedin", name)


def read_if(path):
    return read_text(path) if os.path.exists(path) else None


def read_suggestion(sid):
    path = os.path.join(suggestions_dir(), os.path.basename(sid) + ".json")
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        raise ValueError("No suggestion '%s'. Use list_comment_suggestions." % sid)


def write_suggestion(s):
    os.makedirs(suggestions_dir(), exist_ok=True)
    path = os.path.join(suggestions_dir(), s["id"] + ".json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def all_suggestions():
    out = []
    d = suggestions_dir()
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, name)) as f:
                out.append(json.load(f))
        except Exception:
            continue
    out.sort(key=lambda s: s.get("created", ""))
    return out


def norm_post_url(u):
    """The same post under tracking parameters or a trailing slash is one post."""
    u = (u or "").strip().split("?")[0].split("#")[0].rstrip("/")
    return u.lower()


def lint_comment(text, platform="comment"):
    """The anti-slop gate. Returns None when it passes, else the linter's complaints. platform "eng-blog" is the
    long-form rule set for web pages (2026-10-20: the comment rules cap a text at 6 sentences, so no page passed).
    TAKES_LINT points at another linter (tests); a missing linter lets the draft through."""
    linter = os.environ.get("TAKES_LINT") or os.path.expanduser("~/.claude/shared/anti-slop/lint.py")
    if not os.path.exists(linter):
        return None
    out = subprocess.run([sys.executable, linter, "--platform", platform], input=text,
                         capture_output=True, text=True, timeout=30)
    if out.returncode == 0:
        return None
    lines = [l.rstrip() for l in out.stdout.splitlines()]
    return "\n".join(l for l in lines if l.strip().startswith(("❌", "Banned", "Line", "\"")) or l.startswith("    ")
                     ) or out.stdout[-800:]


def gate(text):
    text = (text or "").strip()
    if not text:
        raise ValueError("The draft is empty.")
    problems = lint_comment(text)
    if problems:
        raise ValueError("The slop gate refused this draft. Rewrite it once, or drop the post.\n" + problems)
    return text


VARIANTS = 3


def gate_variants(a):
    """Three different comments for one post (2026-10-02: The user picks one; the pick teaches the
    next run). Each goes through the slop gate; a refusal names the variants to rewrite."""
    vs = a.get("variants")
    if not isinstance(vs, list) or len(vs) != VARIANTS:
        raise ValueError("variants takes exactly %d different comments for the post." % VARIANTS)
    out, refused = [], []
    for i, v in enumerate(vs, 1):
        try:
            out.append(gate(v if isinstance(v, str) else ""))
        except ValueError as e:
            refused.append("Variant %d: %s" % (i, e))
    if refused:
        raise ValueError("\n".join(refused) + "\nRewrite the refused variants and send all %d again." % VARIANTS)
    if len({" ".join(v.lower().split()) for v in out}) < VARIANTS:
        raise ValueError("Two variants are the same. Make each one a different shape.")
    return out


def picked_text(s):
    """The variant the user picked (before any edit of his), else the newest draft."""
    d = (s.get("drafts") or [{}])[-1]
    vs, i = d.get("variants"), (s.get("decision") or {}).get("variant")
    if vs and isinstance(i, int) and 0 <= i < len(vs):
        return vs[i]
    return d.get("text", "")


def last_text(s):
    return s.get("final") or (s.get("drafts") or [{}])[-1].get("text", "")


# The finder runs as scouts in parallel (2026-10-03, four since that evening): subagents that only
# read LinkedIn and return candidate posts. The chat that starts them drafts comments for the best
# ones. A subagent sees only its brief, so each brief carries the browser rules and the skip lists.
SCOUT_BROWSER = (
    "Browser rules, always: only the Claude in Chrome tools (mcp__claude-in-chrome__*). One tab is "
    "yours: call tabs_create_mcp exactly once, as your first browser step, and write down the tabId "
    "it returns. Pass that tabId on every browser call after it. Other scouts work in the same "
    "Chrome at the same time, each in its own tab: never pick a tab from tabs_context_mcp, never use, "
    "read, navigate or close a tab you did not create. If a call says your tab is gone, create one "
    "new tab and use only that one from then on. If a page shows something you did not open, stop "
    "and report it. Never activate or raise a window, never switch the visible tab, never bring "
    "Chrome to the front, never use the system clipboard. Read only: navigate, scroll and "
    "read. Never click Like, Comment, Post, Follow, Connect, Send or Repost. On a login wall, a "
    "CAPTCHA or a rate-limit message, stop and report it. To open the next post or profile, navigate "
    "your tab: never open a second one. When you are done, close your tab, unless tabs_context_mcp "
    "shows it is the last tab in the group: then navigate it to about:blank and leave it open (an "
    "empty group makes the next new tab open a window).")

# The feed and search pages often carry no post links. Copy link is caught in the page so the
# system clipboard stays untouched (the user OK, 2026-10-08).
SCOUT_LINK = (
    "Every candidate needs the post's own link. If the page you read it on has no "
    "urn:li:activity link for it, catch the post's own Copy link: with javascript_tool run "
    "window.__copied=null; navigator.clipboard.writeText=t=>{window.__copied=t;return Promise.resolve()} "
    "(the link stays in the page and never reaches the system clipboard; run it again after every "
    "page load), click the post's \"...\" menu, then \"Copy link to post\" (the only clicks allowed "
    "beyond reading), then read window.__copied with javascript_tool. A lnkd.in short link: navigate your tab to it "
    "and take the post URL it lands on. Keep the link without its query string. Still no link: open the author's linkedin.com/in/<handle>/recent-activity/all/ in your "
    "tab, find the same post by its first words and try there. No link, no candidate.")

SCOUT_OUTPUT = (
    "Return only JSON, nothing else: {\"candidates\": [{\"url\": the post's own link "
    "(linkedin.com/feed/update/urn:li:activity:...), \"author\", \"author_url\", \"headline\", "
    "\"posted\" (as LinkedIn shows it, e.g. \"3h\"), \"age_hours\" (number), \"comments\" (int), "
    "\"reactions\" (int), \"text\" (the whole post text, word for word, from its first line to its "
    "last, with every line break and empty line kept: with javascript_tool, find the text node with "
    "the post's first words and return the innerText of the <p> around it; get_page_text, read_page "
    "and textContent drop the empty lines between paragraphs. Never shorten, reword or cut a P.S.), "
    "\"author_photo\" (the "
    "src of the author's photo on the post, an img on media.licdn.com), \"why\" (one line: what the user, "
    "an AI agent builder and founder who also surfs and travels, could add)}], %s \"stopped\": "
    "null or what stopped you}. Up to %d candidates, best first. Only posts that pass every rule.")

SCOUT_RULES = (
    "Rules for a candidate: English. Not promoted, not \"Suggested\", not a repost without the "
    "author's own words, not a job post or an event ad. Author headline shows a founder, CEO, CTO, "
    "head of / VP, product, growth or engineering role. No politics, layoffs or competitor fights. "
    "Fewer than ~150 comments. A post where the user can add something real: a story from building "
    "agents or running a community, a counterpoint, a pointed question or a concrete tip.")

# Posts from people not on the target list: fresh, and with proof that people read the author.
SCOUT_FRESH = "Posts under 24 hours old with at least 10 reactions only."

SEARCH_TERMS = ["Claude Code", "AI agents", "agentic workflows", "automation", "solo founder AI",
                "building in public"]

NEW_TARGETS = ("\"new_targets\": [{\"name\", \"url\", \"why\"}] (people who fit the rules and "
               "post often, only ones you would want to read every week),")


# How many names the list scout usually reaches in one run: these count as read.
LIST_SCOUT_REACH = 25


def shuffled_targets(targets_file):
    """The names on the target list, the ones offered longest ago first, random among equals
    (2026-10-04). The scout stops at 20 candidates, so a fixed order kept the bottom of the list
    from ever being read, and plain random kept repeating people. The first LIST_SCOUT_REACH names
    get today's date in list-scout-seen.json."""
    try:
        text = open(targets_file, encoding="utf-8").read()
    except OSError:
        return "the list's order"
    names = list(dict.fromkeys(re.findall(r"^\| \[([^\]]+)\]\(https://www\.linkedin\.com/in/", text, re.M)))
    if not names:
        return "the list's order"
    seen_file = os.path.join(comments_dir(), "list-scout-seen.json")
    try:
        seen = json.load(open(seen_file, encoding="utf-8"))
    except (OSError, ValueError):
        seen = {}
    random.shuffle(names)
    names.sort(key=lambda n: seen.get(n, ""))
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    seen = {n: seen[n] for n in names if n in seen}
    seen.update({n: now for n in names[:LIST_SCOUT_REACH]})
    try:
        with open(seen_file, "w", encoding="utf-8") as f:
            json.dump(seen, f, indent=1, sort_keys=True)
    except OSError:
        pass
    return ", ".join(names)


def scout_briefs(skip_urls, skip_authors, targets_file):
    skip = ("Skip these post URLs (already drafted): %s. Skip these authors (commented in the last 2 "
            "days): %s." % (", ".join(skip_urls) or "none", ", ".join(skip_authors) or "none"))
    no_list = "Skip anyone on the target list at %s: the list scout reads them." % targets_file
    feed = ("You are the feed scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
            "Open linkedin.com/feed/ (sorted by most recent if the page offers it) and scroll down, "
            "reading as you go, until you have read about 60 posts or the posts are over 24 hours old. "
            "Note the candidates first, then get their links. " + SCOUT_LINK + " "
            + SCOUT_RULES + " " + SCOUT_FRESH + " " + skip + " "
            + SCOUT_OUTPUT % (NEW_TARGETS, 12))
    lst = ("You are the target-list scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
           "Read the target list at %s. For each person in it, open "
           "linkedin.com/in/<handle>/recent-activity/all/ and read their newest posts (skip their "
           "reposts and comments). Go through the people in this order, the ones read longest ago first, so "
           "every run reaches different people: %s. Stop early at 20 candidates. "
           % (targets_file, shuffled_targets(targets_file))
           + SCOUT_LINK + " " + SCOUT_RULES + " " + SCOUT_FRESH + " " + skip + " Also note the people whose "
           "newest own post is over 30 days old. "
           + SCOUT_OUTPUT % ("\"quiet\": [names],", 20))
    search = ("You are the search scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
              "For each of these terms: %s, open linkedin.com/search/results/content/?keywords=<the "
              "term>&sortBy=%%22relevance%%22&datePosted=%%22past-24h%%22 in your tab (top posts of the "
              "past day: sorting by latest only shows posts minutes old, with no reactions yet) and "
              "read the first 15 or so posts, scrolling to load them. " % ", ".join('"%s"' % t for t in SEARCH_TERMS)
              + SCOUT_LINK + " " + SCOUT_RULES + " " + SCOUT_FRESH + " Skip posts that read like "
              "engagement bait (\"comment X and I'll send you\", lists of tools, AI-written listicles). "
              + no_list + " " + skip + " " + SCOUT_OUTPUT % (NEW_TARGETS, 10))
    commenters = ("You are the commenter scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
                  "Read the target list at %s. Pick 6 people from its \"Big accounts\" and \"Product "
                  "and growth\" sections, open their linkedin.com/in/<handle>/recent-activity/all/ and "
                  "open their newest own post that is under 48 hours old. Read its top comments. Note "
                  "commenters with a founder, CEO, CTO, head of / VP, product, growth or engineering "
                  "headline whose comment shows real work (a story, numbers, a clear opinion), not "
                  "praise. For up to 8 such people, open their own "
                  "linkedin.com/in/<handle>/recent-activity/all/ and read their newest posts. "
                  % targets_file + SCOUT_LINK + " " + SCOUT_RULES + " " + SCOUT_FRESH + " " + no_list + " " + skip + " "
                  + SCOUT_OUTPUT % (NEW_TARGETS, 10))
    return {"feed": feed, "list": lst, "search": search, "commenters": commenters}


def t_get_comment_context(a):
    mark_seen([], comments_text())
    sugg = all_suggestions()
    decided = [s for s in sugg if s.get("decision")]
    decided.sort(key=lambda s: s["decision"].get("at", ""))

    def post_brief(s):
        p = s.get("post") or {}
        return {"author": p.get("author"), "post": (p.get("text") or "")[:300]}

    approved = [dict(post_brief(s), comment=s.get("final")) for s in decided
                if s["decision"].get("kind") == "approved"][-10:]
    edited = [dict(post_brief(s), draft=picked_text(s), user_wrote=s.get("final"))
              for s in decided if s["decision"].get("kind") == "edited" and s.get("drafts")][-10:]
    picks = []
    for s in decided:
        d, i = (s.get("drafts") or [{}])[-1], s["decision"].get("variant")
        vs = d.get("variants") or []
        if s["decision"].get("kind") in ("approved", "edited") and isinstance(i, int) and 0 <= i < len(vs):
            picks.append(dict(post_brief(s), picked=vs[i], passed_over=[v for j, v in enumerate(vs) if j != i]))
    picks = picks[-10:]
    declined = [dict(post_brief(s), draft=last_text(s), why=s["decision"].get("kind"),
                     reason=s["decision"].get("reason"), note=s["decision"].get("note"))
                for s in decided if s["decision"].get("kind") in ("wrong_post", "bad_comment")][-10:]
    feedback = [{"draft": d.get("text"), "variants": d.get("variants"), "feedback": d.get("feedback"),
                 "about_variant": d.get("feedback_variant"), "his_edit": d.get("edit")}
                for s in sugg for d in s.get("drafts", []) if d.get("feedback")][-10:]
    best = [dict(post_brief(s), comment=s.get("final"), impressions=(s.get("stats") or [{}])[-1].get("impressions"))
            for s in sugg if s.get("best")][-10:]

    cutoff = datetime.now(timezone.utc).timestamp() - 2 * 86400
    recent = sorted({(s.get("post") or {}).get("author") for s in sugg
                     if s.get("status") in ("approved", "posted")
                     and (parse_iso((s.get("decision") or {}).get("at", "")) or datetime.min.replace(tzinfo=timezone.utc)).timestamp() > cutoff}
                    - {None})
    redraft = [{"id": s["id"], "post": s.get("post"), "angle": s.get("angle"), "drafts": s.get("drafts")}
               for s in sugg if s.get("status") == "redraft"]

    style = linkedin_ref("comment-style-guide.md")
    open_notes = [c for c in read_comments(comments_dir())["comments"] if c.get("status") != "resolved"]
    skip_urls = sorted({norm_post_url((s.get("post") or {}).get("url")) for s in sugg} - {""})
    return {
        "lessons": read_text(lessons_path()),
        "lessons_file": lessons_path(),
        "style_guide": style if os.path.exists(style) else None,
        "targets": read_if(linkedin_ref("commenting-targets.md")),
        "past_best_comments": read_if(linkedin_ref("comment-library.md")),
        "examples": {"approved_as_is": approved, "edited_by_user": edited, "variant_picks": picks,
                     "declined": declined, "feedback_given": feedback, "marked_best": best},
        "skip_post_urls": skip_urls,
        "skip_authors": recent,
        "scouts": scout_briefs(skip_urls, recent, linkedin_ref("commenting-targets.md")),
        "waiting_for_redraft": redraft,
        "open_comments": len(open_notes),
        "open_comments_note": ("The user left comments on these files (Comments > Library): get_comments "
                               "library='comments', edit the file, then reply_comment library='comments' "
                               "resolve=true.") if open_notes else None,
        "rules": "English posts only. Author headline must show a founder, CEO, CTO, head of / VP, product, "
                 "growth or engineering role. Under ~150 comments. Under 24 hours old with at least 10 reactions. Skip skip_post_urls "
                 "and skip_authors (commented in the last 2 days). No politics, layoffs or competitor fights. "
                 "Each suggestion needs an angle: what the user can add. No angle, no suggestion. Write 3 "
                 "variants per post, each a different shape (for example a short story from the user's work, a "
                 "pointed question, a counterpoint or a concrete tip) and length. Study edited_by_user "
                 "most: it shows what the user changes. variant_picks shows which shape the user picks over which.",
    }


def save_author_photo(url, sid):
    """Saves the author's LinkedIn photo as suggestions/<sid>.jpg, so the card shows a face. Best
    effort: only LinkedIn's image host, 2 MB at most; any failure keeps the initials."""
    import urllib.request
    url = (url or "").strip()
    host = urllib.parse.urlparse(url).hostname or ""
    if not url.startswith("https://") or not (host == "media.licdn.com" or host.endswith(".licdn.com")):
        return None
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as r:
            if not (r.headers.get("Content-Type") or "").startswith("image/"):
                return None
            data = r.read(2_000_001)
        if not data or len(data) > 2_000_000:
            return None
        os.makedirs(suggestions_dir(), exist_ok=True)
        name = sid + ".jpg"
        with open(os.path.join(suggestions_dir(), name), "wb") as f:
            f.write(data)
        return name
    except Exception:
        return None


def t_add_comment_suggestion(a):
    need_rules("comments")
    url = (a.get("post_url") or "").strip()
    if not url:
        raise ValueError("post_url is required.")
    if not (a.get("angle") or "").strip():
        raise ValueError("Every suggestion needs an angle: one line on what the user can add.")
    known = {norm_post_url((s.get("post") or {}).get("url")): s["id"] for s in all_suggestions()}
    if norm_post_url(url) in known:
        raise ValueError("Already suggested for this post (%s). Pick another post." % known[norm_post_url(url)])
    variants = gate_variants(a)
    stamp = datetime.now(timezone.utc)
    sid = "%s-%s-%s" % (stamp.strftime("%Y%m%d-%H%M%S"), slug(a.get("author") or "post")[:30] or "post",
                        hashlib.sha1(url.encode()).hexdigest()[:4])
    post = {"url": url, "author": (a.get("author") or "").strip(), "text": post_lines(a.get("post_text") or "")}
    for k in ("author_url", "headline", "posted", "source"):
        if a.get(k):
            post[k] = str(a[k]).strip()
    for k in ("comments", "reactions"):
        if isinstance(a.get(k), int):
            post[k] = a[k]
    photo = save_author_photo(a.get("author_photo"), sid)
    if photo:
        post["photo"] = photo
    s = {"id": sid, "created": now_iso(), "status": "review", "post": post,
         "angle": a["angle"].strip(),
         "drafts": [{"text": variants[0], "variants": variants, "at": now_iso(), "by": "agent"}]}
    write_suggestion(s)
    return {"id": sid, "status": "review", "note": "Waiting for the user on the Comments board."}


def t_redraft_comment(a):
    need_rules("comments")
    s = read_suggestion(a["id"])
    if s.get("status") not in ("redraft", "review", "feedback"):
        raise ValueError("Suggestion %s is %s: only a draft in review or waiting for a redraft changes." % (s["id"], s.get("status")))
    variants = gate_variants(a)
    s.setdefault("drafts", []).append({"text": variants[0], "variants": variants, "at": now_iso(), "by": "agent"})
    s["status"] = "review"
    write_suggestion(s)
    return {"id": s["id"], "status": "review", "drafts": len(s["drafts"])}


def suggestion_view(s):
    p = s.get("post") or {}
    v = {"id": s["id"], "status": s.get("status"), "author": p.get("author"), "post_url": p.get("url"),
         "angle": s.get("angle"), "comment": last_text(s)}
    if s.get("decision"):
        v["decision"] = s["decision"]
    if s.get("posted"):
        v["posted"] = s["posted"]
    if s.get("stats"):
        v["stats"] = s["stats"][-1]
    return v


def t_list_comment_suggestions(a):
    want = a.get("status")
    if want and want not in COMMENT_STATUSES:
        raise ValueError("status is one of %s." % ", ".join(COMMENT_STATUSES))
    items = [suggestion_view(s) for s in all_suggestions() if not want or s.get("status") == want]
    return {"suggestions": items[-int(a.get("limit") or 50):]}


def t_set_comment_posted(a):
    s = read_suggestion(a["id"])
    if s.get("status") not in ("approved", "posted"):
        raise ValueError("Only an approved comment can be posted. %s is %s." % (s["id"], s.get("status")))
    s["status"] = "posted"
    s["posted"] = {"at": now_iso()}
    if a.get("url"):
        s["posted"]["url"] = a["url"].strip()
    write_suggestion(s)
    return suggestion_view(s)


def t_set_comment_stats(a):
    s = read_suggestion(a["id"])
    if s.get("status") != "posted":
        raise ValueError("%s is not posted yet." % s["id"])
    reading = {"at": now_iso()}
    for k in ("impressions", "likes", "replies"):
        if isinstance(a.get(k), int):
            reading[k] = a[k]
    s.setdefault("stats", []).append(reading)
    write_suggestion(s)
    return suggestion_view(s)


S = {"type": "string"}
SESSION = {"type": "string", "description": "Session as 'Project/folder', an absolute path, or its id (from get_session). "
           "An old path still works after a rename or move."}
PLATFORM = {"type": "string", "enum": list(PLATFORMS),
            "description": "Which post of the session: linkedin (default, posts/linkedin.md), x (posts/x.md), "
                           "youtube (the long wide video: title + description, posts/youtube.md) or vertical (one "
                           "vertical video and caption for TikTok, Instagram Reels and YouTube Shorts, posts/vertical.md)"
                           + (" or article (a post for the user's blog in markdown, posts/article.md; later also a LinkedIn "
                              "and an X article)." if BLOG else ".")}
TWEETS = {"type": "array", "items": {"type": "string"},
          "description": "X only, instead of text: the tweets of a thread in order (one item = one tweet)."}
LIBRARY = {"type": "string", "description": "A library: 'style:<Name>' for one of the user's styles (e.g. "
           "'style:Magazine'; a new name makes a new style), a project name for that project's own additions, "
           "or 'comments' for the comment copilot's files (lessons, target list, style guide)."}
LESSON = {"type": "string", "description": "With resolve: what this comment taught. A rule id from "
          "get_rules, 'new' (then give rule), or 'one-off'."}
MISSED = {"type": "boolean", "description": "With a rule id: true when the edit broke what that rule says (counted "
          "as the same mistake again), false when the comment asks for something new or is taste near it."}
RULE_DETAILS = {"type": "string", "description": "Longer words for the rule, at most %d characters. '' removes "
                "them." % DETAILS_MAX}
MERGE_INTO = {"type": "string", "description": "With a new rule in a full area: the id of the closest rule in the "
              "same area."}
MERGED = {"type": "string", "description": "With merge_into: one sentence that holds both rules."}
RULE = {"type": "object", "description": "With lesson 'new': one short sentence that holds for the next videos "
        "too. A full area needs merge_into and merged.",
        "properties": {"area": {"type": "string", "enum": AREAS + ["post"]},
                       "text": {"type": "string"}, "check": {"type": "object"}, "details": RULE_DETAILS,
                       "merge_into": MERGE_INTO, "merged": MERGED}}
TOOLS = [
    ("get_comment_context", "LinkedIn comment copilot: everything to read before drafting comments for the user. "
     "Returns lessons.md (the user's rules), the target list, the best past comments, recent examples (approved as is, "
     "edited by the user: study these most, declined with reasons, feedback notes, marked best), post URLs and authors "
     "to skip, drafts waiting for a redraft, and the post rules. Call it first on every drafting run.",
     {}, [], t_get_comment_context),
    ("add_comment_suggestion", "Suggest one LinkedIn comment for the user to review on the Takes Comments board. "
     "Never post it yourself. Send 3 variants; each goes through the anti-slop gate: a refusal names the "
     "variants to rewrite; rewrite once or drop the post. One suggestion per post.",
     {"post_url": {"type": "string", "description": "The post's own URL (linkedin.com/feed/update/urn:li:activity:...)."},
      "author": S, "author_url": S,
      "author_photo": {"type": "string", "description": "The src of the author's round profile photo on the post "
                       "(https://media.licdn.com/dms/image/...). The card shows it instead of initials."},
      "headline": {"type": "string", "description": "The author's headline as LinkedIn shows it."},
      "post_text": {"type": "string", "description": "The post's whole text, word for word, as the author wrote it (the user reads it on the card). "
                    "Never shorten, sum up or reword it. Keep its line breaks: one \\n per line break, \\n\\n between paragraphs, as the post shows them. "
                    "Read it with innerText, not textContent, which drops them."},
      "posted": {"type": "string", "description": "How old the post is, as LinkedIn shows it, e.g. '3h'."},
      "source": {"type": "string", "description": "Which scout found the post: 'feed', 'list', 'search' or 'commenters'."},
      "comments": {"type": "integer", "description": "How many comments the post has."},
      "reactions": {"type": "integer"},
      "angle": {"type": "string", "description": "One line: what the user adds (a story, a counterpoint, a real question)."},
      "variants": {"type": "array", "items": {"type": "string"}, "minItems": 3, "maxItems": 3,
                   "description": "Three different comments, plain text as the user would type them. Each a different "
                   "shape (story, question, counterpoint, tip) and length. The user picks one."}},
     ["post_url", "author", "post_text", "angle", "variants"], t_add_comment_suggestion),
    ("redraft_comment", "Save a new draft for a suggestion the user gave feedback on (get_comment_context lists "
     "them under waiting_for_redraft, each draft with its variants and feedback note, and the user's own edit if "
     "there is one: keep that edit as variant 1, changed only as the note asks). Three new variants that "
     "follow the note; same slop gate as add_comment_suggestion.",
     {"id": S, "variants": {"type": "array", "items": {"type": "string"}, "minItems": 3, "maxItems": 3,
                   "description": "Three different comments, plain text as the user would type them. Each a different "
                   "shape (story, question, counterpoint, tip) and length. The user picks one."}}, ["id", "variants"], t_redraft_comment),
    ("list_comment_suggestions", "List suggested LinkedIn comments, oldest first: review (waiting for the user), "
     "feedback (the user's note, not sent to you yet), redraft (feedback given), approved (to post), posted, declined.",
     {"status": {"type": "string", "enum": COMMENT_STATUSES}, "limit": {"type": "integer"}}, [], t_list_comment_suggestions),
    ("set_comment_posted", "Mark an approved comment as posted on LinkedIn, with the comment's link. Only after "
     "The user approved it and you saw it live under the post.",
     {"id": S, "url": {"type": "string", "description": "The comment's link (copy link to comment)."}}, ["id"],
     t_set_comment_posted),
    ("set_comment_stats", "Save a reading of a posted comment's numbers (about 48 hours after posting).",
     {"id": S, "impressions": {"type": "integer"}, "likes": {"type": "integer"}, "replies": {"type": "integer"}},
     ["id"], t_set_comment_stats),
    ("list_projects", "List Takes projects and how many sessions each has. Start here.", {}, [], t_list_projects),
    ("create_project", "Create a project (a folder in the Takes library).", {"name": S}, ["name"], t_create_project),
    ("list_sessions", "List sessions in a project, newest first, with take and keeper counts.",
     {"project": S}, ["project"], t_list_sessions),
    ("get_session", "Get a session: its id, title, full script, and every take with file path, duration, "
     "keeper flag, name and start time (camera and screen files of one take share a number), plus every "
     "asset file (edits/, thumbnails/, stills/, assets/), the folder rules ('folders') and 'warnings' about "
     "files in the wrong place: fix those. Each take shows edit_ready (word times are ready). Cut takes with "
     "cut_take and rough_cut by default: they fix the audio offset and frame rate. checks: the "
     "check_edit state of each newest edit. rules: the rules for the session's next step that this chat has not seen yet; follow them.",
     {"session": SESSION}, ["session"], t_get_session),
    ("create_session", "Create a recording session with a title and the script to read on the teleprompter, "
     "optionally with variants. Offers it in the Takes app unless open=false (see open_in_app).",
     {"project": {"type": "string", "description": "Project name. Created if missing. Default Inbox."},
      "title": S, "script": {"type": "string", "description": "Markdown script shown on the teleprompter."},
      "variants": {"type": "array", "items": {"type": "object"}, "description": "Optional [{name, script, note}]."},
      "open": {"type": "boolean"}}, ["title"], t_create_session),
    ("update_session", "Change a session's title (renames its folder) and/or replace its main script. "
     "Script changes are saved to history on both sides, so they can be undone. Give a short note. After a "
     "rename, use the returned path or the session id; the old path still works.",
     {"session": SESSION, "title": S, "script": S, "note": {"type": "string", "description": "What changed, e.g. 'Tighter hook'."}},
     ["session"], t_update_session),
    ("set_hooks", "Offer several hooks (opening lines) for a session. Replaces earlier hook options. The app "
     "shows them above the teleprompter; picking one puts it in the script's first paragraph (the hook slot), "
     "and each take records which hook it opened with (take field 'hook'). Write script.md with your best hook "
     "as its own first paragraph. Use this for hook options; use variants for different whole scripts.",
     {"session": SESSION, "hooks": {"type": "array", "items": {"type": "object", "properties": {
         "text": {"type": "string"}, "note": {"type": "string", "description": "Short why, e.g. 'curiosity gap'"}},
         "required": ["text"]}}}, ["session", "hooks"], t_set_hooks),
    ("set_storyboard", "Write the session's storyboard: the video as a row of shots that the user sees as a "
     "horizontal timeline of sketches on the Storyboard tab, each with its script lines. Use it with the "
     "storyboard skill when the user brainstorms a video idea. Replaces the earlier storyboard. Each shot covers "
     "one or two script paragraphs: 'say' is those lines word for word from script.md, 'do' is how to film or "
     "build it in one short line, 'sketch' is what the frame shows (people, props, framing, the camera move or "
     "the motion as arrows; never text in the frame). A sketch already drawn is kept; a new or changed sketch is "
     "drawn in the background, about 30 s. redraw=true draws a shot again with the same sketch text. "
     "With no image key, nothing is drawn and the answer says so: ask the user for a key, or pass your own "
     "sketch as the shot's 'image'. "
     "'video' puts a real clip on the shot instead of a sketch (a file from list_broll, or a file in the "
     "session such as edits/x.mp4 or a still such as generated/x.png); the app shows its frame and plays it on hover. "
     "'variants' puts several clips or stills on one shot (A, B, C... in that order) for the user to choose "
     "from: the shot shows as a stack; the user flips through them and picks one; 'video' is the one in the video "
     "(default the first). Left out, the shot keeps its variants. A new Higgsfield or Replicate clip for a "
     "shot keeps the old one as a variant. "
     "The user records takes per shot and comments on shots: get_session's 'storyboard' lists each shot's id, "
     "section, takes and open comments. 'format' is the video's shape: the cards and sketches use it.",
     {"session": SESSION,
      "format": {"type": "string",
                 "description": "The video's shape as W:H, any shape: 16:9 (YouTube, a landscape launch video), "
                                "9:16 (Reels, Shorts, TikTok), 4:5 (LinkedIn feed), 1:1, 21:9 (cinema), 4:3, 3:4... "
                                "Set it on the first call; later calls keep it. A new format draws every sketch "
                                "again in that shape."},
      "shots": {"type": "array", "items": {"type": "object", "properties": {
         "id": {"type": "string", "description": "The shot's id from get_session's storyboard list. Keep it "
                "when you change a shot: The user's takes and comments point at it. Leave it out for a new shot."},
         "section": {"type": "string", "enum": ["hook", "main", "end"],
                     "description": "The row it shows in: hook (the opening seconds), main, end (the close "
                                    "and the call to action). Default main; kind END goes to end."},
         "kind": {"type": "string", "description": "DESK, WALK, B-ROLL, SCREEN, MG (motion graphic), END..."},
         "say": {"type": "string"}, "do": {"type": "string"}, "sketch": {"type": "string"},
         "seconds": {"type": "number", "description": "Optional. Default: from the words in 'say'."},
         "video": {"type": "string", "description": "Optional: a clip that shows instead of the sketch. A file "
                   "from list_broll (it is added to the session's broll/) or a path in the session."},
         "variants": {"type": "array", "items": {"type": "string"},
                      "description": "Optional: every clip or still tried for this shot, in order (paths as for "
                                     "video). The user picks one on the Storyboard tab; video is the one in the video."},
         "image": {"type": "string", "description": "Optional: a sketch you made yourself (PNG or JPG path), "
                   "used instead of drawing one. For when set_storyboard says Takes has no image key and you "
                   "can make images."},
         "redraw": {"type": "boolean"}}}}}, ["session", "shots"], t_set_storyboard),
    ("set_post", "Write the session's post for LinkedIn (default, posts/linkedin.md) or X (platform=x, "
     "posts/x.md). One session holds one post per platform, so the LinkedIn post and its X version sit together. "
     "LinkedIn: the app shows a real LinkedIn feed post with the video, cut after three lines with '…more', "
     "so put the hook in the first two lines. Max 3000 characters. "
     "X: the app shows a real X post, or a thread when you pass several tweets (tweets=[...], or text with a "
     "line holding only '---' between tweets). The media goes on the first tweet. The timeline cuts a tweet "
     "over 280 characters with 'Show more' (the user has Premium, so longer is allowed). "
     "The user edits the post in the app and comments on selected text; fix those comments with set_post. "
     "YouTube (platform=youtube): the long wide video. Pass title (max 100) and the description as text "
     "(chapters as '0:00 Intro' lines). Vertical (platform=vertical, also for tiktok/reels/shorts): one caption for "
     "TikTok, Instagram Reels and YouTube Shorts with the 9:16 edit; hook in the first line, max 2200 characters, "
     "at most 5 hashtags; title is the Shorts title, on picks the places. "
     "The old text stays in history. get_session returns them as 'post', 'x_post', 'youtube_post', 'vertical_post'"
     + (", 'article'. "
        "Article (platform=article, also 'blog'): a post for the user's blog; the app shows the blog's page. "
        "Pass title, description (one line under the title), category (Tech, Life or Business) and the body as text. "
        + ARTICLE_COMPONENTS + " Read 2-3 of the blog's posts first for the voice (content/blog/*.mdx in "
        + ARTICLE_SITE_REPO + ", e.g. gh api repos/" + ARTICLE_SITE_REPO + "/contents/content/blog). "
        "The other platforms are plain text only: they show no markdown." if BLOG else ". Posts are plain text only: they show no markdown.")
     + " No video? The post works without one "
     "(text only, or pass an image). For other versions use create_post_variants; for opening options "
     "set_post_hooks. With variant=<slug> it edits that variant instead of the main post.",
     {"session": SESSION, "platform": PLATFORM,
      "text": {"type": "string", "description": "The whole post, as it will appear."},
      "tweets": TWEETS,
      "variant": {"type": "string", "description": "Optional: edit this post variant (slug) instead of the main post."},
      "name": {"type": "string", "description": "With variant: rename it."},
      "media": {"type": "string", "description": "Optional: the video or image to show, e.g. 'edits/hook-v3.mp4'. "
                "Default: the newest edit."},
      "note": {"type": "string", "description": "What changed, e.g. 'Shorter hook'."},
      "title": {"type": "string", "description": "youtube: the video title. vertical: the Shorts title (empty: YouTube "
                "uses the caption's first line). Max 100 characters."},
      "on": {"type": "array", "items": {"type": "string", "enum": ["tiktok", "reels", "shorts"]},
             "description": "vertical only: where it goes. Default all three."},
      **({"description": {"type": "string", "description": "article only: the line under the title (front matter description)."},
          "category": {"type": "string", "enum": ARTICLE_CATEGORIES, "description": "article only: where the blog files it."},
          "slug": {"type": "string", "description": "article only: the URL name (example.com/blog/<slug>). Default: from the title."}}
         if BLOG else {}),
      "first_comment": {"type": "string", "description": "LinkedIn only. Optional: the first comment the user posts under it "
                        "(links, resources, a question). The app shows it under the post as the user's comment. "
                        "One per session, shared by the variants. Empty string removes it."}},
     ["session"], t_set_post),
    ("create_post_variants", "Add other versions of the session's LinkedIn or X post (e.g. 'Story first', 'Shorter', "
     "'Single tweet'). The app shows them as tabs above the post preview; the user compares, edits, comments and "
     "picks one with 'Use as main'. Only the main post is scheduled. Write the main post with set_post first. "
     "Edit a variant later with set_post variant=<slug>. For different openings of the same post use set_post_hooks.",
     {"session": SESSION, "platform": PLATFORM, "variants": {"type": "array", "items": {"type": "object", "properties": {
         "name": S, "text": {"type": "string", "description": "The whole post."}, "tweets": TWEETS,
         "note": {"type": "string", "description": "Short why, e.g. 'leads with the number'"}},
         "required": ["name"]}}}, ["session", "variants"], t_create_post_variants),
    ("use_post_variant", "Make a post variant the main post (the one that is scheduled). The old main goes to "
     "post history and the variant tab closes. Only when the user asks; the user usually does it in the app.",
     {"session": SESSION, "platform": PLATFORM, "variant": S}, ["session", "variant"], t_use_post_variant),
    ("delete_post_variants", "Move post variants to the macOS Trash (their text stays in post history).",
     {"session": SESSION, "platform": PLATFORM, "variants": {"type": "array", "items": S}}, ["session", "variants"],
     t_delete_post_variants),
    ("set_post_hooks", "Offer several hooks for the LinkedIn or X post: opening lines (LinkedIn: the part above "
     "'…more', about two lines; X: the first tweet's opening). Replaces earlier hooks for that platform. The app "
     "lists them above the post; picking one replaces the post's first paragraph. Write the post with your best "
     "hook as its own first paragraph.",
     {"session": SESSION, "platform": PLATFORM, "hooks": {"type": "array", "items": {"type": "object", "properties": {
         "text": {"type": "string"}, "note": {"type": "string", "description": "Short why, e.g. 'contrarian'"}},
         "required": ["text"]}}}, ["session", "hooks"], t_set_post_hooks),
    ("post_history", "Every saved version of the post and its variants, newest first: version, draft ('main' or "
     "a variant slug), author (user or claude), note, created, preview. Pass version to get its full text, "
     "e.g. to compare with the current post. A version is saved on every change by Claude and while the user edits.",
     {"session": SESSION, "platform": PLATFORM,
      "version": {"type": "string", "description": "Optional: one version's full text."}},
     ["session"], t_post_history),
    ("restore_post_version", "Put an old version back (into its variant if it still exists, else the main post). "
     "The current text is saved to history first.",
     {"session": SESSION, "platform": PLATFORM, "version": S}, ["session", "version"], t_restore_post_version),
    ("get_post_queue", "The posting plan: every LinkedIn and X post the user marked ready or that is scheduled, "
     "across all projects, sorted by time. Each has platform, session, title, text (X: also 'tweets'), "
     "media_path (the video to upload), status, at (iso, utc, local in the chosen tz, this_mac = the Mac's "
     "zone, which LinkedIn's scheduler uses) and 'action': what to do on that platform now (schedule, move, "
     "replace text, delete, or nothing). The user sets the times with [schedule] on the post tab, or asks you to pick them.",
     {"platform": {"type": "string", "enum": list(PLATFORMS), "description": "Optional: only this platform."},
      "posted": {"type": "boolean", "description": "Also list posts already live. Default false."},
      "drafts": {"type": "boolean", "description": "Also list drafts (not marked ready yet), e.g. for a "
                 "pipeline overview. Default false."}},
     [], t_get_post_queue),
    ("get_plan", "The user's posting plan: the weekdays to post, the slots in the next 14 days, which are "
     "empty (next_gap), the buffer (covered slots before the first empty one) and ready posts with no time yet. "
     "Use it to tie a new take or edit to the slot it can fill, and to suggest a time when the user marks a post "
     "ready. No plan yet: ask the user which days, then set_plan.",
     {}, [], t_get_plan),
    ("set_plan", "Save the posting days the user picked. Overwrites the plan. Returns get_plan.",
     {"days": {"type": "array", "items": {"type": "string"}, "description": "Weekdays: mon, tue, wed, thu, fri, sat, sun."},
      "time": {"type": "string", "description": "Usual posting time, HH:MM 24-hour. Default 09:00."},
      "platforms": {"type": "array", "items": {"type": "string", "enum": list(PLATFORMS)},
                    "description": "Which posts fill a slot. Default [linkedin]."},
      "weeks": {"type": "integer", "description": "How many weeks the Plan board shows, 2 to 12. Default: unchanged."}},
     ["days"], t_set_plan),
    ("plan_video", "Put a session's video card on a day of the user's Plan board (the calendar in Takes), move "
     "it to another day, or take it off (day empty). Use it when the user asks you to plan videos; one call per "
     "video. A card shows the session's title and thumbnail; the user drags cards to reorder them. A card covers "
     "that day's posting slot as planned; a post with a time fills it. The board grows to show the card's week. "
     "Returns get_plan.",
     {"session": SESSION,
      "day": {"type": "string", "description": "YYYY-MM-DD, up to 12 weeks ahead. Empty: take the card off."},
      "before": {"type": "string", "description": "Optional: another planned session on that day; the card goes "
                 "before it. Default: last on that day."}},
     ["session"], t_plan_video),
    ("set_post_status", "Record what you did on LinkedIn or X (platform=x) for a session's post. status=scheduled after you scheduled "
     "it (records the time and text you scheduled, so later changes show up as an action); status=posted "
     "with url once it is live (also marks the session published); ready to undo. The user marks posts ready "
     "in the app; only set ready or draft when asked. A post you were asked to schedule that has no time: "
     "pass at, the time you picked on the platform.",
     {"session": SESSION, "platform": PLATFORM, "status": {"type": "string", "enum": ["draft", "ready", "scheduled", "posted"]},
      "url": {"type": "string", "description": "Link to the live post (status=posted)."},
      "at": {"type": "string", "description": "The time it goes out (or went out), ISO 8601 with offset, "
             "e.g. 2026-09-29T09:32:00-07:00. Pass it with status=scheduled when the post has no time yet or "
             "you scheduled it for another time: the post takes this time. Default for "
             "posted: now."},
      "tz": {"type": "string", "description": "Optional IANA zone for at, e.g. America/Los_Angeles. "
             "Default: the post's zone, else this Mac's."},
      "first_comment_posted": {"type": "boolean", "description": "true after you posted first_comment "
                               "under the live post."}},
     ["session", "status"], t_set_post_status),
    ("get_comments", "The user's review comments in a session or a library (pass library, not session). Video: "
     "'when' (start/end s), an optional rect (x,y,w,h fractions from top left) and a 'frame' PNG with the area "
     "outlined in orange: read it to see what the comment means; 'said' quotes the words spoken then (from the "
     "video's transcript). Image: rect + frame. Text (script, variant, README.md, tokens.json): 'quote' is the "
     "selected text. Default: open comments.",
     {"session": SESSION, "library": LIBRARY,
      "file": {"type": "string", "description": "Optional: only this file, e.g. 'edits/hook-v2.mp4'."},
      "status": {"type": "string", "enum": ["open", "resolved", "all"]}}, [], t_get_comments),
    ("reply_comment", "Reply to review comments and resolve them. After a round of fixes, send ONE call with "
     "replies=[{id, text, resolve, fixed_in, fixed_at, lesson}] for every comment. fixed_in: the new version's "
     "file; fixed_at: the second in it where the fix shows (a click on the reply jumps there). text: one line "
     "('Caption 20% smaller'). Unclear comment: ask a question, resolve omitted. In a session each resolved "
     "comment needs a lesson: a rule id from get_rules, with missed=true when the edit broke that rule (the same "
     "mistake again) or missed=false for a new ask or taste near it; 'new' with rule={area, text} (it applies to "
     "the next videos too); else 'one-off'.",
     {"session": SESSION, "library": LIBRARY,
      "replies": {"type": "array", "items": {"type": "object", "properties": {
          "id": {"type": "string", "description": "Comment id, e.g. 'c3'."}, "text": S, "resolve": {"type": "boolean"},
          "fixed_in": {"type": "string", "description": "File of the new version, relative to the session or library."},
          "fixed_at": {"type": "number", "description": "Seconds into fixed_in where the fix shows."},
          "lesson": LESSON, "rule": RULE, "missed": MISSED},
          "required": ["id"]}},
      # One reply without replies=[...]: the same fields, short here (they load with every Takes chat).
      "id": {"type": "string", "description": "Single reply: comment id. Prefer replies=[...]."},
      **{k: {"type": ty, "description": "As in replies."} for k, ty in (
          ("text", "string"), ("resolve", "boolean"), ("fixed_in", "string"), ("fixed_at", "number"),
          ("lesson", "string"), ("rule", "object"), ("missed", "boolean"))}},
     [], t_reply_comment),
    ("get_rules", "The rules learned from the user's comments, one file per step: plan (storyboard, script), make "
     "(sound, cut, picture, captions, graphics), package (thumbnail), publish (post-all, post-linkedin, post-x, "
     "post-youtube, post-vertical), engage (comments) and other. Read and follow the steps you work on before "
     "you write, edit or design. get_session and next_path show new ones once per chat; a write tool shows "
     "unseen ones once. Without area: the steps with rule counts (full=true at %d)." % AREA_MAX,
     {"area": {"type": "string", "description": "Steps, comma separated ('cut,sound'). 'post' = every post step, "
               "'edit' = the five make steps, 'all' = every rule."}},
     [], t_get_rules),
    ("set_rule", "Add, change, turn off or remove one learned rule. text is one sentence (at most %d "
     "characters); put the rest in details. Keep each area small (%d rules): sharpen a rule before you add one. "
     "When an area is full, add the new rule with merge_into (the closest rule) and merged (one sentence for "
     "both): The user approves the merge on the Feedback board. Both rules are on until the user decides. Never change "
     "a rule the user wrote (by_user) without asking first. A check makes check_edit measure the rule: %s" % (
         RULE_MAX, AREA_MAX, " ".join("%s: %s" % kv for kv in sorted(CHECKS.items()))),
     {"id": {"type": "string", "description": "The rule to change. Omit to add a new rule."},
      "area": {"type": "string", "enum": AREAS}, "text": S, "details": RULE_DETAILS,
      "merge_into": MERGE_INTO, "merged": MERGED,
      "check": {"type": "object", "description": "{kind, target, tolerance, max, floor}. null removes it."},
      "on": {"type": "boolean"}, "remove": {"type": "boolean"}}, [], t_set_rule),
    ("check_edit", "Check each new edit before you show it. It compares the edit with its take: sound, picture, "
     "sync, cut words, undone fixes, rules with a check. Fix each failure in a new version and check that. "
     "pass null: did not run (skip says why). A failure looks wrong: tell the user its say. review: with a Gemini "
     "key, Gemini watches the edit with the rules (about 5 cents, cached per version); without one, a frame sheet "
     "for you to look at. Follow review.note.",
     {"session": SESSION, "file": {"type": "string", "description": "E.g. 'edits/hook-v4.mp4'."},
      "source": {"type": "string", "description": "Optional take file, when not the keeper."},
      "watch": {"type": "boolean", "description": "false: skip Gemini's review (default true)."}},
     ["session", "file"], t_check_edit),
    ("make_image", "Make or change an image straight from Google or OpenAI (much cheaper than a Higgsfield "
     "image: never use higgsfield for images). Drafts first, final last: while the user finds the direction, "
     "draw with GPT Image (fast, 1536 px at most): flare (GPT Image 2.5 Flare, the default for a new image) "
     "or sunburst (GPT Image 2.5 Sunburst, the default for a change or with references). When the user likes a "
     "draft, make its final: from=<that draft> redraws it with Nano Banana 2.1 at 4K, the newest and sharpest, "
     "with the draft and its references as the guide and the same prompt (add one only for a change). Never "
     "make a final before the user picks. When one model fails the next one draws. Waits about 10-60 s and returns "
     "the file, <session>/generated/<name>-vN.png, and the model that drew it; the Assets tab shows both. "
     "Change an image: images=[session files] (a thumbnail, a still, 'sketch' with shot=<id>) and say what to "
     "change. One image per ask.",
     {"session": SESSION,
      "prompt": {"type": "string", "description": "What the image shows, or what to change in the given images. Optional with from."},
      "from": {"type": "string", "description": "The draft the user picked: make its final (Nano Banana 2.1, 4K, same picture)."},
      "final": {"type": "boolean", "description": "Draw the final now with Nano Banana 2.1 at 4K, without a draft. Prefer a draft, then from."},
      "images": {"type": "array", "items": {"type": "string"},
                 "description": "Session images to change or use as references (paths, or 'sketch' with shot)."},
      "shot": {"type": "string", "description": "With images=['sketch']: the shot whose sketch to use."},
      "format": {"type": "string", "description": "Shape, e.g. 16:9, 9:16, 4:5, 1:1. Default 1:1, or the input's shape."},
      "quality": {"type": "string", "enum": ["low", "medium", "high"], "description": "Default medium."},
      "model": {"type": "string", "enum": list(IMAGE_MODELS), "description": "For a draft: default flare, or sunburst with images."},
      "name": {"type": "string", "description": "Short file name. Default: the prompt's first words."}},
     ["session"], t_make_image),
    ("voices", "ElevenLabs voices: the account's own voices (the user's clone, designed and saved voices), the "
     "default voice, the plan and characters left. search=<words> searches the ElevenLabs voice library "
     "(with gender, accent, language, age, use_case); add=<add id from search> with name saves one to the "
     "account; set_default=<voice> makes a voice the default. Not set up: tell the user to open Plugins › Voices.",
     {"search": S, "gender": S, "accent": S, "language": S, "age": S, "use_case": S,
      "add": {"type": "string", "description": "'<public_owner_id>/<voice_id>' from a search result."},
      "name": {"type": "string", "description": "With add: the name the voice gets in the account."},
      "set_default": {"type": "string", "description": "A voice name or id to make the default."}},
     [], t_voices),
    ("design_voice", "Design a new ElevenLabs voice from a description ('warm German woman, 40s, calm, slow'): "
     "writes three samples (generated/voice-<name>-1..3.mp3 with session, else _library/voices/) for the user "
     "to hear on the Assets tab. Then save the pick: save=<the sample's save id> with name.",
     {"session": SESSION, "description": {"type": "string", "description": "Age, gender, accent, tone, pace, use."},
      "text": {"type": "string", "description": "Optional sample text, 100-1000 characters."},
      "save": {"type": "string", "description": "A sample's save id: keep that voice."},
      "name": {"type": "string", "description": "Name of the voice (save) or of the sample files."},
      "set_default": {"type": "boolean", "description": "With save: make it the default voice."}},
     [], t_design_voice),
    ("voiceover", "Make a voice-over with ElevenLabs: reads text (default: the session's script.md) in a voice "
     "(default: The user's default voice, usually a clone) and writes generated/<name>-vN.wav (48 kHz mono, "
     "-14 LUFS), shown on the Assets tab with the voice's name. Write the text as spoken words only. Costs "
     "ElevenLabs characters (about one per letter): one voice-over per ask.",
     {"session": SESSION, "text": {"type": "string", "description": "The words to say. Leave out for script.md."},
      "voice": {"type": "string", "description": "A voice name or id from the ElevenLabs account (voices). Leave out for the default voice (the user picks it in Plugins › Voices)."}, "name": {"type": "string", "description": "Short file name. Default voiceover-<voice>."},
      "model": {"type": "string", "description": "ElevenLabs model id. Default eleven_multilingual_v2; eleven_v3 is more expressive."},
      "stability": {"type": "number", "description": "0-1. Lower = more emotion, higher = steadier."},
      "similarity": {"type": "number", "description": "0-1. How close to the original voice."},
      "style": {"type": "number", "description": "0-1. Style exaggeration."},
      "speed": {"type": "number", "description": "0.7-1.2. Default 1."}},
     ["session"], t_voiceover),
    ("fix_words", "Correct what was said in a take or clip: ElevenLabs says the new words in the voice "
     "(default: The user's default voice, often a clone) with the sentences around them for the same tone, and "
     "Takes cuts them in at the word edges with the take's cleaned voice when there is one. old = the words "
     "as said (from the transcript; Takes transcribes the file first when it has no <stem>.words.json), or "
     "start/end in seconds. Writes generated/<file>-fix-vN.wav, plus an .mp4 with the video when the new "
     "words fit the old time (speed 0.8-1.25x), so the take's times still hold. The lips do not move with "
     "the new words: say so when the fix is on camera.",
     {"session": SESSION, "take": {"type": "string", "description": "Take number."},
      "file": {"type": "string", "description": "Or a session file (an edit, an audio file)."},
      "old": {"type": "string", "description": "The words to replace, as said."},
      "new": {"type": "string", "description": "The words to say instead."},
      "near": {"type": "number", "description": "When old is said more than once: about where, in seconds."},
      "start": {"type": "number"}, "end": {"type": "number"}, "voice": {"type": "string", "description": "A voice name or id from the ElevenLabs account (voices). Leave out for the default voice (the user picks it in Plugins › Voices)."},
      "model": {"type": "string"}, "stability": {"type": "number"}, "similarity": {"type": "number"},
      "style": {"type": "number"}, "speed": {"type": "number"}},
     ["session", "new"], t_fix_words),
    ("change_voice", "Say a clip again in another voice with the ElevenLabs voice changer: same words, timing "
     "and emotion. The user acts the line, a character voice comes out. Whole file or start/end (at most "
     "5 minutes); writes generated/<file>-<voice>-vN.wav, and an .mp4 with the video for a video.",
     {"session": SESSION, "take": {"type": "string", "description": "Take number."},
      "file": {"type": "string", "description": "Or a session file."}, "voice": {"type": "string", "description": "A voice name or id from the ElevenLabs account (voices). Leave out for the default voice (the user picks it in Plugins › Voices)."},
      "start": {"type": "number"}, "end": {"type": "number"},
      "remove_noise": {"type": "boolean", "description": "Remove background noise first."},
      "model": {"type": "string", "description": "Default eleven_multilingual_sts_v2."}},
     ["session"], t_change_voice),
    ("higgsfield", "Make or change a video with Higgsfield (Seedance, Kling, Veo and 30+ more video "
     "models) from inside Takes. Video only: images go to make_image. Returns at once; the job runs in the background and "
     "the file lands in <session>/generated/<name>-vN, where the Assets tab shows it. With shot=<id> the "
     "storyboard shot shows 'Generating' and then plays the clip (aspect ratio = the storyboard format, "
     "length = the shot's length, 4-15 s). For a shot, write a real-footage prompt from the shot's do and say "
     "(subject, setting, light, camera move); pass image='sketch' to use the sketch only as a composition "
     "reference with params {mode: omni_reference}, and say in the prompt that the result is real footage, not a "
     "drawing. Change a video: video=<session file> with params {mode: video_edit} (Seedance), or "
     "workflow=reframe with aspect_ratio for a new shape. Default model: the one the user picked on Plugins › Higgsfield (higgsfield_status default_model); other models by id (`higgsfield model list` in Bash; `higgsfield model get <id>` for params). "
     "Each job costs the user's Higgsfield credits: one job per ask, never a batch nobody asked for. "
     "Not installed or not signed in: tell the user to open Plugins › Higgsfield.",
     {"session": SESSION,
      "prompt": {"type": "string", "description": "What the result shows. Not needed for workflow=reframe."},
      "shot": {"type": "string", "description": "A storyboard shot id: the clip becomes that shot's video."},
      "image": {"type": "string", "description": "A reference image: a session file, or 'sketch' for the shot's sketch."},
      "start_image": {"type": "string", "description": "First frame (session file or 'sketch')."},
      "end_image": {"type": "string", "description": "Last frame (session file)."},
      "video": {"type": "string", "description": "A session video to change or reframe (take number or path)."},
      "model": {"type": "string", "description": "A Higgsfield model id. Leave out for the default."},
      "workflow": {"type": "string", "enum": list(HF_WORKFLOWS), "description": "reframe (new aspect ratio) or draw_to_video."},
      "aspect_ratio": {"type": "string", "description": "e.g. 16:9, 9:16, 4:5, 1:1."},
      "duration": {"type": "number", "description": "Seconds (video)."},
      "params": {"type": "object", "description": "More model params, e.g. {\"mode\": \"omni_reference\", \"resolution\": \"1080p\"}."},
      "name": {"type": "string", "description": "Short file name. Default: shot-<id> or the prompt's first words."}},
     ["session"], t_higgsfield),
    ("higgsfield_status", "Is Higgsfield installed and signed in, and how many credits are left; with session, "
     "its Higgsfield jobs (running, done, error).",
     {"session": SESSION}, [], t_higgsfield_status),
    ("replicate", "Make or change a video on Replicate: the same models as Higgsfield (Seedance 2.5, Kling, "
     "Veo, ...) at a price per second of video, no plan. Returns at once; the job runs in the background and the "
     "file lands in <session>/generated/<name>-vN.mp4, where the Assets tab shows it. model: owner/name; leave it "
     "out for the user's default (replicate_status lists the default models, the first is the default; pick another "
     "of them when it fits better). Takes maps prompt, image (the FIRST FRAME), end_image, video, duration, "
     "aspect_ratio, resolution and audio to the model's own input names; anything else goes in params by the "
     "model's names (call replicate_model first to see its inputs, defaults and allowed values). File inputs, "
     "in those fields or params, take a session file, a take number or 'sketch' (the shot's sketch); Takes uploads "
     "them. With shot=<id> the storyboard shot shows 'Generating' and then plays the clip (aspect ratio = the "
     "storyboard format, length = the shot's length, 4-15 s). For a shot, write a real-footage prompt from the "
     "shot's do and say; never use the sketch as the first frame (the video would look drawn): pass it only to a "
     "reference-image input if the model has one. Each job costs the user money: one job per ask, never a batch "
     "nobody asked for. No token: tell the user to open Plugins › Replicate.",
     {"session": SESSION,
      "prompt": {"type": "string", "description": "What the clip shows and how the camera moves."},
      "model": {"type": "string", "description": "owner/name (or owner/name:version). Leave out for the default."},
      "shot": {"type": "string", "description": "A storyboard shot id: the clip becomes that shot's video."},
      "image": {"type": "string", "description": "First frame: a session file or take still. Not a sketch."},
      "end_image": {"type": "string", "description": "Last frame (session file)."},
      "video": {"type": "string", "description": "A session video to change (take number or path), for models that take one."},
      "duration": {"type": "number", "description": "Seconds."},
      "aspect_ratio": {"type": "string", "description": "e.g. 16:9, 9:16, 1:1."},
      "resolution": {"type": "string", "description": "e.g. 480p (cheap drafts), 720p, 1080p."},
      "audio": {"type": "boolean", "description": "Make sound with the video, when the model can."},
      "params": {"type": "object", "description": "More inputs by the model's own names (replicate_model lists them)."},
      "name": {"type": "string", "description": "Short file name. Default: shot-<id> or the prompt's first words."}},
     ["session"], t_replicate),
    ("replicate_model", "A Replicate model's inputs (type, default, allowed values, what each does), so a job "
     "can set what the user asks for. Leave model out for the default.",
     {"model": {"type": "string", "description": "owner/name, e.g. bytedance/seedance-2.5."}}, [], t_replicate_model),
    ("replicate_status", "Is a Replicate token set, which account, the user's default video models; with session, "
     "its Replicate jobs (running, done, error).",
     {"session": SESSION}, [], t_replicate_status),
    ("next_path", "The path for a new file: the right folder and the next version. kind=edit: "
     "<session>/edits/<name>-vN.mp4. kind=thumbnail: <session>/thumbnails/<name>-vN.png (the edit's name, plus "
     "an option word for several). kind=library: <library>/assets/<group>/<name>-vN.<ext>. Call it before you "
     "write any of these. For edit and thumbnail it also gives the user's rules for that step once per chat: follow "
     "them.",
     {"kind": {"type": "string", "enum": ["edit", "thumbnail", "library"]},
      "name": {"type": "string", "description": "Short name, e.g. 'webmcp-short' or 'logo-mark'. A -vN suffix is ignored."},
      "session": SESSION, "library": LIBRARY,
      "group": {"type": "string", "description": "kind=library: Logos, Icons, Images, Motion, or another one-word group."},
      "ext": {"type": "string", "description": "File extension. Default .mp4 for edit, .png for thumbnail; required for library."}},
     ["kind", "name"], t_next_path),
    ("get_library", "Read the style a video uses: The user picks one of the named styles per video or per project "
     "(e.g. Magazine), and the project library adds to it. Returns the style's name and 'template', the style "
     "library and the project library (README.md style guide, tokens.json colours/type/spacing/radius, assets "
     "by group with every version, fonts, open comment counts) and the merged tokens. Without project: the "
     "list of styles. Read it before you design anything: a thumbnail, captions, a motion graphic, a slide.",
     {"session": SESSION, "project": {"type": "string", "description": "Project name, when there is no session."}},
     [], t_get_library),
    ("set_style", "Set the style of one video (session) or of a whole project. The user usually picks it on the "
     "app's Assets tab. Only when asked.",
     {"session": SESSION, "project": {"type": "string"},
      "style": {"type": "string", "description": "A style name from get_library. With session, empty = use the project's."}},
     ["style"], t_set_style),
    ("save_to_library", "Keep a reusable part of an edit in the style library: a title card, lower third, caption "
     "look, transition, cover layout, sound. It becomes the next version of assets/<group>/<name>, with your "
     "note, and shows on the app's Styles board, where the user comments on it. Do it after each edit for every "
     "part a later video could use again. Save a playable preview (.mp4 or .png), and pass source_dir to keep "
     "the HyperFrames composition that makes it.",
     {"file": {"type": "string", "description": "The rendered part: absolute, or relative to session."},
      "session": SESSION, "library": LIBRARY,
      "group": {"type": "string", "description": "Motion, Titles, Captions, Covers, Logos, Sounds, or another one-word group."},
      "name": {"type": "string", "description": "Short slug, e.g. 'lower-third'. Same name = a new version."},
      "note": {"type": "string", "description": "One line: what it is and when to use it."},
      "source_dir": {"type": "string", "description": "Optional folder that makes it (e.g. the HyperFrames composition)."}},
     ["file", "group", "name", "note"], t_save_to_library),
    ("create_style", "Start a new style from an example the user gives: a link, a video, an image, or words. Makes "
     "the style folder (status new) and returns the steps: study the source, write the guide and tokens, build "
     "the parts, render the preview. The user compares it with the other styles on the Styles board and keeps or "
     "trashes it.",
     {"name": {"type": "string", "description": "Style name, 1-3 words, e.g. 'Bold Notes'."},
      "description": {"type": "string", "description": "One line: the look."},
      "source": {"type": "string", "description": "What it is made from: the link, file path or words."},
      "template": {"type": "string", "description": "Optional video-edit template it goes with."}},
     ["name", "description"], t_create_style),
    ("copy_library", "Copy library files from one library to another: 'style:<Name>' or a project name (copy "
     "to a new 'style:<Name>' to start a new style from an old one). items are "
     "paths inside the library (README.md, tokens.json, assets/Logos/mark-v2.svg); omit for everything. "
     "tokens.json merges by token name; other existing files are skipped, never overwritten. move=true "
     "trashes the copied files in the source.",
     {"from": LIBRARY, "to": LIBRARY, "items": {"type": "array", "items": S}, "move": {"type": "boolean"}},
     ["from", "to"], t_copy_library),
    ("create_variants", "Add alternative versions of the script (e.g. 'Punchy hook', 'Story first'). "
     "Each shows up as a tab above the teleprompter; the user can read any of them and pick one as main. "
     "Use this instead of overwriting the main script when offering options.",
     {"session": SESSION, "variants": {"type": "array", "items": {"type": "object", "properties": {
         "name": {"type": "string", "description": "Short tab label, 1-4 words."},
         "script": S, "note": {"type": "string", "description": "One line: what is different about this variant."}},
         "required": ["name", "script"]}}}, ["session", "variants"], t_create_variants),
    ("update_variant", "Edit or rename a variant: its script, its name (the tab label) or its note. "
     "History keeps the old text.",
     {"session": SESSION, "variant": {"type": "string", "description": "Variant id from get_session."},
      "script": S, "name": S, "note": S}, ["session", "variant"], t_update_variant),
    ("set_favorite_script", "Mark one script as the favorite (star on its tab): 'main' or a variant id. "
     "Omit draft to clear it.",
     {"session": SESSION, "draft": S}, ["session"], t_set_favorite_script),
    ("promote_variant", "Make a variant the main script. The old main stays in history.",
     {"session": SESSION, "variant": S}, ["session", "variant"], t_promote_variant),
    ("delete_variants", "Move variants to the macOS Trash (their text stays in history).",
     {"session": SESSION, "variants": {"type": "array", "items": S}}, ["session", "variants"], t_delete_variants),
    ("script_history", "List saved versions of the script and variants, newest first, with author, note and a preview.",
     {"session": SESSION}, ["session"], t_script_history),
    ("get_script_version", "Get the full text of one saved version.",
     {"session": SESSION, "version": S}, ["session", "version"], t_get_script_version),
    ("restore_script_version", "Put an old version back (the current text is saved to history first).",
     {"session": SESSION, "version": S}, ["session", "version"], t_restore_script_version),
    ("rename_take", "Name a take. Its files become take-NN-<name>-camera.mov / -screen.mov. Empty name resets.",
     {"session": SESSION, "take": {"type": "integer"}, "name": S}, ["session", "take"], t_rename_take),
    ("import_take", "Add recordings that already exist (e.g. from QuickTime, a phone, a download, or files "
     "placed in the session folder) to a session as takes. Never edit session.json by hand: this names the "
     "file take-NN-[name-]camera.<ext>, gives it the next take number, reads its length and lists it. "
     "One take: path (+ screen_path for its screen recording). Several: takes=[{path, screen_path, name, "
     "keeper}], one take each, in order. Files outside the session are copied (move=true moves them); "
     "files already in the session folder are renamed in place.",
     {"session": SESSION,
      "path": {"type": "string", "description": "The camera (or only) video file of one take."},
      "screen_path": {"type": "string", "description": "Optional: the screen recording of the same take."},
      "name": S, "keeper": {"type": "boolean"},
      "takes": {"type": "array", "items": {"type": "object", "properties": {
          "path": S, "screen_path": S, "name": S, "keeper": {"type": "boolean"},
          "kind": {"type": "string", "enum": ["camera", "screen"],
                   "description": "Kind of path when there is no camera file. Default camera."}},
          "required": ["path"]}},
      "move": {"type": "boolean", "description": "Move files instead of copying them. Default false."}},
     ["session"], t_import_take),
    ("phone_videos", "The videos the user AirDropped from an iPhone that wait in ~/Downloads (AirDrop or iPhone "
     "recordings only; all=true for every video), oldest first, with length, recording time and, with "
     "listen=true, the first words said (Whisper, about 10 s per video). Also lists the newest sessions with "
     "the start of each script, so you can match each video to its session and import_take it with move=true.",
     {"folder": {"type": "string", "description": "Default ~/Downloads."},
      "days": {"type": "integer", "description": "Only files from the last N days. Default 14."},
      "listen": {"type": "boolean", "description": "Transcribe the first 40 s of each video. Default false."},
      "all": {"type": "boolean", "description": "Every video in the folder, not only AirDrop/iPhone ones."}},
     [], t_phone_videos),
    ("set_keeper", "Star or unstar a take as the keeper.",
     {"session": SESSION, "take": {"type": "integer"}, "keeper": {"type": "boolean"}},
     ["session", "take"], t_set_keeper),
    ("set_published", "Mark a session as published once its video is live on social media, so the user and "
     "other agents know it is done (the app shows it on the session). One entry per platform; call again for "
     "each platform. published=false unmarks (with platform: only that one). The user then cleans up the "
     "session's files in the app; do not trash them yourself.",
     {"session": SESSION,
      "platform": {"type": "string", "description": "Where it went live: LinkedIn, X, YouTube, Instagram, TikTok, …"},
      "url": {"type": "string", "description": "Link to the post."},
      "published": {"type": "boolean", "description": "false to unmark. Default true."}},
     ["session"], t_set_published),
    ("set_post_stats", "Save one reading of a published post's numbers (impressions or views, likes, "
     "comments, reposts). Each call adds a reading with the time, so the app's Performance board shows the "
     "latest numbers and the trend. Also marks the platform published and saves url when given.",
     {"session": SESSION,
      "platform": {"type": "string", "description": "LinkedIn, X, YouTube, Instagram, TikTok, …"},
      "url": {"type": "string", "description": "Link to the post, if it is not saved yet."},
      "impressions": {"type": "integer"}, "views": {"type": "integer", "description": "Video views."},
      "likes": {"type": "integer", "description": "Likes or reactions."},
      "comments": {"type": "integer"}, "reposts": {"type": "integer", "description": "Reposts, shares or retweets."}},
     ["session", "platform"], t_set_post_stats),
    ("get_performance", "Every published post across all projects with its latest numbers. needs_reading "
     "marks posts whose numbers are older than stale_hours (default 24) or missing; needs_url marks posts "
     "without a link. dashboard: the last day the Signal board's LinkedIn, follower and X data covers; "
     "when dashboard.stale is not empty, do dashboard.refresh. Use for 'update my post stats' and weekly reviews.",
     {"platform": {"type": "string"}, "stale_hours": {"type": "number"}}, [], t_get_performance),
    ("list_broll", "List the user's own b-roll (_library/broll/<folder>/): self-filmed clips at the desk, "
     "hands typing, reactions, lifestyle, outdoor. Each has title, folder, filmed (YYYY-MM), orientation, "
     "duration, description, keywords and path. Use it for B-ROLL shots in a storyboard or an edit before "
     "asking the user to film new b-roll. The user browses the same clips on the app's B-roll tab.",
     {"query": {"type": "string", "description": "Words that must all be in the title, description or keywords."},
      "folder": {"type": "string", "description": "e.g. Desk work, Hands close-up, Reactions, Lifestyle, Outdoor."},
      "orientation": {"type": "string", "enum": ["vertical", "horizontal"]}}, [], t_list_broll),
    ("search_media", "Find footage by meaning across the whole library, on this Mac: clips by what they "
     "show ('hands typing', 'walking outside at night', 'close-up of a phone'), stills and thumbnails, and "
     "the words said in transcripts and scripts ('where I talk about pricing'). Each hit has path, kind "
     "(video, image, speech, script) and, for video and speech, 'at' (seconds into the file). A b-roll "
     "clip found by its description has 'about' (that description). Best hit first. Use it to find b-roll for a storyboard shot or an edit before asking the user to film it, and "
     "to find an old take or clip the user describes. Same search as ⌘K in the app.",
     {"query": {"type": "string", "description": "What to find, in plain words."},
      "kinds": {"type": "array", "items": {"type": "string", "enum": ["video", "image", "speech", "script"]},
                "description": "Only these kinds. Omit for all."},
      "limit": {"type": "integer", "description": "Default 12."}}, ["query"], t_search_media),
    ("add_broll", "Put b-roll clips into a session's broll/ folder (an APFS clone: no extra disk space), so "
     "they show on its Assets tab next to the takes. Use the file from list_broll.",
     {"session": SESSION, "files": {"type": "array", "items": {"type": "string"},
                                     "description": "From list_broll, e.g. '1 Desk work/2023-11 High-Angle Typing at Desk (V).mov'."}},
     ["session", "files"], t_add_broll),
    ("list_music", "List the user's music and sound effects (_library/audio/Music, SFX, ...): file, title, "
     "artist, genre, bpm, duration, path. New downloads in the source folder (Epidemic Sound) are copied in "
     "first. Use for picking a song or an SFX for an edit. SFX are short effects (whoosh, pop, typing, "
     "notification). Mix songs and effects into a new version of the edit with ffmpeg, under the voice: the "
     "app plays only the file, never a song or an effect beside it. The app's Use button asks you for this.",
     {"group": {"type": "string", "description": "Music or SFX. Omit for all."},
      "query": {"type": "string", "description": "Words in the file name."}}, [], t_list_music),
    ("trash_takes", "Move takes to the macOS Trash (recoverable). Pass take numbers, or non_keepers=true "
     "to trash every take without a star.",
     {"session": SESSION, "takes": {"type": "array", "items": {"type": "integer"}}, "non_keepers": {"type": "boolean"}},
     ["session"], t_trash_takes),
    ("trash_sessions", "Move whole sessions to the macOS Trash (recoverable).",
     {"sessions": {"type": "array", "items": S}}, ["sessions"], t_trash_sessions),
    ("move_sessions", "Move sessions to another project (created if missing).",
     {"sessions": {"type": "array", "items": S}, "project": S}, ["sessions", "project"], t_move_sessions),
    ("clean_voice", "Make a take's voice sound like a proper mic (the user's voice-cleanup: room echo, noise, "
     "clipping, hum, then EQ, compressor and loudness). The first call starts it in the background (about "
     "15-60 s per minute of audio); get_session then shows 'voice' under the take, with 'file' when it is done: "
     "use that WAV as the take's voice in edits instead of the audio in the .mov. Later calls only change the "
     "settings (instant). The user sets the same in the app's player.",
     {"session": SESSION, "take": {"type": "integer"},
      "kind": {"type": "string", "description": "camera (default) or screen: the file with the voice."},
      "strength": {"type": "number", "description": "0-1. How much of the cleanup: 1 = full (default), lower keeps some room."},
      "loudness": {"type": "string", "enum": ["normal", "quiet"], "description": "normal = -14 LUFS (default), quiet = -18 LUFS (under music)."},
      "on": {"type": "boolean", "description": "false = use the original audio (keeps the cleaned files)."},
      "rerun": {"type": "boolean", "description": "Clean again from the raw take."}},
     ["session", "take"], t_clean_voice),
    ("set_best_cut", "Set the best cut of a storyboard take after you checked it. The best_cut from Gemini (or from "
     "the transcript, without a key) is only a first suggestion: compare it with the transcript and the frames, then "
     "write the range you use here (by=agent; the first range stays under gemini). The user sees it on the take in the Storyboard tab. This only "
     "marks a range. To make the clip, call cut_take with that range.",
     {"session": SESSION, "take": {"type": "integer"},
      "start": {"type": "number", "description": "Seconds from the start of the take."},
      "end": {"type": "number"},
      "why": {"type": "string", "description": "One short sentence: what you checked, and what you changed."},
      "clean": {"type": "boolean", "description": "Every word of the shot's lines is there. Default true."},
      "said": {"type": "string", "description": "What the user says in the range, word for word."}},
     ["session", "take", "start", "end", "why"], t_set_best_cut),
    ("cut_take", "Cut takes into one clip: video at a constant frame rate, the voice in sync, and word times "
     "for the clip. It is the default for a cut of a take: it fixes the take's audio offset and frame rate, "
     "moves a cut point that falls inside a word to the word's edge (listed in 'moved'), and uses the take's "
     "clean voice when clean_voice is done. For what it cannot do (a J/L cut, a speed change, a cut inside a "
     "word, an effect), use your own ffmpeg on its clip and .wav, or on the take with get_session's "
     "audio_offset_s, and tell the user what you did. set_best_cut only marks a range; cut_take makes the "
     "video. Writes _work/<name>-vN.mp4, .wav (voice only) and .words.json in the session. "
     "A short cut comes back done; a long one returns a job.",
     {"session": SESSION,
      "segments": {"type": "array", "items": {"type": "object", "properties": {
          "take": {"type": "integer", "description": "Take number."},
          "in": {"type": "number", "description": "Start, in seconds of the take."},
          "out": {"type": "number", "description": "End, in seconds of the take."},
          "kind": {"type": "string", "enum": ["camera", "screen"], "description": "The take's file to cut. Default camera."}},
          "required": ["take", "in", "out"]},
          "description": "The parts to keep, in order: [{take, in, out}], seconds of the take. Add kind: 'screen' "
                         "to cut a take's screen file. rough_cut's cut has this shape."}},
     ["session", "segments"], t_cut_take),
    ("rough_cut", "Make a first cut of the takes against script.md: each script line once (the last full try), "
     "without false starts, stutters, ums and pauses longer than gap. A take with a best cut uses only that "
     "range. Returns the clip (like cut_take) plus dropped (each with why) and missing (script lines no take "
     "has). Show the user the clip and tell them what you dropped and what is missing. It is only a first draft: "
     "improve it freely (edit cut and call cut_take; see cut_take for your own ffmpeg).",
     {"session": SESSION,
      "takes": {"type": "array", "items": {"type": "integer"},
                "description": "Take numbers in the order to use. Default: the keeper takes in session order, else all."},
      "gap": {"type": "number", "description": "The longest pause kept, in seconds. Default 0.25."}},
     ["session"], t_rough_cut),
    ("render_edit", "Build an edit from a recipe, as a job, and check it. First version: recipe={name, cut} (cut = "
     "rough_cut's cut) plus what you need: frame {shape '9:16'|'16:9'|'1:1'|'4:5'|'source', crop}, over "
     "(picture layers: alpha graphics or b-roll, with at/in/out), music and sfx (file, at, gain_db), steps (commands "
     "that make the layers, run in _edit/<name>/), cover (a thumbnail). Next version: base=<name> and changes (a JSON "
     "merge patch on the newest recipe; a list replaces the whole list; {\"name\": \"hook-vertical\"} starts a new "
     "line). Takes uses the clean voice once and never uses a finished edit as an input. One render of a name runs "
     "at a time: to compare two options, give the second a new name. Returns a job; then publish_edit.",
     {"session": SESSION,
      "recipe": {"type": "object", "description": "A whole recipe. For a first version, or to rebuild an edit that "
                 "has no recipe. Times in over, music and sfx are seconds of the cut (a cover adds its own)."},
      "base": {"type": "string", "description": "The edit to start from: 'hook' (its newest version), 'hook-v4' or "
               "'edits/hook-v4.mp4'. Required when the session has more than one edit name with a recipe."},
      "changes": {"type": "object", "description": "A JSON merge patch on the base recipe. A list replaces the whole "
                  "list, so repeat the whole entry: {\"music\": [{\"file\": \"@library/audio/Music/Calm.mp3\", "
                  "\"at\": 0, \"in\": 14, \"gain_db\": -21, \"duck_db\": 8, \"fade_out\": 1.5}]}. "
                  "{\"name\": \"hook-vertical\"} starts a new edit line. null removes a field (\"cover\": null)."},
      "go_back": {"type": "boolean", "description": "true to build on an older version on purpose. Without it, an "
                  "old base is refused."},
      "wait_s": {"type": "integer", "description": "Wait up to this many seconds (max 120) and return the finished "
                 "result inline. Default 0."}},
     ["session"], t_render_edit),
    ("publish_edit", "Save a checked render as the next version, edits/<name>-vN.mp4, with its recipe. In one call: "
     "reads the checks the render ran (it refuses on a failed check; accept=[{rule, why}] for a fail you meant), "
     "puts the version on the posts that follow this edit (a version the user picked stays), answers the review "
     "comments it fixes (replies: like reply_comment; fixed_in and resolve are set for you) and saves note as the "
     "changelog line. Call it once per version. To show another file on a post, call set_post media=... after. "
     "Its review (Gemini watched it, or a frame sheet when there is no key) is for the next version: follow review.note.",
     {"session": SESSION,
      "render": {"type": "string", "description": "The job id from render_edit, or its render path."},
      "note": {"type": "string", "description": "One short line the user reads under the edit, at most 60 "
               "characters. Say what the viewer will notice, in plain words. No field names or numbers in dB. "
               "Example: 'Music softer. Cut the restart at 0:41.'"},
      "replies": {"type": "array", "description": "Comments this version fixes: [{id, text, lesson, rule?}], as in "
                  "reply_comment.", "items": {"type": "object"}},
      "accept": {"type": "array", "description": "[{rule, why}]: failed checks you keep on purpose. rule is a rule "
                 "id or a check id. Saved in the recipe.", "items": {"type": "object"}},
      "go_back": {"type": "boolean", "description": "true to save even when a newer version was saved while this "
                  "render ran."}},
     ["session", "render", "note"], t_publish_edit),
    ("get_edit_recipe", "The recipe of an edit: how it was made (cut list, voice, layers, music, sfx, cover, checks, "
     "the exact commands) and the versions before it. get_session shows a short form of the newest one.",
     {"session": SESSION,
      "edit": {"type": "string", "description": "'hook-v4', 'edits/hook-v4.mp4' or 'hook' for its newest. Default: "
               "the newest edit."}},
     ["session"], t_get_edit_recipe),
    ("export_edit", "Export an edit version as a timeline for DaVinci Resolve, Premiere Pro or Final Cut Pro, made "
     "from its recipe: edits/<name>-vN.fcpxml (Resolve, Final Cut), .premiere.xml (Premiere) and .edl (picture "
     "cut only), next to the version. They link the original take files with the cut's in and out points and "
     "the voice as a WAV on the video clock (the clean voice when the recipe used it). left_out lists what the "
     "timeline does not carry (cover, crop, loudness, music ducking). Only when the user asks for it.",
     {"session": SESSION,
      "edit": {"type": "string", "description": "'hook-v4', 'edits/hook-v4.mp4' or 'hook' for its newest. "
               "Default: the newest edit."}},
     ["session"], t_export_edit),
    ("save_broll", "Save a video of a session into the user's b-roll library (_library/broll/<folder>/, an APFS "
     "clone), so every session can use it (list_broll, add_broll). Gemini describes it in the background and "
     "writes the description and keywords into the clip. Only on the user's ask.",
     {"session": SESSION,
      "file": {"type": "string", "description": "Take number, file in the session ('take-03-camera.mov', "
               "'edits/x.mp4'), or absolute path."},
      "folder": {"type": "string", "description": "A folder from list_broll ('1 Desk work'), or a new one."},
      "name": {"type": "string", "description": "A short name; without it the description names the clip."}},
     ["session", "file", "folder"], t_save_broll),
    ("add_idea", "File one of the user's ideas (a video, a feature, a business idea, anything) as its own "
     "markdown file in the Ideas list, which the user sees on the Mac and the phone. Use it whenever the user says there is "
     "an idea, in any chat, often as a voice message on a walk: one call per idea, so split a message with "
     "several. title: short, in the user's words. text: the idea as said, cleaned of filler but not "
     "rewritten, plus anything the user asked you to add. Call list_ideas with query first when it may already "
     "exist, and add to that one with update_idea append instead. Reply with the title(s) you filed.",
     {"title": {"type": "string", "description": "Short title, 3-8 words."},
      "text": {"type": "string", "description": "The idea in markdown, in the user's words."},
      "tags": {"type": "array", "items": {"type": "string"}, "description": "A few lower-case tags (video, takes, nimo...)."},
      "status": {"type": "string", "enum": ["new", "exploring", "doing", "done", "dropped"], "description": "Default new."},
      "source": {"type": "string", "description": "Where it came from: phone, mac or agent. Default agent."},
      "thumbnail_prompt": {"type": "string", "description": "The prompt for its 16:9 thumbnail, which GPT Image 2.5 "
                           "Sunburst draws in the background with photos of the user as references: one scene "
                           "that shows the idea at a glance, his pose, expression (calm closed-mouth smile), "
                           "clothes, place, one proof element, light, his face on one third and a two-word "
                           "title line. Never describe his face. 60-120 words."}},
     ["title"], t_add_idea),
    ("list_ideas", "The user's ideas, newest change first: id, title, status, tags, dates and the first line. "
     "Without status it leaves out dropped ones. INDEX.md in the same folder lists them all (the app and "
     "this server write it; never edit it).",
     {"status": {"type": "string", "description": "new, exploring, doing, done, dropped or all."},
      "tag": {"type": "string", "description": "Only ideas with this tag."},
      "query": {"type": "string", "description": "Words to find in the title, text or tags."}},
     [], t_list_ideas),
    ("get_idea", "One idea in full: its fields and its markdown text.",
     {"id": {"type": "string", "description": "Idea id from list_ideas."}}, ["id"], t_get_idea),
    ("update_idea", "Change an idea: append a note (dated, under the text: use this to add to an idea), "
     "change status (new, exploring, doing, done, dropped), title or tags, link the session made from it, "
     "or replace the whole text with body (only when the user asks to rewrite it).",
     {"id": {"type": "string", "description": "Idea id from list_ideas."},
      "append": {"type": "string", "description": "A note to add at the end, dated."},
      "status": {"type": "string", "enum": ["new", "exploring", "doing", "done", "dropped"]},
      "title": {"type": "string", "description": "New title."},
      "tags": {"type": "array", "items": {"type": "string"}, "description": "The new tags (replaces them)."},
      "session": {"type": "string", "description": "The session made from it, as 'Project/folder'."},
      "body": {"type": "string", "description": "The whole new text. Replaces it."},
      "thumbnail_prompt": {"type": "string", "description": "A new thumbnail prompt: draws a new version with it."},
      "redraw": {"type": "boolean", "description": "Draw a new version of the thumbnail from its last prompt."}},
     ["id"], t_update_idea),
    ("open_in_app", "Offer the user a project, session or file (e.g. a new edit) in the Takes app. It never takes "
     "focus or plays anything: the session gets a dot and opens only on a click. Once per finished result, not "
     "for drafts or in-between steps.",
     {"path": {"type": "string", "description": "Project name, 'Project/folder', 'Project/folder/edits/x-v2.mp4', or absolute path."}},
     ["path"], t_open_in_app),
    ("run_job", "Run slow work (a render, Demucs, Whisper, matting, any command over about 30 s) in Takes, "
     "never as a background Bash job or with sleep. Returns a job id at once. The job outlives the chat and "
     "Takes, and shows its progress in the session's Jobs row. cmd runs in zsh in the session folder. The "
     "result's note says how to wait.",
     {"session": SESSION,
      "cmd": {"type": "string", "description": "The shell command. Print 'TAKES_PROGRESS 0.4' lines for a progress bar (ffmpeg and N% lines work too)."},
      "outputs": {"type": "array", "items": S, "description": "New files the job writes, relative to the session (paths from next_path). [] if none."},
      "label": {"type": "string", "description": "A few words the user sees, e.g. Render edit v3."}},
     ["session", "cmd", "outputs", "label"], t_run_job),
    ("get_job", "A job's status (starting, running, done, failed, stopped, lost), progress, time left, last "
     "log lines, exit code and files. wait_s waits for the end in this call (other takes tools wait too); call "
     "again to keep waiting. With session and no id: the running jobs and those that ended in the last day.",
     {"id": {"type": "string", "description": "Job id from run_job, higgsfield or replicate."},
      "session": SESSION,
      "wait_s": {"type": "number", "description": "Seconds to wait for the job to end, 0 to 50. Default 0."}},
     [], t_get_job),
    ("stop_job", "Stop a running job and every process it started. Files it wrote so far leave the "
     "session (they go to its .jobs folder). Higgsfield and Replicate clips cannot be stopped.",
     {"id": {"type": "string", "description": "Job id from run_job."}, "session": SESSION},
     ["id"], t_stop_job),
]
if not SOCIAL:
    TOOLS = [t for t in TOOLS if t[0] not in SOCIAL_TOOLS]
BY_NAME = {t[0]: t for t in TOOLS}

# What tools/list adds to the table above (2026-10-10; MCP directories such as Smithery score both):
# a description for each parameter that has none, and the MCP tool hints.
PARAM_DOC = {
    "take": "Take number.", "start": "Start, in seconds.", "end": "End, in seconds.",
    "title": "The title.", "name": "The name.", "script": "The whole script, in markdown.",
    "note": "One line: what changed or why.", "project": "Project name.", "variant": "Variant id from get_session.",
    "variants": "Variant ids from get_session.", "version": "Version id from the history list.",
    "keeper": "true stars the take as the keeper.", "move": "Move instead of copy. Default false.",
    "status": "Which status.", "id": "Item id.", "text": "The text.", "resolve": "true resolves the comment.",
    "fixed_in": "File of the new version, relative to the session or library.",
    "fixed_at": "Seconds into fixed_in where the fix shows.", "sessions": "Sessions as 'Project/folder'.",
    "author": "The post author's name.", "author_url": "The post author's profile URL.",
    "reactions": "Reactions on the post when you read it.", "limit": "At most this many. Default all.",
    "impressions": "Impressions.", "likes": "Likes or reactions.", "replies": "Replies.",
    "comments": "Comments.", "platform": "LinkedIn, X, YouTube, Instagram or TikTok. Default all.",
    "stale_hours": "Numbers older than this are stale. Default 24.",
    "orientation": "Only vertical or only horizontal clips.", "kind": "What kind of file.",
    "items": "Paths inside the library. Omit for everything.", "draft": "'main' or a variant id.",
    "area": "The area the rule is for.", "on": "false turns the rule off, true on.",
    "remove": "true removes the rule.", "search": "Words to search the ElevenLabs voice library for.",
    "gender": "With search: male, female or neutral.", "accent": "With search: e.g. american, british.",
    "language": "With search: language code, e.g. en.", "age": "With search: young, middle_aged or old.",
    "use_case": "With search: e.g. narrative_story, conversational.",
    "model": "ElevenLabs model id. Default: the best one for the job.",
    "stability": "Voice stability 0-1. Default: the voice's own.",
    "similarity": "Similarity to the voice 0-1. Default: the voice's own.",
    "style": "Style exaggeration 0-1. Default: the voice's own.", "speed": "Speech speed 0.7-1.2. Default 1.",
    "open": "Offer the session in the app. Default true.",
    "hooks": "The hook options, best first: [{text, note}].",
    "shots": "The shots in order: [{id, section, kind, say, do, sketch, seconds, video, variants, image, redraw}].",
    "takes": "Several takes: [{path, screen_path, name, keeper, kind}], one take each, in order.",
    "non_keepers": "true trashes every take without a star.",
    "create_project.name": "Name of the new project.", "rename_take.name": "New name. Empty resets it.",
    "import_take.name": "Name for the take.", "update_variant.name": "New tab label, 1-4 words.",
    "update_variant.script": "The variant's new script.", "update_session.title": "New title. Renames the folder.",
    "update_session.script": "The new main script, in markdown.", "create_session.title": "The session's title.",
    "set_style.project": "Project name, to set the style of every session in it.",
    "list_sessions.project": "Project name from list_projects.", "move_sessions.project": "Target project.",
    "list_comment_suggestions.status": "Only suggestions with this status. Default all.",
    "get_comments.status": "open (default), resolved or all.",
    "set_post_status.status": "draft, ready, scheduled or posted.",
    "next_path.kind": "edit, thumbnail or library.", "set_rule.text": "The rule, one short sentence.",
    "set_best_cut.take": "Take number.", "set_best_cut.end": "Seconds from the start of the take.",
    "set_comment_stats.impressions": "Impressions of the comment.",
    "set_post_stats.impressions": "Impressions.", "reply_comment.replies": "One reply per comment: "
    "[{id, text, resolve, fixed_in, fixed_at, lesson, rule}].",
    "create_post_variants.variants": "The versions: [{name, text, tweets, note}].",
    "create_variants.variants": "The variants: [{name, script, note}].",
    "delete_post_variants.variants": "Post variant ids from get_session.",
    "trash_takes.takes": "Take numbers to trash.", "use_post_variant.variant": "Post variant id from get_session.",
    "say": "The shot's lines, word for word from script.md.", "do": "How to film or build it, in one short line.",
    "sketch": "What the frame shows. Never text in the frame.", "redraw": "true draws the sketch again.",
    "path": "Path to the file.", "redraft_comment.id": "Suggestion id from get_comment_context.",
    "set_comment_posted.id": "Suggestion id from list_comment_suggestions.",
    "set_comment_stats.id": "Suggestion id from list_comment_suggestions.", "screen_path": "Path to the screen recording of the same take.",
    "check": "{kind, target, tolerance, max, floor}.",
}
# Tools listed only while their check passes (an admin plugin that is off).
TOOL_GATES = {}
READ_ONLY = {"get_comment_context", "list_comment_suggestions", "list_projects", "list_sessions", "get_session",
             "post_history", "get_post_queue", "get_plan", "get_comments", "get_rules", "script_history",
             "get_script_version", "get_performance", "list_broll", "search_media", "list_music", "get_library",
             "phone_videos", "higgsfield_status", "replicate_status", "replicate_model",
             "list_ideas", "get_idea", "get_job", "get_edit_recipe"}
DESTRUCTIVE = {"trash_takes", "trash_sessions", "delete_variants", "delete_post_variants", "copy_library",
               "set_rule", "set_hooks", "set_post_hooks", "set_storyboard",
               # run_job runs any shell command: clients that gate on destructiveHint must ask first.
               # The Takes chat runs with bypassPermissions, so it sees no prompt.
               "run_job", "stop_job"}
OPEN_WORLD = {"make_image", "voices", "design_voice", "voiceover", "fix_words", "change_voice", "higgsfield",
              "higgsfield_status", "replicate", "replicate_model", "replicate_status", "set_storyboard"}


def documented(tool, schema):
    """A copy of schema with PARAM_DOC filled in where a description is missing (nested items too)."""
    out = dict(schema)
    if "properties" in out:
        props = {}
        for k, v in out["properties"].items():
            doc = v.get("description") or PARAM_DOC.get("%s.%s" % (tool, k)) or PARAM_DOC.get(k)
            props[k] = documented(tool, dict(v, description=doc) if doc else v)
        out["properties"] = props
    if isinstance(out.get("items"), dict):
        out["items"] = documented(tool, out["items"])
    return out


# The tools a Takes chat uses in most turns load with the chat, not behind ToolSearch: long chats
# called ToolSearch about 20 times for them (2026-10-10). Only in the Takes chat (TAKES_CHAT=1, set by
# Chat.swift): a terminal Claude that has takes too keeps them deferred, so its context stays small.
# test_tool_docs keeps the set small.
# set_storyboard, set_post and add_broll stay deferred (2026-10-11): each is the first call of one step
# only, and together they were over a third of the preload.
ALWAYS_LOAD = {"get_session", "get_rules", "next_path", "check_edit", "get_comments", "reply_comment",
               "open_in_app", "run_job", "get_job", "render_edit", "publish_edit"}


def in_takes_chat():
    return os.environ.get("TAKES_CHAT") == "1"


def listed(name, desc, props, req):
    """One tool as tools/list sends it. Other MCP clients ignore _meta."""
    out = {"name": name, "description": desc,
           "inputSchema": documented(name, {"type": "object", "properties": props, "required": req}),
           "annotations": {"readOnlyHint": name in READ_ONLY,
                           "destructiveHint": name in DESTRUCTIVE,
                           "openWorldHint": name in OPEN_WORLD}}
    if in_takes_chat() and name in ALWAYS_LOAD:
        out["_meta"] = {"anthropic/alwaysLoad": True}
    return out


# ---------- JSON-RPC over stdio ----------

# Which tool for which step, at the end of the instructions: an agent finds the tool without a search.
TOOL_INDEX = ("Tools by step. Start: get_session (takes, script, open comments, rules), list_sessions. Plan: "
              "update_session (script), create_variants, set_hooks, set_storyboard. Make: next_path, clean_voice, "
              "rough_cut, cut_take, render_edit, publish_edit, get_edit_recipe, list_broll, add_broll, run_job, get_job, "
              "check_edit, open_in_app. Package: next_path kind=thumbnail, make_image. "
              "Publish: set_post, set_post_hooks, create_post_variants, get_post_queue. Review: get_comments, "
              "reply_comment. Rules: get_rules, set_rule.")
# Ideas are private for now: the public server has no ideas tools, so its instructions skip them.
IDEAS_NOTE = (" Ideas: when the user has an idea, in any chat, file it with add_idea (one per idea, with a "
              "thumbnail_prompt) and say what you filed; list_ideas and update_idea for the rest.") if SOCIAL else ""


def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def server_version(here=None):
    """The Takes version, so a directory (Glama, the MCP registry) shows the release, not a fixed number.
    In a checkout: scripts/version.sh (the newest commit's date). The repo's own Info.plist only holds a
    placeholder, so git comes first. In the app: the release tag, or the build's version, from Info.plist."""
    import plistlib
    here = here or os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(here, "..", "scripts", "version.sh")
    if os.path.exists(script):
        try:
            out = subprocess.run(["bash", script], capture_output=True, text=True, timeout=5).stdout.split()
            if out:
                return out[0]
        except Exception:
            pass
    try:
        with open(os.path.join(here, "..", "Info.plist"), "rb") as f:
            info = plistlib.load(f)
        v = (info.get("ReleaseTag") or "").lstrip("v") or info.get("CFBundleShortVersionString")
        if v:
            return v
    except Exception:
        pass
    return "dev"


def handle(msg):
    method, id_ = msg.get("method"), msg.get("id")
    if id_ is None:
        return  # notification
    if method == "initialize":
        v = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL
        reply(id_, {"protocolVersion": v, "capabilities": {"tools": {}},
                    "serverInfo": {"name": "takes", "version": server_version()},
                    "instructions": "Takes is the user's video recorder. Library = projects > sessions > takes. "
                                    "Every tool takes a session's path or its id (get_session); an old path still "
                                    "works after a rename. Cut takes with rough_cut (a first draft: improve it freely) "
                                    "or cut_take by default: they fix the audio offset and frame rate. For what "
                                    "they cannot do (a J/L cut, a speed change, a cut inside a word, an effect), use "
                                    "your own ffmpeg on cut_take's clip and .wav, or on the take with get_session's "
                                    "audio_offset_s, and say what you did. "
                                    "Each session folder has script.md, session.json, SESSION.md and "
                                    "take-NN-[name-]camera.mov / -screen.mov. Scripts: script.md is main; "
                                    "variants/ are alternatives shown as tabs; history/ keeps every version. "
                                    "Offer options as variants rather than overwriting the main script. "
                                    "For several opening hooks, call set_hooks: The user picks one in the app. "
                                    "The posts for the video (or a text-only post): set_post. platform picks the post: linkedin "
                                    "(default), x (a post or thread), youtube (the long wide video: title + description) or "
                                    "vertical (one 9:16 video and one caption for TikTok, Instagram Reels and YouTube Shorts; "
                                    "title = Shorts title, on = which of the three). The app previews each as a real post. "
                                    "For youtube and vertical, set media to the edit of the right shape (16:9 or 9:16): "
                                    "the newest edit may be the other one. Every post tool takes platform: other versions "
                                    "with create_post_variants, opening options with set_post_hooks, old versions with post_history. "
                                    "Files you make: thumbnails go to <session>/thumbnails/ as <name>-vN (path from "
                                    "next_path). Edits: build each version with render_edit (a recipe: cut list, voice, "
                                    "picture layers, music, sfx, cover), then publish_edit saves it as "
                                    "edits/<name>-vN.mp4 with its recipe beside it. The next version starts from that "
                                    "recipe (render_edit base + changes), never from a script in /tmp or from memory. An edit "
                                    "you make by hand is fine too: its path comes from next_path kind=edit. "
                                    "A finished edit is never an input. Never overwrite a version or a take file. "
                                    "stills/ (frames the user "
                                    "saved) and assets/ (files the user dropped) are read only. "
                                    "Slow work (renders, Demucs, Whisper, matting, anything over about 30 s): start it "
                                    "with run_job, never as a background Bash job or with sleep. If it should end within "
                                    "about 2 min, wait with get_job wait_s=50 and go on. Otherwise tell the user in one line "
                                    "what runs. In the Takes chat, end your turn: Takes sends you a note when "
                                    "it ends. Elsewhere no note comes: check later with get_job. "
                                    "Videos the user AirDrops from a phone land in ~/Downloads: phone_videos finds them, "
                                    "then import_take with move=true puts each into its session. "
                                    "Style library: get_library with the project before designing anything; "
                                    "it gives the style the user picked for that project and its template. Reusable "
                                    "style (README style guide, tokens.json, logos, icons, motion graphics, fonts) "
                                    "lives in a style or a project library, never in a session. "
                                    "The user leaves review comments on edits (time range + frame area), images "
                                    "(area) and text (quoted selection), in sessions and libraries: when "
                                    "get_session or get_library shows open_comments, call get_comments, read each "
                                    "frame PNG, fix, and reply_comment with resolve=true. "
                                    "You cannot hear or watch a video: check_edit is your ears and eyes. Run it on "
                                    "every new edit and fix what it finds before you show it; get_session shows which "
                                    "edits are unchecked. "
                                    "The user's rules from past comments: get_session and next_path give the rules for "
                                    "the next step the first time in a chat; get_rules gives any step. A tool that "
                                    "writes for a step with rules this chat has not seen refuses once and shows them: "
                                    "follow them and send the same call again. "
                                    "A take's voice: clean_voice cleans it (the user's voice-cleanup); when get_session shows voice.file "
                                    "under a take, use that WAV as the take's audio in edits. "
                                    "A take recorded for a storyboard shot has best_cut in get_session. by=gemini or by=transcript is only a "
                                    "first suggestion of the clean delivery (start, end in seconds), not the final cut: "
                                    "check it against the take's words (get_session edit_ready) and a look at the "
                                    "frames at both ends, then set_best_cut with the range you use, even when it "
                                    "stays the same. "
                                    "B-roll: list_broll gives the user's own clips with descriptions; add_broll puts one in "
                                    "a session; save_broll saves a session's video into the library. "
                                    "AI media: the replicate tool (pay per clip, the user's default models) or the higgsfield tool (the user's "
                                    "Higgsfield plan) makes a clip for a storyboard shot or changes a session video; use the one "
                                    "The user names, else replicate when replicate_status shows a token; make_image makes or changes an image (GPT Image 2.5 drafts; when the user likes one, "
                                    "from=<draft> makes the 4K Nano Banana 2.1 final; never Higgsfield for images); results land in generated/. "
                                    "Posting plan: get_plan has the days the user wants to post, the empty slots and the "
                                    "video cards on the Plan board (plan_video puts a session on a day). "
                                    "When the user records a take or an edit is done, say in one positive line which slot it "
                                    "can fill; never nag about gaps. "
                                    "Trashing is recoverable. "
                                    + (TOOL_INDEX.replace("list_broll, add_broll, ", "") if core_only() else TOOL_INDEX)
                                    + IDEAS_NOTE
                                    + (CORE_NOTE if core_only() else "")})
    elif method == "ping":
        reply(id_, {})
    elif method == "tools/list":
        reply(id_, {"tools": [listed(n, d, props, req) for n, d, props, req, _ in TOOLS if shown_tool(n)]})
    elif method == "tools/call":
        p = msg.get("params") or {}
        tool = BY_NAME.get(p.get("name"))
        if not tool:
            reply(id_, error={"code": -32602, "message": "Unknown tool %s" % p.get("name")})
            return
        try:
            RESOLVED.clear()
            out = tool[4](p.get("arguments") or {})
            if RESOLVED and isinstance(out, dict):
                ref, path = next(iter(RESOLVED.items()))
                if "moved_from" in out:  # the tool moved it again: its own note names the new path
                    out = dict(out, resolved_from=ref)
                else:
                    moved = "The session moved to %s. Use this path or the id from now on." % path
                    out = dict(out, resolved_from=ref,
                               note=moved + (" " + out["note"] if isinstance(out.get("note"), str) else ""))
            reply(id_, {"content": [{"type": "text", "text": json.dumps(out, indent=2, ensure_ascii=False)}]})
        except Exception as e:
            reply(id_, {"content": [{"type": "text", "text": "Error: %s" % e}], "isError": True})
    else:
        reply(id_, error={"code": -32601, "message": "Method not found: %s" % method})


# ---------- short tool list ----------
# Cursor uses about 40 tools across all its MCP servers and drops the rest without a word
# (2026-10-10). With TAKES_TOOLS=core (Cursor's entry from --setup) the server lists only these:
# the script, takes, storyboard, edit, long jobs, comments, posts and plan. Others still work when called.
CORE_TOOLS = {
    "list_projects", "list_sessions", "get_session", "create_session", "update_session", "create_variants",
    "set_hooks", "set_storyboard", "set_keeper", "import_take", "next_path", "get_library",
    "get_rules", "get_comments", "reply_comment", "clean_voice", "search_media", "make_image",
    "set_post", "create_post_variants", "set_post_hooks", "get_post_queue", "set_post_status", "get_plan",
    # render_edit runs its render as a job and checks it, so run_job and check_edit made room (2026-10-11).
    "open_in_app", "get_job", "cut_take", "rough_cut", "render_edit", "publish_edit",
}
CORE_NOTE = (" This agent has Takes' short tool list (for its tool limit): b-roll, voices, AI video, phone videos, script "
             "and post history, changes to the posting plan, styles and performance are not listed. Ask in the "
             "Takes chat for those.")


def core_only():
    return os.environ.get("TAKES_TOOLS") == "core"


def shown_tool(name):
    gate = TOOL_GATES.get(name)
    return (not core_only() or name in CORE_TOOLS) and (gate is None or gate())


# ---------- agent setup ----------
# Takes works with any MCP agent (2026-10-10), not only Claude Code. `takes_mcp.py --setup` adds
# this server as "takes" to each agent found on this Mac, or points it again at this copy when the
# app moved. The app runs `--setup --once` at launch: then an agent gets the server one time only,
# so a user who removes it keeps it removed (Claude Code always: the Takes chat runs on it).
# It touches only the "takes" entry. An entry that names no takes_mcp.py, or one that still
# exists, stays as it is: a setup made by hand wins. A config file that is not plain JSON stays too.

# (name, CLI, `mcp add` scope args) for agents with their own `mcp` command.
AGENT_CLIS = [("Claude Code", "claude", ["--scope", "user"]), ("Codex", "codex", [])]
# (name, folder or file that says the agent is here, config files to try, key for its servers).
AGENT_FILES = [
    ("Cursor", ".cursor", [".cursor/mcp.json"], "mcpServers"),  # with TAKES_TOOLS=core
    ("Antigravity", ".gemini/antigravity", [".gemini/config/mcp_config.json"], "mcpServers"),
    ("Gemini CLI", ".gemini/settings.json", [".gemini/settings.json"], "mcpServers"),
    ("opencode", ".config/opencode", [".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"], "mcp"),
    ("pi", ".pi/agent", [".pi/agent/mcp.json"], "mcpServers"),  # read by pi-mcp-adapter
    ("Claude Desktop", "Library/Application Support/Claude",
     ["Library/Application Support/Claude/claude_desktop_config.json"], "mcpServers"),
]
PYTHON = "/usr/bin/python3"


def agent_entry(name, key, server):
    if key == "mcp":  # opencode
        return {"type": "local", "command": [PYTHON, server], "enabled": True}
    if name == "Cursor":
        return {"command": PYTHON, "args": [server], "env": {"TAKES_TOOLS": "core"}}
    return {"command": PYTHON, "args": [server]}


def server_scripts(value):
    """The takes_mcp.py paths an entry (or `mcp get` output) names."""
    if isinstance(value, dict):
        return [p for v in value.values() for p in server_scripts(v)]
    if isinstance(value, list):
        return [p for v in value for p in server_scripts(v)]
    if isinstance(value, str):
        return [w for w in value.split() if w.endswith("takes_mcp.py")]
    return []


def entry_ok(value, name=""):
    """True when an entry needs nothing: made by hand, or its script is there. A Cursor entry
    without env gets the short tool list; one with env (TAKES_TOOLS=all: every tool) stays."""
    paths = server_scripts(value)
    if not paths:
        return True
    if name == "Cursor" and isinstance(value, dict) and "env" not in value:
        return False
    return any(os.path.exists(p) for p in paths)


def find_cli(name, home):
    """In ~/.local/bin, Claude's own folder, or on PATH (the app passes the login shell's)."""
    for d in (home + "/.local/bin", home + "/.claude/local"):
        if os.access(os.path.join(d, name), os.X_OK):
            return os.path.join(d, name)
    return shutil.which(name)


def setup_cli(name, cli, scope, server, add):
    def run(*args):
        try:
            r = subprocess.run([cli, "mcp"] + list(args), capture_output=True, text=True, timeout=30,
                               stdin=subprocess.DEVNULL)
            return r.returncode == 0, r.stdout + r.stderr
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, str(e)
    there, out = run("get", "takes")
    if there and entry_ok(out):
        return "ok"
    if not there and not add:
        return "left out"
    if there:
        run("remove", "takes", *scope)
    ok, out = run("add", "takes", *scope, "--", PYTHON, server)
    if not ok:
        return "failed: " + (out.strip().splitlines() or ["mcp add did not work"])[-1]
    return "updated" if there else "added"


def setup_file(name, paths, key, server, add):
    path = next((p for p in paths if os.path.exists(p)), paths[0])
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                text = f.read()
            data = json.loads(text) if text.strip() else {}
        except (OSError, ValueError):
            return "skipped: %s is not plain JSON" % os.path.basename(path)
        if not isinstance(data, dict):
            return "skipped: %s is not plain JSON" % os.path.basename(path)
    servers = data.get(key)
    if servers is not None and not isinstance(servers, dict):
        return "skipped: %s in %s is not a list of servers" % (key, os.path.basename(path))
    servers = servers or {}
    there = "takes" in servers
    if there and entry_ok(servers["takes"], name):
        return "ok"
    if not there and not add:
        return "left out"
    if key == "mcp" and not data:
        data["$schema"] = "https://opencode.ai/config.json"
    servers["takes"] = agent_entry(name, key, server)
    data[key] = servers
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".takes-tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    return "updated" if there else "added"


def agents_status(home=None):
    """Settings › Agents (2026-10-11): each agent Takes knows, whether it is on this Mac, and whether
    it has the takes server. Reads only; changes nothing."""
    home = home or os.path.expanduser("~")
    out = []
    for name, cmd, _ in AGENT_CLIS:
        cli = find_cli(cmd, home)
        connected = False
        if cli:
            try:
                r = subprocess.run([cli, "mcp", "get", "takes"], capture_output=True, text=True, timeout=30,
                                   stdin=subprocess.DEVNULL)
                connected = r.returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                pass
        out.append({"name": name, "found": bool(cli), "connected": connected})
    for name, folder, files, key in AGENT_FILES:
        found = os.path.exists(os.path.join(home, folder))
        connected = False
        for f in files:
            try:
                with open(os.path.join(home, f)) as fh:
                    servers = (json.load(fh) or {}).get(key)
                connected = isinstance(servers, dict) and "takes" in servers
                break
            except (OSError, ValueError, AttributeError):
                continue
        out.append({"name": name, "found": found, "connected": connected})
    return out


def setup_agents(server, home=None, once=False, only=None):
    """[(agent, status)] for each agent on this Mac. Statuses: added, updated, ok, left out (once:
    added before, then removed by the user), skipped: why, failed: why. `only`: just that agent
    (the Connect button in Settings › Agents)."""
    home = home or os.path.expanduser("~")
    server = os.path.abspath(server)
    state = os.path.join(home, "Library/Application Support/Takes/agents.json")
    try:
        with open(state) as f:
            done = set(json.load(f))
    except (OSError, ValueError):
        done = set()
    out = []
    for name, cmd, scope in AGENT_CLIS:
        cli = find_cli(cmd, home)
        if cli and only in (None, name):
            add = not once or name == "Claude Code" or name not in done
            out.append((name, setup_cli(name, cli, scope, server, add)))
    for name, folder, files, key in AGENT_FILES:
        if os.path.exists(os.path.join(home, folder)) and only in (None, name):
            add = not once or name not in done
            out.append((name, setup_file(name, [os.path.join(home, f) for f in files], key, server, add)))
    done |= {n for n, s in out if s in ("added", "updated", "ok")}
    try:
        os.makedirs(os.path.dirname(state), exist_ok=True)
        with open(state, "w") as f:
            json.dump(sorted(done), f)
    except OSError:
        pass
    return out


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            handle(json.loads(line))
        except Exception as e:
            sys.stderr.write("takes-mcp: %s\n" % e)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--setup"]:
        rest = sys.argv[2:]
        only = rest[rest.index("--only") + 1] if "--only" in rest[:-1] else None
        for agent, status in setup_agents(__file__, once="--once" in rest, only=only):
            print("%s: %s" % (agent, status))
    elif sys.argv[1:2] == ["--agents"]:
        print(json.dumps(agents_status()))
    elif sys.argv[1:2] == ["--voice-run"]:
        voice_run(*sys.argv[2:5])
    elif sys.argv[1:2] == ["--edit-review"]:
        edit_review(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--take-cut"]:
        take_cut(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--broll-save"]:
        save_broll(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--broll-describe"]:
        broll_describe(sys.argv[2], rename="--rename" in sys.argv[3:])
    elif sys.argv[1:2] == ["--idea-thumb"]:
        idea_thumb_run(sys.argv[2])
    elif sys.argv[1:2] == ["--ideas"]:  # the app's Ideas board and the phone: one call, JSON in and out
        try:
            res = ideas_call(sys.argv[2], json.loads(sys.argv[3] if len(sys.argv) > 3 else "{}"))
        except (ValueError, KeyError) as e:
            res = {"error": str(e)}
        print(json.dumps(res))
    elif sys.argv[1:2] == ["--sketch-run"]:
        sketch_run(sys.argv[2], retry="--retry" in sys.argv[3:])
    elif sys.argv[1:2] == ["--detach"]:
        detach_exec(sys.argv[2:])
    elif sys.argv[1:2] == ["--job-run"]:
        job_run(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--higgsfield-run"]:
        higgsfield_run(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--replicate-run"]:
        replicate_run(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--replicate"]:  # the app's Plugins › Replicate: one call, JSON in and out
        try:
            arg = json.loads(sys.argv[3] if len(sys.argv) > 3 else "{}")
            if sys.argv[2] == "save_key":
                rep_save_key(sys.stdin.read())
                res = {"saved": True}
            elif sys.argv[2] == "set_models":
                res = {"models": rep_set_models(arg.get("models") or [])}
            else:
                res = {"status": t_replicate_status, "model": t_replicate_model, "catalog": t_replicate_catalog,
                       "details": t_replicate_details}[sys.argv[2]](arg)
        except (ValueError, KeyError) as e:
            res = {"error": str(e)}
        print(json.dumps(res))
    elif sys.argv[1:2] == ["--higgsfield"]:  # the app's Plugins › Higgsfield browser
        try:
            arg = json.loads(sys.argv[3] if len(sys.argv) > 3 else "{}")
            if sys.argv[2] == "set_default":
                res = {"default": hf_set_default(arg.get("model"))}
            else:
                res = {"catalog": t_higgsfield_catalog, "details": t_higgsfield_details}[sys.argv[2]](arg)
        except (ValueError, KeyError) as e:
            res = {"error": str(e)}
        print(json.dumps(res))
    elif sys.argv[1:2] == ["--eleven"]:  # the app's Plugins › Voices: one tool, JSON in and out
        try:
            if sys.argv[2] == "save_key":
                eleven_save_key(sys.stdin.read())
                res = {"saved": True}
            else:
                res = {"voices": t_voices, "design_voice": t_design_voice}[sys.argv[2]](json.loads(sys.argv[3] if len(sys.argv) > 3 else "{}"))
        except (ValueError, KeyError) as e:
            res = {"error": str(e)}
        print(json.dumps(res))
    elif sys.argv[1:2] == ["--export-edit"]:  # the app's Export for Resolve / Premiere: JSON out
        try:
            res = export_edit(os.path.normpath(os.path.abspath(sys.argv[2])), sys.argv[3])
        except (ValueError, KeyError, OSError) as e:
            res = {"error": str(e)}
        print(json.dumps(res))
    elif sys.argv[1:2] == ["--voice-mix"]:
        voice_mix(*sys.argv[2:4])
    elif sys.argv[1:2] == ["--prepare"]:  # the app saved a take: start its prepare job, return at once
        app_prepare(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1:2] == ["--prepare-run"]:  # the prepare job's command, in the session folder
        os.chdir(sys.argv[2])
        signal.signal(signal.SIGTERM, stop_now)
        prepare_run(sys.argv[3:])
    elif sys.argv[1:2] == ["--cut-run"]:  # the cut job's command, in the session folder
        os.chdir(sys.argv[2])
        signal.signal(signal.SIGTERM, stop_now)
        try:
            cut_run(sys.argv[3])
        except (Exception, SystemExit) as e:  # the last line is the reason the Jobs row shows
            if os.path.exists(sys.argv[3]):
                os.remove(sys.argv[3])
            if isinstance(e, SystemExit):
                raise
            say("Takes could not cut it: %s" % e)
            sys.exit(1)
    elif sys.argv[1:2] == ["--render-run"]:  # the render job's command, in the session folder
        os.chdir(sys.argv[2])
        signal.signal(signal.SIGTERM, stop_now)
        try:
            render_run(sys.argv[3])
        except SystemExit:
            raise
        except BaseException as e:  # the last line is the reason the Jobs row shows
            say(render_failed(e))
            sys.exit(1)
    elif sys.argv[1:2] == ["--session-id"]:
        print(session_id(os.path.normpath(os.path.abspath(sys.argv[2]))))
    else:
        main()
