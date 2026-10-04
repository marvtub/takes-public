"""save_broll: a session's video goes into the b-roll library, described (stand-in model) and tagged."""
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
FAKE = r'''
import json, sys
print(json.dumps({"name": "drone city at dusk", "summary": "A drone shot over a city at dusk.", "shots": [{"start": 0, "end": 2, "what": "city"}],
                  "tags": ["drone", "city"], "setting": "city", "people": "none", "camera": "drone",
                  "mood": "calm", "best_uses": ["scale"], "best_moments": [{"start": 0, "end": 2, "why": "wide"}]}))
'''


class SaveBroll(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-02-broll")
        os.makedirs(self.s)
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x96:d=2", "-y",
                        os.path.join(self.s, "take-01-camera.mov")], check=True)
        t.write_meta(self.s, {"title": "B-roll", "createdAt": "2026-10-02T00:00:00Z", "named": True,
                              "takes": [{"number": 1, "kind": "camera", "file": "take-01-camera.mov",
                                         "startedAt": "2026-10-02T00:00:00Z", "duration": 2}]})
        fake = os.path.join(self.root, "fake.py")
        open(fake, "w").write(FAKE)
        os.environ["TAKES_DESCRIBE_CMD"] = json.dumps([sys.executable, fake])

    def tearDown(self):
        shutil.rmtree(self.root)
        for k in ("TAKES_ROOT", "TAKES_DESCRIBE_CMD"):
            os.environ.pop(k, None)

    def test_save_describe_rename_and_list(self):
        src = os.path.join(self.s, "take-01-camera.mov")
        saved = t.save_broll(src, "5 Outdoor", describe=False)
        self.assertTrue(os.path.basename(saved).endswith("take-01-camera (V).mov"))
        self.assertTrue(os.path.exists(src))  # the take stays
        final = t.broll_describe(saved, rename=True)
        self.assertTrue(final.endswith(" Drone City At (V).mov"), final)
        self.assertFalse(os.path.exists(saved))
        c = t.t_list_broll({"query": "drone"})["clips"]
        self.assertEqual(len(c), 1)
        self.assertEqual((c[0]["title"], c[0]["folder"], c[0]["orientation"]), ("Drone City At", "Outdoor", "vertical"))
        self.assertIn("A drone shot over a city at dusk.", c[0]["description"])
        self.assertEqual(c[0]["keywords"], "drone, city")

    def test_named_keeps_its_name(self):
        saved = t.save_broll(os.path.join(self.s, "take-01-camera.mov"), "Outdoor", "Snow Walk", describe=False)
        self.assertTrue(saved.endswith(" Snow Walk (V).mov"))
        self.assertEqual(t.broll_describe(saved), saved)
        again = t.save_broll(os.path.join(self.s, "take-01-camera.mov"), "Outdoor", "Snow Walk", describe=False)
        self.assertTrue(again.endswith(" Snow Walk 2 (V).mov"))

    def test_outside_file_refused(self):
        with self.assertRaises(ValueError):
            t.t_save_broll({"session": self.s, "file": "../../x.mov", "folder": "Outdoor"})


if __name__ == "__main__":
    unittest.main()
