import os
import sys
import unicodedata
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class FillersTest(unittest.TestCase):
    def test_english_and_korean_ums(self):
        for w in ["um,", "Uh.", "음", "음...", "어,", "으음"]:
            self.assertIn(t.norm_word(w), t.FILLERS, w)

    def test_decomposed_hangul_still_matches(self):
        self.assertIn(t.norm_word(unicodedata.normalize("NFD", "음")), t.FILLERS)

    def test_korean_words_that_look_like_ums_stay(self):
        for w in ["그", "저", "음식", "어디", "안녕하세요"]:
            self.assertNotIn(t.norm_word(w), t.FILLERS, w)


if __name__ == "__main__":
    unittest.main()
