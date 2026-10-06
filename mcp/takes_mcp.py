#!/usr/bin/env python3
"""MCP server for Takes (stdio, stdlib only).

Lets Claude Code manage the Takes library: projects, sessions, scripts, takes.
It writes the same on-disk format as the app (see Sources/Takes/Library.swift).
The app rescans every 2 seconds, so changes show up without a click.

Register:  claude mcp add takes --scope user -- python3 <path>/takes_mcp.py
"""
import hashlib
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import unicodedata
import urllib.parse
from datetime import datetime, timezone

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


def resolve_session(ref):
    """Accepts an absolute path or 'Project/folder' relative to the library root."""
    path = ref if os.path.isabs(ref) else os.path.join(root(), ref)
    path = os.path.normpath(os.path.expanduser(path))
    if not os.path.isdir(path):
        raise ValueError("No session folder at %s" % path)
    return path


def resolve_project(name):
    path = name if os.path.isabs(name) else os.path.join(root(), name)
    path = os.path.normpath(path)
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
    if meta.get("music"):
        m = meta["music"]
        lines.append("Music: `_library/audio/%s` from %s at %d%%" % (
            m["file"], clock(m.get("start", 0)), round(m.get("volume", 0.35) * 100)))
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


def trash(paths):
    if paths:
        subprocess.run(["/usr/bin/trash"] + list(paths), check=True, capture_output=True)


def session_summary(session):
    meta = read_meta(session)
    takes = meta.get("takes", [])
    numbers = {t["number"] for t in takes}
    keepers = {t["number"] for t in takes if t.get("keeper")}
    script = os.path.join(session, "script.md")
    return {"session": os.path.relpath(session, root()), "path": session, "title": meta["title"],
            "created": meta["createdAt"], "takes": len(numbers), "keepers": len(keepers),
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
    name = a["name"].replace("/", "-").strip()
    if not name:
        raise ValueError("Empty project name.")
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
    for t in sorted(meta.get("takes", []), key=lambda t: (t["number"], t["kind"])):
        v = voice_view(s, t)
        c = cuts.get(str(t["number"]))
        c = {k: v for k, v in c.items() if k not in ("pid", "model")} if c else None
        takes.append(dict(t, path=os.path.join(s, t["file"]), **({"voice": v} if v else {}),
                          **({"best_cut": c} if c else {})))
    return {"session": os.path.relpath(s, root()), "path": s, "title": meta["title"],
            "created": meta["createdAt"], "script": script, "variants": variants(s),
            "favorite_script": meta.get("favorite"),
            "published": meta.get("published") or False,
            "music": music_view(meta.get("music")),
            "style": dict(zip(("name", "picked_by"), style_pick(os.path.dirname(s), s))),
            "sfx": sfx_view(s, meta.get("sfx")),
            "history_versions": len(history(s)), "takes": takes,
            "assets": assets(s, {t["file"] for t in meta.get("takes", [])}),
            "post": post_overview(s),
            "x_post": post_overview(s, "x"),
            "youtube_post": post_overview(s, "youtube"),
            "vertical_post": post_overview(s, "vertical"),
            **({"article": post_overview(s, "article")} if BLOG else {}),
            "hooks": read_hooks(s).get("hooks", []),
            "storyboard": storyboard_view(s),
            "hook_in_script": next((h["id"] for h in read_hooks(s).get("hooks", [])
                                    if h["text"].strip() == first_paragraph(script)), None),
            "open_comments": sum(1 for c in read_comments(s)["comments"] if c.get("status") != "resolved"),
            "folders": FOLDERS,
            "warnings": misplaced(s),
            "library": "Style for this project: get_library with project '%s'." % os.path.basename(os.path.dirname(s)),
            "manifest": os.path.join(s, "SESSION.md")}


# Where each kind of file goes. The one source of truth for Claude; the app shows the same folders.
FOLDERS = {
    "edits/": "Edited videos only, as <slug>-vN.mp4. Get the path from next_path kind=edit.",
    "thumbnails/": "Thumbnail images for an edit, as <slug>-vN.png (options: <slug>-<option>-vN.png). "
                   "Get the path from next_path kind=thumbnail.",
    "stills/": "Frames the user saved from a paused video. Read them; never write here.",
    "storyboard/": "The storyboard and its sketches. Write it only with set_storyboard.",
    "generated/": "AI videos (higgsfield) and images (make_image), as <name>-vN.<ext>. Write here only with those tools.",
    "assets/": "Files the user dropped on the Assets tab. Read them; never write here.",
    "(library)": "Reusable style (logos, icons, images, motion graphics, fonts, colours, type) goes in the "
                 "style or project library, never in a session. See get_library.",
    "(working files)": "Scratch renders, contact sheets and project files stay outside the session folder.",
}


def misplaced(s):
    """Files in the wrong folder, so Claude can see and fix its own mistakes."""
    out = []
    for folder, want, what in (("edits", ("video",), "an edited video"), ("thumbnails", ("image",), "an image")):
        d = os.path.join(s, folder)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.startswith(".") or f.endswith((".words.json", ".srt", ".vtt")):
                continue  # transcripts sit next to their video
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
    """Every version number of <base>-vN.* in folder d."""
    if not os.path.isdir(d):
        return []
    return sorted(v for b, v, _ in (split_version(f) for f in os.listdir(d)) if b == base and v)


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
    n = (have[-1] if have else 0) + 1
    os.makedirs(d, exist_ok=True)
    prev = next((os.path.join(d, f) for f in sorted(os.listdir(d))
                 if split_version(f)[:2] == (base, have[-1])), None) if have else None
    return {"path": os.path.join(d, "%s-v%d%s" % (base, n, ext)), "version": n, "previous": prev,
            "note": "Write the file to exactly this path. Never overwrite an earlier version."}


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
                     "Tell the user it is on the Styles board. He keeps it there, or trashes it."]}


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
    skip_files = {"script.md", "session.json", "SESSION.md", ".order.json", "hooks.json", "comments.json", "evergreen.json", "cuts.json"}
    out = []
    for dirpath, dirs, files in os.walk(s):
        rel = os.path.relpath(dirpath, s)
        top = "" if rel == "." else rel.split(os.sep)[0]
        dirs[:] = [d for d in dirs if not d.startswith(".") and not (rel == "." and d in ("variants", "history", "comments", "posts", "voice", "storyboard"))]
        for f in files:
            if f.startswith(".") or f.endswith(".words.json") or (rel == "." and (f in skip_files or f in take_files)):
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
                    "Then reply_comment with resolve=true."}


