"""Banknote prep: python3 engrave.py <this folder> [seconds] [lines] [cols] [fps]
Reads footage.mp4 and person.webm and writes lum.js: the brightness of the portrait (the area PORTRAIT in
index.html: head and shoulders) on a grid of engraving lines, per frame. The room behind the speaker is pushed
light, so the engraving shows only the speaker."""
import sys, os, re, subprocess, base64, numpy as np, cv2
# Look: how dark the room behind the speaker prints (0 = ink, 1 = paper), and how much contrast the face gets.
ROOM, CONTRAST = 0.3, 1.75
d = sys.argv[1]; secs = float(sys.argv[2]) if len(sys.argv) > 2 else 3.4
lines = int(sys.argv[3]) if len(sys.argv) > 3 else 120; cols = int(sys.argv[4]) if len(sys.argv) > 4 else 220
fps = float(sys.argv[5]) if len(sys.argv) > 5 else 15
html = open(os.path.join(d, "index.html")).read()
m = re.search(r"const PORTRAIT = \{ x: ([\d.]+), y: ([\d.]+), w: ([\d.]+), h: ([\d.]+) \}", html)
px, py, pw, ph = map(float, m.groups())
o = subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","csv=p=0",os.path.join(d,"footage.mp4")],capture_output=True,text=True).stdout.strip().split(",")
W, H = int(o[0]), int(o[1])
cw, ch = int(pw * W), int(ph * H); cx, cy = int(px * W - cw / 2), int(py * H - ch / 2)
vf = f"fps={fps},crop={cw}:{ch}:{max(0,cx)}:{max(0,cy)},scale={cols}:{lines}:flags=area"
def grab(f, fmt, ch_, dec=[]):
    raw = subprocess.run(["ffmpeg","-v","error",*dec,"-i",os.path.join(d,f),"-t",str(secs),"-vf",vf,"-f","rawvideo","-pix_fmt",fmt,"-"],capture_output=True).stdout
    return np.frombuffer(raw,np.uint8).reshape(-1,lines,cols,ch_)
g = grab("footage.mp4","gray",1)[...,0].astype(np.float32) / 255
a = grab("person.webm","rgba",4,["-c:v","libvpx-vp9"])[...,3].astype(np.float32) / 255
n = min(len(g), len(a)); g, a = g[:n], a[:n]
# auto levels on the speaker, then the room goes light
# levels from the face (the upper half of the speaker), so the face reads whatever the shirt does
face = (a > 0.5).copy(); face[:, lines // 2:, :] = False
lo, hi = np.percentile(g[face], 2), np.percentile(g[face], 98)
g = np.clip((g - lo) / (hi - lo + 1e-3), 0, 1)
# even out side light: divide by a wide blur of the speaker (detail stays, the light/dark half of the face goes)
k = max(3, cols // 6) | 1
for i in range(n):
    wa = cv2.GaussianBlur(a[i], (k, k), 0) + 1e-3
    wide = cv2.GaussianBlur(g[i] * a[i], (k, k), 0) / wa
    g[i] = np.clip(g[i] - 0.6 * (wide - wide[a[i] > 0.5].mean() if (a[i] > 0.5).any() else 0), 0, 1)
# deep darks and bright lights, like a print
g = np.clip(0.5 + (g - 0.5) * CONTRAST, 0, 1)
v = g * a + (ROOM + 0.12 * g) * (1 - a)
data = (np.clip(v, 0, 1) * 255).astype(np.uint8)
open(os.path.join(d,"lum.js"),"w").write("window.LUM={lines:%d,cols:%d,fps:%g,frames:%d,data:'%s'};" % (lines,cols,fps,n,base64.b64encode(data.tobytes()).decode()))
print("lum.js", lines, "x", cols, n, "frames")
