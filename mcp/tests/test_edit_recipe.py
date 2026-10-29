"""Edit recipes (2026-10-11): render_edit builds a recipe into a checked render, publish_edit saves it as
the next version with its recipe, the next version starts from that recipe. Media made with ffmpeg in a
temp library; real renders run as real jobs. No network, no money."""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import takes_mcp as t  # noqa: E402

os.environ["TAKES_NO_REVIEW"] = "1"  # never let a real Gemini key watch a test edit
from test_edit_ready import FFMPEG, ff, flash_take  # noqa: E402

REAL = {n: getattr(t, n) for n in ("spawn_detached", "start_job", "trash", "take_clock", "open_in_app",
                                   "link_noclobber", "clone_file", "claimed_outputs")}


def text(path):
    with open(path) as f:
        return f.read()


def jload(path):
    with open(path) as f:
        return json.load(f)


def probe(path):
    out = subprocess.run([shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe", "-v", "error", "-show_entries",
                          "stream=codec_type,width,height,r_frame_rate:format=duration", "-of", "json", path],
                         capture_output=True, text=True).stdout
    return json.loads(out)


def lufs(path):
    err = subprocess.run([FFMPEG, "-nostats", "-i", path, "-vn", "-af", "ebur128", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    return float(re.findall(r"I:\s*(-?[\d.]+)\s*LUFS", err.rsplit("Summary:", 1)[-1])[0])


def rgb_at(path, sec):
    raw = subprocess.run([FFMPEG, "-v", "error", "-ss", "%.3f" % sec, "-i", path, "-frames:v", "1", "-vf",
                          "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    return tuple(raw[:3])


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_JOB_TIMEOUT"] = "300"
        os.environ["TAKES_HOST_ID"] = "this-mac"
        for k in ("TAKES_CHAT", "TAKES_BOARD", "CLAUDE_CODE_SESSION_ID", "TAKES_STEP_TIMEOUT"):
            os.environ.pop(k, None)
        for k, v in REAL.items():
            setattr(t, k, v)
        t.forget_seen()
        t.CLOCKS.clear()
        self.opened, self.trashed = [], []
        t.open_in_app = lambda p: self.opened.append(p)
        t.trash = lambda paths: self.trashed.extend(paths) or [os.remove(p) for p in paths]
        self.s = os.path.join(self.root, "Proj", "2026-10-11-demo")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "demo", "createdAt": "2026-10-11T00:00:00Z", "named": True, "takes": []})

    def tearDown(self):
        for k, v in REAL.items():
            setattr(t, k, v)
        for j in t.all_jobs(self.s) if os.path.isdir(self.s) else []:
            if j["status"] in ("starting", "running") and j.get("pid"):
                try:
                    os.kill(j["pid"], signal.SIGTERM)
                except OSError:
                    pass
        shutil.rmtree(self.root, ignore_errors=True)
        for k in ("TAKES_ROOT", "TAKES_JOB_TIMEOUT", "TAKES_HOST_ID", "TAKES_STEP_TIMEOUT"):
            os.environ.pop(k, None)

    def add_take(self, n=1, secs=6, kind="camera", **kw):
        f = "take-%02d-%s.mov" % (n, kind)
        flash_take(os.path.join(self.s, f), secs=secs, **kw)
        meta = t.read_meta(self.s)
        meta["takes"].append({"number": n, "kind": kind, "file": f, "startedAt": "2026-10-11T00:00:00Z",
                              "duration": secs})
        t.write_meta(self.s, meta)
        return f

    def music(self, name="Calm.wav", secs=10, f=300):
        d = os.path.join(self.root, "_library", "audio", "Music")
        os.makedirs(d, exist_ok=True)
        ff("-f", "lavfi", "-i", "sine=f=%d:d=%d" % (f, secs), "-af", "volume=0.3", os.path.join(d, name))
        return "@library/audio/Music/" + name

    def thumb(self, name="hook-v1.png", color="red", size="160x120"):
        d = os.path.join(self.s, "thumbnails")
        os.makedirs(d, exist_ok=True)
        ff("-f", "lavfi", "-i", "color=%s:s=%s" % (color, size), "-frames:v", "1", os.path.join(d, name))
        return "thumbnails/" + name

    def clip(self, rel, size="160x120", secs=1, color="blue"):
        p = os.path.join(self.s, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        ff("-f", "lavfi", "-i", "color=%s:s=%s:r=30:d=%s" % (color, size, secs), "-f", "lavfi", "-i",
           "sine=d=%s" % secs, "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", p)
        return p

    CUT = [{"take": 1, "in": 0.5, "out": 2.5}, {"take": 1, "in": 3.5, "out": 5.5}]

    def render(self, **a):
        r = t.t_render_edit(dict({"session": self.s, "wait_s": 120}, **a))
        self.assertEqual(r.get("status"), "done", r)
        return r

    def fake_render(self, name="hook", parent=None, passed=True, started=None, size="160x120", extra=None):
        """A finished render without ffmpeg's render: for publish_edit's own rules."""
        rid = t.new_job_id(self.s)
        os.makedirs(os.path.join(self.s, t.RENDERS), exist_ok=True)
        self.clip(os.path.join(t.RENDERS, rid + ".mp4"), size=size)
        res = [{"check": "streams", "pass": True}, {"check": "av_sync", "pass": passed,
                                                    **({} if passed else {"say": "The sound is late."})}]
        r = dict({"recipe": 1, "name": name, "cut": [{"take": 1, "in": 0.5, "out": 2.5, "kind": "camera"}],
                  "frame": {"shape": "source", "w": 160, "h": 120, "fps": 30}, "over": [], "music": [], "sfx": [],
                  "steps": [], "parent": parent, "by": "render_edit", "host": "this-mac", "render_id": rid,
                  "job": rid, "started": started or t.now_iso(), "checks": {"passed": passed, "results": res},
                  "inputs": {}, "commands": []}, **(extra or {}))
        t.write_json(os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT), r)
        with open(os.path.join(self.s, t.RENDERS, rid + ".words.json"), "w") as f:
            json.dump({"words": []}, f)
        return rid

    def recipe(self, rel):
        with open(os.path.join(self.s, rel)) as f:
            return json.load(f)


class Pure(Base):
    def test_merge_patch(self):
        base = {"a": {"b": 1, "c": 2}, "l": [1, 2], "x": 1}
        self.assertEqual(t.merge_patch(base, {"a": {"b": 5}, "l": [3], "x": None, "y": {"z": None}}),
                         {"a": {"b": 5, "c": 2}, "l": [3], "y": {}})

    def test_diff_names_values_a_list_replace_dropped(self):
        a = {"music": [{"file": "m", "in": 14.0, "gain_db": -18}]}
        changes = {"music": [{"file": "m", "gain_db": -21}]}
        b = t.merge_patch(a, changes)
        d = t.recipe_diff(a, b)
        self.assertEqual(d["music[0].gain_db"], [-18, -21])
        self.assertEqual(d["music[0].in"], [14.0, None])
        warn = t.unnamed_changes(d, changes)
        self.assertEqual(len(warn), 1)
        self.assertIn("music[0].in went from 14.0", warn[0])
        # An emptied list is on purpose: no warning.
        self.assertEqual(t.unnamed_changes(t.recipe_diff(a, {"music": []}), {"music": []}), [])

    def test_norm_and_fill_defaults(self):
        self.add_take()
        song = self.music()
        r = t.norm_recipe(self.s, {"name": "Hook One", "cut": self.CUT,
                                   "music": [{"file": os.path.join(self.root, "_library/audio/Music/Calm.wav")}]})
        self.assertEqual(r["name"], "hook-one")
        self.assertEqual(r["music"][0]["file"], song)  # an absolute library path is stored as @library/...
        self.assertEqual(r["music"][0]["gain_db"], -18)
        self.assertEqual(r["cut"][0]["kind"], "camera")
        t.fill_recipe(self.s, r)
        self.assertEqual(r["voice"]["source"], "take")
        self.assertEqual((r["frame"]["w"], r["frame"]["h"], r["frame"]["fps"]), (160, 120, 30))
        self.assertEqual(r["takes"][0]["file"], "take-01-camera.mov")
        self.assertIn("take-01-camera.mov", r["inputs"])
        # A clean voice that is done: the recipe uses it, keyed by number and kind, with its chain.
        key = t.voice_key(1, "camera")
        os.makedirs(os.path.join(self.s, "voice"))
        ff("-f", "lavfi", "-i", "sine=d=6", "-ac", "1", "-ar", "48000", t.voice_files(self.s, key)["mix"])
        t.write_voice(self.s, key, {"state": "done", "on": True, "strength": 0.7, "loudness": "quiet",
                                    "clock": "video", "steps": ["clearvoice"]})
        r2 = t.norm_recipe(self.s, {"name": "hook", "cut": self.CUT})
        t.fill_recipe(self.s, r2)
        self.assertEqual(r2["voice"]["source"], "clean")
        self.assertEqual(r2["voice"]["keys"][key], os.path.join("voice", key + ".wav"))
        self.assertEqual(r2["voice"]["chain"][key]["strength"], 0.7)
        self.assertEqual(t.recipe_target(r2), -18.0)  # a quiet voice aims at -18, not a fixed -14
        r2["loudness"] = -16
        self.assertEqual(t.recipe_target(r2), -16.0)

    def test_refusals(self):
        self.add_take()
        song = self.music()
        self.clip("edits/hook-v1.mp4")
        ok = {"name": "hook", "cut": self.CUT}

        def refused(rec, part):
            with self.assertRaises(ValueError) as e:
                r = t.norm_recipe(self.s, rec)
                t.check_recipe(self.s, r)
            self.assertIn(part, str(e.exception))
        refused(dict(ok, music=[{"file": "edits/hook-v1.mp4"}]), "final mix is never an input")
        self.clip("_edit/renders/job-abc123.mp4")
        self.clip("_edit/hook/.versions/v1/mix.mp4")
        refused(dict(ok, music=[{"file": "_edit/renders/job-abc123.mp4"}]), "final mix is never an input")
        refused(dict(ok, sfx=[{"file": "_edit/hook/.versions/v1/mix.mp4", "at": 0}]), "final mix is never an input")
        refused(dict(ok, loudness="loud"), "loudness is a number in LUFS, e.g. -14.")
        refused(dict(ok, music=[{"file": song}, {"file": song, "at": 3}]), "One song at a time")
        refused(dict(ok, sfx=[{"file": "gone.wav", "at": 1}]), "gone.wav is gone")
        refused(dict(ok, steps=[{"run": ["true"], "cwd": "edits"}]), "must be inside _edit/hook/")
        refused(dict(ok, steps=[{"run": "npx hyperframes render"}]), "not a shell line")
        refused(dict(ok, steps=[{"run": ["x"], "makes": ["../../evil.mov"]}]), "must be inside")
        refused(dict(ok, cut=[{"take": 1, "in": 2, "out": 60}]), "Give 0 <= in < out")
        outside = os.path.join(tempfile.gettempdir(), "takes-outside-%d.wav" % os.getpid())
        ff("-f", "lavfi", "-i", "sine=d=1", outside)
        try:
            refused(dict(ok, sfx=[{"file": outside, "at": 1}]), "Copy it into the session or the library first")
        finally:
            os.remove(outside)
        refused({"cut": self.CUT}, "Give name")
        # Music entries that follow each other are fine.
        r = t.norm_recipe(self.s, dict(ok, music=[{"file": song, "out": 3}, {"file": song, "at": 3}]))
        t.check_recipe(self.s, r)

    def test_take_gone_and_disk_full(self):
        self.add_take()
        os.remove(os.path.join(self.s, "take-01-camera.mov"))
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT}})
        self.assertIn("take-01-camera.mov is gone. Pick another take in cut.", str(e.exception))
        self.add_take(2)
        real = shutil.disk_usage
        t.shutil.disk_usage = lambda p: real(p)._replace(free=1000)
        try:
            with self.assertRaises(ValueError) as e:
                t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": [{"take": 2, "in": 0, "out": 2}]}})
        finally:
            t.shutil.disk_usage = real
        self.assertRegex(str(e.exception), r"Not enough free disk: this render needs about \d+ [MG]B, 1 MB is free\.")

    def test_render_plan_is_pure_and_the_voice_goes_in_once(self):
        self.add_take()
        song = self.music()
        cover = self.thumb()
        self.clip("_edit/hook/layer.mov")
        r = t.norm_recipe(self.s, {"name": "hook", "cut": self.CUT, "music": [{"file": song}], "cover": {"image": cover},
                                   "over": [{"file": "_edit/hook/layer.mov", "at": 1, "out": 1, "alpha": True}],
                                   "sfx": [{"file": song, "at": 3.5, "gain_db": -12}]})
        t.fill_recipe(self.s, r)
        meas = {"length": 4.0, "music": {song: -20.0}, "voice": -18.0, "gain": 1.5}
        listed = sorted(os.listdir(self.s))
        a = t.render_plan(self.s, r, "TMP", "OUT.mp4", meas)
        b = t.render_plan(self.s, r, "TMP", "OUT.mp4", meas)
        self.assertEqual(a, b)
        self.assertEqual(sorted(os.listdir(self.s)), listed)  # it writes nothing
        sound = " ".join(a["sound"])
        voice = sound.split("-filter_complex", 1)[1].split(";")[0]
        for f in ("acompressor", "afftdn", "highpass", "loudnorm", "equalizer"):
            self.assertNotIn(f, sound)
        self.assertIn("adelay=100", voice)  # the cover's 0.1 s before the voice
        self.assertIn("sidechaincompress", sound)
        self.assertIn("volume=-12.00dB", sound)  # the song to -14 LUFS once (+6), then its gain_db (-18)
        picture = a["picture"]
        self.assertEqual(" ".join(picture).count("libx264") + " ".join(a["mux"]).count("libx264"), 1)
        self.assertIn("-an", picture)
        self.assertIn("copy", a["mux"])
        self.assertIn("[cv][cb]concat", " ".join(picture))
        self.assertIn("overlay=enable='between(t,1.100,2.100)'", " ".join(picture))
        self.assertIn("volume=1.50dB", " ".join(a["mux"]))
        self.assertAlmostEqual(a["total"], 4.1)

    def test_a_quiet_mix_says_why(self):
        r = {"name": "hook", "mix": {"target": -14.0, "lufs": -20.9}, "voice": {"source": "take"},
             "checks": {"results": []}}
        v = t.render_view(self.s, "job-1", r)
        self.assertEqual(v["warnings"], ["The edit is at -20.9 LUFS, not -14: its loudest peaks hold it down (Takes adds "
                                         "no limiter). Clean the voice with clean_voice, then render again."])
        r["mix"]["lufs"] = -14.2
        self.assertNotIn("warnings", t.render_view(self.s, "job-1", r))

    def test_final_gain_never_passes_true_peak(self):
        self.assertEqual(t.final_gain(-14, -20, -10), 6.0)
        self.assertEqual(t.final_gain(-14, -20, -5), 4.0)
        self.assertEqual(t.final_gain(-14, float("-inf"), float("-inf")), 0.0)