def t_reply_comment(a):
    """One reply, or many at once (replies=[...]), in one write."""
    s = comment_root(a)
    data = read_comments(s)
    by_id = {c["id"]: c for c in data["comments"]}
    items = a.get("replies") or [a]
    missing = [r.get("id") for r in items if r.get("id") not in by_id]
    if missing:
        raise ValueError("No comment %s. Use get_comments." % ", ".join(map(str, missing)))
    done = []
    for r in items:
        c = by_id[r["id"]]
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
    write_comments(s, data)
    views = [comment_view(s, c) for c in done]
    return views[0] if len(views) == 1 and not a.get("replies") else {"updated": views}


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
#               image (the sketch file, set when drawn), error (why it could not be drawn)
#   storyboard/<hash>.png        one sketch per shot, named by the hash of its sketch text: a changed sketch
#                                is a new file, an unchanged one is never drawn twice.
#
# The app shows the shots as a horizontal timeline on the Storyboard tab. Sketches are drawn in the
# background (Nano Banana 2.1; GPT Image 2.5 Flare when Gemini fails) and land in the json one by one,
# so the tab fills in while you watch. storyboard/.models.json keeps the model that drew each sketch.

STORYBOARD_DIR = "storyboard"
# Nano Banana 2.1 (out 2026-10-06) is the cheapest of the three image models ($0.034 a 1K image) and
# draws the marker style well; GPT Image 2.5 Flare draws when Gemini fails.
SKETCH_MODELS = ("nano-banana-2.1", "flare")
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
    before = read_storyboard(s)
    old = before["shots"]
    fmt = (a.get("format") or before.get("format") or DEFAULT_FORMAT).strip()
    fmt = parse_format(fmt)
    shots = []
    for i, x in enumerate(a["shots"]):
        say, sketch = (x.get("say") or "").strip(), (x.get("sketch") or "").strip()
        video = shot_video(s, (x.get("video") or "").strip())
        if not sketch and not video:
            raise ValueError("Shot %d has no sketch: say what the frame shows." % (i + 1))
        shot = {"section": shot_section(x), "kind": (x.get("kind") or "SHOT").strip().upper(), "say": say,
                "do": (x.get("do") or "").strip(), "sketch": sketch}
        if x.get("seconds"):
            shot["seconds"] = round(float(x["seconds"]), 1)
        if video:
            # A real clip shows instead of a sketch (the app plays it on hover): nothing to draw.
            shot["video"] = video
        else:
            name = sketch_name(sketch, fmt)
            if os.path.exists(os.path.join(s, STORYBOARD_DIR, name)) and not x.get("redraw"):
                shot["image"] = name
        shots.append(shot)
    for shot, i in zip(shots, shot_ids(old, a["shots"])):
        shot["id"] = i
    # A Higgsfield clip still on its way keeps its place: the runner finds the shot by id.
    running = {o.get("id"): o["generating"] for o in old if o.get("generating")}
    for shot in shots:
        if shot["id"] in running and not shot.get("video"):
            shot["generating"] = running[shot["id"]]
    # The app shows hook, main, end in that order: keep the file in the same order.
    shots.sort(key=lambda x: SECTIONS.index(x["section"]))
    write_storyboard(s, {"shots": shots, "format": fmt})
    for given in a["shots"]:
        if given.get("redraw"):
            p = os.path.join(s, STORYBOARD_DIR, sketch_name((given.get("sketch") or "").strip(), fmt))
            if os.path.exists(p):
                os.remove(p)
    gone = {o.get("id") for o in old} - {x["id"] for x in shots} - {None}
    todo = sum(1 for x in shots if not x.get("image") and not x.get("video"))
    if todo:
        start_sketches(s)
    out = {"shots": len(shots), "format": fmt, "drawing": todo, "ids": [x["id"] for x in shots],
           "note": ("Drawing %d sketches in the background (about 30 s). The Storyboard tab fills in as they land."
                    % todo) if todo else "All sketches already drawn."}
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


def start_sketches(s):
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "--sketch-run", s],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def sketch_run(s):
    """Draw every shot without an image. Runs detached; one runner per session at a time."""
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
        raise ValueError("No GOOGLE_AI_API_KEY in ~/.claude/.env.")
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
#   nano-banana-2.1  cheapest and fast: sketches
#   flare            fast, high quality: a new image
#   sunburst         best quality and editing: a change to an image
# When one fails (no key, no credit), the next one draws. Each file's model goes in .models.json in its
# folder (generated/, storyboard/), and the app shows it.

IMAGE_MODELS = {
    "nano-banana-2.1": ("gemini", "gemini-nano-banana-2.1", "Nano Banana 2.1"),
    "flare": ("openai", "gpt-image-2.5-flare", "GPT Image 2.5 Flare"),
    "sunburst": ("openai", "gpt-image-2.5-sunburst", "GPT Image 2.5 Sunburst"),
}
IMAGE_MODEL = "gpt-image-2.5-flare"


