"""Code body prep: python3 grid.py <this folder> [cols] [fps] [seconds]
Reads footage.mp4 and person.webm next to it and writes grid.js: for every grid frame, each cell's colour
(RGB, from the footage) and how much of the speaker is in it (from the cutout). index.html draws the letters."""
import sys, os, subprocess, base64, numpy as np
d = sys.argv[1]; cols = int(sys.argv[2]) if len(sys.argv) > 2 else 96
fps = float(sys.argv[3]) if len(sys.argv) > 3 else 15; secs = float(sys.argv[4]) if len(sys.argv) > 4 else 4
p = lambda n: os.path.join(d, n)
o = subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","csv=p=0",p("footage.mp4")],capture_output=True,text=True).stdout.strip().split(",")
W, H = int(o[0]), int(o[1]); cell = W / cols; rows = int(round(H / cell))
def grab(f, fmt, ch, dec=[]):
    raw = subprocess.run(["ffmpeg","-v","error",*dec,"-i",f,"-t",str(secs),"-vf",f"fps={fps},scale={cols}:{rows}:flags=area","-f","rawvideo","-pix_fmt",fmt,"-"],capture_output=True).stdout
    return np.frombuffer(raw,np.uint8).reshape(-1,rows,cols,ch)
rgb = grab(p("footage.mp4"),"rgb24",3); a = grab(p("person.webm"),"rgba",4,["-c:v","libvpx-vp9"])[...,3:]
n = min(len(rgb),len(a)); data = np.concatenate([rgb[:n],a[:n]],axis=3).astype(np.uint8)
open(p("grid.js"),"w").write("window.GRID={cols:%d,rows:%d,fps:%g,frames:%d,data:'%s'};" % (cols,rows,fps,n,base64.b64encode(data.tobytes()).decode()))
print("grid.js", cols, "x", rows, n, "frames", round(os.path.getsize(p("grid.js"))/1e6,1), "MB")
