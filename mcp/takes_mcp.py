#!/usr/bin/env python3
"""MCP server for Takes (stdio, stdlib only).

Lets Claude Code manage the Takes library: projects, sessions, scripts, takes.
It writes the same on-disk format as the app (see Sources/Takes/Library.swift).
The app rescans every 2 seconds, so changes show up without a click.

Register:  claude mcp add takes --scope user -- python3 <path>/takes_mcp.py
"""
import concurrent.futures
import glob
import hashlib
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
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
                          **({"best_cut": c} if c else {}), **take_said(s, t, meta.get("takes", []))))
    return {"session": os.path.relpath(s, root()), "path": s, "title": meta["title"],
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
    "generated/": "AI videos (replicate, higgsfield) and images (make_image), as <name>-vN.<ext>. Write here only with those tools.",
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
    if kind == "edit":
        need_rules(*EDIT_AREAS)
    elif kind == "thumbnail":
        need_rules("thumbnail")
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
    done = []
    for r in items:
        c = by_id[r["id"]]
        if lessons is not None and r.get("lesson"):
            apply_lesson(lessons, s, c, r)
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
    return views[0] if len(views) == 1 and not a.get("replies") else {"updated": views}


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
# Rules stay few and short (AREA_MAX per area, RULE_MAX characters): every chat reads them.
AREAS = ["storyboard", "script", "sound", "cut", "picture", "captions", "graphics", "thumbnail",
         "post-all", "post-linkedin", "post-x", "post-youtube", "post-vertical", "other"]
EDIT_AREAS = ["sound", "cut", "picture", "captions", "graphics"]
AREA_MAX = 10
RULE_MAX = 220
CHECKS = {
    "loudness": "Integrated loudness in LUFS: {target, tolerance} (default -14 ± 1).",
    "peak": "True peak in dBTP: {max} (default -1).",
    "pauses": "No silence longer than {max} seconds (default 0.4), quieter than {floor} dB (default -35).",
    "length": "At most {max} seconds long.",
}
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
                rules += [dict(r, area=area) for r in json.load(f).get("rules", [])]
        except FileNotFoundError:
            pass
        except (OSError, ValueError):
            bad.append(area)
    return {"rules": rules, "unreadable": bad}


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


# The steps this chat has read the rules for. A tool that writes for a step refuses once when they are
# unread, and the refusal carries them, so no agent writes a post or an edit without them (2026-10-09:
# "make sure the agents actually look into those"). One MCP process is one chat.
RULES_SEEN = set()


def need_rules(*areas):
    want = [x for x in areas if x not in RULES_SEEN]
    if not want:
        return
    RULES_SEEN.update(want)
    rules = [r for r in read_lessons()["rules"] if r.get("on", True) and r["area"] in want]
    lines = ["- %s: %s" % (r["id"], r["text"]) for r in rules]
    if "comments" in want:
        text = read_text(lessons_path()).strip()
        if text:
            lines.append(text)
    if not lines:
        return
    raise ValueError("Nothing written yet. First read the user's rules for %s; they come from his comments. "
                     "Check your work against each one, then call again:\n%s" % (", ".join(want), "\n".join(lines)))


def rule_view(r):
    v = {"id": r["id"], "area": r["area"], "text": r["text"]}
    if r.get("check"):
        v["check"] = r["check"]
    if r.get("repeats"):
        v["repeated"] = len(r["repeats"])
    if r.get("by") == "you":
        v["by_user"] = True
    return v


def comment_ref(s, cid):
    return "%s#%s" % (os.path.relpath(s, root()), cid)


def clean_check(c):
    if not c:
        return None
    if not isinstance(c, dict) or c.get("kind") not in CHECKS:
        raise ValueError("check.kind is one of: %s." % ", ".join(sorted(CHECKS)))
    out = {"kind": c["kind"]}
    for k in ("target", "tolerance", "max", "floor"):
        if c.get(k) is not None:
            out[k] = float(c[k])
    return out


def new_rule(d, area, text, check=None, by="takes", ref=None):
    """Adds a rule to d (not written). Refuses a full area: merge or remove one first."""
    area = (area or "").strip().lower()
    if area not in AREAS:
        raise ValueError("area is one of: %s." % ", ".join(AREAS))
    text = " ".join((text or "").split())
    if not text:
        raise ValueError("Give the rule's text: one short sentence.")
    if len(text) > RULE_MAX:
        raise ValueError("Rule is %d characters; keep it under %d. One rule, one sentence." % (len(text), RULE_MAX))
    on = [r for r in d["rules"] if r["area"] == area and r.get("on", True)]
    if len(on) >= AREA_MAX:
        raise ValueError("The %s area has %d rules, the most it keeps. Merge two into one (set_rule id=... "
                         "text=...) or remove one (set_rule id=... remove=true), then add this one. Or use "
                         "lesson 'one-off'." % (area, len(on)))
    n = 1 + max([int(r["id"].rsplit("-", 1)[1]) for r in d["rules"]
                 if r["id"].startswith(area + "-") and r["id"].rsplit("-", 1)[1].isdigit()] or [0])
    r = {"id": "%s-%d" % (area, n), "area": area, "text": text, "on": True, "by": by, "made": now_iso(),
         "from": [ref] if ref else [], "repeats": []}
    c = clean_check(check)
    if c:
        r["check"] = c
    d["rules"].append(r)
    return r


def t_get_rules(a):
    """The rules learned from the user's comments, the ones that are on."""
    d = read_lessons()
    areas = a.get("area")
    if isinstance(areas, str):
        areas = [x.strip() for x in areas.split(",") if x.strip()]
    if not areas:
        # Only the list of steps: every rule at once is ~4k tokens, and an agent needs one or two steps
        # (2026-10-09). area=all still gives everything, for the Feedback board.
        on = [r for r in d["rules"] if r.get("on", True)]
        steps = [{"area": x, "rules": n} for x in AREAS for n in [sum(r["area"] == x for r in on)] if n]
        lines = [l for l in read_text(lessons_path()).splitlines() if l.lstrip().startswith("-")]
        steps.append({"area": "comments", "rules": len(lines)})
        return {"steps": steps, "note": "Call get_rules again with the steps you work on, e.g. area='post-all,"
                "post-x', 'script', 'edit' (sound, cut, picture, captions, graphics), 'thumbnail', "
                "'comments'. area='all' gives every rule."}
    if "all" in areas:
        areas = []
    # "post" is every post file; "edit" the five steps of an edit.
    areas = [y for x in (areas or []) for y in ([z for z in AREAS if z.startswith("post-")] if x == "post"
                                                else EDIT_AREAS if x == "edit" else [x])]
    RULES_SEEN.update(areas or AREAS + ["comments"])
    rules = [rule_view(r) for r in d["rules"] if r.get("on", True) and (not areas or r["area"] in areas)]
    out = {"rules": rules}
    if not areas or "comments" in areas:
        out["comments"] = read_text(lessons_path())
    out["note"] = ("Follow every rule here; they come from the user's comments. A rule the user wrote or changed "
                   "(by_user) wins over anything else. 'comments' holds the comment copilot's lessons. Before you "
                   "show an edit, run check_edit on it. When you resolve a comment, give it a lesson in "
                   "reply_comment: an existing rule id, 'new' with rule={area, text}, or 'one-off' (area 'post' "
                   "picks the platform from the commented file). Keep the set small: at most %d per area, so "
                   "merge or sharpen a rule before you add one." % AREA_MAX)
    return out


def t_set_rule(a):
    """Add, change, turn off or remove one rule."""
    d = read_lessons()
    if not a.get("id"):
        r = new_rule(d, a.get("area"), a.get("text"), a.get("check"), ref=a.get("from"))
        write_lessons(d)
        return {"added": rule_view(r)}
    r = next((x for x in d["rules"] if x["id"] == a["id"]), None)
    if r is None:
        raise ValueError("No rule %s. Use get_rules." % a["id"])
    if r.get("by") == "you" and ("text" in a or "on" in a or a.get("remove")):
        raise ValueError("The user wrote or changed rule %s. Ask him before you change it." % r["id"])
    if a.get("remove"):
        d["rules"].remove(r)
        write_lessons(d)
        return {"removed": r["id"]}
    if "text" in a:
        text = " ".join((a["text"] or "").split())
        if not text or len(text) > RULE_MAX:
            raise ValueError("Rule text: one sentence, 1 to %d characters." % RULE_MAX)
        r["text"] = text
    if "check" in a:
        c = clean_check(a["check"])
        if c:
            r["check"] = c
        else:
            r.pop("check", None)
    if "on" in a:
        r["on"] = bool(a["on"])
    r["changed"] = now_iso()
    write_lessons(d)
    return {"changed": rule_view(r)}


def apply_lesson(d, s, c, r):
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
        made = new_rule(d, rule.get("area"), rule.get("text"), rule.get("check"), ref=ref)
        c["lesson"] = made["id"]
        c.pop("repeat", None)
        return made["id"]
    rule = next((x for x in d["rules"] if x["id"] == lesson), None)
    if rule is None:
        raise ValueError("Comment %s: lesson is a rule id from get_rules, 'new' with rule={area, text}, "
                         "or 'one-off' (not '%s')." % (c["id"], lesson))
    c["lesson"] = rule["id"]
    # The rule was there before the user wrote the comment: the same mistake again.
    made, at = parse_iso(rule.get("made", "")), parse_iso((c.get("at") or "")[:19] + "Z")
    if made and at and made < at:
        c["repeat"] = True
        if ref not in rule["repeats"]:
            rule["repeats"].append(ref)
    elif ref not in rule["from"]:
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


def t_check_edit(a):
    """Runs every rule that has a check on one video, and saves the result for the Feedback board."""
    s = resolve_session(a["session"])
    f = a["file"]
    path = f if os.path.isabs(f) else os.path.join(s, f)
    if not os.path.isfile(path):
        raise ValueError("No file %s." % f)
    rules = [r for r in read_lessons()["rules"] if r.get("on", True) and r.get("check")]
    results = []
    for r in rules:
        try:
            res = run_check(path, r["check"])
        except ValueError as e:
            res = {"pass": None, "error": str(e)}
        results.append(dict({"rule": r["id"], "text": r["text"]}, **res))
    rel = os.path.relpath(path, s)
    cp = os.path.join(s, "checks.json")
    try:
        with open(cp) as fh:
            saved = json.load(fh)
    except (OSError, ValueError):
        saved = {}
    saved[rel] = {"at": now_iso(), "results": [{"rule": x["rule"], "pass": x["pass"]} for x in results]}
    tmp = cp + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(saved, fh, indent=2)
    os.replace(tmp, cp)
    failed = [x for x in results if x["pass"] is False]
    return {"file": rel, "results": results, "passed": not failed,
            "note": ("Fix each failed check and run check_edit again before you show the edit."
                     if failed else "All checks pass. Rules without a check: look at the stills.")
            if rules else "No rule has a check yet. When a rule is repeated and a number can test it, "
                          "add a check with set_rule (kinds: %s)." % ", ".join(sorted(CHECKS))}


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
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "--sketch-run", s] + (["--retry"] if retry else []),
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


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
    return {"samples": samples, "note": "The user listens on the Assets tab. Save his pick with design_voice "
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
    return re.sub(r"[^\w']+", "", w.casefold())


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
        ff("-i", src, "-vn", "-ac", "1", "-ar", "16000", "-b:a", "64k", mp3)
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


def with_audio(video, wav, out):
    ff("-i", video, "-i", wav, "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k",
       "-shortest", "-movflags", "+faststart", out)


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
        with_audio(src, os.path.join(s, rel), os.path.join(s, vrel))
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
        with_audio(src, os.path.join(s, rel), os.path.join(s, vrel))
        note_model(s, vrel, "ElevenLabs · " + vname)
        out["video"] = vrel
    return out


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
           "shot": shot and shot["id"], "status": "running", "started": now_iso()}
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
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "--replicate-run", s, job_path],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


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
                "set_comment_posted", "set_comment_stats", "set_post_stats", "get_performance"}
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
        need_rules("script")
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
# All WAVs are 48 kHz mono float with the same timing as the take, so cut them with the take's times.

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
    no_list = "Skip anyone on his target list at %s: the list scout reads them." % targets_file
    feed = ("You are the feed scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
            "Open linkedin.com/feed/ (sorted by most recent if the page offers it) and scroll down, "
            "reading as you go, until you have read about 60 posts or the posts are over 24 hours old. "
            "Note the candidates first, then get their links. " + SCOUT_LINK + " "
            + SCOUT_RULES + " " + SCOUT_FRESH + " " + skip + " "
            + SCOUT_OUTPUT % (NEW_TARGETS, 12))
    lst = ("You are the target-list scout for the user's LinkedIn comment copilot. " + SCOUT_BROWSER + " "
           "Read his target list at %s. For each person in it, open "
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
                  "Read his target list at %s. Pick 6 people from its \"Big accounts\" and \"Product "
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
    RULES_SEEN.add("comments")
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
LESSON = {"type": "string", "description": "With resolve: what this comment taught. A rule id from "
          "get_rules, 'new' (then give rule), or 'one-off'."}
RULE = {"type": "object", "description": "With lesson 'new': {area, text, check?}. One short sentence that "
        "holds for the next videos too.", "properties": {"area": {"type": "string", "enum": AREAS + ["post"]},
        "text": {"type": "string"}, "check": {"type": "object"}}}
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
     "them under waiting_for_redraft, each draft with its variants and feedback note, and his own edit if he "
     "typed one: keep that edit as variant 1, changed only as the note asks). Three new variants that "
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
     "With no image key, nothing is drawn and the answer says so: ask the user for a key, or pass your own "
     "sketch as the shot's 'image'. "
     "'video' puts a real clip on the shot instead of a sketch (a file from list_broll, or a file in the "
     "session such as edits/x.mp4 or a still such as generated/x.png); the app shows its frame and plays it on hover. "
     "'variants' puts several clips or stills on one shot (A, B, C... in that order) for the user to choose "
     "from: the shot shows as a stack, he flips through them and picks one; 'video' is the one in the video "
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
     "comment is unclear. In a session, each resolved comment needs a lesson: a rule id from get_rules when "
     "that rule covers it (the same mistake again), 'new' with rule={area, text} when it applies to the next "
     "videos too, else 'one-off'.",
     {"session": SESSION, "library": LIBRARY,
      "replies": {"type": "array", "items": {"type": "object", "properties": {
          "id": {"type": "string", "description": "Comment id, e.g. 'c3'."}, "text": S, "resolve": {"type": "boolean"},
          "fixed_in": {"type": "string", "description": "File of the new version, relative to the session or library."},
          "fixed_at": {"type": "number", "description": "Seconds into fixed_in where the fix shows."},
          "lesson": LESSON, "rule": RULE},
          "required": ["id"]}},
      "id": {"type": "string", "description": "Single reply: comment id. Prefer replies=[...]."},
      "text": S, "resolve": {"type": "boolean"}, "fixed_in": S, "fixed_at": {"type": "number"},
      "lesson": LESSON, "rule": RULE},
     [], t_reply_comment),
    ("get_rules", "The rules learned from the user's comments, one file per step of the content journey: plan "
     "(storyboard, script), make (sound, cut, picture, captions, graphics), package (thumbnail), publish "
     "(post-all, post-linkedin, post-x, post-youtube, post-vertical), engage (comments: the comment copilot's "
     "lessons) and other. Read the steps you work on before you write, edit or design, and follow them: the "
     "tools that write for a step refuse once until you have. The user edits them on the Feedback board.",
     {"area": {"type": "string", "description": "The steps, comma separated, e.g. 'post-all,post-x' or 'cut,sound'. "
               "'post' is every post file, 'edit' the five make steps, 'all' every rule. Without it: only the "
               "list of steps and how many rules each has."}},
     [], t_get_rules),
    ("set_rule", "Add, change, turn off or remove one learned rule. Keep each rule one short sentence and the "
     "set small (at most %d per area): sharpen or merge a rule before you add one. Never change a rule "
     "The user wrote (by_user) without asking him. A check makes check_edit measure the rule: %s" % (
         AREA_MAX, " ".join("%s: %s" % kv for kv in sorted(CHECKS.items()))),
     {"id": {"type": "string", "description": "The rule to change. Omit to add a new rule."},
      "area": {"type": "string", "enum": AREAS}, "text": S,
      "check": {"type": "object", "description": "{kind, target, tolerance, max, floor}. null removes it."},
      "on": {"type": "boolean"}, "remove": {"type": "boolean"}}, [], t_set_rule),
    ("check_edit", "Measure an edit against every learned rule that has a check (loudness, true peak, pauses, "
     "length). Run it before you show the user a new version, fix what fails, and run it again.",
     {"session": SESSION, "file": {"type": "string", "description": "The video, e.g. 'edits/hook-v4.mp4'."}},
     ["session", "file"], t_check_edit),
    ("make_image", "Make or change an image straight from Google or OpenAI (much cheaper than a Higgsfield "
     "image: never use higgsfield for images). Drafts first, final last: while the user finds the direction, "
     "draw with GPT Image (fast, 1536 px at most): flare (GPT Image 2.5 Flare, the default for a new image) "
     "or sunburst (GPT Image 2.5 Sunburst, the default for a change or with references). When he likes a "
     "draft, make its final: from=<that draft> redraws it with Nano Banana 2.1 at 4K, the newest and sharpest, "
     "with the draft and its references as the guide and the same prompt (add one only for a change). Never "
     "make a final before he picks. When one model fails the next one draws. Waits about 10-60 s and returns "
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
     "account; set_default=<voice> makes a voice the default. Not set up: tell him to open Plugins › Voices.",
     {"search": S, "gender": S, "accent": S, "language": S, "age": S, "use_case": S,
      "add": {"type": "string", "description": "'<public_owner_id>/<voice_id>' from a search result."},
      "name": {"type": "string", "description": "With add: the name the voice gets in the account."},
      "set_default": {"type": "string", "description": "A voice name or id to make the default."}},
     [], t_voices),
    ("design_voice", "Design a new ElevenLabs voice from a description ('warm German woman, 40s, calm, slow'): "
     "writes three samples (generated/voice-<name>-1..3.mp3 with session, else _library/voices/) for the user "
     "to hear on the Assets tab. Then save his pick: save=<the sample's save id> with name.",
     {"session": SESSION, "description": {"type": "string", "description": "Age, gender, accent, tone, pace, use."},
      "text": {"type": "string", "description": "Optional sample text, 100-1000 characters."},
      "save": {"type": "string", "description": "A sample's save id: keep that voice."},
      "name": {"type": "string", "description": "Name of the voice (save) or of the sample files."},
      "set_default": {"type": "boolean", "description": "With save: make it the default voice."}},
     [], t_design_voice),
    ("voiceover", "Make a voice-over with ElevenLabs: reads text (default: the session's script.md) in a voice "
     "(default: The user's default voice, usually his clone) and writes generated/<name>-vN.wav (48 kHz mono, "
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
     "(default: The user's default voice, his clone) with the sentences around them for the same tone, and "
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
     "Each job costs the user's Higgsfield credits: one job per ask, never a batch he did not ask for. "
     "Not installed or not signed in: tell him to open Plugins › Higgsfield.",
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
     "out for the user's default (replicate_status lists his default models, the first is the default; pick another "
     "of them when it fits better). Takes maps prompt, image (the FIRST FRAME), end_image, video, duration, "
     "aspect_ratio, resolution and audio to the model's own input names; anything else goes in params by the "
     "model's names (call replicate_model first to see its inputs, defaults and allowed values). File inputs, "
     "in those fields or params, take a session file, a take number or 'sketch' (the shot's sketch); Takes uploads "
     "them. With shot=<id> the storyboard shot shows 'Generating' and then plays the clip (aspect ratio = the "
     "storyboard format, length = the shot's length, 4-15 s). For a shot, write a real-footage prompt from the "
     "shot's do and say; never use the sketch as the first frame (the video would look drawn): pass it only to a "
     "reference-image input if the model has one. Each job costs the user money: one job per ask, never a batch he "
     "did not ask for. No token: tell him to open Plugins › Replicate.",
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
     "can set what the user asks for. Leave model out for his default.",
     {"model": {"type": "string", "description": "owner/name, e.g. bytedance/seedance-2.5."}}, [], t_replicate_model),
    ("replicate_status", "Is a Replicate token set, which account, the user's default video models; with session, "
     "its Replicate jobs (running, done, error).",
     {"session": SESSION}, [], t_replicate_status),
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
    ("search_media", "Find footage by meaning across the whole library, on this Mac: clips by what they "
     "show ('hands typing', 'walking outside at night', 'close-up of a phone'), stills and thumbnails, and "
     "the words said in transcripts and scripts ('where I talk about pricing'). Each hit has path, kind "
     "(video, image, speech, script) and, for video and speech, 'at' (seconds into the file). A b-roll "
     "clip found by its description has 'about' (that description). Best hit first. Use it to find b-roll for a storyboard shot or an edit before asking the user to film it, and "
     "to find an old take or clip he describes. Same search as ⌘K in the app.",
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
     "artist, genre, bpm, duration, path. New downloads in his source folder (Epidemic Sound) are copied in "
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
if not SOCIAL:
    TOOLS = [t for t in TOOLS if t[0] not in SOCIAL_TOOLS]
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
                                    "The user's rules from past comments: get_rules for the step you work on (script, "
                                    "storyboard, the edit steps, thumbnail, post-all plus post-<platform>, comments) "
                                    "before you write; the tools that write for a step refuse once until you have. "
                                    "A take's voice: clean_voice cleans it (the user's voice-cleanup); when get_session shows voice.file "
                                    "under a take, use that WAV as the take's audio in edits. "
                                    "A take recorded for a storyboard shot has best_cut in get_session. by=gemini is only Gemini's "
                                    "first suggestion of the clean delivery (start, end in seconds), not the final cut: "
                                    "check it yourself before you cut (Whisper word times against the shot's lines, a "
                                    "look at the frames at both ends, the other tries), then set_best_cut with the "
                                    "range you use, even when it stays the same. "
                                    "B-roll: list_broll gives the user's own clips with descriptions; add_broll puts one in "
                                    "a session; save_broll saves a session's video into the library. "
                                    "AI media: the replicate tool (pay per clip, the user's default models) or the higgsfield tool (his "
                                    "Higgsfield plan) makes a clip for a storyboard shot or changes a session video; use the one "
                                    "he names, else replicate when replicate_status shows a token; make_image makes or changes an image (GPT Image 2.5 drafts; when the user likes one, "
                                    "from=<draft> makes the 4K Nano Banana 2.1 final; never Higgsfield for images); results land in generated/. "
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
        sketch_run(sys.argv[2], retry="--retry" in sys.argv[3:])
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
    elif sys.argv[1:2] == ["--voice-mix"]:
        voice_mix(*sys.argv[2:4])
    else:
        main()
