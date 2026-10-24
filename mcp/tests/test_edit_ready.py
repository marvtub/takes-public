"""Edit-ready takes (2026-10-11): the video clock for every voice WAV, prepared word times, a stable
session id with old paths, cut_take and rough_cut. Media made with ffmpeg in a temp library; the
speech model is a stand-in (TAKES_PREP_CMD): no network, no model, no money."""
import array
import importlib.util
import json
import math
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
SERVER = os.path.join(os.path.dirname(__file__), "..", "takes_mcp.py")
# Other test files replace these in their setUp and keep them replaced: take the real ones now.
REAL = {n: getattr(t, n) for n in ("spawn_detached", "start_job", "start_prepare", "trash", "model_cached",
                                   "take_clock", "ff")}

# Stands in for prepare_take.py: words from TAKES_TEST_WORDS (a JSON file), a log line per run.
FAKE = r'''
import json, os, sys, time
wav, out = sys.argv[1], sys.argv[2]
log = os.environ.get("TAKES_TEST_LOG")
if log:
    open(log, "a").write("start %f %s\n" % (time.time(), " ".join(sys.argv[3:])))
print("TAKES_PROGRESS 0.5", flush=True)
time.sleep(float(os.environ.get("TAKES_TEST_SLEEP") or 0))
if os.environ.get("TAKES_TEST_FAIL"):
    print(os.environ["TAKES_TEST_FAIL"], flush=True)
    sys.exit(int(os.environ.get("TAKES_TEST_CODE") or 1))
words = json.load(open(os.environ["TAKES_TEST_WORDS"])) if os.environ.get("TAKES_TEST_WORDS") else []
json.dump({"language": "en", "words": words, "sounds": [[9.0, 9.2]]}, open(out, "w"))
if log:
    open(log, "a").write("end %f\n" % time.time())
'''


def ff(*args):
    subprocess.run([FFMPEG, "-v", "error", "-y"] + [str(a) for a in args], check=True)


def flash_take(path, secs=6, offset=0.2, flashes=(1.0, 3.0, 5.0), size="160x120", rate=30):
    """A video with a white frame and a 1 kHz beep at each flash second (video time); the audio stream
    starts `offset` late, as on a real camera take."""
    tmp = path + ".parts"
    os.makedirs(tmp, exist_ok=True)
    frames_on = "+".join("eq(n,%d)" % round(f * rate) for f in flashes)
    ff("-f", "lavfi", "-i", "color=black:s=%s:r=%d:d=%s" % (size, rate, secs), "-vf",
       "drawbox=enable='%s':color=white:t=fill" % frames_on, "-c:v", "libx264", "-pix_fmt", "yuv420p",
       os.path.join(tmp, "v.mov"))
    on = "+".join("between(t,%.3f,%.3f)" % (f - offset, f - offset + 0.04) for f in flashes)
    ff("-f", "lavfi", "-i", "sine=f=1000:d=%s:sample_rate=48000" % (secs - offset), "-af",
       "volume=volume=0:enable='not(%s)'" % on, "-ac", "2", os.path.join(tmp, "a.wav"))
    ff("-i", os.path.join(tmp, "v.mov"), "-itsoffset", offset, "-i", os.path.join(tmp, "a.wav"),
       "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le", path)
    shutil.rmtree(tmp)


