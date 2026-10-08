import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class TranscriptWordsTests(unittest.TestCase):
    def words(self, data):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "v1.words.json"), "w") as f:
            json.dump(data, f)
        return t.transcript_words(os.path.join(d, "v1.mp4"))

    def test_whisper_objects(self):
        self.assertEqual(self.words({"words": [{"word": " So", "start": 0.03, "end": 0.11}]}), [(0.03, 0.11, "So")])

    def test_compact_lists(self):
        # Edit scripts write [word, start, end]; this used to stop get_comments with
        # "'list' object has no attribute 'get'".
        self.assertEqual(self.words([["So", 0.03, 0.11], ["it", 0.2, 0.3]]), [(0.03, 0.11, "So"), (0.2, 0.3, "it")])
        self.assertEqual(self.words({"words": [["So", 0.03, 0.11]]}), [(0.03, 0.11, "So")])

    def test_bad_words_are_skipped(self):
        self.assertEqual(self.words([["So"], "x", None, {"word": "ok", "start": "a"}, ["yes", 1, 2]]), [(1.0, 2.0, "yes")])


class TakeTranscriptTests(unittest.TestCase):
    """The app writes <take>.words.json; get_session shows it, rename and trash keep it with the take."""

    def setUp(self):
        import shutil
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-08-test")
        os.makedirs(self.s)
        takes = [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "startedAt": "2026-10-08T10:00:00Z"},
                 {"number": 1, "kind": "screen", "file": "take-01-screen.mov", "startedAt": "2026-10-08T10:00:00Z"},
                 {"number": 2, "kind": "camera", "file": "take-02-camera.mov", "startedAt": "2026-10-08T10:01:00Z"}]
        with open(os.path.join(self.s, "session.json"), "w") as f:
            json.dump({"title": "test", "createdAt": "2026-10-08T10:00:00Z", "takes": takes}, f)
        for x in takes:
            open(os.path.join(self.s, x["file"]), "w").close()
        with open(os.path.join(self.s, "take-01-camera.words.json"), "w") as f:
            json.dump({"words": [{"word": "Hello", "start": 0.1, "end": 0.4}, {"word": "there", "start": 0.4, "end": 0.7}],
                       "source": "apple en_US"}, f)
        self.addCleanup(shutil.rmtree, self.root)
        self.addCleanup(os.environ.pop, "TAKES_ROOT", None)

    def test_get_session_says_what_each_take_says(self):
        takes = t.t_get_session({"session": self.s})["takes"]
        cam1 = next(x for x in takes if x["number"] == 1 and x["kind"] == "camera")
        scr1 = next(x for x in takes if x["kind"] == "screen")
        cam2 = next(x for x in takes if x["number"] == 2)
        self.assertEqual(cam1["said"], "Hello there")
        self.assertTrue(cam1["transcript"].endswith("take-01-camera.words.json"))
        self.assertNotIn("said", scr1)  # the camera file speaks for the take
        self.assertIsNone(cam2["said"])

    def test_rename_moves_the_transcript(self):
        t.t_rename_take({"session": self.s, "take": "1", "name": "Hook"})
        self.assertTrue(os.path.exists(os.path.join(self.s, "take-01-hook-camera.words.json")))
        self.assertFalse(os.path.exists(os.path.join(self.s, "take-01-camera.words.json")))


if __name__ == "__main__":
    unittest.main()
