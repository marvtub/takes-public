#!/usr/bin/env python3
"""Layout morph: the camera over a screen recording, changing layout mid-video (2026-10-30).

The camera sits in a box over the screen. At each change in the plan, the box glides to the next
layout: its place, size, corner radius and the camera crop ease together over MORPH_S (cubic in-out),
and a dark panel slides in or out behind it. Writes a see-through W x H layer (ProRes 4444) for
render_edit's "over", and prints the recipe's sfx: a short real whoosh at the fastest point of each change.

  sh layout-morph/morph.sh --camera ../../take-02-camera.mov --out morph.mov --size 1920x1080 \\
      --fps 30 --start -0.35 --length 39.2 --face 990,500 \\
      --plan '[{"at": 0, "layout": "card"}, {"at": 9.5, "layout": "bubble"}, {"at": 19, "layout": "side"}]'

Layouts (each one fits any frame; corner br/bl/tr/tl for card and bubble, default br):
  card    a rounded 16:9 card in a corner
  bubble  a round bubble in a corner
  side    the camera tall in a dark panel: on the right in a wide frame, at the bottom in a square or tall one
  full    the camera fills the frame

--start: the camera second at the layer's start (cut in - screen_lag_s; below 0 holds the first frame).
The layout math is plain Python; the drawing needs numpy and OpenCV (morph.sh runs it with uv).
"""
import argparse
import json
import os
import subprocess
import sys

MORPH_S = 0.7
WHOOSHES = [("whoosh-1.wav", 0.082), ("whoosh-2.wav", 0.079), ("whoosh-3.wav", 0.076)]  # file, peak second
WHOOSH_GAIN = -11
PANEL_RGB = (16, 16, 18)
EDGE, SHADOW_DY = 3, 10
# How much of the camera's height each layout shows around the face (1 = all of it).
CROP = {"card": 0.57, "bubble": 0.67, "side": 1.0, "full": 1.0}


def ease(u):
    u = min(max(u, 0.0), 1.0)
    return 4 * u ** 3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2


def lerp(x, y, k):
    if isinstance(x, (tuple, list)):
        return tuple(lerp(i, j, k) for i, j in zip(x, y))
    return x + (y - x) * k


def wide(W, H):
    return W > H


def panel_rect(W, H):
    """The dark panel when it is fully in: the right third of a wide frame, the bottom 42% of a tall one."""
    if wide(W, H):
        pw = round(W * 0.317)
        return (W - pw, 0, pw, H)
    ph = round(H * 0.42)
    return (0, H - ph, W, ph)


def layout(name, W, H, corner="br"):
    """{box (x, y, w, h), radius, crop (share of the camera height), panel (0 out .. 1 in)} for a W x H frame."""
    s = min(W, H)
    m = round(s * 0.035)
    if name == "card":
        w = round((W if wide(W, H) else W * 1.6) * 0.283)
        w = min(w, W - 2 * m)
        box_w, box_h, r = w, round(w * 9 / 16), round(s * 0.02)
    elif name == "bubble":
        box_w = box_h = round(s * (0.296 if wide(W, H) else 0.36))
        r = box_w / 2
    elif name == "side":
        px, py, pw, ph = panel_rect(W, H)
        g = round(s * 0.022)
        return {"box": (px + g, py + g, pw - 2 * g, ph - 2 * g), "radius": round(s * 0.02), "crop": CROP["side"], "panel": 1.0}
    elif name == "full":
        return {"box": (0, 0, W, H), "radius": 0, "crop": CROP["full"], "panel": 0.0}
    else:
        raise ValueError("No layout '%s': card, bubble, side or full." % name)
    if corner not in ("br", "bl", "tr", "tl"):
        raise ValueError("corner is br, bl, tr or tl.")
    x = W - box_w - m if corner[1] == "r" else m
    y = H - box_h - m if corner[0] == "b" else m
    return {"box": (x, y, box_w, box_h), "radius": r, "crop": CROP[name], "panel": 0.0}


