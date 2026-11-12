#!/usr/bin/env python3
"""Click ring: the clicks of a screen take's cursor log, in the edit's time and pixels (2026-10-30).

The cursor log (take-NN-screen.events.json, written by Takes beside the screen file) has each click
in seconds and pixels of the .mov. render_edit puts a cut part of the take at its place in the edit,
crops it (frame.crop), then scales it to cover the edit's frame and cuts the centre (fill_frame in
takes_mcp.py). This script does the same to each click and writes the clicks into index.html.

  python3 clicks.py --events ../../take-03-screen.events.json --take 3 \\
      --cut '[{"take": 3, "kind": "screen", "in": 4.2, "out": 11.8}]' --size 1080x1920 \\
      [--crop '{"x": 0, "y": 0, "w": 1728, "h": 2234}'] [--zoom zoom.json] [--html click-ring/index.html]

With the recipe's zoom, render_edit writes _edit/<name>/zoom.json before the steps: run this script as a
step with --zoom zoom.json, before the HyperFrames step, so each ring sits where the zoomed screen shows it.

Prints {"at", "duration", "rings", "sfx"}: put the layer at "at" in the edit and the "sfx" entries in the
recipe's sfx, one real mouse click (click.wav) on each ring. Plain Python, no packages.
"""
import argparse
import bisect
import json
import math
import os
import re
import sys

RADIUS = 40     # the ring's full radius in px of the .mov (20 points on a 2x screen)
MIN_RADIUS = 18  # never smaller than this in the edit, so a far-out frame still shows it
LEAD, TAIL = 0.1, 0.8  # the layer starts this long before the first click and ends this long after the last
# The click sound (2026-10-30): a real mouse click, press and release (Pixeliota, Freesound 678248, CC0).
# Made-in-code clicks did not sound like a mouse to people. The press starts CLICK_ONSET into the file.
CLICK_FILE, CLICK_ONSET, CLICK_GAIN = "click.wav", 0.005, -7


def fill(cw, ch, W, H):
    """fill_frame: the scale and the offset of the centre cut, for a cw x ch picture in a W x H frame."""
    k = max(W / cw, H / ch)
    return k, math.floor((cw * k - W) / 2), math.floor((ch * k - H) / 2)


def rings(events, take, cut, W, H, crop=None, buttons=("left",)):
    """[[t, x, y, r]] in edit seconds and px, for each button-down click that the edit shows."""
    sw, sh = events["size"]
    cx, cy, cw, ch = (crop["x"], crop["y"], crop["w"], crop["h"]) if crop else (0, 0, sw, sh)
    k, ox, oy = fill(cw, ch, W, H)
    r = max(MIN_RADIUS, round(RADIUS * k))
    out, start = [], 0.0
    for g in cut:
        a, b = float(g["in"]), float(g["out"])
        if int(g["take"]) == int(take) and g.get("kind") == "screen":
            for c in events.get("clicks") or []:
                if not c.get("down") or c.get("button") not in buttons or not a <= c["t"] < b:
                    continue
                x, y = (c["x"] - cx) * k - ox, (c["y"] - cy) * k - oy
                if 0 <= x < W and 0 <= y < H:
                    out.append([round(start + c["t"] - a, 3), round(x, 1), round(y, 1), r])
        start += b - a
    return sorted(out), start


def zoomed(found, zoom, W, H):
    """The rings where the zoomed screen shows them (zoom.json of render_edit: [t, z, left, top] per zoomed
    frame). A ring in a zoomed frame moves and grows with it; one the zoom left out of the frame goes."""
    frames = zoom.get("frames") or []
    ts = [f[0] for f in frames]
    step = 1.0 / float(zoom.get("fps") or 30)
    out = []
    for t, x, y, r in found:
        i = bisect.bisect_left(ts, t - step / 2)
        if i < len(frames) and abs(frames[i][0] - t) <= step / 2:
            _, z, left, top = frames[i]
            x, y, r = (x - left) * z, (y - top) * z, round(r * z)
            if not (0 <= x < W and 0 <= y < H):
                continue
        out.append([t, round(x, 1), round(y, 1), r])
    return out


def layer(found, length):
    """The layer's start and length in the edit, and the ring times from its start."""
    if not found:
        return None
    at = max(0.0, found[0][0] - LEAD)
    end = min(length, found[-1][0] + TAIL)
    return round(at, 3), round(max(end - at, 0.5), 3), [[round(t - at, 3), x, y, r] for t, x, y, r in found]


def click_sfx(found, name, folder="click-ring"):
    """The recipe's sfx entries: the click sound on each ring, its press on the click's frame."""
    f = "_edit/%s/%s/%s" % (name, folder, CLICK_FILE)
    return [{"file": f, "at": round(max(t - CLICK_ONSET, 0.0), 3), "gain_db": CLICK_GAIN} for t, *_ in found]


def write_html(path, clicks, W, H, duration):
    with open(path) as f:
        html = f.read()
    html = re.sub(r"const CLICKS = .*?;\n", lambda _: "const CLICKS = %s;\n" % json.dumps(clicks), html, count=1)
    html = re.sub(r'data-duration="[^"]*"', 'data-duration="%s"' % duration, html, count=1)
    html = re.sub(r'data-width="[^"]*"', 'data-width="%d"' % W, html, count=1)
    html = re.sub(r'data-height="[^"]*"', 'data-height="%d"' % H, html, count=1)
    with open(path, "w") as f:
        f.write(html)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--events", required=True)
    p.add_argument("--take", required=True, type=int)
    p.add_argument("--cut", required=True, help="the recipe's cut, as JSON")
    p.add_argument("--size", required=True, help="the edit's size, WxH")
    p.add_argument("--crop", help="the recipe's frame.crop, as JSON")
    p.add_argument("--buttons", default="left", help="left, right, other, comma separated")
    p.add_argument("--zoom", help="render_edit's zoom.json, when the recipe zooms")
    p.add_argument("--html", default="click-ring/index.html")
    p.add_argument("--name", help="the edit's name (default: this folder's name, _edit/<name>/)")
    a = p.parse_args()
    W, H = (int(v) for v in a.size.lower().split("x"))
    with open(a.events) as f:
        events = json.load(f)
    found, length = rings(events, a.take, json.loads(a.cut), W, H,
                          json.loads(a.crop) if a.crop else None, tuple(a.buttons.split(",")))
    if a.zoom and os.path.exists(a.zoom):
        with open(a.zoom) as f:
            found = zoomed(found, json.load(f), W, H)
    lay = layer(found, length)
    if not lay:
        sys.exit("No clicks in the parts of take %d this cut shows." % a.take)
    at, duration, clicks = lay
    write_html(a.html, clicks, W, H, duration)
    name = a.name or os.path.basename(os.getcwd())
    folder = os.path.basename(os.path.dirname(os.path.abspath(a.html)))
    print(json.dumps({"at": at, "duration": duration, "rings": len(clicks), "sfx": click_sfx(found, name, folder)}))


if __name__ == "__main__":
    main()
