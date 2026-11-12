#!/usr/bin/env python3
"""Cursor looks: a screen take's pointer, in the edit's time and pixels, with its state (2026-10-31).

The cursor log (take-NN-screen.events.json, written by Takes beside the screen file) has each move and
click in seconds and pixels of the .mov, and the cursor shape at each move. render_edit puts a cut part of
the take at its place in the edit, crops it (frame.crop), then scales it to cover the edit's frame and cuts
the centre (fill_frame in takes_mcp.py). This script does the same to the pointer, finds its state at each
moment and writes it all into index.html, which draws the look.

  python3 cursor.py --events ../../take-03-screen.events.json --take 3 \\
      --cut '[{"take": 3, "kind": "screen", "in": 4.2, "out": 11.8}]' --size 1080x1920 --look plasma \\
      [--crop '{"x": 0, "y": 0, "w": 1728, "h": 2234}'] [--zoom zoom.json] [--accent '#FFE600'] [--scale 1.2] \\
      [--labels '[{"at": 2.1, "text": "Export the video"}]'] [--wait '[[6.0, 8.5, "Rendering"]]'] [--raw]

States: move; hover (the pointing hand); text (the I-beam); drag (a button held down while it moves, or the
grab hand); wait (--wait spans, or a cursor that keeps changing shape, like the spinning wait). Each click
presses the look and leaves a burst where it clicked.

Prints {"at", "duration", "look", "clicks", "states"}: put the layer at "at" in the edit, and set the recipe's
pointer to {"look": "none"} so render_edit does not draw the system arrow under it. Plain Python, no packages.
"""
import argparse
import bisect
import json
import math
import os
import re
import sys

LOOKS = ("glass", "comet", "ink", "caption", "stick", "pixel", "plasma", "glassmorph")
ACCENT = {"plasma": "#FFE600", "glassmorph": "#7C5CFF"}  # every other look: #FF5A36
FPS = 30            # path samples a second
SMOOTH_S = 0.08     # the eased path: a centred average over this many seconds each side
CLICK_S = 0.2       # ... exactly on the log this near a click
DRAG_PT = 6         # a held button that moves this many points is a drag
WAIT_CHANGES = 4    # this many shape changes in WAIT_S, none of them a known shape, is the spinning wait
WAIT_S = 1.0
LABEL_S = 1.6       # a label shows this long, unless it says
LEAD, TAIL = 0.0, 0.0


def fill(cw, ch, W, H):
    """fill_frame: the scale and the offset of the centre cut, for a cw x ch picture in a W x H frame."""
    k = max(W / cw, H / ch)
    return k, math.floor((cw * k - W) / 2), math.floor((ch * k - H) / 2)


def shape_states(ev):
    """The state of each shape of the log: its name (Takes names the system's own cursors since 2026-10-31),
    else a guess from its size: narrow and tall is the I-beam, the first is the arrow, any other the hand."""
    out = []
    for i, s in enumerate(ev.get("shapes") or [ev.get("arrow") or {}]):
        n = s.get("name")
        if n in ("arrow", "text", "hand", "grab"):
            out.append({"arrow": "move", "text": "text", "hand": "hover", "grab": "drag"}[n])
        elif n is not None or i == 0:
            out.append("move" if i == 0 else "hover")
        else:
            w, h = (s.get("size") or [1, 1])[:2]
            out.append("text" if w <= 0.6 * h else "hover")
    return out


def take_states(ev):
    """[(t, state)] in take seconds, at each change: the shape's state, drags and the spinning wait."""
    moves = ev.get("moves") or []
    names = shape_states(ev)
    named = {i for i, s in enumerate(ev.get("shapes") or []) if s.get("name")}
    shape = [int(m[3]) if len(m) > 3 and 0 <= int(m[3]) < len(names) else 0 for m in moves]
    base = [(m[0], names[s]) for m, s in zip(moves, shape)]
    # The spinning wait: an unnamed shape that keeps changing.
    changes = [moves[i][0] for i in range(1, len(moves)) if shape[i] != shape[i - 1] and shape[i] not in named
               and shape[i] != 0]
    waits = []
    for i in range(len(changes)):
        j = bisect.bisect_right(changes, changes[i] + WAIT_S)
        if j - i >= WAIT_CHANGES:
            a, b = changes[i], changes[j - 1] + 0.3
            if waits and a <= waits[-1][1]:
                waits[-1][1] = max(waits[-1][1], b)
            else:
                waits.append([a, b])
    # Drags: a left button held down while the pointer moves DRAG_PT points or more.
    scale = float(ev.get("scale") or 2)
    drags, down = [], None
    for c in sorted(ev.get("clicks") or [], key=lambda c: c["t"]):
        if c.get("button") != "left":
            continue
        if c.get("down"):
            down = c
        elif down is not None:
            a, b = down["t"], c["t"]
            far = max([math.hypot(m[1] - down["x"], m[2] - down["y"]) for m in moves if a <= m[0] <= b] or [0])
            if far >= DRAG_PT * scale:
                drags.append([a, b])
            down = None

    def state(t, s):
        if any(a <= t < b for a, b in waits):
            return "wait"
        if any(a <= t < b for a, b in drags):
            return "drag"
        return s

    times = sorted({t for t, _ in base} | {x for span in waits + drags for x in span})
    out = []
    for t in times:
        i = max(0, bisect.bisect_right([m[0] for m in moves], t) - 1)
        s = state(t, base[i][1] if base else "move")
        if not out or out[-1][1] != s:
            out.append((t, s))
    return out or [(0.0, "move")]


