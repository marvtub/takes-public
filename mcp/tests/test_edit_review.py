"""check_edit's review: Gemini (stand-in) watches the edit once per version; without a key, a frame sheet."""
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


class EditReview(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.env = {k: os.environ.pop(k, None) for k in ("TAKES_ROOT", "TAKES_NO_REVIEW", "TAKES_REVIEW_CMD")}
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-13-review")
        os.makedirs(os.path.join(self.s, "edits"))
        t.write_meta(self.s, {"title": "Review", "createdAt": "2026-10-13T00:00:00Z", "named": True, "takes": []})
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "testsrc=s=128x160:d=6:r=30", "-f", "lavfi",
                        "-i", "sine=f=220:d=6", "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                        "-y", os.path.join(self.s, "edits", "hook-v1.mp4")], check=True)
        self.calls = os.path.join(self.root, "calls")
        fake = os.path.join(self.root, "fake.py")
        with open(fake, "w") as f:
            f.write("import json, sys\nopen(%r, 'a').write('x')\nprint(json.dumps({'problems': [\n"
                    " {'start': 4.0, 'end': 5.0, 'area': 'graphics', 'what': 'Too busy.', 'sure': 'high', 'rule': ''},\n"
                    " {'start': 1.0, 'end': 2.0, 'area': 'cut', 'what': 'Long pause.', 'sure': 'medium'},\n"
                    " {'start': 40.0, 'end': 41.0, 'area': 'cut', 'what': 'Past the end.', 'sure': 'high'}]}))\n" % self.calls)
        os.environ["TAKES_REVIEW_CMD"] = json.dumps([sys.executable, fake])
        self.key, self.builtin = t.gemini_key, t.run_builtin
        # These tests are about the review: the built-in checks would only start ffmpeg (2026-10-27).
        t.run_builtin = lambda s, rel, path, given=None, as_rel=None: ([], {"src": {"path": None}, "known": False})

    def tearDown(self):
        t.gemini_key, t.run_builtin = self.key, self.builtin
        shutil.rmtree(self.root)
        for k, v in self.env.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v

    def check(self, **kw):
        return t.t_check_edit(dict({"session": self.s, "file": "edits/hook-v1.mp4"}, **kw))["review"]

    def test_review_runs_once_per_version(self):
        r = self.check()
        self.assertEqual(r["state"], "done", r)
        self.assertEqual([p["what"] for p in r["problems"]], ["Long pause.", "Too busy."])  # sorted; past the end dropped
        self.assertNotIn("rule", r["problems"][1])  # empty fields go
        self.assertEqual(self.check()["state"], "done")
        self.assertEqual(open(self.calls).read(), "x")  # cached: Gemini watched it once

    def test_failed_review_gives_the_sheet(self):
        os.environ["TAKES_REVIEW_CMD"] = json.dumps(["/usr/bin/false"])
        r = self.check()
        self.assertEqual(r["state"], "none")
        self.assertIn("failed", r["why"])
        self.assertTrue(os.path.isfile(r["sheet"]))

    def test_no_key_gives_a_frame_sheet(self):
        os.environ.pop("TAKES_REVIEW_CMD")
        t.gemini_key = lambda: None
        r = self.check()
        self.assertEqual(r["state"], "none")
        self.assertIn("no Gemini key", r["why"])
        self.assertTrue(os.path.isfile(r["sheet"]))
        self.assertEqual(len(r["times"]), 6)  # one frame a second for a 6 s edit
        self.assertFalse(os.path.exists(self.calls))
        self.assertNotIn(".checks-cache", [a["file"] for a in t.t_get_session({"session": self.s})["assets"]])

    def test_watch_false_is_off(self):
        self.assertEqual(self.check(watch=False), {"state": "off"})
        self.assertFalse(os.path.exists(self.calls))


if __name__ == "__main__":
    unittest.main()
