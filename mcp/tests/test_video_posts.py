"""The video platforms: posts/youtube.md (title + description) and posts/vertical.md (one caption for
TikTok, Reels and Shorts, front matter on and title)."""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class VideoPostTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "P", "2026-10-03-a")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "A", "createdAt": "2026-10-03T10:00:00Z", "takes": []})

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_youtube_title_and_description(self):
        out = t.t_set_post({"session": self.s, "platform": "youtube", "title": "Why I record every day",
                            "text": "0:00 Intro\n1:20 The setup\n"})
        self.assertEqual(out["title"], "Why I record every day")
        self.assertFalse(out["title_over_limit"])
        fm, body = t.post_file(self.s, "youtube")
        self.assertEqual(fm["title"], "Why I record every day")
        self.assertTrue(body.startswith("0:00 Intro"))
        self.assertTrue(os.path.exists(os.path.join(self.s, "posts", "youtube.md")))

    def test_tiktok_reels_shorts_share_the_vertical_post(self):
        for name in ("tiktok", "reels", "shorts", "instagram"):
            self.assertEqual(t.platform_of({"platform": name}), "vertical")
        out = t.t_set_post({"session": self.s, "platform": "tiktok", "text": "Hook line\n#ai #video"})
        self.assertEqual(out["on"], ["tiktok", "reels", "shorts"])
        self.assertEqual(out["hashtags"], 2)
        self.assertFalse(out["hashtags_over_reels_limit"])
        self.assertNotIn("on", t.post_file(self.s, "vertical")[0])

    def test_places_and_hashtag_limit(self):
        out = t.t_set_post({"session": self.s, "platform": "vertical", "on": ["shorts", "reels"],
                            "text": "Hook " + " ".join("#t%d" % i for i in range(6))})
        self.assertEqual(out["on"], ["reels", "shorts"])
        self.assertTrue(out["hashtags_over_reels_limit"])
        self.assertEqual(t.post_file(self.s, "vertical")[0]["on"], "reels, shorts")
        with self.assertRaises(ValueError):
            t.t_set_post({"session": self.s, "platform": "vertical", "on": ["snapchat"]})
        with self.assertRaises(ValueError):
            t.t_set_post({"session": self.s, "platform": "linkedin", "text": "x", "title": "No"})

    def test_video_posts_do_not_borrow_the_linkedin_media(self):
        os.makedirs(os.path.join(self.s, "edits"))
        for f in ("wide-v1.mp4", "tall-v1.mp4"):
            open(os.path.join(self.s, "edits", f), "w").close()
        t.t_set_post({"session": self.s, "text": "LinkedIn", "media": "edits/wide-v1.mp4"})
        t.t_set_post({"session": self.s, "platform": "x", "text": "X"})
        t.t_set_post({"session": self.s, "platform": "vertical", "text": "Caption", "media": "edits/tall-v1.mp4"})
        self.assertTrue(t.read_post(self.s, "x")["media_path"].endswith("wide-v1.mp4"))
        self.assertTrue(t.read_post(self.s, "vertical")["media_path"].endswith("tall-v1.mp4"))

    def test_get_session_lists_them(self):
        t.t_set_post({"session": self.s, "platform": "youtube", "title": "T", "text": "D"})
        out = t.t_get_session({"session": self.s})
        self.assertEqual(out["youtube_post"]["title"], "T")
        self.assertIsNone(out["vertical_post"])


if __name__ == "__main__":
    unittest.main()