def track(ev, times, raw=False):
    """(x, y) in .mov pixels at each take time (sorted): an eased path, exactly on the log near clicks."""
    moves = ev["moves"]
    mt = [m[0] for m in moves]
    pts = [(moves[max(0, bisect.bisect_right(mt, t) - 1)][1], moves[max(0, bisect.bisect_right(mt, t) - 1)][2])
           for t in times]
    if raw or len(times) < 2:
        return pts
    downs = sorted(c["t"] for c in ev.get("clicks") or [])
    sx, sy = [0.0], [0.0]
    for x, y in pts:
        sx.append(sx[-1] + x)
        sy.append(sy[-1] + y)
    out = []
    for i, t in enumerate(times):
        lo, hi = bisect.bisect_left(times, t - SMOOTH_S), bisect.bisect_right(times, t + SMOOTH_S)
        ax, ay = (sx[hi] - sx[lo]) / (hi - lo), (sy[hi] - sy[lo]) / (hi - lo)
        j = bisect.bisect_left(downs, t)
        d = min([abs(t - downs[k]) for k in (j - 1, j) if 0 <= k < len(downs)] or [float("inf")])
        w = min(1.0, d / CLICK_S)
        x, y = pts[i]
        out.append((x + (ax - x) * w, y + (ay - y) * w))
    return out


def build(ev, take, cut, W, H, crop=None, raw=False, fps=FPS):
    """The pointer in the edit: {path: [[t, x, y]] (x None = not shown), states: [[t, state]], clicks: [[t, x, y]],
    unit: edit px per point, length}, in edit seconds and px, before the zoom."""
    sw, sh = ev["size"]
    cx, cy, cw, ch = (crop["x"], crop["y"], crop["w"], crop["h"]) if crop else (0, 0, sw, sh)
    k, ox, oy = fill(cw, ch, W, H)
    zoom = float((ev.get("arrow") or {}).get("zoom") or 1)
    unit = k * float(ev.get("scale") or 2) * zoom
    st = take_states(ev)
    st_t = [t for t, _ in st]
    path, states, clicks, start = [], [], [], 0.0
    for g in cut:
        a, b = float(g["in"]), float(g["out"])
        n = int(round((b - a) * fps))
        if int(g["take"]) == int(take) and g.get("kind") == "screen":
            times = [a + i / float(fps) for i in range(n)]
            for i, (x, y) in enumerate(track(ev, times, raw)):
                path.append([round(start + i / float(fps), 3), round((x - cx) * k - ox, 1), round((y - cy) * k - oy, 1)])
            for t in [a] + [t for t in st_t if a < t < b]:
                s = st[max(0, bisect.bisect_right(st_t, t) - 1)][1]
                if not states or states[-1][1] != s:
                    states.append([round(start + t - a, 3), s])
            for c in ev.get("clicks") or []:
                if c.get("down") and c.get("button") == "left" and a <= c["t"] < b:
                    clicks.append([round(start + c["t"] - a, 3), round((c["x"] - cx) * k - ox, 1),
                                   round((c["y"] - cy) * k - oy, 1)])
        elif path and path[-1][1] is not None:
            path.append([round(start, 3), None, None])
        start += b - a
    return {"path": path, "states": states, "clicks": sorted(clicks), "unit": round(unit, 4), "length": round(start, 3)}


def zoomed(found, zoom):
    """The path and clicks where the zoomed screen shows them (zoom.json of render_edit: [t, z, left, top] per
    zoomed frame). In a zoomed frame the pointer moves and grows with it: each point gets its size [.., z]."""
    frames = zoom.get("frames") or []
    ts = [f[0] for f in frames]
    step = 1.0 / float(zoom.get("fps") or 30)

    def at(t, x, y):
        i = bisect.bisect_left(ts, t - step / 2)
        if x is not None and i < len(frames) and abs(frames[i][0] - t) <= step / 2:
            _, z, left, top = frames[i]
            return [t, round((x - left) * z, 1), round((y - top) * z, 1), round(z, 3)]
        return [t, x, y, 1]
    found["path"] = [at(*p) for p in found["path"]]
    found["clicks"] = [at(*c) for c in found["clicks"]]
    return found


