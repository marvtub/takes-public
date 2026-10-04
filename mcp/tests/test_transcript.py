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


if __name__ == "__main__":
    unittest.main()