class Bases(Base):
    def setUp(self):
        super().setUp()
        self.add_take()

    def published(self, name, n, recipe=True, made=None):
        rel = os.path.join("edits", "%s-v%d.mp4" % (name, n))
        self.clip(rel)
        if recipe:
            r = t.norm_recipe(self.s, {"name": name, "cut": self.CUT})
            t.fill_recipe(self.s, r)
            r.update(edit=rel, made=made or t.now_iso(), note="v%d" % n, host="this-mac",
                     parent=os.path.join("edits", "%s-v%d.mp4" % (name, n - 1)) if n > 1 else None)
            t.write_json(os.path.join(self.s, t.recipe_path(rel)), r)
        return rel

    def test_old_base_refused_unless_go_back(self):
        self.published("hook", 4)
        self.published("hook", 6)
        with self.assertRaises(ValueError) as e:
            t.pick_base(self.s, {"base": "hook-v4"})
        self.assertEqual(str(e.exception), "hook-v4 is old: hook-v6 is the newest. Use base=hook to build on hook-v6, "
                                           "or add go_back=true to build on hook-v4 on purpose.")
        base, warns = t.pick_base(self.s, {"base": "hook-v4", "go_back": True})
        self.assertEqual(base["edit"], "edits/hook-v4.mp4")
        self.assertEqual(t.pick_base(self.s, {"base": "hook"})[0]["edit"], "edits/hook-v6.mp4")

    def test_newest_without_recipe_warns(self):
        self.published("hook", 4)
        self.published("hook", 5, recipe=False)
        base, warns = t.pick_base(self.s, {"base": "hook"})
        self.assertEqual(base["edit"], "edits/hook-v4.mp4")
        self.assertEqual(warns, ["hook-v5 has no recipe: its changes are not in this base."])

    def test_two_names_need_base(self):
        self.published("hook", 1)
        self.published("hook-vertical", 1)
        with self.assertRaises(ValueError) as e:
            t.pick_base(self.s, {})
        self.assertEqual(str(e.exception), "This session has 2 edits: hook, hook-vertical. Say which one with base=<name>.")

    def test_steps_from_another_mac_do_not_run(self):
        rel = self.published("hook", 1)
        r = self.recipe(t.recipe_path(rel))
        r.update(host="other-mac", steps=[{"run": ["true"], "cwd": "_edit/hook", "makes": []}])
        t.write_json(os.path.join(self.s, t.recipe_path(rel)), r)
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "base": "hook", "changes": {"cover": None}})
        self.assertEqual(str(e.exception), "hook-v1 came from another Mac. Its steps did not run. Pass steps again to run them.")

    def stub_start(self):
        started = []
        t.start_job = lambda s, cmd, outputs, label, estimate_s=None, job_id=None: started.append(job_id) or {"id": job_id}
        return started

    def test_a_base_with_a_gone_file_takes_changes_that_replace_it(self):
        old, cover = self.music("Old.wav"), self.thumb()
        rel = self.published("hook", 1)
        r = self.recipe(t.recipe_path(rel))
        r.update(t.norm_recipe(self.s, dict(t.agent_part(r), music=[{"file": old}], cover=cover)))
        t.write_json(os.path.join(self.s, t.recipe_path(rel)), r)
        os.remove(t.lib_path(old))
        os.remove(os.path.join(self.s, cover))
        started = self.stub_start()
        # Only the merged recipe must be whole: what the changes replace may be gone.
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "base": "hook", "changes": {"cover": None}})
        self.assertEqual(str(e.exception), "Old.wav is gone. Pick another file for music[0].")
        out = t.t_render_edit({"session": self.s, "base": "hook",
                               "changes": {"music": [{"file": self.music("New.wav")}], "cover": None}})
        self.assertEqual(out["status"], "running")
        self.assertEqual(out["changed"]["music[0].file"], ["@library/audio/Music/Old.wav", "@library/audio/Music/New.wav"])
        self.add_take(2)
        os.remove(os.path.join(self.s, "take-01-camera.mov"))
        out = t.t_render_edit({"session": self.s, "base": "hook", "changes": {
            "music": None, "cover": None, "cut": [{"take": 2, "in": 0.5, "out": 2.5}]}})
        self.assertEqual(len(started), 2)

    def test_one_render_of_a_name_at_a_time(self):
        rid = t.new_job_id(self.s)
        os.makedirs(os.path.join(self.s, t.RENDERS))
        t.write_json(os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT), {"name": "hook"})
        t.claimed_outputs = lambda s: {os.path.join(t.RENDERS, rid + ".mp4"): rid}
        started = self.stub_start()
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT}})
        self.assertEqual(str(e.exception), "A render of hook runs now (%s). Wait for it with get_job id=%s wait_s=50, "
                                           "or stop it with stop_job id=%s. Then call render_edit again." % (rid, rid, rid))
        self.assertEqual(started, [])
        t.t_render_edit({"session": self.s, "recipe": {"name": "hook-tall", "cut": self.CUT}})
        self.assertEqual(len(started), 1)

    def test_a_crop_larger_than_the_take_is_refused(self):
        self.stub_start()
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT, "frame": {
                "shape": "9:16", "crop": {"x": 100, "y": 0, "w": 900, "h": 900}}}})
        self.assertEqual(str(e.exception), "frame.crop is larger than the take (160x120). Give x+w <= 160, y+h <= 120.")

    def test_a_lost_render_says_render_again(self):
        rid = t.new_job_id(self.s)
        b = t.job_brief(self.s, {"id": rid, "status": "lost", "outputs": [os.path.join(t.RENDERS, rid + ".mp4")]})
        self.assertEqual(b["next"], "The render stopped (the Mac restarted or the job quit). Call render_edit again "
                                    "with the same base and changes.")

    def test_broken_recipe_is_never_rewritten(self):
        rel = self.published("hook", 1)
        p = os.path.join(self.s, t.recipe_path(rel))
        with open(p, "w") as f:
            f.write("{not json")
        with self.assertRaises(ValueError) as e:
            t.t_get_edit_recipe({"session": self.s, "edit": "hook-v1"})
        self.assertIn("cannot read edits/hook-v1.recipe.json", str(e.exception))
        with self.assertRaises(ValueError):
            t.t_render_edit({"session": self.s, "base": "hook-v1", "changes": {}})
        self.assertEqual(text(p), "{not json")

    def test_get_edit_recipe_lineage_stops_at_a_missing_parent(self):
        self.published("hook", 2)
        self.published("hook", 3)
        out = t.t_get_edit_recipe({"session": self.s, "edit": "hook"})
        self.assertEqual(out["recipe"]["edit"], "edits/hook-v3.mp4")
        self.assertEqual([x["edit"] for x in out["lineage"]], ["edits/hook-v2.mp4"])
        self.assertEqual(out["missing"], ["edits/hook-v1.mp4"])
        self.assertEqual(t.t_get_edit_recipe({"session": self.s, "edit": "hook-v2"})["newer"], ["edits/hook-v3.mp4"])

    def test_get_session_shows_the_recipe_and_hides_its_files(self):
        self.clip("edits/old-v1.mp4")
        g = t.t_get_session({"session": self.s})
        self.assertIsNone(g["edit_recipe"])
        self.assertIn("No recipe yet", g["edit_recipe_note"])
        self.published("hook", 1)
        self.clip("_edit/hook/layer.mov")
        g = t.t_get_session({"session": self.s})
        short = g["edit_recipe"]
        self.assertEqual(short["edit"], "edits/hook-v1.mp4")
        self.assertEqual(short["cut"], "2 parts")
        self.assertEqual(short["full"], "get_edit_recipe edit=hook-v1")
        self.assertEqual(g["edit_log"][0]["note"], "v1")
        files = [x["file"] for x in g["assets"]]
        self.assertNotIn("edits/hook-v1.recipe.json", files)
        self.assertFalse(any(f.startswith("_edit") for f in files))
        self.assertEqual(g["warnings"], [])

    def test_a_new_clean_voice_warns(self):
        rel = self.published("hook", 1)
        base = self.recipe(t.recipe_path(rel))
        key = t.voice_key(1, "camera")
        base["voice"] = {"source": "clean", "keys": {key: "voice/%s.wav" % key},
                         "chain": {key: {"steps": [], "strength": 1.0, "loudness": "normal"}}}
        os.makedirs(os.path.join(self.s, "voice"))
        ff("-f", "lavfi", "-i", "sine=d=6", "-ac", "1", "-ar", "48000", t.voice_files(self.s, key)["mix"])
        t.write_voice(self.s, key, {"state": "done", "on": True, "strength": 0.5, "loudness": "normal", "steps": []})
        r = t.norm_recipe(self.s, t.agent_part(base))
        warns = t.fill_recipe(self.s, r, base)
        self.assertEqual(warns, ["The clean voice changed since hook-v1 (new strength). This version uses the new one."])

    def test_next_path_counts_a_claim(self):
        self.published("hook", 2)
        t.write_json(os.path.join(self.s, "edits", "hook-v3.recipe.json"), {"name": "hook", "render_id": "job-x"})
        self.assertEqual(t.t_next_path({"kind": "edit", "name": "hook", "session": self.s})["version"], 4)