def layer(found, labels, waits):
    """The layer's start and length in the edit, and every time from its start."""
    shown = [p[0] for p in found["path"] if p[1] is not None]
    if not shown:
        return None
    at = max(0.0, shown[0] - LEAD)
    end = min(found["length"], found["path"][-1][0] + 1.0 / FPS + TAIL)

    def rel(t):
        return round(t - at, 3)
    states = found["states"]
    for a, b, _ in waits:  # the agent's own wait spans win over the log's state
        before = [s for t, s in states if t <= b] or ["move"]
        states = [x for x in states if not a <= x[0] <= b] + [[a, "wait"], [b, before[-1]]]
        states.sort(key=lambda x: x[0])
    out = {"path": [[rel(p[0])] + p[1:] for p in found["path"]],
           "states": [[rel(t), s] for t, s in states],
           "clicks": [[rel(c[0])] + c[1:] for c in found["clicks"]],
           "labels": [[rel(x["at"]), float(x.get("len") or LABEL_S), x["text"]] for x in labels],
           "waits": [[rel(a), rel(b), text] for a, b, text in waits]}
    return round(at, 3), round(max(end - at, 0.5), 3), out


def write_html(path, data, W, H, duration):
    with open(path) as f:
        html = f.read()
    html = re.sub(r"const DATA = .*?;\n", lambda _: "const DATA = %s;\n" % json.dumps(data, separators=(",", ":")),
                  html, count=1, flags=re.S)
    html = re.sub(r'data-duration="[^"]*"', 'data-duration="%s"' % duration, html, count=1)
    html = re.sub(r'data-width="[^"]*"', 'data-width="%d"' % W, html, count=1)
    html = re.sub(r'data-height="[^"]*"', 'data-height="%d"' % H, html, count=1)
    html = re.sub(r'<meta name="viewport" content="[^"]*"', '<meta name="viewport" content="width=%d, height=%d"' % (W, H),
                  html, count=1)
    with open(path, "w") as f:
        f.write(html)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--events", required=True)
    p.add_argument("--take", required=True, type=int)
    p.add_argument("--cut", required=True, help="the recipe's cut, as JSON")
    p.add_argument("--size", required=True, help="the edit's size, WxH")
    p.add_argument("--look", required=True, choices=LOOKS)
    p.add_argument("--accent", help="the look's colour, #RRGGBB")
    p.add_argument("--scale", type=float, default=1.0, help="the look's size: 1.5 = half again as big")
    p.add_argument("--crop", help="the recipe's frame.crop, as JSON")
    p.add_argument("--zoom", help="render_edit's zoom.json, when the recipe zooms")
    p.add_argument("--labels", help='caption chips: [{"at": edit s, "text": "...", "len"?: s}]')
    p.add_argument("--wait", help='wait spans: [[from, to, "text"?]] in edit seconds')
    p.add_argument("--raw", action="store_true", help="exactly the logged path, not eased")
    p.add_argument("--html", default="cursor-looks/index.html")
    a = p.parse_args()
    W, H = (int(v) for v in a.size.lower().split("x"))
    if a.accent and not re.fullmatch(r"#[0-9A-Fa-f]{6}", a.accent):
        sys.exit("--accent is a colour like #FF5A36.")
    if not 0.3 <= a.scale <= 4:
        sys.exit("--scale is from 0.3 to 4.")
    with open(a.events) as f:
        ev = json.load(f)
    if not ev.get("moves"):
        sys.exit("This cursor log has no moves.")
    found = build(ev, a.take, json.loads(a.cut), W, H, json.loads(a.crop) if a.crop else None, a.raw)
    if a.zoom and os.path.exists(a.zoom):
        with open(a.zoom) as f:
            found = zoomed(found, json.load(f))
    labels = json.loads(a.labels) if a.labels else []
    waits = [(float(w[0]), float(w[1]), str(w[2]) if len(w) > 2 else "Loading") for w in json.loads(a.wait or "[]")]
    lay = layer(found, labels, waits)
    if not lay:
        sys.exit("The cut shows no screen part of take %d." % a.take)
    at, duration, data = lay
    data.update(look=a.look, accent=a.accent or ACCENT.get(a.look, "#FF5A36"), unit=round(found["unit"] * a.scale, 4),
                fps=FPS)
    write_html(a.html, data, W, H, duration)
    count = {}
    for _, s in data["states"]:
        count[s] = count.get(s, 0) + 1
    print(json.dumps({"at": at, "duration": duration, "look": a.look, "clicks": len(data["clicks"]), "states": count}))


if __name__ == "__main__":
    main()