def flash_times(video, rate=30):
    raw = subprocess.run([FFMPEG, "-v", "error", "-i", video, "-vf", "scale=8:8,format=gray", "-f", "rawvideo", "-"],
                         capture_output=True, check=True).stdout
    out = []
    for i in range(len(raw) // 64):
        if sum(raw[i * 64:(i + 1) * 64]) / 64 > 128:
            out.append(i / float(rate))
    return out


def beep_times(media):
    raw = subprocess.run([FFMPEG, "-v", "error", "-i", media, "-vn", "-ac", "1", "-ar", "48000", "-f", "s16le", "-"],
                         capture_output=True, check=True).stdout
    a = array.array("h")
    a.frombytes(raw[:len(raw) // 2 * 2])
    hop, out, loud = 240, [], False
    for i in range(0, len(a) - hop, hop):
        e = max(abs(x) for x in a[i:i + hop])
        if e > 1200 and not loud:
            out.append(i / 48000.0)
        loud = e > 1200
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_JOB_TIMEOUT"] = "120"
        for k in ("TAKES_CHAT", "TAKES_BOARD", "TAKES_TEST_SLEEP", "TAKES_TEST_FAIL", "TAKES_TEST_CODE",
                  "TAKES_TEST_LOG", "TAKES_TEST_WORDS"):
            os.environ.pop(k, None)
        for k, v in REAL.items():
            setattr(t, k, v)
        t.CLOCKS.clear()
        self.trashed = []
        t.trash = lambda paths: self.trashed.extend(paths) or [os.remove(p) for p in paths]
        fake = os.path.join(self.root, ".fake_prepare.py")
        with open(fake, "w") as f:
            f.write(FAKE)
        os.environ["TAKES_PREP_CMD"] = json.dumps([sys.executable, fake])
        self.s = self.session("2026-10-11-demo")

    def tearDown(self):
        for k, v in REAL.items():
            setattr(t, k, v)
        for d in t.all_session_folders(self.root):
            for j in t.all_jobs(d):
                if j["status"] in ("starting", "running") and j.get("pid"):
                    try:
                        os.kill(j["pid"], signal.SIGTERM)
                    except OSError:
                        pass
        shutil.rmtree(self.root, ignore_errors=True)
        for k in ("TAKES_ROOT", "TAKES_JOB_TIMEOUT", "TAKES_PREP_CMD", "TAKES_TEST_SLEEP", "TAKES_TEST_FAIL",
                  "TAKES_TEST_CODE", "TAKES_TEST_LOG", "TAKES_TEST_WORDS"):
            os.environ.pop(k, None)

    def session(self, name, project="Proj", created="2026-10-11T00:00:00Z", takes=()):
        s = os.path.join(self.root, project, name)
        os.makedirs(s)
        t.write_meta(s, {"title": name, "createdAt": created, "named": True, "takes": list(takes)})
        return s

    def add_take(self, n=1, secs=6, kind="camera", name=None, **kw):
        f = "take-%02d-%s.mov" % (n, kind) if not name else "take-%02d-%s-%s.mov" % (n, name, kind)
        flash_take(os.path.join(self.s, f), secs=secs, **kw)
        meta = t.read_meta(self.s)
        meta["takes"].append({"number": n, "kind": kind, "file": f, "startedAt": "2026-10-11T00:00:00Z",
                              "duration": secs})
        t.write_meta(self.s, meta)
        return f

    def words(self, words):
        p = os.path.join(self.root, ".words-%d.json" % len(os.listdir(self.root)))
        with open(p, "w") as f:
            json.dump(words, f)
        os.environ["TAKES_TEST_WORDS"] = p

    def doc(self, f):
        with open(os.path.join(self.s, os.path.splitext(f)[0] + ".words.json")) as fh:
            return json.load(fh)


class Clock(Base):
    def test_take_clock_offset_and_cfr(self):
        f = self.add_take()
        c = t.take_clock(os.path.join(self.s, f))
        self.assertGreaterEqual(c["audio_offset_s"], 0.15)
        self.assertLessEqual(c["audio_offset_s"], 0.22)
        self.assertEqual((c["fps"], c["fps_mode"]), (30, "cfr"))

    def test_take_clock_vfr(self):
        a, b, out = (os.path.join(self.root, n) for n in ("a.mp4", "b.mp4", "vfr.mov"))
        ff("-f", "lavfi", "-i", "color=red:s=64x64:r=30:d=1", "-c:v", "libx264", a)
        ff("-f", "lavfi", "-i", "color=blue:s=64x64:r=25:d=1", "-c:v", "libx264", b)
        lst = os.path.join(self.root, "l.txt")
        open(lst, "w").write("file '%s'\nfile '%s'\n" % (a, b))
        ff("-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", out)
        c = t.take_clock(out)
        self.assertEqual(c["fps_mode"], "vfr")
        self.assertIn(c["fps"], (25, 30))

    def test_take_clock_no_audio(self):
        p = os.path.join(self.root, "silent.mov")
        ff("-f", "lavfi", "-i", "color=black:s=64x64:r=30:d=1", p)
        self.assertIsNone(t.take_clock(p)["audio_offset_s"])

    def test_extract_voice_is_on_video_clock(self):
        f = self.add_take(secs=3)
        out = os.path.join(self.root, "v.wav")
        t.extract_voice(os.path.join(self.s, f), out)
        self.assertAlmostEqual(t.media_duration(out), 3.0, delta=0.03)
        # The beep at video 1.0 s is at 1.0 s of the WAV, not 0.8.
        self.assertAlmostEqual(beep_times(out)[0], 1.0, delta=0.012)

    def test_scribe_uses_video_clock(self):
        seen = []
        t.ff = lambda *a: seen.append(a)
        t.eleven_http, real = (lambda *a, **k: {"words": []}), t.eleven_http
        try:
            t.eleven_transcribe(os.path.join(self.root, "x.mov"))
        finally:
            t.eleven_http = real
        self.assertIn(t.VIDEO_CLOCK, " ".join(str(x) for x in seen[0]))


class VoiceClock(Base):
    FAKE_VOICE = r'''
import json, shutil, subprocess, sys
src, out = sys.argv[1], sys.argv[2]
open(sys.argv[0] + ".inputs", "a").write(src + "\n")
subprocess.run([%r, "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", out], check=True)
json.dump({"steps": [], "diagnosis": {}}, open(out[:-4] + ".report.json", "w"))
''' % FFMPEG

    def test_voice_run_feeds_padded_wav(self):
        f = self.add_take(secs=3)
        fake = os.path.join(self.root, "voice.py")
        open(fake, "w").write(self.FAKE_VOICE)
        os.environ["TAKES_VOICE_CMD"] = json.dumps([sys.executable, fake])
        try:
            t.voice_run(self.s, "1", "camera")
        finally:
            os.environ.pop("TAKES_VOICE_CMD")
        v = t.read_voice(self.s, "take-01-camera")
        self.assertEqual((v["state"], v["clock"]), ("done", "video"), v.get("error"))
        inputs = open(fake + ".inputs").read().split()
        self.assertTrue(all(x.endswith(".src.wav") for x in inputs))
        self.assertFalse(os.path.exists(inputs[0]), "the padded WAV is removed after")
        mix = t.voice_files(self.s, "take-01-camera")["mix"]
        self.assertAlmostEqual(t.media_duration(mix), 3.0, delta=0.03)
        self.assertEqual(t.voice_offset(self.s, "take-01-camera"), 0.0)
        view = t.voice_view(self.s, t.read_meta(self.s)["takes"][0])
        self.assertNotIn("starts_at_s", view)

    def legacy_voice(self):
        f = self.add_take(secs=3)
        fl = t.voice_files(self.s, "take-01-camera")
        os.makedirs(os.path.dirname(fl["mix"]), exist_ok=True)
        ff("-i", os.path.join(self.s, f), "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", fl["mix"])
        t.write_voice(self.s, "take-01-camera", {"state": "done", "on": True, "strength": 1.0, "loudness": "normal"})
        return f

    def test_old_voice_reports_offset(self):
        self.legacy_voice()
        off = t.voice_offset(self.s, "take-01-camera")
        self.assertGreater(off, 0.15)
        view = t.voice_view(self.s, t.read_meta(self.s)["takes"][0])
        self.assertAlmostEqual(view["starts_at_s"], off, places=3)
        self.assertIn("adelay=%d" % round(off * 1000), view["use"])

    def test_fix_words_legacy_voice_splice_position(self):
        f = self.legacy_voice()
        off = t.voice_offset(self.s, "take-01-camera")
        with open(os.path.join(self.s, "take-01-camera.words.json"), "w") as fh:
            json.dump({"v": 2, "clock": "video", "words": [{"word": "hello", "start": 1.0, "end": 1.5}]}, fh)
        calls = {}
        real = {n: getattr(t, n) for n in ("resolve_voice", "tts", "splice", "with_audio", "mean_db")}

        def fake_tts(text, vid, out, *a, **k):
            ff("-f", "lavfi", "-i", "sine=f=300:d=0.5", out)
        t.resolve_voice = lambda ref: ("v1", "Me")
        t.tts = fake_tts
        t.mean_db = lambda *a, **k: None
        t.splice = lambda base, piece, start, end, out, length: calls.update(start=start, end=end) or \
            shutil.copy(base, out)
        t.with_audio = lambda video, wav, out, delay_s=0.0: calls.update(delay=delay_s) or shutil.copy(video, out)
        try:
            t.t_fix_words({"session": self.s, "take": "1", "old": "hello", "new": "hi"})
        finally:
            for n, v in real.items():
                setattr(t, n, v)
        self.assertAlmostEqual(calls["start"], 1.0 - off, places=3)
        self.assertAlmostEqual(calls["delay"], off, places=3)


class Prepare(Base):
    WORDS = [{"word": "If", "start": 0.41, "end": 0.52}, {"word": "um,", "start": 0.83, "end": 1.02},
             {"word": "datacenter", "start": 2.0, "end": 2.6}]

    def apple(self, f):
        with open(os.path.join(self.s, os.path.splitext(f)[0] + ".words.json"), "w") as fh:
            json.dump({"words": [{"word": "If", "start": 0.24, "end": 1.5}], "source": "apple en_US"}, fh)

    def test_prepare_writes_v2(self):
        f = self.add_take()
        self.apple(f)
        self.words(self.WORDS)
        log = os.path.join(self.root, "log")
        os.environ["TAKES_TEST_LOG"] = log
        self.assertEqual(t.prepare_take(self.s, 1), "done")
        d = self.doc(f)
        self.assertEqual((d["v"], d["clock"]), (2, "video"))
        self.assertEqual(d["before"]["source"], "apple en_US")
        self.assertEqual([w.get("filler", False) for w in d["words"]], [False, True, False])
        self.assertGreater(d["audio_offset_s"], 0.15)
        self.assertEqual(d["sounds"], [[9.0, 9.2]])
        self.assertIn("--language en", open(log).read())

    def test_prepare_twice_keeps_first_before_and_skips_when_ready(self):
        f = self.add_take()
        self.apple(f)
        self.words(self.WORDS)
        log = os.path.join(self.root, "log")
        os.environ["TAKES_TEST_LOG"] = log
        t.prepare_take(self.s, 1)
        self.assertEqual(t.prepare_take(self.s, 1), "ready")
        self.assertEqual(open(log).read().count("start"), 1)
        d = self.doc(f)
        d["duration"] = 99  # made from another file: prepares again
        json.dump(d, open(os.path.join(self.s, "take-01-camera.words.json"), "w"))
        t.prepare_take(self.s, 1)
        self.assertEqual(open(log).read().count("start"), 2)
        self.assertEqual(self.doc(f)["before"]["source"], "apple en_US")

    def test_apple_words_written_during_whisper_go_under_before(self):
        self.add_take()
        self.words(self.WORDS)
        os.environ["TAKES_TEST_SLEEP"] = "1.0"
        th = threading.Thread(target=t.prepare_take, args=(self.s, 1))
        th.start()
        time.sleep(0.6)
        self.apple("take-01-camera.mov")
        th.join()
        d = self.doc("take-01-camera.mov")
        self.assertEqual(d["v"], 2)
        self.assertEqual(d["before"]["source"], "apple en_US")

    def test_prepare_bad_words_file_untouched(self):
        f = self.add_take()
        p = os.path.join(self.s, "take-01-camera.words.json")
        open(p, "w").write("{bad json")
        with self.assertRaises(t.PrepareError) as e:
            t.prepare_take(self.s, 1)
        self.assertEqual(str(e.exception), "Takes cannot read take-01-camera.words.json. Takes did not change it. "
                                           "Move it out of the session folder, then try again: Takes finds the words "
                                           "again.")
        self.assertEqual(open(p).read(), "{bad json")

    def test_prepare_no_sound(self):
        p = os.path.join(self.s, "take-01-camera.mov")
        ff("-f", "lavfi", "-i", "color=black:s=64x64:r=30:d=1", p)
        t.write_meta(self.s, dict(t.read_meta(self.s), takes=[{"number": 1, "kind": "camera", "file": "take-01-camera.mov",
                                                                "startedAt": "2026-10-11T00:00:00Z"}]))
        with self.assertRaises(t.PrepareError) as e:
            t.prepare_take(self.s, 1)
        self.assertEqual(str(e.exception), "Take 1 has no sound. Takes cannot find words in it.")

    def test_prepare_follows_take_rename(self):
        self.add_take()
        self.words(self.WORDS)
        os.environ["TAKES_TEST_SLEEP"] = "1.5"
        log = os.environ["TAKES_TEST_LOG"] = os.path.join(self.root, "log")
        th = threading.Thread(target=t.prepare_take, args=(self.s, 1))
        th.start()
        # Rename while the stand-in runs, not while ffmpeg still reads the take (slow on a busy Mac).
        end = time.time() + 30
        while not (os.path.exists(log) and "start" in open(log).read()) and time.time() < end:
            time.sleep(0.02)
        t.t_rename_take({"session": self.s, "take": 1, "name": "Intro"})
        th.join()
        self.assertTrue(os.path.exists(os.path.join(self.s, "take-01-intro-camera.words.json")))
        self.assertFalse(os.path.exists(os.path.join(self.s, "take-01-camera.words.json")))

    def test_prepare_lock_ignores_tmpdir(self):
        self.add_take()
        self.add_take(2)
        self.words(self.WORDS)
        log = os.path.join(self.root, "log")
        env = dict(os.environ, TAKES_TEST_LOG=log, TAKES_TEST_SLEEP="0.6")
        procs = [subprocess.Popen([sys.executable, SERVER, "--prepare-run", self.s, str(n)], cwd=self.s,
                                  env=dict(env, TMPDIR=tempfile.mkdtemp()), stdout=subprocess.PIPE, text=True)
                 for n in (1, 2)]
        outs = [p.communicate(timeout=60)[0] for p in procs]
        lines = [l.split() for l in open(log).read().splitlines()]
        spans = [(float(lines[i][1]), float(lines[i + 1][1])) for i in range(0, len(lines), 2)]
        self.assertEqual(len(spans), 2)
        a, b = sorted(spans)
        self.assertLessEqual(a[1], b[0], "two Whisper runs at once")
        self.assertTrue(any("Waits for " in o for o in outs), outs)

    def test_prepare_waits_for_recording(self):
        self.add_take()
        self.words(self.WORDS)
        t.PREP_WAIT_S, wait = 0.2, t.PREP_WAIT_S
        rec = subprocess.Popen(["sleep", "30"])
        marker = os.path.join(self.root, ".recording")
        open(marker, "w").write(str(rec.pid))
        try:
            p = subprocess.Popen([sys.executable, SERVER, "--prepare-run", self.s, "1"], cwd=self.s,
                                 stdout=subprocess.PIPE, text=True, env=dict(os.environ))
            # Until it says it waits: a fixed 1.5 s was too short on a busy Mac (2026-10-20).
            head = ""
            while "Waits for the recording" not in head:
                line = p.stdout.readline()
                if not line: break
                head += line
            self.assertIsNone(p.poll(), "it waits while the take records")
            self.assertFalse(os.path.exists(os.path.join(self.s, "take-01-camera.words.json")))
            os.remove(marker)
            out = head + p.communicate(timeout=30)[0]
            self.assertIn("Waits for the recording to end.", out)
            self.assertTrue(os.path.exists(os.path.join(self.s, "take-01-camera.words.json")))
            # A marker of a dead app is stale.
            open(marker, "w").write("999999")
            os.remove(os.path.join(self.s, "take-01-camera.words.json"))
            self.assertEqual(t.prepare_take(self.s, 1), "done")
        finally:
            t.PREP_WAIT_S = wait
            rec.kill()

    def test_prepare_waits_for_recording_after_the_lock(self):
        # Another take's Whisper holds the lock; a take starts to record before it ends.
        import fcntl
        self.add_take()
        self.words(self.WORDS)
        log = os.path.join(self.root, "log")
        t.PREP_WAIT_S, wait = 0.2, t.PREP_WAIT_S
        fd = os.open(os.path.join(self.root, ".prepare.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.pwrite(fd, b"7 2026-10-11-other", 0)
        rec = subprocess.Popen(["sleep", "30"])
        marker = os.path.join(self.root, ".recording")
        try:
            p = subprocess.Popen([sys.executable, SERVER, "--prepare-run", self.s, "1"], cwd=self.s,
                                 stdout=subprocess.PIPE, text=True, env=dict(os.environ, TAKES_TEST_LOG=log))
            # Until it says it waits on the lock: a fixed second was too short on a busy Mac.
            head = ""
            while "Waits for" not in head:
                line = p.stdout.readline()
                if not line: break
                head += line
            open(marker, "w").write(str(rec.pid))
            os.close(fd)  # the other take ends
            time.sleep(1.5)
            self.assertIsNone(p.poll(), "it waits while the take records")
            self.assertFalse(os.path.exists(log), "Whisper ran while a take recorded")
            os.remove(marker)
            out = head + p.communicate(timeout=30)[0]
            self.assertIn("Waits for take 7 of 2026-10-11-other.", out)
            self.assertIn("Waits for the recording to end.", out)
            self.assertTrue(os.path.exists(log))
        finally:
            t.PREP_WAIT_S = wait
            rec.kill()

    def test_uv_without_network_is_the_download_error(self):
        # uv stops before prepare_take.py runs (no TAKES_PROGRESS line): offline, one plain error.
        self.add_take()
        os.environ["TAKES_PREP_CMD"] = json.dumps([sys.executable, "-c", (
            "print('hint: Packages were unavailable because the network was disabled.'); raise SystemExit(1)")])
        with self.assertRaises(t.PrepareError) as e:
            t.prepare_take(self.s, 1)
        self.assertEqual(str(e.exception), t.DOWNLOAD_ERROR)
        self.assertTrue(os.path.exists(os.path.join(self.root, ".prepare-offline")))
        started = []
        t.start_job = lambda s, cmd, outputs, label, estimate_s=None: started.append(label) or {"id": "job-1"}
        t.model_cached = lambda model=None: False
        self.assertIsNone(t.app_prepare(self.s, 1), "the next saved take adds no failed row")
        self.assertEqual(started, [])
        # A failure inside the script is its own reason, not the download error.
        os.remove(os.path.join(self.root, ".prepare-offline"))
        os.environ["TAKES_PREP_CMD"] = json.dumps([sys.executable, "-c", (
            "print('TAKES_PROGRESS 0'); print('prepare_take.py needs a 16-bit WAV.'); raise SystemExit(1)")])
        with self.assertRaises(t.PrepareError) as e:
            t.prepare_take(self.s, 1)
        self.assertEqual(str(e.exception), "prepare_take.py needs a 16-bit WAV.")
        self.assertFalse(os.path.exists(os.path.join(self.root, ".prepare-offline")))

    def test_prepare_labels_and_cmd(self):
        seen = []
        t.start_job = lambda s, cmd, outputs, label, estimate_s=None: seen.append((cmd, label)) or {"id": "job-1"}
        s = self.session("2026-10-11-it's \"a\" ✨ test")
        t.model_cached = lambda model=None: True
        t.start_prepare(s, [3])
        t.start_prepare(s, [5, 3])
        t.model_cached = lambda model=None: False
        t.start_prepare(s, [3])
        self.assertEqual([x[1] for x in seen], ["Finding words in take 3", "Finding words in takes 3, 5",
                                                "Getting the speech model (one time, about 500 MB)"])
        import shlex
        argv = shlex.split(seen[1][0])
        self.assertEqual(argv[2:], ["--prepare-run", ".", "3", "5"])
        self.assertTrue(os.path.exists(argv[1]))

    def test_app_prepare_skipped_offline(self):
        self.add_take()
        started = []
        t.start_job = lambda s, cmd, outputs, label, estimate_s=None: started.append(label) or {"id": "job-1"}
        t.model_cached = lambda model=None: False
        open(os.path.join(self.root, ".prepare-offline"), "w").write("now")
        self.assertIsNone(t.app_prepare(self.s, 1))
        self.assertEqual(started, [])
        os.utime(os.path.join(self.root, ".prepare-offline"), (time.time() - 7200, time.time() - 7200))
        t.app_prepare(self.s, 1)
        self.assertEqual(len(started), 1)

    def test_download_error_and_offline_marker(self):
        self.add_take()
        os.environ["TAKES_TEST_FAIL"] = t.DOWNLOAD_ERROR
        os.environ["TAKES_TEST_CODE"] = "3"
        with self.assertRaises(t.PrepareError) as e:
            t.prepare_take(self.s, 1)
        self.assertEqual(str(e.exception), "Takes could not download the speech model. Connect to the internet. "
                                           "Takes tries again at the next cut.")
        self.assertTrue(os.path.exists(os.path.join(self.root, ".prepare-offline")))

    def test_prepare_job_progress_and_reason(self):
        self.add_take()
        os.environ["TAKES_TEST_FAIL"] = "Take 1 has no sound. Takes cannot find words in it."
        t.model_cached = lambda model=None: True
        job = t.start_prepare(self.s, [1])
        b = t.t_get_job({"id": job["id"], "session": self.s, "wait_s": 30})
        self.assertEqual(b["status"], "failed")
        self.assertEqual(b["error"], "Take 1 has no sound. Takes cannot find words in it.")
        self.assertEqual(b["label"], "Finding words in take 1")
        g = t.t_get_session({"session": self.s})["takes"][0]
        self.assertEqual((g["edit_ready"], g["prepare_error"]), (False, b["error"]))

    def test_import_take_starts_prepare(self):
        calls = []
        t.start_prepare = lambda s, numbers: calls.append(list(numbers))
        src = os.path.join(self.root, "phone.mov")
        flash_take(src, secs=2)
        t.t_import_take({"session": self.s, "takes": [{"path": src}, {"path": src}]})
        self.assertEqual(calls, [[1, 2]])

    def test_get_session_shows_ready_without_ffprobe_or_writes(self):
        f = self.add_take()
        self.words(self.WORDS)
        before = {n: os.stat(os.path.join(self.s, n)).st_mtime_ns for n in os.listdir(self.s)}
        t.take_clock = lambda path: self.fail("get_session ran ffprobe")
        g = t.t_get_session({"session": self.s})
        self.assertEqual(g["takes"][0]["edit_ready"], False)
        self.assertNotIn("audio_offset_s", g["takes"][0])
        self.assertEqual(before, {n: os.stat(os.path.join(self.s, n)).st_mtime_ns for n in os.listdir(self.s)})
        t.take_clock = REAL["take_clock"]
        t.prepare_take(self.s, 1)
        t.take_clock = lambda path: self.fail("get_session ran ffprobe")
        g = t.t_get_session({"session": self.s})["takes"][0]
        self.assertTrue(g["edit_ready"])
        self.assertGreater(g["audio_offset_s"], 0.15)


class SessionIds(Base):
    def test_id_derived_and_stable_on_rename(self):
        os.remove(os.path.join(self.s, "session.json"))
        with open(os.path.join(self.s, "session.json"), "w") as f:
            json.dump({"title": "x", "createdAt": "2026-10-11T00:00:00Z", "takes": []}, f)
        sid = t.session_id(self.s)
        self.assertRegex(sid, r"^[0-9a-f]{12}$")
        r = t.t_update_session({"session": self.s, "title": "New name"})
        self.assertEqual(r["id"], sid)
        self.assertEqual(t.read_meta(r["path"])["id"], sid, "the first write stores it")

    def test_same_created_at_different_ids(self):
        b = self.session("2026-10-11-other")
        self.assertNotEqual(t.session_id(self.s), t.session_id(b))

    def test_write_meta_stores_id_and_read_never_writes(self):
        s = os.path.join(self.root, "Proj", "bare")
        os.makedirs(s)
        with open(os.path.join(s, "session.json"), "w") as f:
            json.dump({"title": "x", "createdAt": "2026-10-11T00:00:00Z", "takes": []}, f)
        sid = t.session_id(s)
        before = open(os.path.join(s, "session.json")).read()
        t.t_get_session({"session": s})
        t.t_list_sessions({"project": "Proj"})
        self.assertEqual(open(os.path.join(s, "session.json")).read(), before)
        t.write_meta(s, t.read_meta(s))
        self.assertEqual(t.read_meta(s)["id"], sid)

    def test_resolve_by_id(self):
        sid = t.session_id(self.s)
        self.assertEqual(t.resolve_session(sid), self.s)
        self.assertEqual(t.t_get_session({"session": sid})["path"], self.s)

    def test_resolve_by_old_path_chain(self):
        a = self.s
        b = t.t_update_session({"session": a, "title": "Bee"})["path"]
        c = t.t_update_session({"session": b, "title": "Sea"})["path"]
        self.assertEqual(t.resolve_session(a), c)
        self.assertEqual(t.resolve_session("Proj/2026-10-11-demo"), c)

    def test_resolve_by_folder_name_after_project_rename(self):
        os.rename(os.path.join(self.root, "Proj"), os.path.join(self.root, "Renamed"))
        self.assertEqual(t.resolve_session(self.s), os.path.join(self.root, "Renamed", "2026-10-11-demo"))

    def test_folder_name_fallback_not_used_when_project_exists(self):
        other = self.session("2026-10-11-lost", project="Other")
        self.assertTrue(other)
        with self.assertRaises(ValueError) as e:
            t.resolve_session(os.path.join(self.root, "Proj", "2026-10-11-lost"))
        self.assertIn("call list_sessions, or pass the session id", str(e.exception))

    def test_resolve_ambiguous_id_errors(self):
        copy = os.path.join(self.root, "Proj", "copy")
        t.write_meta(self.s, t.read_meta(self.s))
        shutil.copytree(self.s, copy)
        with self.assertRaises(ValueError) as e:
            t.resolve_session(t.session_id(self.s))
        self.assertIn("Two sessions have the id", str(e.exception))

    def test_resolve_unknown_says_list_sessions(self):
        with self.assertRaises(ValueError) as e:
            t.resolve_session("Proj/nothing-here")
        self.assertIn("It may have been renamed: call list_sessions", str(e.exception))

    def test_resolve_result_has_resolved_from(self):
        old = self.s
        new = t.t_update_session({"session": old, "title": "Moved"})["path"]
        out = []
        real = t.reply
        t.reply = lambda id_, result=None, error=None: out.append(result)
        try:
            t.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                      "params": {"name": "get_session", "arguments": {"session": old}}})
        finally:
            t.reply = real
        body = json.loads(out[0]["content"][0]["text"])
        self.assertEqual(body["resolved_from"], old)
        self.assertTrue(body["note"].startswith("The session moved to %s." % new))

    def test_rename_by_old_path_names_the_new_path_once(self):
        old = self.s
        t.t_update_session({"session": old, "title": "Beta"})
        out = []
        real = t.reply
        t.reply = lambda id_, result=None, error=None: out.append(result)
        try:
            t.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                      "params": {"name": "update_session", "arguments": {"session": old, "title": "Alpha"}}})
        finally:
            t.reply = real
        body = json.loads(out[0]["content"][0]["text"])
        self.assertEqual(body["resolved_from"], old)
        self.assertTrue(body["path"].endswith("2026-10-11-alpha"))
        self.assertEqual(body["note"], "The folder has a new name. Use this path or the id from now on; the old "
                                       "path still works.")

    def test_update_session_returns_path_first(self):
        old = self.s
        r = t.t_update_session({"session": old, "title": "My video"})
        self.assertEqual(list(r)[:3], ["path", "moved_from", "id"])
        self.assertEqual(r["path"], os.path.join(self.root, "Proj", "2026-10-11-my-video"))
        self.assertEqual(r["moved_from"], old)
        self.assertIn("old path still works", r["note"])
        r = t.t_update_session({"session": r["path"], "title": "My video"})
        self.assertNotIn("moved_from", r)

    def test_rename_back_gets_original_name(self):
        a = self.s
        b = t.t_update_session({"session": a, "title": "B"})["path"]
        back = t.t_update_session({"session": b, "title": "demo"})["path"]
        self.assertEqual(back, a)
        moves = t.read_moves(self.root)
        self.assertNotIn("Proj/2026-10-11-demo", moves)
        self.assertEqual(moves["Proj/2026-10-11-b"], "Proj/2026-10-11-demo")
        self.assertEqual(t.resolve_session(b), a)

    def test_new_session_skips_name_of_other_moved_session(self):
        today = time.strftime("%Y-%m-%d")
        first = t.t_create_session({"project": "Proj", "title": "", "open": False})["path"]
        self.assertTrue(first.endswith(today + "-untitled"))
        renamed = t.t_update_session({"session": first, "title": "Real"})["path"]
        second = t.t_create_session({"project": "Proj", "title": "", "open": False})["path"]
        self.assertTrue(second.endswith(today + "-untitled-2"), second)
        self.assertEqual(t.resolve_session(first), renamed, "the old path still finds the renamed one")
        shutil.rmtree(renamed)
        third = t.t_create_session({"project": "Proj", "title": "", "open": False})["path"]
        self.assertTrue(third.endswith(today + "-untitled"), third)

    def test_move_sessions_writes_moves(self):
        sid = t.session_id(self.s)
        r = t.t_move_sessions({"sessions": [self.s], "project": "Elsewhere"})
        self.assertEqual(r["moved"], [{"from": "Proj/2026-10-11-demo", "to": "Elsewhere/2026-10-11-demo", "id": sid}])
        self.assertEqual(t.resolve_session("Proj/2026-10-11-demo"), os.path.join(self.root, "Elsewhere", "2026-10-11-demo"))

    def test_session_id_cli(self):
        out = subprocess.run([sys.executable, SERVER, "--session-id", self.s], capture_output=True, text=True).stdout
        self.assertEqual(out.strip(), t.session_id(self.s))


class Cuts(Base):
    def setUp(self):
        super().setUp()
        self.f = self.add_take()
        self.words([{"word": "Hello", "start": 0.6, "end": 0.9}, {"word": "datacenter", "start": 2.0, "end": 2.4},
                    {"word": "world", "start": 2.7, "end": 3.2}])

    def cut(self, segs, **kw):
        r = t.t_cut_take(dict({"session": self.s, "segments": segs}, **kw))
        self.assertNotEqual(r.get("status"), "running", r)
        return r

    def assert_sync(self, media, want):
        flashes, beeps = flash_times(media), beep_times(media)
        self.assertEqual(len(flashes), len(want), flashes)
        self.assertEqual(len(beeps), len(want), beeps)
        for f, b, w in zip(flashes, beeps, want):
            self.assertAlmostEqual(f, w, delta=0.034)
            self.assertLessEqual(abs(f - b), 0.034, (flashes, beeps))

    def test_cut_take_in_sync(self):
        r = self.cut([{"take": 1, "in": 0.5, "out": 1.5}, {"take": 1, "in": 2.5, "out": 3.5}])
        self.assertAlmostEqual(r["length_s"], 2.0, delta=0.034)
        self.assertAlmostEqual(t.media_duration(r["video"]), 2.0, delta=0.07)
        c = t.take_clock(r["video"])
        self.assertEqual(c["fps_mode"], "cfr")
        self.assert_sync(r["video"], [0.5, 1.5])
        for got, want in zip(beep_times(r["voice"]), [0.5, 1.5]):
            self.assertAlmostEqual(got, want, delta=0.02)
        self.assertEqual(r["voice_source"], "take sound")
        self.assertTrue(r["video"].endswith("/_work/take-01-v1.mp4"))

    def test_cut_take_reverse_order_in_sync(self):
        r = self.cut([{"take": 1, "in": 2.5, "out": 3.5}, {"take": 1, "in": 0.5, "out": 1.5}])
        self.assert_sync(r["video"], [0.5, 1.5])

    def test_cut_take_many_segments_in_sync(self):
        # More segments than one picture pass holds: the parts join without a gap or a drift.
        segs = [{"take": 1, "in": 0.0, "out": 0.4}] * 4 + [{"take": 1, "in": 0.9, "out": 1.2}] \
            + [{"take": 1, "in": 1.5, "out": 1.8}] * 4 + [{"take": 1, "in": 4.9, "out": 5.3}]
        r = self.cut(segs)
        self.assertAlmostEqual(t.media_duration(r["video"]), 3.5, delta=0.07)
        self.assertEqual(t.take_clock(r["video"])["fps_mode"], "cfr")
        self.assert_sync(r["video"], [1.7, 3.2])

    def test_cut_batch_small_above_1080p_or_10_bit(self):
        # A 4K HEVC Main10 decoder holds about 320 MB: 150 segments 8 at a time peaked at 2.5 GB.
        self.assertEqual(t.cut_batch({"width": 1920, "height": 1080, "pix_fmt": "yuv420p"}), 8)
        self.assertEqual(t.cut_batch({"width": 3840, "height": 2160, "pix_fmt": "yuv420p"}), 3)
        self.assertEqual(t.cut_batch({"width": 1920, "height": 1080, "pix_fmt": "yuv420p10le"}), 3)
        seen, run_ff = [], t.run_ff

        def fake(cmd, total, lo=0.0, hi=1.0):
            seen.append(cmd.count("-i"))
            if len(seen) == 2:
                self.assertEqual(cmd.count("-threads"), 3, "4K decoders on 4 threads")
            open(cmd[-1], "w").close()
        t.run_ff = fake
        try:
            c = {"fps": 30, "width": 3840, "height": 2160, "pix_fmt": "p010le", "audio_offset_s": 0.2}
            segs = [{"take": 1, "in": 9.0 - i, "out": 9.5 - i} for i in range(7)]
            out = os.path.join(self.s, "x.part.mp4")
            t.render_cut(segs, ["a.mov"] * 7, [c] * 7, [None] * 7, out, os.path.join(self.s, "x.part.wav"))
        finally:
            t.run_ff = run_ff
        self.assertEqual(seen, [7, 3, 3, 1, 2], "sound in one pass, picture 3 inputs at a time, then the join")
        self.assertFalse(os.path.exists(os.path.join(self.s, "x.cut")))

    def test_stopped_cut_leaves_no_files(self):
        t.prepare_take(self.s, 1)
        jobs = []
        t.start_job = lambda s, cmd, outputs, label, estimate_s=None: jobs.append(cmd) or {"id": "job-1"}
        segs = t.check_segments(self.s, [{"take": 1, "in": 0.5, "out": 1.5}])
        t.start_cut(self.s, segs, "take-01")
        t.start_job = REAL["start_job"]
        # An ffmpeg that hangs: the job is stopped in the middle of the cut.
        bin_dir = os.path.join(self.root, ".bin")
        os.makedirs(bin_dir)
        with open(os.path.join(bin_dir, "ffmpeg"), "w") as f:
            f.write("#!/bin/sh\nsleep 30\n")
        os.chmod(os.path.join(bin_dir, "ffmpeg"), 0o755)
        env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ.get("PATH", ""))
        p = subprocess.Popen(["/bin/zsh", "-c", jobs[0]], cwd=self.s, env=env, start_new_session=True,
                             stdout=subprocess.PIPE, text=True)
        work = os.path.join(self.s, "_work")
        end = time.time() + 30
        while not os.path.exists(os.path.join(work, ".take-01-v1.cut")) and time.time() < end:
            time.sleep(0.1)
        self.assertTrue(os.path.exists(os.path.join(work, ".take-01-v1.cut")))
        os.killpg(p.pid, signal.SIGTERM)
        p.communicate(timeout=20)
        self.assertEqual(os.listdir(work), [], "a stopped cut cleans up after itself")
        # A killed cut (SIGKILL skips every finally): the next cut sweeps what it left.
        os.makedirs(os.path.join(work, ".take-01-v1.cut"))
        open(os.path.join(work, ".take-01-v1.cut", "000.mp4"), "w").write("x")
        open(os.path.join(work, ".take-01-v1.part.mp4"), "w").write("x")
        req = os.path.join(work, "take-01-v1.request.json")
        open(req, "w").write("{}")
        open(os.path.join(work, "take-01-v1.mp4"), "w").write("half")
        os.utime(req, (time.time() - 120, time.time() - 120))
        r = self.cut([{"take": 1, "in": 0.5, "out": 1.0}])
        self.assertTrue(r["video"].endswith("take-01-v1.mp4"))
        self.assertEqual(sorted(os.listdir(work)), ["take-01-v1.json", "take-01-v1.mp4", "take-01-v1.wav",
                                                    "take-01-v1.words.json"])

    def test_cut_take_snaps_inside_word(self):
        r = self.cut([{"take": 1, "in": 0.0, "out": 2.2}])
        self.assertEqual(r["moved"], [{"was": 2.2, "now": 2.467, "why": "inside 'datacenter'"}])
        r = self.cut([{"take": 1, "in": 2.1, "out": 3.3}])
        # 2.0 - 0.04, down to a whole frame: the in-point is never later than 0.04 before the onset.
        self.assertEqual(r["moved"], [{"was": 2.1, "now": 1.933, "why": "inside 'datacenter'"}])
        r = self.cut([{"take": 1, "in": 0.01, "out": 1.0}])
        self.assertEqual(r["moved"], [], "frame rounding is not a move")

    def test_cut_take_uses_clean_voice(self):
        key = "take-01-camera"
        fl = t.voice_files(self.s, key)
        os.makedirs(os.path.dirname(fl["mix"]), exist_ok=True)
        # A legacy voice WAV: plain -vn, so it starts at the take's first sound.
        ff("-i", os.path.join(self.s, self.f), "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", fl["mix"])
        t.write_voice(self.s, key, {"state": "done", "on": True})
        r = self.cut([{"take": 1, "in": 0.5, "out": 1.5}, {"take": 1, "in": 2.5, "out": 3.5}])
        self.assertEqual(r["voice_source"], "clean voice")
        self.assert_sync(r["video"], [0.5, 1.5])
        # The same voice on the video clock.
        t.extract_voice(os.path.join(self.s, self.f), fl["mix"])
        t.write_voice(self.s, key, {"state": "done", "on": True, "clock": "video"})
        r = self.cut([{"take": 1, "in": 0.0, "out": 1.5}])
        self.assert_sync(r["video"], [1.0])

    def test_cut_take_screen_kind(self):
        self.add_take(1, kind="screen", flashes=(2.0,), offset=0.05)
        r = self.cut([{"take": 1, "in": 1.5, "out": 2.5, "kind": "screen", "crop": "x"}])
        self.assertEqual(r["cut"][0]["kind"], "screen")
        self.assertEqual(r["cut"][0]["crop"], "x")
        self.assertEqual(len(flash_times(r["video"])), 1)

    def test_cut_take_versions_never_overwrite(self):
        a = self.cut([{"take": 1, "in": 0.5, "out": 1.5}])
        bytes1 = open(a["video"], "rb").read()
        b = self.cut([{"take": 1, "in": 2.5, "out": 3.5}])
        self.assertTrue(b["video"].endswith("take-01-v2.mp4"))
        self.assertEqual(open(a["video"], "rb").read(), bytes1)

    def test_cut_take_concurrent_versions(self):
        got = []

        def go(x):
            got.append(t.t_cut_take({"session": self.s, "segments": [{"take": 1, "in": x, "out": x + 0.5}]}))
        th = [threading.Thread(target=go, args=(x,)) for x in (0.5, 2.5)]
        for x in th:
            x.start()
        for x in th:
            x.join()
        self.assertEqual(sorted(os.path.basename(g["video"]) for g in got), ["take-01-v1.mp4", "take-01-v2.mp4"])

    def test_cut_take_keeps_newest_5(self):
        for i in range(6):
            self.cut([{"take": 1, "in": 0.5, "out": 1.0}])
        self.assertIn(os.path.join(self.s, "_work", "take-01-v1.mp4"), self.trashed)
        self.assertFalse(any("-v2." in p for p in self.trashed))

    def test_cut_take_errors(self):
        cases = [([{"take": 1, "in": 1, "out": 9}], "is 6.0"), ([{"take": 1, "in": 2, "out": 1}], "0 <= in < out"),
                 ([{"take": 7, "in": 0, "out": 1}], "No take 7"),
                 ([{"take": 1, "in": 0, "out": 0.5}] * 201, "At most 200"),
                 ([{"take": 1, "start": 0, "end": 1}], "needs take, in and out"),
                 ([{"take": 1, "in": 0, "out": 0.03}], "shorter than 2 frames")]
        for segs, msg in cases:
            with self.assertRaises(ValueError) as e:
                t.t_cut_take({"session": self.s, "segments": segs})
            self.assertIn(msg, str(e.exception))
        with self.assertRaises(ValueError) as e:
            t.t_cut_take({"session": self.s, "take": 1, "start": 0, "end": 1})
        self.assertIn("cut_take takes segments", str(e.exception))

    def test_plain_errors_for_wrong_types(self):
        with self.assertRaises(ValueError) as e:
            t.t_cut_take({"session": self.s, "segments": [{"take": "two", "in": 1, "out": 2}]})
        self.assertEqual(str(e.exception), "Segment 1: take is a take number, e.g. 3. get_session lists the takes.")
        for bad in ("12", "2", 3):
            with self.assertRaises(ValueError) as e:
                t.t_rough_cut({"session": self.s, "takes": bad})
            self.assertEqual(str(e.exception), "takes is a list of take numbers, e.g. [3, 5].")

    def test_voice_source_names_one_take(self):
        self.add_take(2)
        key = "take-01-camera"
        fl = t.voice_files(self.s, key)
        os.makedirs(os.path.dirname(fl["mix"]), exist_ok=True)
        t.extract_voice(os.path.join(self.s, self.f), fl["mix"])
        t.write_voice(self.s, key, {"state": "done", "on": True, "clock": "video"})
        r = self.cut([{"take": 1, "in": 0.5, "out": 1.5}, {"take": 2, "in": 2.5, "out": 3.5}])
        self.assertEqual(r["voice_source"], "clean voice for take 1, take sound for the rest")

    def test_cut_take_words_in_clip_time(self):
        r = self.cut([{"take": 1, "in": 2.5, "out": 3.5}, {"take": 1, "in": 0.5, "out": 1.0}])
        d = json.load(open(r["words"]))
        self.assertEqual(d["clock"], "video")
        self.assertEqual([c["at"] for c in d["made_from"]["cut"]], [0.0, r["cut"][1]["at"]])
        self.assertEqual(d["made_from"]["session_id"], t.session_id(self.s))
        world = next(w for w in d["words"] if w["word"] == "world")
        self.assertAlmostEqual(world["start"], 2.7 - r["cut"][0]["in"], places=2)
        hello = next(w for w in d["words"] if w["word"] == "Hello")
        self.assertAlmostEqual(hello["start"], r["cut"][1]["at"] + 0.6 - r["cut"][1]["in"], places=2)

    def test_cut_take_running_shape(self):
        t.CUT_WAIT, wait = 0, t.CUT_WAIT
        try:
            os.environ["TAKES_TEST_SLEEP"] = "2"
            os.remove(os.path.join(self.s, "take-01-camera.words.json")) if os.path.exists(
                os.path.join(self.s, "take-01-camera.words.json")) else None
            r = t.t_cut_take({"session": self.s, "segments": [{"take": 1, "in": 0.5, "out": 1.5}]})
        finally:
            t.CUT_WAIT = wait
        self.assertEqual(set(r), {"status", "job", "note"})
        self.assertEqual(r["status"], "running")
        b = t.t_get_job({"id": r["job"], "session": self.s, "wait_s": 40})
        self.assertEqual(b["status"], "done", b)
        self.assertTrue(b["result"]["video"].endswith("take-01-v1.mp4"))

    def test_assets_hide_underscore_folders(self):
        self.cut([{"take": 1, "in": 0.5, "out": 1.0}])
        files = [a["file"] for a in t.t_get_session({"session": self.s})["assets"]]
        self.assertFalse([f for f in files if f.startswith("_work")], files)

    def test_rough_cut_renders_full_clip(self):
        with open(os.path.join(self.s, "script.md"), "w") as f:
            f.write("# Intro\n\nHello datacenter world. [smile]\n\nThe line nobody said.\n")
        self.words([{"word": "Hello", "start": 0.6, "end": 0.9}, {"word": "um", "start": 1.2, "end": 1.4},
                    {"word": "datacenter", "start": 2.0, "end": 2.4}, {"word": "world.", "start": 2.7, "end": 3.2}])
        r = t.t_rough_cut({"session": self.s})
        self.assertNotEqual(r.get("status"), "running", r)
        self.assertTrue(r["video"].endswith("_work/rough-v1.mp4"))
        self.assertEqual([d["why"] for d in r["dropped"] if d["why"] != "sound"], ["filler"])
        self.assertEqual([m["text"] for m in r["missing"]], ["The line nobody said."])
        self.assertIn("open_in_app", r["next"])
        saved = json.load(open(r["video"][:-4] + ".json"))
        self.assertEqual(saved["gap"], 0.25)
        self.assertEqual(saved["missing"], r["missing"])

    def test_rough_cut_honours_best_cut(self):
        t.write_cut(self.s, 1, state="done", start=1.9, end=3.3)
        r = t.t_rough_cut({"session": self.s})
        self.assertEqual(" ".join(c["text"] for c in r["cut"]), "datacenter world")

    def test_rough_cut_keeps_a_word_that_starts_before_best_cut(self):
        # Whisper starts "datacenter" at 2.0, before the range: its end is inside, so it stays, cut at its start.
        t.write_cut(self.s, 1, state="done", start=2.15, end=3.3)
        r = t.t_rough_cut({"session": self.s})
        self.assertEqual(" ".join(c["text"] for c in r["cut"]), "datacenter world")
        self.assertLessEqual(r["cut"][0]["in"], 2.0)
        self.assertGreater(r["cut"][0]["in"], 0.9)  # never into "Hello"
        out = [d for d in r["dropped"] if d["why"] == "outside best_cut"]
        self.assertEqual([d["text"] for d in out], ["Hello"])

    def test_rough_cut_running_shape(self):
        t.CUT_WAIT, wait = 0, t.CUT_WAIT
        os.environ["TAKES_TEST_SLEEP"] = "3"
        try:
            r = t.t_rough_cut({"session": self.s})
        finally:
            t.CUT_WAIT = wait
        self.assertEqual(set(r), {"status", "job", "note"})
        self.assertIn("call rough_cut again", r["note"])