class Publish(Base):
    def setUp(self):
        super().setUp()
        self.add_take()

    def test_publish_writes_version_recipe_words_and_moves_the_check(self):
        rid = self.fake_render()
        t.save_check(self.s, os.path.join(t.RENDERS, rid + ".mp4"), {"v": 2, "mtime": 0, "results": []})
        os.makedirs(os.path.join(self.s, "_edit", "hook", "node_modules"))
        with open(os.path.join(self.s, "_edit", "hook", "index.html"), "w") as f:
            f.write("<html>")
        with open(os.path.join(self.s, "_edit", "hook", "node_modules", "x.js"), "w") as f:
            f.write("x")
        before = time.time()
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "First cut."})
        self.assertEqual(out["edit"], "edits/hook-v1.mp4")
        r = self.recipe("edits/hook-v1.recipe.json")
        self.assertEqual((r["note"], r["edit"], r["render_id"], r["fixed"], r["accepted"]),
                         ("First cut.", "edits/hook-v1.mp4", rid, [], []))
        self.assertTrue(os.path.exists(os.path.join(self.s, "edits/hook-v1.words.json")))
        self.assertFalse(os.path.exists(os.path.join(self.s, t.RENDERS, rid + ".mp4")))
        self.assertGreaterEqual(os.path.getmtime(os.path.join(self.s, "edits/hook-v1.mp4")), before - 1)
        checks = jload(os.path.join(self.s, "checks.json"))
        self.assertIn("edits/hook-v1.mp4", checks)
        self.assertNotIn(os.path.join(t.RENDERS, rid + ".mp4"), checks)
        self.assertEqual(r["src"], "_edit/hook/.versions/v1")
        self.assertTrue(os.path.exists(os.path.join(self.s, "_edit/hook/.versions/v1/index.html")))
        self.assertFalse(os.path.exists(os.path.join(self.s, "_edit/hook/.versions/v1/node_modules")))
        self.assertEqual(self.opened, [os.path.join(self.s, "edits/hook-v1.mp4")])
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "Again."})
        self.assertEqual(str(e.exception), "This render is saved already as edits/hook-v1.mp4.")

    def test_note_rules(self):
        rid = self.fake_render()
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x" * 61})
        self.assertEqual(str(e.exception), "note is too long: at most 60 characters.")
        with self.assertRaises(ValueError):
            t.t_publish_edit({"session": self.s, "render": rid, "note": " "})

    def test_failed_check_refuses_and_accept_saves(self):
        rid = self.fake_render(passed=False)
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertIn("1 check fails on the render: av_sync (The sound is late.)", str(e.exception))
        self.assertIn("Nothing was saved.", str(e.exception))
        self.assertFalse(os.path.isdir(os.path.join(self.s, "edits")) and os.listdir(os.path.join(self.s, "edits")))
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x",
                                "accept": [{"rule": "av_sync", "why": "On purpose."}]})
        self.assertEqual(out["checks"]["accepted"], ["av_sync (The sound is late.)"])
        self.assertEqual(self.recipe("edits/hook-v1.recipe.json")["accepted"], [{"rule": "av_sync", "why": "On purpose."}])

    def test_accept_by_rule_id(self):
        rid = self.fake_render()
        p = os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT)
        r = jload(p)
        r["checks"]["results"].append({"rule": "sound-4", "pass": False, "say": "Pause."})
        t.write_json(p, r)
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x",
                                "accept": [{"rule": "sound-4", "why": "The pause is on purpose."}]})
        self.assertTrue(out["checks"]["passed"])

    def test_a_version_saved_during_the_render_refuses(self):
        rid = self.fake_render(started="2020-01-01T00:00:00Z")
        self.clip("edits/hook-v1.mp4")
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertEqual(str(e.exception), "hook-v1 was saved while this render ran, and its changes are not in it. "
                                           "Render again with base=hook.")
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["edit"], "edits/hook-v2.mp4")

    def test_two_publishes_at_once_take_two_versions(self):
        a, b = self.fake_render(), self.fake_render()
        got, errs = [], []

        def go(rid):
            try:
                got.append(t.t_publish_edit({"session": self.s, "render": rid, "note": rid, "go_back": True})["edit"])
            except Exception as e:
                errs.append(e)
        th = [threading.Thread(target=go, args=(x,)) for x in (a, b)]
        [x.start() for x in th]
        [x.join() for x in th]
        self.assertEqual(errs, [])
        self.assertEqual(sorted(got), ["edits/hook-v1.mp4", "edits/hook-v2.mp4"])

    def test_the_same_render_published_twice_at_once_saves_once(self):
        rid = self.fake_render()
        got, errs = [], []

        def slow(src, dst):
            time.sleep(0.3)
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = slow

        def go():
            try:
                got.append(t.t_publish_edit({"session": self.s, "render": rid, "note": "Twice."})["edit"])
            except ValueError as e:
                errs.append(str(e))
        th = [threading.Thread(target=go) for _ in range(2)]
        [x.start() for x in th]
        [x.join() for x in th]
        self.assertEqual(got, ["edits/hook-v1.mp4"])
        self.assertEqual(errs, ["This render is saved already as edits/hook-v1.mp4."])
        self.assertEqual(sorted(os.listdir(os.path.join(self.s, "edits"))),
                         ["hook-v1.mp4", "hook-v1.recipe.json", "hook-v1.words.json"])

    def test_a_render_gone_during_the_move_leaves_no_claim(self):
        rid = self.fake_render()

        def gone(src, dst):
            os.remove(src)
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = gone
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertIn("The render %s is gone." % rid, str(e.exception))
        self.assertEqual(os.listdir(os.path.join(self.s, "edits")), [])

    def test_a_crash_between_claim_and_move_finishes_on_the_second_call(self):
        rid = self.fake_render()
        calls = []

        def boom(src, dst):
            calls.append(dst)
            if len(calls) == 1:
                raise OSError("crash")
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = boom
        with self.assertRaises(OSError):
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertTrue(os.path.exists(os.path.join(self.s, "edits/hook-v1.recipe.json")))
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertEqual(out["edit"], "edits/hook-v1.mp4")
        self.assertEqual(sorted(os.listdir(os.path.join(self.s, "edits"))),
                         ["hook-v1.mp4", "hook-v1.recipe.json", "hook-v1.words.json"])

    def test_another_writer_between_claim_and_move_keeps_its_file(self):
        rid = self.fake_render()

        def race(src, dst):
            if dst.endswith("hook-v1.mp4") and not os.path.exists(dst):
                with open(dst, "w") as f:  # the app's Cover got there first
                    f.write("app")
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = race
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["edit"], "edits/hook-v2.mp4")
        self.assertEqual(text(os.path.join(self.s, "edits/hook-v1.mp4")), "app")
        self.assertFalse(os.path.exists(os.path.join(self.s, "edits/hook-v1.recipe.json")))
        self.assertTrue(os.path.exists(os.path.join(self.s, "edits/hook-v2.recipe.json")))

    def test_link_falls_back_to_a_copy_and_never_overwrites(self):
        src = os.path.join(self.root, "a.bin")
        with open(src, "w") as f:
            f.write("a")
        dst = os.path.join(self.root, "b.bin")
        real = os.link
        t.os.link = lambda a, b: (_ for _ in ()).throw(OSError(18, "cross-device"))
        try:
            t.link_noclobber(src, dst)
        finally:
            t.os.link = real
        self.assertEqual(text(dst), "a")
        self.assertFalse(os.path.exists(src))
        with open(src, "w") as f:
            f.write("c")
        with self.assertRaises(FileExistsError):
            t.link_noclobber(src, dst)
        self.assertEqual(text(dst), "a")

    def test_freeze_skips_and_falls_back(self):
        d = os.path.join(self.s, "_edit", "hook")
        os.makedirs(os.path.join(d, ".cache"))
        with open(os.path.join(d, "a.txt"), "w") as f:
            f.write("a")
        with open(os.path.join(d, "big.mov"), "w") as f:
            f.write("b")
        t.clone_file = lambda a, b: False
        real = t.FREEZE_MAX
        t.FREEZE_MAX = 0
        try:
            src, skipped = t.freeze_sources(self.s, "hook", 1)
        finally:
            t.FREEZE_MAX = real
        self.assertEqual(src, "_edit/hook/.versions/v1")
        self.assertEqual(sorted(skipped), ["_edit/hook/a.txt", "_edit/hook/big.mov"])
        t.freeze_sources(self.s, "hook", 2)
        self.assertTrue(os.path.exists(os.path.join(d, ".versions/v2/a.txt")))
        self.assertFalse(os.path.exists(os.path.join(d, ".versions/v2/.versions")))

    def test_posts_follow_the_edit_and_a_starred_post_stays(self):
        self.clip("edits/hook-v1.mp4")
        self.clip("edits/hook-vertical-v1.mp4", size="90x160")
        os.utime(os.path.join(self.s, "edits/hook-vertical-v1.mp4"), (time.time() - 100,) * 2)
        os.utime(os.path.join(self.s, "edits/hook-v1.mp4"), (time.time() - 50,) * 2)
        cover = self.thumb()
        t.write_post_file(self.s, {}, "LinkedIn text\n", "linkedin")
        t.write_post_file(self.s, {"media": "edits/hook-v1.mp4"}, "X text\n", "x")  # starred by the user
        t.write_post_file(self.s, {"media": "edits/hook-vertical-v1.mp4", "media_by": "takes",
                                   "cover_from": "edits/a.mp4", "cover_video": "edits/b.mp4"}, "Tall\n", "vertical")
        t.write_post_file(self.s, {"media": "edits/hook-v1.mp4", "media_by": "takes", "cover_from": "edits/hook-v0.mp4",
                                   "cover_video": "edits/hook-v1.mp4", "cover": "thumbnails/old.png"}, "Wide\n", "youtube")
        rid = self.fake_render(size="160x90", extra={"cover": {"image": cover, "seconds": 0.1}})
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["edit"], "edits/hook-v2.mp4")
        self.assertEqual(out["posts"]["linkedin"], "edits/hook-v2.mp4")
        self.assertEqual(out["posts"]["x"], "edits/hook-v1.mp4 (kept: The user picked it)")
        self.assertEqual(out["posts"]["vertical"], "edits/hook-vertical-v1.mp4 (kept: other shape)")
        self.assertEqual(out["posts"]["youtube"], "edits/hook-v2.mp4")
        li, _ = t.post_file(self.s, "linkedin")
        self.assertEqual((li["media"], li["media_by"], li["cover"]), ("edits/hook-v2.mp4", "takes", cover))
        x, text = t.post_file(self.s, "x")
        self.assertEqual((x["media"], x.get("media_by"), text), ("edits/hook-v1.mp4", None, "X text\n"))
        yt, _ = t.post_file(self.s, "youtube")
        self.assertEqual((yt["media"], yt["cover"], yt.get("cover_from"), yt.get("cover_video")),
                         ("edits/hook-v2.mp4", cover, None, None))
        v, _ = t.post_file(self.s, "vertical")
        self.assertEqual(v["media"], "edits/hook-vertical-v1.mp4")

    def test_a_post_without_pick_on_another_edit_stays_on_it(self):
        self.clip("edits/intro-v1.mp4")
        t.write_post_file(self.s, {}, "LinkedIn\n", "linkedin")
        rid = self.fake_render()
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertEqual(out["posts"]["linkedin"], "edits/intro-v1.mp4 (kept: another edit)")
        self.assertEqual(t.post_file(self.s, "linkedin")[0]["media"], "edits/intro-v1.mp4")

    def test_a_vertical_post_without_pick_follows_its_tall_edit(self):
        self.clip("edits/short-v1.mp4", size="90x160")
        os.utime(os.path.join(self.s, "edits/short-v1.mp4"), (time.time() - 100,) * 2)
        self.clip("edits/wide-v1.mp4")
        t.write_post_file(self.s, {}, "Tall\n", "vertical")
        rid = self.fake_render(name="short", size="90x160")
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["posts"]["vertical"], "edits/short-v2.mp4")

    def test_x_follows_a_linkedin_star(self):
        self.clip("edits/hook-v1.mp4")
        t.write_post_file(self.s, {"media": "edits/hook-v1.mp4"}, "LinkedIn\n", "linkedin")
        t.write_post_file(self.s, {}, "X\n", "x")
        rid = self.fake_render()
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["posts"]["x"], "edits/hook-v1.mp4 (kept: The user picked it)")
        self.assertIsNone(t.post_file(self.s, "x")[0].get("media"))

    def test_a_post_cover_missing_from_the_recipe_warns(self):
        self.thumb()
        t.write_post_file(self.s, {"cover": "thumbnails/hook-v1.png"}, "LinkedIn\n", "linkedin")
        r = t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": [{"take": 1, "in": 0.5, "out": 1.5}]}})
        self.assertIn("The LinkedIn post has a cover, and this version has none. Add cover to the recipe to keep it.",
                      r["warnings"])
        t.t_get_job({"id": r["job"], "wait_s": 50})

    def test_set_post_marks_its_pick(self):
        self.clip("edits/hook-v1.mp4")
        t.t_set_post({"session": self.s, "text": "Hi", "media": "edits/hook-v1.mp4"})
        self.assertEqual(t.post_file(self.s)[0]["media_by"], "takes")
        t.t_set_post({"session": self.s, "text": "Hi again"})
        self.assertEqual(t.post_file(self.s)[0]["media_by"], "takes")

    def test_replies_resolve_with_the_new_version(self):
        self.clip("edits/hook-v1.mp4")
        t.write_comments(self.s, {"comments": [
            {"id": "c1", "file": "edits/hook-v1.mp4", "text": "Too loud", "start": 1.0, "status": "open"},
            {"id": "c2", "file": "edits/hook-v1.mp4", "text": "Cut this", "start": 2.0, "status": "open"}]})
        rid = self.fake_render()
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True,
                              "replies": [{"id": "c1", "text": "Softer."}]})
        self.assertIn("Give each reply a lesson (c1)", str(e.exception))
        self.assertFalse(os.path.exists(os.path.join(self.s, "edits/hook-v2.mp4")))
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "Music softer.", "go_back": True,
                                "replies": [{"id": "c1", "text": "Softer.", "lesson": "one-off"},
                                            {"id": "c2", "text": "Cut.", "lesson": "one-off"}]})
        self.assertEqual(out["replied"], ["c1", "c2"])
        self.assertEqual(out["open_comments"], 0)
        cs = {c["id"]: c for c in t.read_comments(self.s)["comments"]}
        self.assertEqual(cs["c1"]["status"], "resolved")
        self.assertEqual(cs["c1"]["replies"][-1]["file"], "edits/hook-v2.mp4")
        self.assertEqual(self.recipe("edits/hook-v2.recipe.json")["fixed"], ["c1", "c2"])

    def test_old_renders_go_to_the_trash(self):
        old, kept, busy = self.fake_render(), self.fake_render(), self.fake_render()
        week = time.time() - 8 * 86400
        for rid in (old, kept, busy):
            os.utime(os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT), (week, week))
        os.makedirs(os.path.join(self.s, "edits"))
        t.write_json(os.path.join(self.s, "edits", "hook-v1.recipe.json"), {"render_id": kept})
        real = t.claimed_outputs
        t.claimed_outputs = lambda s: {os.path.join(t.RENDERS, busy + ".mp4"): busy}
        try:
            t.sweep_renders(self.s)
        finally:
            t.claimed_outputs = real
        gone = {os.path.basename(p) for p in self.trashed}
        self.assertIn(old + ".mp4", gone)
        self.assertIn(old + t.RECIPE_EXT, gone)
        self.assertFalse(any(kept in g or busy in g for g in gone))

    def test_a_stopped_render_frees_its_parts_at_once(self):
        d = os.path.join(self.s, t.RENDERS)
        for rid in ("job-dead01", "job-live01"):
            os.makedirs(os.path.join(d, rid + ".tmp"))
            with open(os.path.join(d, rid + ".tmp", "cut.mov"), "w") as f:
                f.write("prores")
            with open(os.path.join(d, rid + ".mp4.part"), "w") as f:
                f.write("part")
        t.claimed_outputs = lambda s: {os.path.join(t.RENDERS, "job-live01.mp4"): "job-live01"}
        t.sweep_renders(self.s)
        left = sorted(os.listdir(d))
        self.assertNotIn("job-dead01.tmp", left)
        self.assertNotIn("job-dead01.mp4.part", left)
        self.assertIn("job-live01.tmp", left)
        self.assertIn("job-live01.mp4.part", left)


