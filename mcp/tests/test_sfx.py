"""sfx: sound effects placed on a video at a second (session.json "sfx", same shape as the app)."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class Sfx(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-09-30-x")
        os.makedirs(os.path.join(self.s, "edits"))
        with open(os.path.join(self.s, "session.json"), "w") as f:
            json.dump({"title": "X", "createdAt": "2026-09-30T10:00:00Z", "takes": []}, f)
        for p in ("edits/a-v1.mp4", "take-01-camera.mov"):
            open(os.path.join(self.s, p), "w").close()
        os.makedirs(os.path.join(t.audio_dir(), "SFX"))
        open(os.path.join(t.audio_dir(), "SFX", "1_Whoosh.mp3"), "w").close()

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_set_replaces_one_video_and_get_session_shows_paths(self):
        t.t_set_sfx({"session": self.s, "video": "take-01-camera.mov", "cues": [{"file": "SFX/1_Whoosh.mp3", "at": 3}]})
        t.t_set_sfx({"session": self.s, "video": os.path.join(self.s, "edits/a-v1.mp4"),
                     "cues": [{"file": "SFX/1_Whoosh.mp3", "at": 9.5, "volume": 0.5},
                              {"file": "SFX/1_Whoosh.mp3", "at": 1.25}]})
        sfx = t.t_get_session({"session": self.s})["sfx"]
        self.assertEqual([(c["video"], c["at"]) for c in sfx],
                         [("edits/a-v1.mp4", 1.25), ("edits/a-v1.mp4", 9.5), ("take-01-camera.mov", 3.0)])
        self.assertEqual(sfx[0]["title"], "Whoosh")
        self.assertEqual(sfx[1]["volume"], 0.5)
        self.assertTrue(sfx[2]["video_path"].endswith("take-01-camera.mov"))
        t.t_set_sfx({"session": self.s, "video": "edits/a-v1.mp4", "cues": []})
        self.assertEqual(len(t.t_get_session({"session": self.s})["sfx"]), 1)

    def test_rejects_unknown_sound_or_video(self):
        with self.assertRaises(ValueError):
            t.t_set_sfx({"session": self.s, "video": "take-01-camera.mov", "cues": [{"file": "SFX/nope.mp3", "at": 1}]})
        with self.assertRaises(ValueError):
            t.t_set_sfx({"session": self.s, "video": "edits/none.mp4", "cues": []})


if __name__ == "__main__":
    unittest.main()