def w(word, start, end, **kw):
    return dict({"word": word, "start": start, "end": end}, **kw)


def say_words(text, start=0.0, step=0.4, pause_at=()):
    """Words of text, one every step seconds, with a 1 s pause before the indexes in pause_at."""
    out, at = [], start
    for i, x in enumerate(text.split()):
        if i in pause_at:
            at += 1.0
        out.append(w(x, round(at, 3), round(at + step - 0.1, 3)))
        at += step
    return out


class PlanRough(unittest.TestCase):
    def texts(self, plan):
        return [c["text"] for c in plan["cut_list"]]

    def test_false_start_dropped(self):
        script = "Takes is free and open source. The link is in the comments."
        words = say_words("Takes is free and open source the link is the link is in the comments",
                          pause_at=(9,))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["kept_text"], "Takes is free and open source the link is in the comments")
        self.assertEqual([(d["text"], d["why"]) for d in p["dropped"]], [("the link is", "retake")])
        self.assertEqual(p["missing"], [])

    def test_a_try_split_by_a_pause_still_wins(self):
        script = "Every video I posted this month came out of an app."
        words = say_words("every single video I posted this month came every single video I posted this month "
                          "came out of an app", pause_at=(8, 9))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["kept_text"], "every single video I posted this month came out of an app")
        self.assertGreater(p["cut_list"][0]["in"], 4.0, "the first try goes whole")

    def test_a_restart_glued_to_the_end_of_a_try(self):
        script = "Every video I posted this month came out of an app."
        words = say_words("every single video I posted this month came out of every single video I posted this "
                          "month came out of an app", pause_at=(11,))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["kept_text"], "every single video I posted this month came out of an app")

    def test_last_full_try_wins_across_takes(self):
        script = "The link is in the comments."
        p = t.plan_rough({3: {"words": say_words("the link is in the comments")},
                          5: {"words": say_words("the link is in the comments")}}, script)
        self.assertEqual({c["take"] for c in p["cut_list"]}, {5})
        self.assertEqual({d["take"] for d in p["dropped"]}, {3})

    def test_words_not_said_again_stay(self):
        script = "One two three four. Five six seven eight."
        words = say_words("one two three four five six seven eight one two three four", pause_at=(8,))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["kept_text"], "one two three four five six seven eight")
        self.assertEqual(p["cut_list"][0]["text"], "one two three four")
        self.assertGreater(p["cut_list"][0]["in"], 3.0, "the second try of line one is kept")

    def test_ad_lib_retake_take_wins_whole(self):
        # Take 2 says the script again in other words, after two false starts. The clip is take 2 from its
        # last start: no orphan words of take 1, each line once, the outro at the end (2026-10-11).
        script = ("Twelve weeks. That's all it took for most AI tokens to move to open models. At Acme, "
                  "people build agents that read their inbox. Every one of those steps costs tokens. And look "
                  "at the money. Open models now run more than half the tokens. The code I ship still goes "
                  "to the best models.")
        one = say_words("Twelve weeks. That's all it took for most of AI tokens to move to open models. Pretty "
                        "insane. At Acme, people build agents that update your CRM. All of these actions cost "
                        "tokens. And look at the money. Open models now run 75 % of all tokens. And don't get "
                        "me wrong, the code I ship still goes to the frontier models.", pause_at=(17, 31, 37))
        two = say_words("Okay. So, twelve weeks is all it took for most AI tokens to move to open, open models. "
                        "Okay. So, twelve weeks is all it took for most, okay. So, twelve weeks is all it took "
                        "for most token consumption to move to open models. Insane. If you look at Acme, many "
                        "people use Acme for CRM updates. And every single step of these tasks costs tokens. "
                        "And I mean, look at the money. Open models now run 75 % of all token consumption. The "
                        "code I ship goes to frontier models. If you look at the trajectory, it's a bright "
                        "future ahead.", pause_at=(17, 28))
        p = t.plan_rough({1: {"words": one}, 2: {"words": two}}, script)
        self.assertEqual({c["take"] for c in p["cut_list"]}, {2})
        self.assertTrue(p["kept_text"].startswith("twelve weeks is all it took for most token consumption"),
                        p["kept_text"])
        self.assertTrue(p["kept_text"].endswith("If you look at the trajectory, it's a bright future ahead."),
                        p["kept_text"])
        self.assertEqual(p["kept_text"].count("look at the money"), 1)
        self.assertEqual(p["kept_text"].count("twelve weeks"), 1)

    def test_short_match_back_in_the_script_stays_in_place(self):
        script = "And look at the money. The code I ship goes to the best models."
        words = say_words("and look at the money the code I ship goes to the best models if you look at the "
                          "trajectory it is a bright future", pause_at=(5, 14))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertTrue(p["kept_text"].endswith("best models if you look at the trajectory it is a bright future"),
                        p["kept_text"])
        self.assertEqual(p["dropped"], [])

    def test_an_um_does_not_make_an_orphan(self):
        script = "Takes is free and open source."
        words = say_words("Takes is um free and open source")
        words[2]["filler"] = True
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["kept_text"], "Takes is free and open source")

    def test_a_later_try_that_stops_does_not_win(self):
        script = "Takes is free and open source. The link is in the comments."
        words = say_words("Takes is free and open source Takes is free and", pause_at=(6,))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["kept_text"], "Takes is free and open source")
        self.assertEqual([(d["text"], d["why"]) for d in p["dropped"]], [("Takes is free and", "retake")])

    def test_repeated_two_word_phrase_not_a_retake(self):
        script = "I came and the dog ran. You left and the cat sat."
        words = say_words("I came and the dog ran you left and the cat sat", pause_at=(6,))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["dropped"], [])

    def test_stutter(self):
        p = t.plan_rough({1: {"words": say_words("I I think so")}}, "I think so.")
        self.assertEqual([(d["text"], d["why"]) for d in p["dropped"]], [("I", "stutter")])
        self.assertEqual(p["kept_text"], "I think so")

    def test_fillers_and_sounds_dropped(self):
        words = [w("So", 0.0, 0.3), w("um", 0.4, 0.6, filler=True), w("yes", 0.7, 1.0)]
        p = t.plan_rough({1: {"words": words, "sounds": [[1.3, 1.5]]}}, "")
        self.assertEqual([d["why"] for d in p["dropped"]], ["filler", "sound"])
        self.assertEqual(len(p["cut_list"]), 2, "a dropped um splits the segment")
        self.assertLessEqual(p["cut_list"][0]["out"], 0.38)
        self.assertGreaterEqual(p["cut_list"][1]["in"], 0.62)

    def test_a_sign_is_a_word(self):
        p = t.plan_rough({1: {"words": [w("99", 0.0, 0.3), w("%", 0.3, 0.6), w("of", 0.6, 0.8)]}}, "99% of it.")
        self.assertEqual(p["kept_text"], "99 % of")
        self.assertEqual(p["dropped"], [])

    def test_missing_line_reported(self):
        script = "First line here now. Second line here now."
        p = t.plan_rough({1: {"words": say_words("first line here now")},
                          2: {"words": say_words("second line")}}, script)
        self.assertEqual(p["missing"], [{"text": "Second line here now.", "said_in": [2]}])

    def test_offscript_words_kept(self):
        script = "Takes is free. It is open source."
        words = say_words("Takes is free by the way it is open source", pause_at=(3, 6))
        p = t.plan_rough({1: {"words": words}}, script)
        self.assertEqual(p["kept_text"], "Takes is free by the way it is open source")

    def test_no_script_repeat_detection(self):
        words = say_words("this is the start this is the start of it", pause_at=(4,))
        p = t.plan_rough({1: {"words": words}}, "")
        self.assertEqual(p["kept_text"], "this is the start of it")
        self.assertEqual(p["dropped"][0]["why"], "retake")

    def test_gap_shortens_long_pauses(self):
        words = [w("one", 0.0, 0.3), w("two", 0.8, 1.1)]
        p = t.plan_rough({1: {"words": words}}, "", gap=0.25)
        self.assertEqual(len(p["cut_list"]), 2)
        kept = (p["cut_list"][0]["out"] - p["cut_list"][0]["in"]) + (p["cut_list"][1]["out"] - p["cut_list"][1]["in"])
        self.assertLess(kept, 1.1 - 0.15)
        p = t.plan_rough({1: {"words": words}}, "", gap=0.6)
        self.assertEqual(len(p["cut_list"]), 1)

    def test_segments_never_overlap_words(self):
        rng = random.Random(7)
        vocab = "the a link is in comments takes free open source um uh so and".split()
        for _ in range(200):
            words, at = [], rng.random()
            for i in range(rng.randint(1, 25)):
                d = rng.uniform(0.05, 0.6)
                x = rng.choice(vocab)
                words.append(w(x, round(at, 3), round(at + d, 3), **({"filler": True} if x in ("um", "uh") else {})))
                at += d + rng.choice([0.0, 0.01, 0.1, 0.3, 0.8, 1.5])
            sounds = [[round(at + 0.2, 3), round(at + 0.4, 3)]] if rng.random() < 0.5 else []
            script = " ".join(rng.choice(vocab) for _ in range(rng.randint(0, 20)))
            p = t.plan_rough({1: {"words": words, "sounds": sounds}}, script, gap=rng.choice([0.1, 0.25, 1.0]))
            for c in p["cut_list"]:
                self.assertLess(c["in"], c["out"])
                inside = [x for x in words if x["start"] >= c["in"] - 1e-6 and x["end"] <= c["out"] + 1e-6]
                for x in words:
                    if x in inside:
                        continue
                    self.assertFalse(x["start"] < c["out"] - 1e-6 and x["end"] > c["in"] + 1e-6, (c, x, words))
                for a, b in sounds:
                    self.assertFalse(a < c["out"] and b > c["in"], (c, sounds))
                self.assertEqual(" ".join(x["word"] for x in inside), c["text"])


