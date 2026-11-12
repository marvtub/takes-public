"""Impact frame prep: python3 ink.py <this folder> [seconds] [still-at]
Reads person.webm (the speaker's cutout) and writes person-ink.webm: the speaker as a manga ink drawing, cream
with black contour lines (eyes, nose, mouth, beard, the edges of the cap and the clothes) and black only in the
darkest parts (hair, pupils). Side light is evened out first, so half the face does not go to ink.
With still-at (seconds) it writes ink-test.png from that moment instead, to check the look."""
import sys, os, subprocess, numpy as np, cv2
d = sys.argv[1]; secs = float(sys.argv[2]) if len(sys.argv) > 2 else 2.4
still = float(sys.argv[3]) if len(sys.argv) > 3 else None
LINE = 0.3     # contour strength: lower = more lines
SIGMA = 1.8     # contour width (px at 1080)
DARK = 0.2     # below this (0..1, after evening the light) it is solid ink
CREAM = (226, 239, 243)  # BGR of #f3efe2
src = os.path.join(d, "person.webm")
W, H = 1080, 1920
o = subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","csv=p=0",src],capture_output=True,text=True).stdout.strip().split(",")
W, H = int(o[0]), int(o[1]); s = min(W, H) / 1080
args = ["-ss", str(still), "-frames:v", "1"] if still is not None else ["-t", str(secs)]
raw = subprocess.run(["ffmpeg","-v","error","-c:v","libvpx-vp9","-i",src,*args,"-f","rawvideo","-pix_fmt","bgra","-"],capture_output=True).stdout
fr = np.frombuffer(raw, np.uint8).reshape(-1, H, W, 4)
clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8))
def ink(f):
    a = f[..., 3]
    g = cv2.cvtColor(f[..., :3], cv2.COLOR_BGR2GRAY)
    g = clahe.apply(g).astype(np.float32) / 255
    # evening the light: divide by a big blur of itself (keeps detail, drops the side light)
    big = cv2.GaussianBlur(g, (0, 0), 40 * s) + 1e-3
    e = np.clip(g / big * 0.55, 0, 1)
    # XDoG contours
    g1 = cv2.GaussianBlur(e, (0, 0), SIGMA * s); g2 = cv2.GaussianBlur(e, (0, 0), SIGMA * s * 1.6)
    dog = g1 - 0.985 * g2
    line = dog < -LINE * 0.02
    # the outline of the cutout itself
    edge = cv2.morphologyEx((a > 128).astype(np.uint8), cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0
    dark = cv2.GaussianBlur(e, (0, 0), 1.2 * s) < DARK
    m = (line | dark | edge)
    # drop specks (texture noise), keep strokes
    n, lab, st, _ = cv2.connectedComponentsWithStats(m.astype(np.uint8), connectivity=8)
    keep = st[:, cv2.CC_STAT_AREA] >= int(40 * s * s); keep[0] = False
    m = keep[lab]
    out = np.empty_like(f); out[..., :3] = CREAM; out[m, :3] = (10, 10, 10); out[..., 3] = a
    return out
if still is not None:
    o = ink(fr[0]); bg = np.full_like(o[..., :3], 200)
    al = o[..., 3:4] / 255; cv2.imwrite(os.path.join(d, "ink-test.png"), (o[..., :3] * al + bg * (1 - al)).astype(np.uint8)); print("ink-test.png"); sys.exit()
p = subprocess.Popen(["ffmpeg","-v","error","-y","-f","rawvideo","-pix_fmt","bgra","-s",f"{W}x{H}","-r","30","-i","-",
                      "-c:v","libvpx-vp9","-pix_fmt","yuva420p","-b:v","6M","-auto-alt-ref","0",os.path.join(d,"person-ink.webm")],stdin=subprocess.PIPE)
for f in fr: p.stdin.write(ink(f).tobytes())
p.stdin.close(); p.wait(); print("person-ink.webm", len(fr), "frames")