def draw_image(prompt, out, fmt=None, images=(), quality="medium", models=("flare",)):
    """Draw with the first model that works; returns its name ("Nano Banana 2.1")."""
    problems = []
    for m in models:
        api, model_id, label = IMAGE_MODELS[m]
        try:
            if api == "openai":
                openai_image(prompt, out, fmt, images=images, quality=quality, model=model_id)
            else:
                draw_gemini(prompt, out, fmt, model_id, images=images, size="2K" if quality == "high" else "1K")
            return label
        except ValueError as e:
            problems.append("%s: %s" % (label, e))
    raise ValueError(" ".join(problems))


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
    """Make or change an image (Flare new, Sunburst for a change); it lands in generated/<name>-vN.png."""
    s = resolve_session(a["session"])
    prompt = (a.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("Give a prompt: what the image shows, or what to change.")
    refs = a.get("images") or ([a["image"]] if a.get("image") else [])
    if isinstance(refs, str):
        refs = [refs]
    board = read_storyboard(s)
    paths = []
    for ref in refs[:16]:
        if ref == "sketch":
            shot = next((x for x in board["shots"] if x.get("id") == a.get("shot")), None)
            if not shot or not shot.get("image"):
                raise ValueError("'sketch' needs shot=<id> whose sketch is drawn.")
            paths.append(os.path.join(s, STORYBOARD_DIR, shot["image"]))
            continue
        f = session_file(s, ref)
        if media_kind(f) != "image":
            raise ValueError("%s is not an image." % ref)
        paths.append(f)
    fmt = (a.get("format") or "").strip() or (None if paths else "1:1")
    quality = (a.get("quality") or "medium").strip().lower()
    if quality not in ("low", "medium", "high"):
        raise ValueError("quality is low, medium or high.")
    name = slug(a.get("name") or " ".join(prompt.split()[:5])) or "image"
    d = os.path.join(s, GENERATED_DIR)
    os.makedirs(d, exist_ok=True)
    have = versions_in(d, name)
    rel = os.path.join(GENERATED_DIR, "%s-v%d.png" % (name, (have[-1] if have else 0) + 1))
    first = (a.get("model") or ("sunburst" if paths else "flare")).strip().lower()
    if first not in IMAGE_MODELS:
        raise ValueError("model is nano-banana-2.1, flare or sunburst.")
    order = [first] + [m for m in ("flare", "nano-banana-2.1") if m != first]
    label = draw_image(prompt, os.path.join(s, rel), fmt, images=paths, quality=quality, models=order)
    note_model(s, rel, label)
    return {"file": rel, "model": label, "note": "Shows on the Assets tab with the model's name. Look at it before you reply."}


# ---------- Higgsfield: AI video (2026-10-06) ----------
#
# Video only: images go to GPT Image directly (make_image), much cheaper. Takes runs the official `higgsfield` CLI (signed in once from Takes › Settings › Higgsfield, the
# same browser sign-in as Higgsfield's own MCP, no API key). A job runs detached like the sketches:
# the tool returns at once, the file lands in <session>/generated/, and a storyboard shot plays it.

GENERATED_DIR = "generated"
HF_VIDEO_MODEL = "seedance_2_5"
HF_WORKFLOWS = ("reframe", "draw_to_video")
HF_SETUP = "Open Takes › Settings › Higgsfield: Install, then Sign in."


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


def t_higgsfield_status(a):
    """Installed, signed in, credits; and a session's jobs."""
    out = {"installed": higgsfield_cli() is not None}
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
        args = ["generate", "create", (a.get("model") or HF_VIDEO_MODEL).strip()]
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
           "status": "running", "started": now_iso()}
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
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "--higgsfield-run", s, job_path],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


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


def higgsfield_run(s, job_path):
    """Detached: run the job, download the result, put it on its shot."""
    import urllib.request
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
                x["video"] = job["file"]
            edit_shot(s, job["shot"], done)
    except Exception as e:
        job.update(status="error", error=str(e)[:300], ended=now_iso())
        if job.get("shot"):
            def failed(x):
                x.pop("generating", None)
                x["clip_error"] = job["error"]
            edit_shot(s, job["shot"], failed)
    hf_save_job(s, job)


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
    "<Collapse title=\"...\">text</Collapse>; <Tweet id=\"123\" />; inline <Tooltip text=\"meaning\">word</Tooltip>.")
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
            return max(files, key=os.path.getmtime)
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
        return "draft: The user has not marked it ready (schedule it only when he says so, and pass at)"
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
                       "X side. He edits it there and comments on selected text (get_comments file='%s'). "
                       % pf(p, "post")) + \
            ("Tweets %s run over %d characters: the timeline cuts them with 'Show more' (fine with Premium)."
             % (", ".join(map(str, long)), X_FEED_CUT) if long else "")
    elif p == "article":
        out["note"] = ("The user sees it as a post on his blog (Satoshi, the orange accent, the blog's "
                       "components) in the post tab, Article side, and writes in it there (markdown beside the page). "
                       "He comments on selected text (get_comments file='%s'); the quote may be the page's words "
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
                    "The user picks one with 'Use as main' (or you call use_post_variant when he asks)."}


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


def t_create_session(a):
    project = a.get("project") or "Inbox"
    pdir = os.path.join(root(), project.replace("/", "-"))
    os.makedirs(pdir, exist_ok=True)
    title = a.get("title", "").strip()
    date = datetime.now().strftime("%Y-%m-%d")
    folder = unique(os.path.join(pdir, "%s-%s" % (date, slug(title) or "untitled")))
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
    s = resolve_session(a["session"])
    meta = read_meta(s)
    if "script" in a:
        set_main_script(s, a["script"], a.get("author", "claude"), a.get("note", ""))
    if a.get("title", "").strip():
        meta["title"] = a["title"].strip()
        meta["named"] = True
        target = os.path.join(os.path.dirname(s), "%s-%s" % (meta["createdAt"][:10], slug(meta["title"])))
        if target != s:
            target = unique(target)
            os.rename(s, target)
            s = target
    write_meta(s, meta)
    return session_summary(s)


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
            t["file"] = new
        if name:
            t["name"] = name
        else:
            t.pop("name", None)
    if not found:
        raise ValueError("No take %d in this session." % n)
    write_meta(s, meta)
    return t_get_session({"session": s})


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
    return {"session": os.path.relpath(s, root()), "imported": done,
            "note": "The takes show in the app's take list. The originals stay unless move=true "
                    "(files already inside the session folder are renamed in place)."}


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
                    "needs_url: find the post on his profile and pass url to set_post_stats. Only read; "
                    "never like, comment or post."}


# ---------- Music and sound effects ----------
# <root>/_library/audio/<Group>/<file>: Music/, SFX/, ... copied from a source folder (default
# ~/Documents/Epidemic Sound; the app's "soundSource" setting). A session picks one song:
# session.json "music": {"file": "Music/x.mp3", "start": seconds of the song at video 0, "volume": 0-1}.

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


def music_view(m):
    if not m:
        return None
    path = os.path.join(audio_dir(), m["file"])
    return dict(m, title=song_title(m["file"]), path=path, exists=os.path.exists(path),
                note="start = second of the song that plays at 0:00 of the video. volume is what the user "
                     "liked under his voice in the app; use it as the starting mix.")


def sfx_view(s, cues):
    """The sound effects the user placed on the session's videos, with full paths."""
    out = []
    for c in cues or []:
        video = c["video"] if os.path.isabs(c["video"]) else os.path.join(s, c["video"])
        out.append(dict(c, title=song_title(c["file"]), path=os.path.join(audio_dir(), c["file"]), video_path=video))
    return out


def t_set_sfx(a):
    """Replace the sound effects on one video of the session."""
    s = resolve_session(a["session"])
    meta = read_meta(s)
    v = a["video"]
    if os.path.isabs(v) and v.startswith(os.path.normpath(s) + os.sep):
        v = os.path.relpath(v, s)
    if not os.path.exists(v if os.path.isabs(v) else os.path.join(s, v)):
        raise ValueError("No video at %s." % v)
    new = []
    for c in a.get("cues") or []:
        f = c["file"]
        if os.path.isabs(f):
            f = os.path.relpath(f, audio_dir())
        if f.startswith("..") or not os.path.exists(os.path.join(audio_dir(), f)):
            raise ValueError("No sound at _library/audio/%s. Use a file from list_music." % f)
        new.append({"file": f, "video": v, "at": round(float(c["at"]), 2), "volume": float(c.get("volume", 0.8))})
    keep = [c for c in meta.get("sfx") or [] if c.get("video") != v]
    all_ = sorted(keep + new, key=lambda c: (c["video"], c["at"]))
    if all_:
        meta["sfx"] = all_
    else:
        meta.pop("sfx", None)
    write_meta(s, meta)
    return {"session": os.path.relpath(s, root()), "sfx": sfx_view(s, meta.get("sfx"))}


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