class RangeWords(unittest.TestCase):
    def test_in_range(self):
        self.assertTrue(t.in_range(w("was", 4.7, 5.1), 5.0, 9.0))      # end inside: Whisper started it early
        self.assertTrue(t.in_range(w("stuck", 8.8, 9.1), 5.0, 9.0))    # most of it inside
        self.assertFalse(t.in_range(w("so", 8.95, 9.4), 5.0, 9.0))     # most of it after the range
        self.assertFalse(t.in_range(w("okay", 3.0, 3.4), 5.0, 9.0))

    def test_outside_words_are_dropped_with_why(self):
        words = say_words("okay so it was basically stuck")
        for x in words[:2]:
            x["outside"] = True
        p = t.plan_rough({1: {"words": words}}, "")
        self.assertEqual([c["text"] for c in p["cut_list"]], ["it was basically stuck"])
        self.assertEqual([(d["text"], d["why"]) for d in p["dropped"]], [("okay so", "outside best_cut")])


def tone_wav(path, parts, sr=16000):
    """A 16-bit mono WAV: (seconds, loud) parts; quiet parts are faint noise, loud parts a 220 Hz tone."""
    rng, x = random.Random(1), array.array("h")
    for secs, loud in parts:
        for i in range(int(secs * sr)):
            v = 0.3 * math.sin(2 * math.pi * 220 * i / sr) if loud else 0.0
            x.append(int((v + rng.uniform(-0.001, 0.001)) * 32767))
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(sr)
        f.writeframes(x.tobytes())