class Render(Base):
    """Real renders, as jobs."""

    def test_render_publish_and_next_version(self):
        self.add_take()
        song = self.music()
        cover = self.thumb()
        r = self.render(recipe={"name": "hook", "cut": self.CUT, "music": [{"file": song}], "cover": {"image": cover}})
        rel = r["render"]
        self.assertFalse(os.path.exists(os.path.join(self.s, t.RENDERS, r["job"] + ".tmp")))
        p = probe(os.path.join(self.s, rel))
        kinds = sorted(x["codec_type"] for x in p["streams"])
        self.assertEqual(kinds, ["audio", "video"])
        v = next(x for x in p["streams"] if x["codec_type"] == "video")
        self.assertEqual((v["width"], v["height"], v["r_frame_rate"]), (160, 120, "30/1"))
        self.assertAlmostEqual(float(p["format"]["duration"]), 4.1, delta=0.04)
        self.assertLess(abs(lufs(os.path.join(self.s, rel)) - (-14.0)), 1.0)
        red = rgb_at(os.path.join(self.s, rel), 0.0)
        self.assertGreater(red[0], 180)
        self.assertLess(red[2], 80)
        job = jload(os.path.join(self.s, ".jobs", r["job"] + ".json"))
        self.assertEqual(job["label"], "New version of hook")
        self.assertEqual(job["stage"], t.RENDER_DONE)
        # get_job and check_edit know a render.
        b = t.t_get_job({"id": r["job"]})
        self.assertIn("publish_edit render=%s" % r["job"], b["next"])
        self.assertEqual(b["result"]["render"], r["render"])
        c = t.t_check_edit({"session": self.s, "file": r["render"]})
        self.assertEqual(c["file"], r["render"])
        out = t.t_publish_edit({"session": self.s, "render": r["job"], "note": "First cut.",
                                "accept": [{"rule": x.split(" ")[0], "why": "Music under the voice."}
                                           for x in r["checks"].get("failed", [])]})
        v1 = self.recipe("edits/hook-v1.recipe.json")
        for k in ("takes", "cut", "voice", "style", "music", "sfx", "cover", "checks", "fixed", "commands", "parent",
                  "frame", "over", "inputs", "note"):
            self.assertIn(k, v1)
        self.assertEqual(v1["music"][0]["file"], song)
        self.assertEqual(v1["takes"][0]["take"], 1)
        self.assertTrue(any("libx264" in c for c in v1["commands"]))
        # The next version: change one value; only that value and Takes' own fields differ.
        entry = dict(v1["music"][0], gain_db=-21)
        r2 = self.render(base="hook", changes={"music": [entry]})
        self.assertEqual(r2["changed"], {"music[0].gain_db": [-18, -21]})
        self.assertEqual(r2["warnings"], [])
        t.t_publish_edit({"session": self.s, "render": r2["job"], "note": "Music softer.",
                          "accept": [{"rule": x.split(" ")[0], "why": "Music."} for x in r2["checks"].get("failed", [])]})
        v2 = self.recipe("edits/hook-v2.recipe.json")
        self.assertEqual(v2["parent"], "edits/hook-v1.mp4")
        allowed = {"music[0].gain_db", "parent", "edit", "made", "note", "render_id", "src", "fixed", "accepted",
                   "started", "rendered", "commands", "checks", "inputs", "mix"}
        diff = {k if k.startswith("music") else re.split(r"[.\[]", k)[0] for k in t.recipe_diff(v1, v2)}
        self.assertTrue(diff <= allowed, diff - allowed)
        # Same recipe, same inputs: same commands (job paths aside) and the same loudness.
        norm = lambda cs, rid: [[x.replace(rid, "JOB") for x in c] for c in cs]  # noqa: E731
        r3 = self.render(base="hook", changes={"music": [dict(entry)]})
        r3r = self.recipe(os.path.join(t.RENDERS, r3["job"] + t.RECIPE_EXT))
        self.assertEqual(norm(r3r["commands"], r3["job"]), norm(v2["commands"], v2["render_id"]))
        self.assertAlmostEqual(lufs(os.path.join(self.s, r3["render"])), lufs(os.path.join(self.s, "edits/hook-v2.mp4")),
                               delta=0.1)
        # A take renamed after v1 still resolves by number and kind.
        os.rename(os.path.join(self.s, "take-01-camera.mov"), os.path.join(self.s, "take-01-intro-camera.mov"))
        meta = t.read_meta(self.s)
        meta["takes"][0]["file"] = "take-01-intro-camera.mov"
        t.write_meta(self.s, meta)
        r4 = self.render(base="hook", changes={"cover": None, "music": []})
        self.assertAlmostEqual(r4["length_s"], 4.0, delta=0.04)

    def test_steps_and_an_alpha_layer(self):
        self.add_take()
        step = [FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "color=green@0.0:s=160x120:r=30:d=4,format=rgba,"
                "drawbox=x=0:y=0:w=80:h=120:color=green:t=fill", "-c:v", "qtrle", "graphics.mov"]
        r = self.render(recipe={"name": "hook", "cut": self.CUT, "steps": [{"run": step, "makes": ["graphics.mov"]}],
                                "over": [{"file": "_edit/hook/graphics.mov", "at": 0, "alpha": True}]})
        self.assertEqual(r["runs"], [step])
        out = os.path.join(self.s, r["render"])
        self.assertGreater(rgb_at(out, 0.5)[1], 40)  # the green half covers the take's black picture
        self.assertTrue(os.path.exists(os.path.join(self.s, "_edit/hook/words.json")))

    def test_a_session_renamed_during_the_render(self):
        self.add_take()
        sid = t.session_id(self.s)
        r = t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT, "steps": [
            {"run": [sys.executable, "-c", "import time; time.sleep(2)"]}]}})
        new = self.s + "-renamed"
        os.rename(self.s, new)
        t.record_move(self.s, new)
        self.s = new
        b = t.t_get_job({"id": r["job"], "wait_s": 50})
        while b["status"] in ("starting", "running"):
            b = t.t_get_job({"id": r["job"], "wait_s": 50})
        self.assertEqual(b["status"], "done", b)
        out = t.t_publish_edit({"session": sid, "render": r["job"], "note": "x",
                                "accept": [{"rule": x.split(" ")[0], "why": "test"} for x in b["result"]["checks"].get("failed", [])]})
        self.assertTrue(os.path.exists(os.path.join(new, out["edit"])))

    def test_a_failed_step_stops_with_a_plain_reason(self):
        self.add_take()
        r = t.t_render_edit({"session": self.s, "wait_s": 120, "recipe": {
            "name": "hook", "cut": self.CUT, "steps": [{"run": [sys.executable, "-c", "raise SystemExit(3)"]}]}})
        self.assertEqual(r["status"], "failed")
        self.assertEqual(r["error"], "Stopped: the graphics step failed. Nothing was saved. Ask Takes in the chat to "
                                     "try again.")
        self.assertFalse(os.path.exists(os.path.join(self.s, r["render"])))
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": r["job"], "note": "x"})
        self.assertIn("did not finish", str(e.exception))

    def test_a_step_that_hangs_is_stopped(self):
        self.add_take()
        os.environ["TAKES_STEP_TIMEOUT"] = "1"
        r = t.t_render_edit({"session": self.s, "wait_s": 120, "recipe": {
            "name": "hook", "cut": self.CUT, "steps": [{"run": [sys.executable, "-c", "import time; time.sleep(30)"]}]}})
        self.assertEqual(r["status"], "failed")
        self.assertIn("Stopped: the graphics step took more than 1 s.", r["error"])


if __name__ == "__main__":
    unittest.main()
