"""Voice note prep: python3 wave.py <audio or video> <start s> <length s> <out wave.js> [bars]
Writes the voice message's waveform: one loudness value (0 to 1) per bar."""
import sys, subprocess, numpy as np
src, ss, dur, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
bars = int(sys.argv[5]) if len(sys.argv) > 5 else 56
raw = subprocess.run(["ffmpeg","-v","error","-ss",str(ss),"-t",str(dur),"-i",src,"-ac","1","-ar","16000","-f","s16le","-"],capture_output=True).stdout
a = np.abs(np.frombuffer(raw,np.int16).astype(np.float32))/32768
ch = np.array_split(a, bars); v = np.array([np.sqrt((c**2).mean()) if len(c) else 0 for c in ch])
v = (v / (v.max() or 1)) ** 0.7
open(out,"w").write("window.WAVE=[%s];" % ",".join("%.3f" % x for x in v)); print("wave", bars, "bars ->", out)