def t_set_music(a):
    s = resolve_session(a["session"])
    meta = read_meta(s)
    if not a.get("file"):
        meta.pop("music", None)
    else:
        f = a["file"]
        if os.path.isabs(f):
            f = os.path.relpath(f, audio_dir())
        if f.startswith("..") or not os.path.exists(os.path.join(audio_dir(), f)):
            raise ValueError("No sound at _library/audio/%s. Use a file from list_music." % f)
        old = meta.get("music") or {}
        meta["music"] = {"file": f, "start": float(a.get("start", old.get("start", 0) if old.get("file") == f else 0)),
                         "volume": float(a.get("volume", old.get("volume", 0.35)))}
    write_meta(s, meta)
    return {"session": os.path.relpath(s, root()), "music": music_view(meta.get("music"))}


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
    trash([os.path.join(s, t["file"]) for t in doomed if os.path.exists(os.path.join(s, t["file"]))])
    meta["takes"] = [t for t in meta["takes"] if t["number"] not in numbers]
    write_meta(s, meta)
    return {"trashed_takes": sorted(numbers), "note": "Moved to the macOS Trash."}


def t_trash_sessions(a):
    paths = [resolve_session(x) for x in a["sessions"]]
    trash(paths)
    return {"trashed": [os.path.relpath(p, root()) for p in paths], "note": "Moved to the macOS Trash."}


def t_move_sessions(a):
    dest = os.path.join(root(), a["project"].replace("/", "-"))
    os.makedirs(dest, exist_ok=True)
    moved = []
    for x in a["sessions"]:
        s = resolve_session(x)
        if os.path.dirname(s) == dest:
            continue
        target = unique(os.path.join(dest, os.path.basename(s)))
        os.rename(s, target)
        moved.append(os.path.relpath(target, root()))
    return {"moved": moved}


def t_create_variants(a):
    s = resolve_session(a["session"])
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
# All WAVs are 48 kHz mono float with the same timing as the take, so cut them with the take's times.

VOICE_LOUDNESS = {"normal": 0.0, "quiet": -4.0}  # dB from the script's -14 LUFS: -14 or -18 LUFS
VOICE_DEFAULTS = {"strength": 1.0, "loudness": "normal", "on": True}


def voice_script():
    return os.environ.get("TAKES_VOICE_SCRIPT") or os.path.expanduser(
        "~/.agents/skills/voice-cleanup/scripts/clean_voice.py")


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
        out["use"] = "Use this WAV as the voice of this take in edits (same timing as the take file)."
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
    try:
        if os.environ.get("TAKES_VOICE_CMD"):  # tests: a stand-in for the script
            base = json.loads(os.environ["TAKES_VOICE_CMD"]) + [src]
        else:
            uv, script = find_tool("uv"), voice_script()
            if not uv:
                raise ValueError("uv is not installed (brew install uv).")
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
        v.update(state="done", finished=now_iso())
        v.pop("error", None)
    except Exception as e:
        v.update(state="failed", error=str(e)[:400])
    v.pop("pid", None)
    write_voice(s, key, v)


def start_voice(s, t):
    """Start voice_run in the background (it takes about 15-60 s per minute of audio)."""
    key = voice_key(t["number"], t["kind"])
    v = read_voice(s, key)
    if v and v.get("state") == "running":
        return
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--voice-run", s, str(t["number"]), t["kind"]],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    try:
        with open(voice_files(s, key)["json"]) as f:
            now = json.load(f)
    except (OSError, ValueError):
        now = {}
    if now.get("pid") != p.pid:  # the runner has not written yet
        write_voice(s, key, dict(now or VOICE_DEFAULTS, state="running", pid=p.pid, started=now_iso()))


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
        args = [sys.executable, os.path.abspath(__file__), "--broll-describe", target] + ([] if name else ["--rename"])
        subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
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
    for env in (os.path.expanduser("~/.claude/.env"),):
        try:
            for line in open(env):
                k, _, v = line.strip().partition("=")
                if k.strip().removeprefix("export ").strip() in ("GEMINI_API_KEY", "GOOGLE_AI_API_KEY"):
                    return v.strip().strip('"').strip("'")
        except OSError:
            pass
    return None


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


def gemini_call(path_or_bytes, mime, key, prompt=None, schema=None, ask="Describe this clip."):
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
    body = {"contents": [{"parts": [part, {"text": ask}]}],
            "system_instruction": {"parts": [{"text": prompt or DESCRIBE_PROMPT}]},
            "generationConfig": {"response_mime_type": "application/json", "response_schema": schema or DESCRIBE_SCHEMA,
                                 "temperature": 0.2}}
    req = urllib.request.Request(base + "/v1beta/models/%s:generateContent" % DESCRIBE_MODEL, method="POST",
                                 data=json.dumps(body).encode(), headers=dict(hdr, **{"Content-Type": "application/json"}))
    try:
        out = json.load(urllib.request.urlopen(req, timeout=600))
    except urllib.error.HTTPError as e:
        raise ValueError("Gemini said %s: %s" % (e.code, e.read().decode(errors="replace")[:300]))
    text = "".join(p.get("text", "") for p in out["candidates"][0]["content"]["parts"])
    return json.loads(text)


def describe_video(src, prompt=None, schema=None, ask="Describe this clip.", fps=5):
    """Gemini's JSON answer about one video: its description (DESCRIBE_SCHEMA) unless told otherwise."""
    import tempfile
    if os.environ.get("TAKES_DESCRIBE_CMD"):  # tests: a stand-in that prints the JSON answer
        r = subprocess.run(json.loads(os.environ["TAKES_DESCRIBE_CMD"]) + [src], capture_output=True, text=True)
        if r.returncode != 0:
            raise ValueError(r.stderr.strip() or "The description failed.")
        return json.loads(r.stdout)
    key = gemini_key()
    if not key:
        raise ValueError("No Gemini key: set GOOGLE_AI_API_KEY in ~/.claude/.env.")
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
        return gemini_call(proxy, "video/mp4", key, prompt, schema, ask)
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

