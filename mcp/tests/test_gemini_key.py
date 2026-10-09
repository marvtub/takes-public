"""gemini_key: the environment first, then ~/.claude/.env, where GEMINI_API_KEY (Settings › Gemini) wins."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

NAMES = ("GEMINI_API_KEY", "GOOGLE_AI_API_KEY", "GOOGLE_API_KEY")


class GeminiKey(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.pop(k, None) for k in NAMES + ("HOME",)}
        os.environ["HOME"] = tempfile.mkdtemp()
        os.makedirs(os.path.join(os.environ["HOME"], ".claude"))

    def tearDown(self):
        for k, v in self.saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v

    def env(self, text):
        open(os.path.join(os.environ["HOME"], ".claude", ".env"), "w").write(text)

    def test_the_saved_key_wins_over_an_older_one(self):
        self.env("GOOGLE_AI_API_KEY=old\nexport GEMINI_API_KEY=\"new\"\n")
        self.assertEqual(t.gemini_key(), "new")

    def test_older_name_still_works(self):
        self.env("GOOGLE_AI_API_KEY='g'\n")
        self.assertEqual(t.gemini_key(), "g")

    def test_environment_first_and_none_without_a_key(self):
        self.env("")
        self.assertIsNone(t.gemini_key())
        os.environ["GOOGLE_API_KEY"] = "e"
        self.assertEqual(t.gemini_key(), "e")


if __name__ == "__main__":
    unittest.main()
