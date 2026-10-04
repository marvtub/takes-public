"""The X post: posts/x.md next to the LinkedIn post, threads split at '---' lines, its own history."""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class XPostTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "P", "2026-09-29-a")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "A", "createdAt": "2026-09-29T10:00:00Z", "takes": []})

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_tweets_split_at_rule_lines(self):
        self.assertEqual(t.tweets("One\n\n---\n\nTwo\n---\nThree\n"), ["One", "Two", "Three"])
        self.assertEqual(t.tweets("Just one --- inline\n"), ["Just one --- inline"])
        self.assertEqual(t.tweets(""), [])

    def test_thread_is_its_own_post(self):
        t.t_set_post({"session": self.s, "text": "LinkedIn text"})
        out = t.t_set_post({"session": self.s, "platform": "x", "tweets": ["Hook", "x" * 300], "note": "Thread"})
        self.assertEqual(out["platform"], "X")
        self.assertTrue(out["thread"])
        self.assertEqual([w["cut_in_feed"] for w in out["tweets"]], [False, True])
        self.assertTrue(os.path.exists(os.path.join(self.s, "posts", "x.md")))
        self.assertEqual(t.read_post(self.s)["text"], "LinkedIn text\n")          # untouched
        hist = os.listdir(os.path.join(self.s, "posts", "x", "history"))
        self.assertTrue(hist and all(h.endswith("-x.md") for h in hist))
        self.assertEqual(t.t_get_session({"session": self.s})["x_post"]["tweets"][0]["text"], "Hook")

    def test_variants_hooks_and_status(self):
        t.t_set_post({"session": self.s, "platform": "x", "text": "Main\n"})
        t.t_create_post_variants({"session": self.s, "platform": "x",
                                  "variants": [{"name": "Thread", "tweets": ["A", "B"]}]})
        self.assertEqual(t.post_variants(self.s, "x")[0]["text"], "A\n\n---\n\nB\n")
        self.assertEqual(t.post_variants(self.s), [])                               # LinkedIn has none
        t.t_set_post_hooks({"session": self.s, "platform": "x", "hooks": [{"text": "Hot take"}]})
        self.assertTrue(os.path.exists(os.path.join(self.s, "posts", "x", "hooks.json")))
        t.t_set_post_status({"session": self.s, "platform": "x", "status": "ready",
                             "at": "2026-10-01T09:00:00-07:00"})
        q = t.t_get_post_queue({})["posts"]
        self.assertEqual([(p["platform"], p["action"]) for p in q], [("X", "schedule on X (Typefully)")])
        with self.assertRaises(ValueError):
            t.t_set_post({"session": self.s, "platform": "x", "first_comment": "no"})


if __name__ == "__main__":
    unittest.main()