CUT_PROMPT = """You pick the best cut of one video take for an editor. The person, the user, records short talking videos. In this take he tries to say the given lines, often more than once, with false starts, pauses and retakes. Find the single best full delivery of the lines: clear, confident, no stumble, every word there. Give its start and end in seconds from the start of the video, tight: start just before the first word, end just after the last word (keep a natural breath, about 0.2 s). If no delivery has every word, pick the best one and set clean to false. If the shot has no lines (b-roll), pick the steadiest, best-looking stretch of about the given length."""

CUT_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "start": {"type": "NUMBER"}, "end": {"type": "NUMBER"},
        "clean": {"type": "BOOLEAN", "description": "Every word of the lines is there, without a stumble."},
        "why": {"type": "STRING", "description": "One short sentence: why this one, and what was wrong with others."},
        "said": {"type": "STRING", "description": "What he says in the picked range, word for word."},
        "attempts": {"type": "INTEGER", "description": "How many times he started the lines."},
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


def take_cut(s, n):
    """Gemini picks the best cut of take n against its storyboard shot's lines. Runs detached."""
    os.environ["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
    t = voice_take(s, n)
    shot = next((x for x in read_storyboard(s)["shots"] if x.get("id") == t.get("shot")), None)
    write_cut(s, n, state="running", pid=os.getpid(), shot=t.get("shot"), error=None)
    try:
        src = os.path.join(s, t["file"])
        say = (shot or {}).get("say", "").strip()
        secs = (shot or {}).get("seconds") or (round(len(say.split()) / 2.6, 1) if say else 4)
        ask = ("The lines:\n%s\n\nAbout %s s when said well." % (say, secs)) if say else \
              ("No lines: a b-roll shot. %s. About %s s." % ((shot or {}).get("how") or "", secs))
        out = describe_video(src, CUT_PROMPT, CUT_SCHEMA, ask, fps=10)
        dur = media_duration(src) or out["end"]
        start, end = max(0.0, float(out["start"])), min(float(dur), float(out["end"]))
        if end <= start:
            raise ValueError("Gemini gave no usable range.")
        write_cut(s, n, state="done", start=round(start, 2), end=round(end, 2), clean=bool(out.get("clean")),
                  why=out.get("why"), said=out.get("said"), attempts=out.get("attempts"),
                  model=DESCRIBE_MODEL, at=now_iso(), pid=None, by="gemini", gemini=None)
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
                                  if old.get("by", "gemini") == "gemini" and old.get("state") == "done" else None)
    write_cut(s, n, state="done", start=round(start, 2), end=round(end, 2), why=a["why"].strip(),
              clean=a.get("clean", True), said=a.get("said"), attempts=None, by="agent", gemini=first,
              shot=t.get("shot") or old.get("shot"), at=now_iso(), error=None, pid=None)
    return {"take": n, "best_cut": read_cuts(s)[str(n)]}


def short_name(text):
    """At most three words, Title Case."""
    words = re.findall(r"[\w'&+-]+", text or "")[:3]
    return " ".join(w if w.isupper() else w[:1].upper() + w[1:] for w in words)


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
    p = os.path.join(comments_dir(), "lessons.md")
    if not os.path.exists(p):
        os.makedirs(comments_dir(), exist_ok=True)
        write_text(p, LESSONS_SEED)
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


