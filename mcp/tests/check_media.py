"""Synthetic media for the check_edit tests: a voice-like sound (pink noise shaped by random syllables, so
it has energy up to 16 kHz and never repeats) over a moving test picture, with its word times."""
import hashlib
import json
import os
import random
import shutil
import struct
import subprocess
import time
import wave

FF = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
WORDS = ("so the next thing we build is a small tool that reads every take and finds the parts that "
         "matter most for people who make videos alone at home with one camera and a laptop").split()


# Made media is kept between runs (2026-10-27): the same take and the same cut were encoded again in
# every 4-test chunk and every run, most of check_edit's test time. A file is found by its ffmpeg
# arguments, with each input file read as its content hash, so a changed input makes a new file.
CACHE = os.environ.get("TAKES_TEST_MEDIA") or os.path.expanduser("~/Library/Caches/takes-test-media")
KEEP_DAYS = 14


def digest(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def cache_key(args):
    """The cache name of one ffmpeg call, or None when it cannot be cached (an input file that is
    missing, or a path that is not the output or an input)."""
    out = args[-1]
    parts, prev = [FF, str(os.path.getmtime(FF)) if os.path.exists(FF) else ""], None
    for a in args[:-1]:
        if os.sep in a and os.path.isfile(a) and prev in ("-i", "-filter_complex_script"):
            parts.append(digest(a))
        elif os.path.isabs(a) and prev in ("-i",):
            return None
        else:
            parts.append(a)
        prev = a
    return hashlib.sha1("\0".join(parts).encode()).hexdigest() + os.path.splitext(out)[1]


def prune_cache():
    try:
        old = time.time() - KEEP_DAYS * 86400
        for f in os.listdir(CACHE):
            p = os.path.join(CACHE, f)
            if os.path.getmtime(p) < old:
                os.remove(p)
    except OSError:
        pass


def ff(*args):
    args = [str(a) for a in args]
    # Test videos encode at veryfast: at the default preset their encodes were half of Reframe's CPU
    # (2026-10-22). A call that names its own preset keeps it.
    if "libx264" in args and "-preset" not in args:
        i = args.index("libx264") + 1
        args[i:i] = ["-preset", "veryfast"]
    key = cache_key(args)
    hit = key and os.path.join(CACHE, key)
    if hit and os.path.isfile(hit):
        shutil.copyfile(hit, args[-1])
        os.utime(hit)
        return
    subprocess.run([FF, "-v", "error", "-y"] + args, check=True)
    if hit:
        try:
            os.makedirs(CACHE, exist_ok=True)
            tmp = "%s.%d.tmp" % (hit, os.getpid())
            shutil.copyfile(args[-1], tmp)
            os.replace(tmp, hit)  # parallel workers: the last one wins, every copy is the same
        except OSError:
            pass


prune_cache()


def voice_gate(path, seconds=20.0, seed=7, rate=1000):
    """A gate track (0..1 at rate per second) and its words [(start, end, word)] and sentence ends."""
    rnd = random.Random(seed)
    g = [0.0] * int(seconds * rate)
    words, ends, t, i = [], set(), 0.4, 0
    while t < seconds - 1.0:
        n = rnd.randint(4, 7)
        for k in range(n):
            if t > seconds - 1.0:
                break
            start = t
            for _ in range(rnd.randint(1, 3)):
                d = rnd.uniform(0.09, 0.22)
                a, b = int(t * rate), int(min(seconds, t + d) * rate)
                peak = rnd.uniform(0.6, 1.0)
                for j in range(a, b):
                    x = (j - a) / float(max(1, b - a))
                    g[j] = peak * min(1.0, x * 12, (1 - x) * 12)
                t += d + 0.02
            words.append((round(start, 3), round(t - 0.02, 3), WORDS[i % len(WORDS)]))
            i += 1
            t += rnd.uniform(0.06, 0.13)
        ends.add(len(words) - 1)
        t += rnd.uniform(0.45, 0.7)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(x * 32000)) for x in g))
    return words, ends


def make_take(folder, name="take-01-camera.mov", seconds=20.0, seed=7, picture="testsrc2=size=320x240:rate=30",
              audio_delay=0.0):
    """A camera take: moving picture, voice and the words file next to it. Returns (words, script text,
    sentences as [(start, end)] in seconds)."""
    gate = os.path.join(folder, ".gate-%d.wav" % seed)
    words, ends = voice_gate(gate, seconds, seed)
    out = os.path.join(folder, name)
    # A dim room: dark, soft colours, so a colour change in the shadows shows in the numbers.
    ff("-f", "lavfi", "-i", "%s:duration=%g,eq=contrast=0.3:brightness=-0.3:saturation=0.4" % (picture, seconds),
       "-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=48000:amplitude=0.5:seed=%d:duration=%g" % (seed, seconds),
       "-i", gate,
       "-f", "lavfi", "-i", "anoisesrc=color=pink:sample_rate=48000:amplitude=0.001:seed=99:duration=%g" % seconds,
       "-filter_complex", "[2]aresample=48000[g];[1][g]amultiply[v];[v][3]amix=inputs=2:normalize=0,"
       "adelay=%d:all=1,atrim=0:%g[a]" % (int(audio_delay * 1000), seconds),
       "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "15", "-c:a", "aac", "-b:a", "192k",
       "-ar", "48000", out)
    os.remove(gate)
    doc = {"v": 2, "clock": "video", "source": "test", "words": [{"word": w, "start": a, "end": b} for a, b, w in words]}
    with open(os.path.splitext(out)[0] + ".words.json", "w") as f:
        json.dump(doc, f)
    sentences, spans, cur = [], [], []
    for i, (a, b, w) in enumerate(words):
        cur.append((a, b, w))
        if i in ends or i == len(words) - 1:
            sentences.append(" ".join(x[2] for x in cur).capitalize() + ".")
            spans.append((cur[0][0], cur[-1][1]))
            cur = []
    return words, " ".join(sentences), spans


def cut(src, out, segs, vf=None, af=None, size="320x240", extra=(), audio_shift=0.0):
    """An edit of src: segments [(in, out)] of the take, back to back; vf/af on the result.
    audio_shift > 0: the sound of each segment comes from that many seconds earlier (baked late)."""
    parts, n = [], len(segs)
    for i, (a, b) in enumerate(segs):
        parts.append("[0:v]trim=%g:%g,setpts=PTS-STARTPTS[v%d]" % (a, b, i))
        parts.append("[0:a]atrim=%g:%g,asetpts=PTS-STARTPTS[a%d]" % (a - audio_shift, b - audio_shift, i))
    parts.append("".join("[v%d][a%d]" % (i, i) for i in range(n)) + "concat=n=%d:v=1:a=1[vv][aa]" % n)
    parts.append("[vv]%s[vo]" % (vf or "null"))
    parts.append("[aa]%s[ao]" % (af or "anull"))
    ff("-i", src, "-filter_complex", ";".join(parts), "-map", "[vo]", "-map", "[ao]", "-c:v", "libx264",
       "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", *extra, out)
    return out
