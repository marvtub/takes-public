"""import_take: recordings made outside Takes become real takes (no hand-edited session.json)."""
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


def clip(path, secs=1):
    subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=%d" % secs,
                    "-y", path], check=True)


class ImportTake(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-09-27-test")
        os.makedirs(self.s)
        self.out = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root)
        shutil.rmtree(self.out)
        os.environ.pop("TAKES_ROOT", None)

    def meta(self):
        with open(os.path.join(self.s, "session.json")) as f:
            return json.load(f)

    def test_copies_outside_file_and_lists_it(self):
        src = os.path.join(self.out, "phone.mp4")
        clip(src, 2)
        r = t.t_import_take({"session": self.s, "path": src, "name": "Phone"})
        self.assertTrue(os.path.exists(src), "outside files are copied, not moved")
        take = self.meta()["takes"][0]
        self.assertEqual((take["number"], take["kind"], take["file"]), (1, "camera", "take-01-phone-camera.mp4"))
        self.assertAlmostEqual(take["duration"], 2, delta=0.2)
        self.assertTrue(os.path.exists(os.path.join(self.s, take["file"])))
        self.assertTrue(r["imported"][0]["copied"])

    def test_renames_files_already_in_session_and_numbers_in_order(self):
        a, b, scr = (os.path.join(self.s, n) for n in ("a.mov", "b.mov", "b-screen.mov"))
        for p in (a, b, scr):
            clip(p)
        t.t_import_take({"session": self.s, "takes": [{"path": a}, {"path": b, "screen_path": scr, "keeper": True}]})
        takes = self.meta()["takes"]
        self.assertEqual([(x["number"], x["kind"], x["file"]) for x in takes],
                         [(1, "camera", "take-01-camera.mov"), (2, "camera", "take-02-camera.mov"),
                          (2, "screen", "take-02-screen.mov")])
        self.assertTrue(takes[1]["keeper"])
        self.assertFalse(any(os.path.exists(p) for p in (a, b, scr)), "in-session files are renamed in place")
        # The imported takes are what get_session reports.
        listed = t.t_get_session({"session": self.s})["takes"]
        self.assertEqual({x["number"] for x in listed}, {1, 2})

    def test_rejects_non_video_and_missing(self):
        txt = os.path.join(self.out, "notes.txt")
        open(txt, "w").close()
        with self.assertRaises(ValueError):
            t.t_import_take({"session": self.s, "path": txt})
        with self.assertRaises(ValueError):
            t.t_import_take({"session": self.s, "path": os.path.join(self.out, "nope.mov")})
        self.assertFalse(os.path.exists(os.path.join(self.s, "session.json")))

    def test_rename_keeps_extension(self):
        src = os.path.join(self.out, "x.mp4")
        clip(src)
        t.t_import_take({"session": self.s, "path": src})
        t.t_rename_take({"session": self.s, "take": 1, "name": "Intro"})
        self.assertEqual(self.meta()["takes"][0]["file"], "take-01-intro-camera.mp4")


if __name__ == "__main__":
    unittest.main()