def steps(plan, W, H):
    """The plan as [(at, layout dict)], sorted, the first one from 0."""
    out = []
    for p in sorted(plan, key=lambda p: float(p["at"])):
        out.append((float(p["at"]), layout(p["layout"], W, H, p.get("corner", "br"))))
    if not out:
        raise ValueError("The plan has no layout.")
    return out


def layout_at(st, t):
    """The layout at second t of the layer: each change eases from the one before over MORPH_S."""
    cur = st[0][1]
    for at, nxt in st[1:]:
        if t < at:
            break
        k = ease((t - at) / MORPH_S)
        cur = {key: lerp(cur[key], nxt[key], k) for key in cur}
    return cur


def crop_rect(L, cam_w, cam_h, face):
    """The camera crop for a layout: the box's aspect, centred on the face, inside the camera frame."""
    bw, bh = L["box"][2], L["box"][3]
    ch = min(L["crop"] * cam_h, cam_h)
    cw = ch * bw / bh
    if cw > cam_w:
        cw, ch = cam_w, cam_w * bh / bw
    cx = min(max(face[0] - cw / 2, 0), cam_w - cw)
    cy = min(max(face[1] - ch / 2, 0), cam_h - ch)
    return cx, cy, cw, ch


def whoosh_sfx(plan, at0, name, folder="layout-morph"):
    """The recipe's sfx: a whoosh at the fastest point of each change (the middle of the ease)."""
    out = []
    for i, p in enumerate(sorted(plan, key=lambda p: float(p["at"]))[1:]):
        f, peak = WHOOSHES[i % len(WHOOSHES)]
        out.append({"file": "_edit/%s/%s/%s" % (name, folder, f),
                    "at": round(max(at0 + float(p["at"]) + MORPH_S / 2 - peak, 0.0), 3), "gain_db": WHOOSH_GAIN})
    return out


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "json", path], capture_output=True, text=True, check=True)
    s = json.loads(r.stdout)["streams"][0]
    return int(s["width"]), int(s["height"])


