"""Clean voice: the runner writes clean, dry and the mix; settings remix; get_session shows the file."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FFPROBE = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"

# Stands in for clean_voice.py: "clean" is the input at full level, "dry" (--steps) at half.
FAKE = r'''
import json, subprocess, sys
src, out = sys.argv[1], sys.argv[2]
dry = "--steps" in sys.argv
subprocess.run([%r, "-v", "error", "-y", "-i", src, "-vn", "-ac", "1", "-ar", "48000",
                "-af", "volume=%%s" %% ("0.5" if dry else "1"), "-c:a", "pcm_f32le", out], check=True)
json.dump({"steps": ["clearvoice"], "diagnosis": {"echo_tail_db": -16.9, "snr_db": 26.5, "clipped_runs": 0},
           "echo_after_db": -27.0}, open(out[:-4] + ".report.json", "w"))
''' % FFMPEG


def volume(path):
    out = subprocess.run([FFMPEG, "-i", path, "-af", "volumedetect", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    return float(out.split("mean_volume:")[1].split("dB")[0])


class Voice(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-09-29-voice")
        os.makedirs(self.s)
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "sine=f=220:d=2", "-f", "lavfi",
                        "-i", "color=c=black:s=64x64:d=2", "-shortest", "-y",
                        os.path.join(self.s, "take-01-camera.mov")], check=True)
        t.write_meta(self.s, {"title": "Voice", "createdAt": "2026-09-29T00:00:00Z", "named": True,
                              "takes": [{"number": 1, "kind": "camera", "file": "take-01-camera.mov",
                                         "startedAt": "2026-09-29T00:00:00Z", "duration": 2}]})
        fake = os.path.join(self.root, "fake.py")
        open(fake, "w").write(FAKE)
        os.environ["TAKES_VOICE_CMD"] = json.dumps([sys.executable, fake])
        self.f = t.voice_files(self.s, "take-01-camera")

    def tearDown(self):
        shutil.rmtree(self.root)
        for k in ("TAKES_ROOT", "TAKES_VOICE_CMD"):
            os.environ.pop(k, None)

    def test_run_mix_and_settings(self):
        t.voice_run(self.s, "1", "camera")
        v = t.read_voice(self.s, "take-01-camera")
        self.assertEqual(v["state"], "done", v.get("error"))
        self.assertEqual(v["steps"], ["clearvoice"])
        for k in ("clean", "dry", "mix"):
            self.assertTrue(os.path.exists(self.f[k]), k)
        take = t.t_get_session({"session": self.s})["takes"][0]
        self.assertEqual(take["voice"]["file"], self.f["mix"])
        self.assertEqual(take["voice"]["echo_after_db"], -27.0)
        self.assertNotIn("voice", [a["folder"] for a in t.t_get_session({"session": self.s})["assets"]])

        full = volume(self.f["mix"])
        t.t_clean_voice({"session": self.s, "take": 1, "strength": 0})
        self.assertAlmostEqual(volume(self.f["mix"]), full - 6.0, delta=0.3)  # all dry = half level
        t.t_clean_voice({"session": self.s, "take": 1, "strength": 1, "loudness": "quiet"})
        self.assertAlmostEqual(volume(self.f["mix"]), full - 4.0, delta=0.3)

        r = t.t_clean_voice({"session": self.s, "take": 1, "on": False})
        self.assertFalse(os.path.exists(self.f["mix"]))
        self.assertNotIn("file", r)
        self.assertTrue(os.path.exists(self.f["clean"]), "switching off keeps the cleaned audio")
        r = t.t_clean_voice({"session": self.s, "take": 1, "on": True})
        self.assertEqual(r["file"], self.f["mix"])

    def test_first_call_starts_in_background(self):
        r = t.t_clean_voice({"session": self.s, "take": 1, "strength": 0.7})
        self.assertEqual(r["state"], "running")
        self.assertIn("note", r)
        for _ in range(100):
            if t.read_voice(self.s, "take-01-camera")["state"] != "running":
                break
            subprocess.run(["sleep", "0.1"])
        v = t.read_voice(self.s, "take-01-camera")
        self.assertEqual(v["state"], "done", v.get("error"))
        self.assertEqual(v["strength"], 0.7)

    def test_failure_is_reported(self):
        os.environ["TAKES_VOICE_CMD"] = json.dumps([sys.executable, "-c", "import sys; sys.exit('no model')"])
        t.voice_run(self.s, "1", "camera")
        v = t.read_voice(self.s, "take-01-camera")
        self.assertEqual(v["state"], "failed")
        self.assertIn("no model", v["error"])

    def test_dead_runner_counts_as_failed(self):
        t.write_voice(self.s, "take-01-camera", {"state": "running", "pid": 999999})
        self.assertEqual(t.read_voice(self.s, "take-01-camera")["state"], "failed")

    def test_bad_take(self):
        with self.assertRaises(ValueError):
            t.t_clean_voice({"session": self.s, "take": 7})


    def test_script_ships_with_the_server(self):
        # The public copy has no skill folder: the script next to takes_mcp.py must be there.
        here = os.path.dirname(os.path.abspath(t.__file__))
        self.assertTrue(os.path.exists(os.path.join(here, "clean_voice.py")))
        old = os.environ.pop("TAKES_VOICE_SCRIPT", None)
        try:
            self.assertTrue(os.path.exists(t.voice_script()))
        finally:
            if old is not None:
                os.environ["TAKES_VOICE_SCRIPT"] = old


if __name__ == "__main__":
    unittest.main()
