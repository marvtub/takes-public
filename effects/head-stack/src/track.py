"""Head track: python3 track.py <this folder> [seconds]
Reads person.webm and writes track.js: the top of the head (x, y as parts of the frame) for every frame,
smoothed, so things can sit on the head as it moves."""
import sys, os, subprocess, numpy as np
d = sys.argv[1]; secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6
p = os.path.join(d, "person.webm")
o = subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height,r_frame_rate","-of","csv=p=0",p],capture_output=True,text=True).stdout.strip().split(",")
W, H = int(o[0]), int(o[1]); fps = eval(o[2]); w, h = W // 4, H // 4
raw = subprocess.run(["ffmpeg","-v","error","-c:v","libvpx-vp9","-i",p,"-t",str(secs),"-vf",f"scale={w}:{h}","-f","rawvideo","-pix_fmt","rgba","-"],capture_output=True).stdout
A = np.frombuffer(raw,np.uint8).reshape(-1,h,w,4)[...,3] > 128
pts = []
for a in A:
    rows = np.where(a.any(1))[0]
    if not len(rows): pts.append(pts[-1] if pts else (0.5, 0.2)); continue
    top = rows[0]; band = a[top:top + max(2, h // 60)]
    xs = np.where(band.any(0))[0]
    pts.append(((xs.mean() + 0.5) / w, (top + 0.5) / h))
pts = np.array(pts)
k = 5; ker = np.ones(k) / k
sm = np.stack([np.convolve(np.pad(pts[:, i], (k // 2, k // 2), mode="edge"), ker, "valid") for i in range(2)], 1)
open(os.path.join(d, "track.js"), "w").write("window.TRACK={fps:%g,pts:[%s]};" % (fps, ",".join("[%.4f,%.4f]" % tuple(q) for q in sm)))
print("track.js", len(sm), "frames, head top at start", sm[0].round(3))