def lint_comment(text):
    """The anti-slop gate. Returns None when it passes, else the linter's complaints.
    TAKES_LINT points at another linter (tests); a missing linter lets the draft through."""
    linter = os.environ.get("TAKES_LINT") or os.path.expanduser("~/.claude/shared/anti-slop/lint.py")
    if not os.path.exists(linter):
        return None
    out = subprocess.run([sys.executable, linter, "--platform", "comment"], input=text,
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

# The feed and search pages often carry no post links, and the clipboard is off limits. The
# author's activity page always has them.
SCOUT_LINK = (
    "Every candidate needs the post's own link. If the page you read it on has no "
    "urn:li:activity link for it, open the author's linkedin.com/in/<handle>/recent-activity/all/ "
    "in your tab, find the same post by its first words and take the link from there. No link, no "
    "candidate.")

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
SCOUT_FRESH = "Posts under 12 hours old with at least 20 reactions only."

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
    no_list = "Skip anyone on his target list at %s: the list scout reads them." % targets_file
    feed = ("You are the feed scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
            "Open linkedin.com/feed/ (sorted by most recent if the page offers it) and scroll down, "
            "reading as you go, until you have read about 60 posts or the posts are over 12 hours old. "
            "Note the candidates first, then get their links. " + SCOUT_LINK + " "
            + SCOUT_RULES + " " + SCOUT_FRESH + " " + skip + " "
            + SCOUT_OUTPUT % (NEW_TARGETS, 12))
    lst = ("You are the target-list scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
           "Read his target list at %s. For each person in it, open "
           "linkedin.com/in/<handle>/recent-activity/all/ and read their newest posts (skip their "
           "reposts and comments). Go through the people in this order, the ones read longest ago first, so "
           "every run reaches different people: %s. Stop early at 20 candidates. "
           % (targets_file, shuffled_targets(targets_file))
           + SCOUT_RULES + " Posts under 24 hours old. " + skip + " Also note the people whose "
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
                  "Read his target list at %s. Pick 6 people from its \"Big accounts\" and \"Product "
                  "and growth\" sections, open their linkedin.com/in/<handle>/recent-activity/all/ and "
                  "open their newest own post that is under 48 hours old. Read its top comments. Note "
                  "commenters with a founder, CEO, CTO, head of / VP, product, growth or engineering "
                  "headline whose comment shows real work (a story, numbers, a clear opinion), not "
                  "praise. For up to 8 such people, open their own "
                  "linkedin.com/in/<handle>/recent-activity/all/ and read their newest posts. "
                  % targets_file + SCOUT_RULES + " Posts under 24 hours old with at least 10 "
                  "reactions. " + no_list + " " + skip + " "
                  + SCOUT_OUTPUT % (NEW_TARGETS, 10))
    return {"feed": feed, "list": lst, "search": search, "commenters": commenters}


def t_get_comment_context(a):
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
                 "about_variant": d.get("feedback_variant")}
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
                 "growth or engineering role. Under ~150 comments. A post by someone on the target list: under 24 hours old. "
                 "Anyone else: under 12 hours old with at least 20 reactions (from a commenter scout: under 24 hours, 10 reactions). Skip skip_post_urls "
                 "and skip_authors (commented in the last 2 days). No politics, layoffs or competitor fights. "
                 "Each suggestion needs an angle: what the user can add. No angle, no suggestion. Write 3 "
                 "variants per post, each a different shape (for example a short story from his work, a "
                 "pointed question, a counterpoint or a concrete tip) and length. Study edited_by_user "
                 "most: it shows what he changes. variant_picks shows which shape he picks over which.",
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
SESSION = {"type": "string", "description": "Session as 'Project/folder' (from list_sessions) or an absolute path."}
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
TOOLS = [
    ("get_comment_context", "LinkedIn comment copilot: everything to read before drafting comments for the user. "
     "Returns lessons.md (his rules), the target list, his best past comments, recent examples (approved as is, "
     "edited by him: study these most, declined with reasons, feedback notes, marked best), post URLs and authors "
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
                   "shape (story, question, counterpoint, tip) and length. He picks one."}},
     ["post_url", "author", "post_text", "angle", "variants"], t_add_comment_suggestion),
    ("redraft_comment", "Save a new draft for a suggestion the user gave feedback on (get_comment_context lists "
     "them under waiting_for_redraft, each draft with its variants and feedback note). Three new variants that "
     "follow the note; same slop gate as add_comment_suggestion.",
     {"id": S, "variants": {"type": "array", "items": {"type": "string"}, "minItems": 3, "maxItems": 3,
                   "description": "Three different comments, plain text as the user would type them. Each a different "
                   "shape (story, question, counterpoint, tip) and length. He picks one."}}, ["id", "variants"], t_redraft_comment),
    ("list_comment_suggestions", "List suggested LinkedIn comments, oldest first: review (waiting for the user), "
     "feedback (his note, not sent to you yet), redraft (he gave feedback), approved (to post), posted, declined.",
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
    ("get_session", "Get a session: title, full script, and every take with file path, duration, "
     "keeper flag, name and start time (camera and screen files of one take share a number), plus every "
     "asset file (edits/, thumbnails/, stills/, assets/), the folder rules ('folders') and 'warnings' about "
     "files in the wrong place: fix those.",
     {"session": SESSION}, ["session"], t_get_session),
    ("create_session", "Create a recording session with a title and the script to read on the teleprompter, "
     "optionally with variants. Offers it in the Takes app unless open=false (see open_in_app).",
     {"project": {"type": "string", "description": "Project name. Created if missing. Default Inbox."},
      "title": S, "script": {"type": "string", "description": "Markdown script shown on the teleprompter."},
      "variants": {"type": "array", "items": {"type": "object"}, "description": "Optional [{name, script, note}]."},
      "open": {"type": "boolean"}}, ["title"], t_create_session),
    ("update_session", "Change a session's title (renames its folder) and/or replace its main script. "
     "Script changes are saved to history on both sides, so they can be undone. Give a short note.",
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
     "'video' puts a real clip on the shot instead of a sketch (a file from list_broll, or a file in the "
     "session such as edits/x.mp4); the app shows its frame and plays it on hover. "
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
        + ARTICLE_COMPONENTS + " Read 2-3 of his posts first for his voice (content/blog/*.mdx in "
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
                        "(links, resources, a question). The app shows it under the post as his comment. "
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
     "post history and the variant tab closes. Only when the user asks; he usually does it in the app.",
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
     "media_path (the video to upload), status, at (iso, utc, local in his chosen tz, this_mac = the Mac's "
     "zone, which LinkedIn's scheduler uses) and 'action': what to do on that platform now (schedule, move, "
     "replace text, delete, or nothing). The user sets the times with [schedule] on the post tab, or asks you to pick them.",
     {"platform": {"type": "string", "enum": list(PLATFORMS), "description": "Optional: only this platform."},
      "posted": {"type": "boolean", "description": "Also list posts already live. Default false."},
      "drafts": {"type": "boolean", "description": "Also list drafts (not marked ready yet), e.g. for a "
                 "pipeline overview. Default false."}},
     [], t_get_post_queue),
    ("set_post_status", "Record what you did on LinkedIn or X (platform=x) for a session's post. status=scheduled after you scheduled "
     "it (records the time and text you scheduled, so later changes show up as an action); status=posted "
     "with url once it is live (also marks the session published); ready to undo. The user marks posts ready "
     "himself; only set ready or draft when he asks. A post he asked you to schedule that has no time: "
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
    ("get_comments", "The user's review comments, in a session (edits, thumbnails, stills, scripts) or in a "
     "library (pass library instead of session). Video: a time ('when', start/end seconds), an optional area "
     "(rect = x,y,w,h fractions from top left) and a 'frame' PNG of that moment with the area outlined in "
     "orange: read it to see what he means; 'said' quotes the words spoken around that time when the video "
     "has a transcript next to it (<stem>.words.json, .srt or .vtt). Image: rect + frame. Text (script.md, variants/<slug>.md, a "
     "library README.md or tokens.json): 'quote' is the text he selected. Default: open comments.",
     {"session": SESSION, "library": LIBRARY,
      "file": {"type": "string", "description": "Optional: only this file, e.g. 'edits/hook-v2.mp4'."},
      "status": {"type": "string", "enum": ["open", "resolved", "all"]}}, [], t_get_comments),
    ("reply_comment", "Reply to review comments and/or resolve them. After a round of fixes, send ONE call with "
     "replies=[{id, text, resolve, fixed_in, fixed_at}] for every comment. fixed_in is the new version's file "
     "(e.g. 'edits/hook-v4.mp4') and fixed_at the second in it where the fix shows: The user clicks the reply to "
     "jump there. Keep text to one line ('Caption 20% smaller'). Ask a question with resolve omitted when a "
     "comment is unclear.",
     {"session": SESSION, "library": LIBRARY,
      "replies": {"type": "array", "items": {"type": "object", "properties": {
          "id": {"type": "string", "description": "Comment id, e.g. 'c3'."}, "text": S, "resolve": {"type": "boolean"},
          "fixed_in": {"type": "string", "description": "File of the new version, relative to the session or library."},
          "fixed_at": {"type": "number", "description": "Seconds into fixed_in where the fix shows."}},
          "required": ["id"]}},
      "id": {"type": "string", "description": "Single reply: comment id. Prefer replies=[...]."},
      "text": S, "resolve": {"type": "boolean"}, "fixed_in": S, "fixed_at": {"type": "number"}},
     [], t_reply_comment),
    ("make_image", "Make or change an image straight from Google or OpenAI (much cheaper than a Higgsfield "
     "image: never use higgsfield for images). Models: flare (GPT Image 2.5 Flare, fast, high quality: the "
     "default for a new image), sunburst (GPT Image 2.5 Sunburst, best quality and editing: the default for a "
     "change), nano-banana-2.1 (cheapest, fast). When one fails the next one draws. Waits about 10-60 s and "
     "returns the file, <session>/generated/<name>-vN.png, and the model that drew it; the Assets tab shows "
     "both. Change an image: images=[session files] (a thumbnail, a still, 'sketch' with shot=<id>) and say "
     "what to change. One image per ask.",
     {"session": SESSION,
      "prompt": {"type": "string", "description": "What the image shows, or what to change in the given images."},
      "images": {"type": "array", "items": {"type": "string"},
                 "description": "Session images to change or use as references (paths, or 'sketch' with shot)."},
      "shot": {"type": "string", "description": "With images=['sketch']: the shot whose sketch to use."},
      "format": {"type": "string", "description": "Shape, e.g. 16:9, 9:16, 4:5, 1:1. Default 1:1, or the input's shape."},
      "quality": {"type": "string", "enum": ["low", "medium", "high"], "description": "Default medium."},
      "model": {"type": "string", "enum": list(IMAGE_MODELS), "description": "Default flare, or sunburst with images."},
      "name": {"type": "string", "description": "Short file name. Default: the prompt's first words."}},
     ["session", "prompt"], t_make_image),
    ("higgsfield", "Make or change a video with Higgsfield (Seedance, Kling, Veo and 30+ more video "
     "models) from inside Takes. Video only: images go to make_image. Returns at once; the job runs in the background and "
     "the file lands in <session>/generated/<name>-vN, where the Assets tab shows it. With shot=<id> the "
     "storyboard shot shows 'Generating' and then plays the clip (aspect ratio = the storyboard format, "
     "length = the shot's length, 4-15 s). For a shot, write a real-footage prompt from the shot's do and say "
     "(subject, setting, light, camera move); pass image='sketch' to use the sketch only as a composition "
     "reference with params {mode: omni_reference}, and say in the prompt that the result is real footage, not a "
     "drawing. Change a video: video=<session file> with params {mode: video_edit} (Seedance), or "
     "workflow=reframe with aspect_ratio for a new shape. Default model: seedance_2_5; other models by id (`higgsfield model list` in Bash; `higgsfield model get <id>` for params). "
     "Each job costs the user's Higgsfield credits: one job per ask, never a batch he did not ask for. "
     "Not installed or not signed in: tell him to open Settings › Higgsfield.",
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
    ("next_path", "Get the path for a new file you make: the right folder and the next version number. "
     "kind=edit: <session>/edits/<name>-vN.mp4. kind=thumbnail: <session>/thumbnails/<name>-vN.png (use the "
     "edit's name, plus an option word if you offer several). kind=library: <library>/assets/<group>/<name>-vN.<ext>. "
     "Always call this before you write an edit, a thumbnail or a library asset.",
     {"kind": {"type": "string", "enum": ["edit", "thumbnail", "library"]},
      "name": {"type": "string", "description": "Short name, e.g. 'webmcp-short' or 'logo-mark'. A -vN suffix is ignored."},
      "session": SESSION, "library": LIBRARY,
      "group": {"type": "string", "description": "kind=library: Logos, Icons, Images, Motion, or another one-word group."},
      "ext": {"type": "string", "description": "File extension. Default .mp4 for edit, .png for thumbnail; required for library."}},
     ["kind", "name"], t_next_path),
    ("get_library", "Read the style a video uses: The user picks one of his named styles per video or per project "
     "(e.g. Magazine), and the project library adds to it. Returns the style's name and 'template', the style "
     "library and the project library (README.md style guide, tokens.json colours/type/spacing/radius, assets "
     "by group with every version, fonts, open comment counts) and the merged tokens. Without project: the "
     "list of styles. Read it before you design anything: a thumbnail, captions, a motion graphic, a slide.",
     {"session": SESSION, "project": {"type": "string", "description": "Project name, when there is no session."}},
     [], t_get_library),
    ("set_style", "Set the style of one video (session) or of a whole project. The user usually picks it on the "
     "app's Assets tab. Only when he asks.",
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
     "the parts, render the preview. He compares it with his other styles on the Styles board and keeps or "
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
    ("phone_videos", "The videos the user AirDropped from his iPhone that wait in ~/Downloads (AirDrop or iPhone "
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
    ("list_broll", "List the user's own b-roll (_library/broll/<folder>/): self-filmed clips of him at his desk, "
     "hands typing, reactions, lifestyle, outdoor. Each has title, folder, filmed (YYYY-MM), orientation, "
     "duration, description, keywords and path. Use it for B-ROLL shots in a storyboard or an edit before "
     "asking him to film new b-roll. He browses the same clips on the app's B-roll tab.",
     {"query": {"type": "string", "description": "Words that must all be in the title, description or keywords."},
      "folder": {"type": "string", "description": "e.g. Desk work, Hands close-up, Reactions, Lifestyle, Outdoor."},
      "orientation": {"type": "string", "enum": ["vertical", "horizontal"]}}, [], t_list_broll),
    ("add_broll", "Put b-roll clips into a session's broll/ folder (an APFS clone: no extra disk space), so "
     "they show on its Assets tab next to the takes. Use the file from list_broll.",
     {"session": SESSION, "files": {"type": "array", "items": {"type": "string"},
                                     "description": "From list_broll, e.g. '1 Desk work/2023-11 High-Angle Typing at Desk (V).mov'."}},
     ["session", "files"], t_add_broll),
    ("list_music", "List the user's music and sound effects (_library/audio/Music, SFX, ...): file, title, "
     "artist, genre, bpm, duration, path. New downloads in his source folder (Epidemic Sound) are copied in "
     "first. Use for picking a song or an SFX for an edit. SFX are short effects (whoosh, pop, typing, "
     "notification): mix them into the edit at a cut or a moment with ffmpeg, under the voice.",
     {"group": {"type": "string", "description": "Music or SFX. Omit for all."},
      "query": {"type": "string", "description": "Words in the file name."}}, [], t_list_music),
    ("set_music", "Pick the song for a session's video (the user tries songs under the video in the app's "
     "sounds tab and picks one there too). get_session returns it as 'music' with its path, start and "
     "volume: use that song in the edit. Omit file to clear. Only suggest; ask before replacing his pick.",
     {"session": SESSION, "file": {"type": "string", "description": "From list_music, e.g. 'Music/26428_Chasing the Truth.mp3'."},
      "start": {"type": "number", "description": "Second of the song that plays at the start of the video."},
      "volume": {"type": "number", "description": "0-1, under the voice. Default 0.35."}},
     ["session"], t_set_music),
    ("set_sfx", "Place sound effects on one of the session's videos (a take or an edit): each cue is a file "
     "from list_music (SFX/...) at a second of that video. Replaces that video's cues; cues=[] clears them. "
     "The user places them in the app too (sounds tab, 'add at'), and hears them when the video plays. "
     "get_session returns them as 'sfx' with path and video_path: mix each into the edit at 'at', at 'volume' "
     "(0-1, relative to the file). A cue on a take is a moment of the raw take: map it through your cut list.",
     {"session": SESSION, "video": {"type": "string", "description": "The video, relative to the session "
                                                                   "(take-02-camera.mov, edits/x-v3.mp4)."},
      "cues": {"type": "array", "items": {"type": "object", "properties": {
          "file": S, "at": {"type": "number"}, "volume": {"type": "number"}}, "required": ["file", "at"]}}},
     ["session", "video"], t_set_sfx),
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
    ("set_best_cut", "Set the best cut of a storyboard take after you checked it. Gemini's best_cut is only a "
     "first suggestion: compare it with the transcript and the frames, then write the range you use here "
     "(by=agent; Gemini's range stays under gemini). The user sees it on the take in the Storyboard tab.",
     {"session": SESSION, "take": {"type": "integer"},
      "start": {"type": "number", "description": "Seconds from the start of the take."},
      "end": {"type": "number"},
      "why": {"type": "string", "description": "One short sentence: what you checked, and what you changed."},
      "clean": {"type": "boolean", "description": "Every word of the shot's lines is there. Default true."},
      "said": {"type": "string", "description": "What he says in the range, word for word."}},
     ["session", "take", "start", "end", "why"], t_set_best_cut),
    ("save_broll", "Save a video of a session into the user's b-roll library (_library/broll/<folder>/, an APFS "
     "clone), so every session can use it (list_broll, add_broll). Gemini describes it in the background and "
     "writes the description and keywords into the clip. Only on the user's ask.",
     {"session": SESSION,
      "file": {"type": "string", "description": "Take number, file in the session ('take-03-camera.mov', "
               "'edits/x.mp4'), or absolute path."},
      "folder": {"type": "string", "description": "A folder from list_broll ('1 Desk work'), or a new one."},
      "name": {"type": "string", "description": "A short name; without it the description names the clip."}},
     ["session", "file", "folder"], t_save_broll),
    ("open_in_app", "Offer the user a project, session or file (e.g. a new edit) in the Takes app. It never "
     "takes focus and never changes his screen or plays anything: the session gets a dot and the stage a "
     "notice, and it opens only when he clicks it. He often works in another session while you run, so "
     "call it once per finished result, not for drafts or in-between steps.",
     {"path": {"type": "string", "description": "Project name, 'Project/folder', 'Project/folder/edits/x-v2.mp4', or absolute path."}},
     ["path"], t_open_in_app),
]
BY_NAME = {t[0]: t for t in TOOLS}


# ---------- JSON-RPC over stdio ----------

def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(msg):
    method, id_ = msg.get("method"), msg.get("id")
    if id_ is None:
        return  # notification
    if method == "initialize":
        v = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL
        reply(id_, {"protocolVersion": v, "capabilities": {"tools": {}},
                    "serverInfo": {"name": "takes", "version": "0.5"},
                    "instructions": "Takes is the user's video recorder. Library = projects > sessions > takes. "
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
                                    "Files you make: edited videos go to <session>/edits/, thumbnails to "
                                    "<session>/thumbnails/, both as <name>-vN; always get the path from "
                                    "next_path, never overwrite a version or a take file. stills/ (frames the user "
                                    "saved) and assets/ (files he dropped) are his: read only. "
                                    "Videos the user AirDrops from his phone land in ~/Downloads: phone_videos finds them, "
                                    "then import_take with move=true puts each into its session. "
                                    "Style library: get_library with the project before designing anything; "
                                    "it gives the style the user picked for that project and its template. Reusable "
                                    "style (README style guide, tokens.json, logos, icons, motion graphics, fonts) "
                                    "lives in a style or a project library, never in a session. "
                                    "The user leaves review comments on edits (time range + frame area), images "
                                    "(area) and text (quoted selection), in sessions and libraries: when "
                                    "get_session or get_library shows open_comments, call get_comments, read each "
                                    "frame PNG, fix, and reply_comment with resolve=true. "
                                    "A take's voice: clean_voice cleans it (the user's voice-cleanup); when get_session shows voice.file "
                                    "under a take, use that WAV as the take's audio in edits. "
                                    "A take recorded for a storyboard shot has best_cut in get_session. by=gemini is only Gemini's "
                                    "first suggestion of the clean delivery (start, end in seconds), not the final cut: "
                                    "check it yourself before you cut (Whisper word times against the shot's lines, a "
                                    "look at the frames at both ends, the other tries), then set_best_cut with the "
                                    "range you use, even when it stays the same. "
                                    "B-roll: list_broll gives the user's own clips with descriptions; add_broll puts one in "
                                    "a session; save_broll saves a session's video into the library. "
                                    "AI media: the higgsfield tool makes a clip for a storyboard shot or changes a session "
                                    "video; make_image makes or changes an image (Nano Banana 2.1 or GPT Image 2.5, never Higgsfield for "
                                    "images); results land in generated/. "
                                    "Trashing is recoverable."})
    elif method == "ping":
        reply(id_, {})
    elif method == "tools/list":
        reply(id_, {"tools": [{"name": n, "description": d,
                               "inputSchema": {"type": "object", "properties": props, "required": req}}
                              for n, d, props, req, _ in TOOLS]})
    elif method == "tools/call":
        p = msg.get("params") or {}
        tool = BY_NAME.get(p.get("name"))
        if not tool:
            reply(id_, error={"code": -32602, "message": "Unknown tool %s" % p.get("name")})
            return
        try:
            out = tool[4](p.get("arguments") or {})
            reply(id_, {"content": [{"type": "text", "text": json.dumps(out, indent=2, ensure_ascii=False)}]})
        except Exception as e:
            reply(id_, {"content": [{"type": "text", "text": "Error: %s" % e}], "isError": True})
    else:
        reply(id_, error={"code": -32601, "message": "Method not found: %s" % method})


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
    if sys.argv[1:2] == ["--voice-run"]:
        voice_run(*sys.argv[2:5])
    elif sys.argv[1:2] == ["--take-cut"]:
        take_cut(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--broll-save"]:
        save_broll(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--broll-describe"]:
        broll_describe(sys.argv[2], rename="--rename" in sys.argv[3:])
    elif sys.argv[1:2] == ["--sketch-run"]:
        sketch_run(sys.argv[2])
    elif sys.argv[1:2] == ["--higgsfield-run"]:
        higgsfield_run(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["--voice-mix"]:
        voice_mix(*sys.argv[2:4])
    else:
        main()