def render(a, W, H, st):
    import numpy as np
    import cv2

    cam_w, cam_h = probe(a.camera)
    face = tuple(float(v) for v in a.face.split(",")) if a.face else (cam_w / 2, cam_h / 2)
    shadow = max(round(min(W, H) * 0.037), 8)

    def sdf(xs, ys, bw, bh, r):
        qx = np.maximum(np.maximum(r - xs, xs - (bw - r)), 0)
        qy = np.maximum(np.maximum(r - ys, ys - (bh - r)), 0)
        return np.hypot(qx, qy) - r

    def over(dst, rgb, alpha, y0, x0):
        h, w = alpha.shape
        reg = dst[y0:y0 + h, x0:x0 + w]
        sa = alpha[..., None]
        da = reg[..., 3:4]
        oa = sa + da * (1 - sa)
        reg[..., :3] = (rgb * sa + reg[..., :3] * da * (1 - sa)) / np.maximum(oa, 1e-6)
        reg[..., 3:4] = oa

    pre, ss = max(-a.start, 0.0), max(a.start, 0.0)
    cam = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", "%.3f" % ss, "-i", a.camera, "-vf",
                            "fps=%s,tpad=start_duration=%.3f:start_mode=clone,eq=contrast=1.02:saturation=1.02"
                            % (a.fps, pre), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "%dx%d" % (W, H),
                            "-r", str(a.fps), "-i", "-", "-c:v", "prores_ks", "-profile:v", "4444",
                            "-pix_fmt", "yuva444p10le", a.out], stdin=subprocess.PIPE)
    n = int(round(a.length * float(a.fps)))
    size = cam_w * cam_h * 3
    frame = np.zeros((cam_h, cam_w, 3), np.uint8)
    px0, py0, pw, ph = panel_rect(W, H)
    for i in range(n):
        buf = cam.stdout.read(size)
        if len(buf) == size:
            frame = np.frombuffer(buf, np.uint8).reshape(cam_h, cam_w, 3)
        L = layout_at(st, i / float(a.fps))
        canvas = np.zeros((H, W, 4), np.float32)

        # the panel slides in from its edge: off to the right in a wide frame, off the bottom in a tall one
        k = L["panel"]
        if k > 0.001:
            if wide(W, H):
                x = int(round(px0 + (1 - k) * pw))
                canvas[:, x:] = PANEL_RGB + (255,)
            else:
                y = int(round(py0 + (1 - k) * ph))
                canvas[y:, :] = PANEL_RGB + (255,)
            canvas[..., :3] /= 255
            canvas[..., 3] /= 255

        bx, by, bw, bh = L["box"]
        r = min(L["radius"], bw / 2, bh / 2)
        full = bw >= W - 1 and bh >= H - 1
        if not full:
            mg = shadow + SHADOW_DY + EDGE + 2
            x0, y0 = max(int(bx) - mg, 0), max(int(by) - mg, 0)
            x1, y1 = min(int(bx + bw) + mg, W), min(int(by + bh) + mg, H)
            ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float32)
            d = sdf(xs - bx + 0.5, ys - by + 0.5, bw, bh, r)
            ds = sdf(xs - bx + 0.5, ys - by - SHADOW_DY + 0.5, bw, bh, r)
            over(canvas, np.zeros(3, np.float32), np.clip(1 - ds / shadow, 0, 1) * (110 / 255), y0, x0)
            over(canvas, np.ones(3, np.float32), np.clip(EDGE + 0.5 - d, 0, 1) * (235 / 255), y0, x0)

        cx, cy, cw, ch = crop_rect(L, cam_w, cam_h, face)
        tw, th = max(int(round(bw)), 2), max(int(round(bh)), 2)
        fx0, fy0 = int(round(bx)), int(round(by))
        tw, th = min(tw, W - fx0), min(th, H - fy0)
        crop = frame[int(cy):int(cy + ch), int(cx):int(cx + cw)]
        face_px = cv2.resize(crop, (tw, th), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
        fys, fxs = np.mgrid[0:th, 0:tw].astype(np.float32)
        fa = np.ones((th, tw), np.float32) if full else np.clip(0.5 - sdf(fxs + 0.5, fys + 0.5, tw, th, r), 0, 1)
        over(canvas, face_px, fa, fy0, fx0)

        enc.stdin.write((np.clip(canvas, 0, 1) * 255 + 0.5).astype(np.uint8).tobytes())
        if i % 30 == 0:
            print("TAKES_PROGRESS %.3f" % (i / n), file=sys.stderr, flush=True)
    enc.stdin.close()
    if enc.wait() != 0:
        sys.exit("ffmpeg could not write %s." % a.out)
    cam.kill()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--camera", required=True, help="the take's camera file")
    p.add_argument("--out", default="morph.mov")
    p.add_argument("--size", required=True, help="the edit's size, WxH")
    p.add_argument("--fps", default="30")
    p.add_argument("--start", type=float, default=0.0, help="camera second at the layer's start")
    p.add_argument("--length", type=float, required=True, help="seconds of the layer")
    p.add_argument("--face", help="the face's centre in camera pixels, x,y (default: the middle)")
    p.add_argument("--plan", required=True, help='[{"at": s, "layout": "card", "corner": "br"}, ...]')
    p.add_argument("--at", type=float, default=0.0, help="where the layer sits in the edit (for the sfx times)")
    p.add_argument("--name", help="the edit's name (default: this folder's name, _edit/<name>/)")
    p.add_argument("--dry", action="store_true", help="print the sfx only, draw nothing")
    a = p.parse_args()
    W, H = (int(v) for v in a.size.lower().split("x"))
    plan = json.loads(a.plan)
    st = steps(plan, W, H)
    if not a.dry:
        render(a, W, H, st)
    name = a.name or os.path.basename(os.getcwd())
    print(json.dumps({"layer": a.out, "at": a.at, "changes": len(st) - 1,
                      "sfx": whoosh_sfx(plan, a.at, name, os.path.basename(os.path.dirname(os.path.abspath(__file__))))}))


if __name__ == "__main__":
    main()