@unittest.skipUnless(importlib.util.find_spec("numpy"), "prepare_take.py needs numpy")
class Onsets(unittest.TestCase):
    """faster-whisper starts the first word after a pause 0.16 to 1.1 s early; prepare_take.py moves it
    to the voice onset in the WAV."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("prepare_take", os.path.join(
            os.path.dirname(__file__), "..", "prepare_take.py"))
        self.p = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.p)
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def fix(self, parts, words):
        path = os.path.join(self.tmp, "voice.wav")
        tone_wav(path, parts)
        x, sr = self.p.read_wav(path)
        v = self.p.voiced_frames(x, sr)
        return self.p.onsets(self.p.snap(words, v), v)

    def test_early_start_after_a_pause_moves_to_the_onset(self):
        # 2 s quiet, "was" 2.0-2.4, 0.05 s gap, "basically" 2.45-3.0, then quiet.
        ws = self.fix([(2.0, False), (0.4, True), (0.05, False), (0.55, True), (1.0, False)],
                      [w("was", 1.1, 2.4), w("basically", 2.46, 3.0)])
        self.assertAlmostEqual(ws[0]["start"], 2.0, delta=0.02)
        self.assertEqual(ws[1]["start"], 2.46, "no pause before it: Whisper's start stays")
        # cut_take's in-point inside the word goes just before the real onset, not into the pause.
        x, word = t.snap_point(ws, 2.1, "in")
        self.assertEqual(word, "was")
        self.assertAlmostEqual(x, ws[0]["start"] - 0.04, places=3)

    def test_a_breath_before_the_word_is_not_the_onset(self):
        # A breath at 1.0-1.2, 0.5 s quiet, the word at 1.7-2.2: Whisper starts the word at the breath.
        ws = self.fix([(1.0, False), (0.2, True), (0.5, False), (0.5, True), (0.5, False)],
                      [w("stuck", 1.0, 2.2)])
        self.assertAlmostEqual(ws[0]["start"], 1.7, delta=0.02)

    def test_start_stays_before_the_end(self):
        ws = self.fix([(1.0, False), (0.05, True), (0.5, False)], [w("a", 0.2, 1.05)])
        self.assertLessEqual(ws[0]["start"], 1.05 - self.p.WORD_MIN + 1e-9)


class OldWordsFiles(Base):
    """A v2 words file from before the onset pass gets only that pass (no Whisper), once."""

    def setUp(self):
        super().setUp()
        self.f = self.add_take()  # beeps at 1.0, 3.0 and 5.0 s of video, silence between
        self.path = os.path.join(self.s, "take-01-camera.words.json")
        c = t.take_clock(os.path.join(self.s, self.f))
        self.old = {"v": 2, "clock": "video", "source": "faster-whisper small", "audio_offset_s": c["audio_offset_s"],
                    "fps": c["fps"], "fps_mode": c["fps_mode"], "duration": c["duration"],
                    "words": [w("So", 0.4, 1.2), w("then", 2.2, 3.2)], "sounds": []}
        with open(self.path, "w") as f:
            json.dump(self.old, f)

    def test_runs_once_and_marks_the_file(self):
        doc = t.ensure_onsets(self.s, t.voice_take(self.s, 1))
        self.assertEqual(doc["onsets"], 1)
        self.assertAlmostEqual(doc["words"][0]["start"], 1.0, delta=0.03)
        self.assertAlmostEqual(doc["words"][1]["start"], 3.0, delta=0.03)
        self.assertEqual([x["end"] for x in doc["words"]], [1.2, 3.2])
        self.assertEqual(self.doc(self.f), doc)
        self.assertFalse(os.path.exists(self.path + ".tmp"))
        calls = []
        real = t.extract_voice
        t.extract_voice = lambda *a, **k: calls.append(a)
        try:
            self.assertEqual(t.ensure_onsets(self.s, t.voice_take(self.s, 1)), doc)
        finally:
            t.extract_voice = real
        self.assertEqual(calls, [], "a marked file is never read again")

    def test_no_voice_leaves_the_file(self):
        os.remove(os.path.join(self.s, self.f))
        self.assertEqual(t.ensure_onsets(self.s, t.voice_take(self.s, 1)), self.old)
        self.assertEqual(self.doc(self.f), self.old)

    def test_rough_cut_uses_the_upgraded_starts(self):
        r = t.t_rough_cut({"session": self.s})
        self.assertNotEqual(r.get("status"), "running", r)
        self.assertGreaterEqual(r["cut"][0]["in"], 0.9)
        self.assertEqual(self.doc(self.f)["onsets"], 1)

    def test_new_prepares_are_marked(self):
        os.remove(self.path)
        self.words([w("So", 0.9, 1.2)])
        self.assertEqual(t.prepare_take(self.s, 1), "done")
        self.assertEqual(self.doc(self.f)["onsets"], 1)


class Docs(unittest.TestCase):
    def test_sync_rule_in_descriptions_and_instructions(self):
        # A default with its reason, not a ban (2026-10-11): own ffmpeg is fine for what the tools cannot do.
        for name in ("get_session", "cut_take", "rough_cut"):
            d = t.BY_NAME[name][1]
            self.assertNotRegex(d, r"(?i)never[^.]*own ffmpeg", name)
        self.assertIn("by default: they fix the audio offset and frame rate", t.BY_NAME["get_session"][1])
        self.assertIn("own ffmpeg", t.BY_NAME["cut_take"][1])
        self.assertIn("first draft", t.BY_NAME["rough_cut"][1])
        self.assertIn("rough_cut's cut)", t.BY_NAME["render_edit"][1])
        self.assertNotIn("cut_list", json.dumps([x[:4] for x in t.TOOLS]))
        out = []
        real = t.reply
        t.reply = lambda id_, result=None, error=None: out.append(result)
        try:
            t.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        finally:
            t.reply = real
        text = out[0]["instructions"]
        i = text.index("Cut takes with rough_cut (a first draft: improve it freely) or cut_take by default")
        self.assertLess(i, 400)
        self.assertLess(i, text.index("clean_voice"))
        self.assertNotRegex(text, r"(?i)never[^.]*own ffmpeg")
        self.assertIn("by hand is fine too: its path comes from next_path", text)
        self.assertNotIn("Whisper word times", text)
        self.assertIn("cut_take", t.CORE_TOOLS)


if __name__ == "__main__":
    unittest.main()
