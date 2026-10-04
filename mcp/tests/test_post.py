"""set_post: the LinkedIn post for a session's video, in the shape the app reads."""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class SetPost(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-09-28-test")
        os.makedirs(os.path.join(self.s, "edits"))
        open(os.path.join(self.s, "edits", "cut-v2.mp4"), "w").close()

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def history(self):
        d = os.path.join(self.s, "posts", "history")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def test_writes_and_reads(self):
        self.assertIsNone(t.t_get_session({"session": self.s})["post"])
        out = t.t_set_post({"session": self.s, "text": "Hook line.\n\nBody."})
        with open(os.path.join(self.s, "posts", "linkedin.md")) as f:
            self.assertEqual(f.read(), "Hook line.\n\nBody.\n")  # no front matter without media
        self.assertEqual(out["chars"], len("Hook line.\n\nBody."))
        post = t.t_get_session({"session": self.s})["post"]
        self.assertEqual(post["text"], "Hook line.\n\nBody.\n")
        self.assertIsNone(post["media"])

    def test_media_is_kept_and_checked(self):
        t.t_set_post({"session": self.s, "text": "A", "media": os.path.join(self.s, "edits", "cut-v2.mp4")})
        t.t_set_post({"session": self.s, "text": "B"})
        post = t.t_get_session({"session": self.s})["post"]
        self.assertEqual((post["text"], post["media"]), ("B\n", "edits/cut-v2.mp4"))
        with self.assertRaises(ValueError):
            t.t_set_post({"session": self.s, "text": "C", "media": "edits/nope.mp4"})

    def test_users_text_is_kept_in_history(self):
        t.t_set_post({"session": self.s, "text": "Claude one"})
        with open(os.path.join(self.s, "posts", "linkedin.md"), "w") as f:
            f.write("The user edit\n")   # the app saves his edits straight to the file
        t.t_set_post({"session": self.s, "text": "Claude two"})
        texts = []
        for n in self.history():
            with open(os.path.join(self.s, "posts", "history", n)) as f:
                texts.append(t.parse_fm(f.read())[1])
        self.assertEqual(texts, ["Claude one\n", "The user edit\n", "Claude two\n"])

    def test_not_an_asset_and_comments_name_it(self):
        t.t_set_post({"session": self.s, "text": "Hi"})
        files = [a["file"] for a in t.t_get_session({"session": self.s})["assets"]]
        self.assertNotIn("posts/linkedin.md", files)
        view = t.comment_view(self.s, {"id": "c1", "file": "posts/linkedin.md", "text": "shorter"})
        self.assertEqual(view["when"], "whole text")


    def write(self, fm):
        with open(os.path.join(self.s, "posts", "linkedin.md"), "w") as f:
            f.write(t.render_fm(list(fm.items()), "Post text\n"))

    def test_queue_and_actions(self):
        t.t_set_post({"session": self.s, "text": "Post text"})
        self.assertEqual(t.t_get_post_queue({})["posts"], [])          # a draft is not in the queue
        self.assertEqual(t.t_get_post_queue({"drafts": True})["posts"][0]["status"], "draft")
        self.write({"status": "ready"})
        q = t.t_get_post_queue({})["posts"]
        self.assertEqual((q[0]["session"], q[0]["action"]), ("Proj/2026-09-28-test", "ready, no time yet: ask the user when, or schedule it and pass at"))
        self.write({"status": "ready", "at": "2026-10-01T09:00:00-07:00", "tz": "America/Los_Angeles"})
        post = t.t_get_post_queue({})["posts"][0]
        self.assertEqual(post["action"], "schedule on LinkedIn")
        self.assertEqual(post["at"]["utc"], "2026-10-01T16:00:00Z")
        self.assertIn("09:00 AM PDT (America/Los_Angeles)", post["at"]["local"])
        self.assertEqual(post["media_path"], os.path.join(self.s, "edits", "cut-v2.mp4"))  # newest edit

        done = t.t_set_post_status({"session": self.s, "status": "scheduled"})
        self.assertEqual(done["action"], "scheduled, nothing to do")
        self.write(dict(t.post_file(self.s)[0], at="2026-10-01T18:00:00+02:00"))  # same moment, other zone
        self.assertEqual(t.read_post(self.s)["action"], "scheduled, nothing to do")
        self.write(dict(t.post_file(self.s)[0], at="2026-10-02T09:00:00-07:00"))
        self.assertIn("move the scheduled post", t.read_post(self.s)["action"])
        t.t_set_post_status({"session": self.s, "status": "scheduled"})
        t.t_set_post({"session": self.s, "text": "New text"})              # keeps status and time
        post = t.read_post(self.s)
        self.assertEqual(post["status"], "scheduled")
        self.assertIn("replace its text", post["action"])

    def test_scheduled_takes_the_time_claude_picked(self):
        t.t_set_post({"session": self.s, "text": "Post text"})
        with self.assertRaises(ValueError):
            t.t_set_post_status({"session": self.s, "status": "scheduled"})     # no time anywhere
        post = t.t_set_post_status({"session": self.s, "status": "scheduled",
                                    "at": "2026-09-29T09:32:00-07:00", "tz": "America/Los_Angeles"})
        fm = t.post_file(self.s)[0]
        self.assertEqual((fm["at"], fm["tz"], fm["scheduled_at"]),
                         ("2026-09-29T09:32:00-07:00", "America/Los_Angeles", "2026-09-29T09:32:00-07:00"))
        self.assertEqual(post["action"], "scheduled, nothing to do")
        # A time in another zone is stored in the post's zone.
        t.t_set_post_status({"session": self.s, "status": "scheduled", "at": "2026-09-29T18:32:00+02:00"})
        self.assertEqual(t.post_file(self.s)[0]["at"], "2026-09-29T09:32:00-07:00")

    def test_posted_marks_the_session_published(self):
        t.t_set_post({"session": self.s, "text": "Post text"})
        t.t_set_post_status({"session": self.s, "status": "posted", "url": "https://l.in/p"})
        self.assertEqual(t.read_post(self.s)["url"], "https://l.in/p")
        self.assertEqual(t.t_get_session({"session": self.s})["published"][0]["platform"], "LinkedIn")
        self.assertEqual(len(t.t_get_post_queue({"posted": True})["posts"]), 1)


    def test_variants_hooks_and_history(self):
        with self.assertRaises(ValueError):
            t.t_create_post_variants({"session": self.s, "variants": [{"name": "A", "text": "x"}]})
        t.t_set_post({"session": self.s, "text": "Main hook.\n\nBody."})
        made = t.t_create_post_variants({"session": self.s, "variants": [
            {"name": "Story first", "text": "Story.", "note": "narrative"}]})["created_variants"]
        self.assertEqual(made, ["story-first"])
        t.t_set_post({"session": self.s, "variant": "story-first", "text": "Story, tighter."})
        post = t.t_get_session({"session": self.s})["post"]
        self.assertEqual([(v["variant"], v["text"]) for v in post["variants"]], [("story-first", "Story, tighter.\n")])
        self.assertEqual(post["text"], "Main hook.\n\nBody.\n")        # variants never touch the main post

        hooks = t.t_set_post_hooks({"session": self.s, "hooks": [{"text": "Main hook."}, "Other hook."]})["hooks"]
        self.assertEqual([h["id"] for h in hooks], ["h1", "h2"])
        self.assertEqual(t.t_get_session({"session": self.s})["post"]["hook_in_post"], "h1")

        drafts = [v["draft"] for v in t.t_post_history({"session": self.s})["versions"]]
        self.assertEqual(drafts, ["story-first", "story-first", "main"])
        t.t_use_post_variant({"session": self.s, "variant": "story-first"})
        post = t.read_post(self.s)
        self.assertEqual(post["text"], "Story, tighter.\n")
        self.assertEqual(t.post_variants(self.s), [])
        old = next(v for v in t.t_post_history({"session": self.s})["versions"]
                   if v["draft"] == "main" and v["preview"].startswith("Main hook"))
        self.assertEqual(t.t_post_history({"session": self.s, "version": old["version"]})["text"], "Main hook.\n\nBody.\n")
        t.t_restore_post_version({"session": self.s, "version": old["version"]})
        self.assertEqual(t.read_post(self.s)["text"], "Main hook.\n\nBody.\n")

    def test_restore_keeps_the_plan(self):
        t.t_set_post({"session": self.s, "text": "One"})
        v = t.t_post_history({"session": self.s})["versions"][0]["version"]
        self.write({"status": "ready", "at": "2026-10-01T09:00:00-07:00"})
        t.t_restore_post_version({"session": self.s, "version": v})
        post = t.read_post(self.s)
        self.assertEqual((post["text"], post["status"]), ("One\n", "ready"))


if __name__ == "__main__":
    unittest.main()


class FirstComment(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-09-28-test")
        os.makedirs(self.s)

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_set_read_and_post_it_once_live(self):
        t.t_set_post({"session": self.s, "text": "Hook.", "first_comment": "Links: example.com"})
        with open(os.path.join(self.s, "posts", "first-comment.md")) as f:
            self.assertEqual(f.read(), "Links: example.com\n")
        post = t.t_get_session({"session": self.s})["post"]
        self.assertEqual(post["first_comment"], "Links: example.com")
        # Text-only change keeps it.
        t.t_set_post({"session": self.s, "text": "Hook 2."})
        self.assertEqual(t.read_post(self.s)["first_comment"], "Links: example.com")
        # Live: the queue lists it without posted=true until the comment is on.
        t.t_set_post_status({"session": self.s, "status": "posted", "url": "https://linkedin.com/x"})
        q = t.t_get_post_queue({})["posts"]
        self.assertEqual(len(q), 1)
        self.assertIn("first comment", q[0]["action"])
        t.t_set_post_status({"session": self.s, "status": "posted", "first_comment_posted": True})
        self.assertEqual(t.t_get_post_queue({})["posts"], [])
        self.assertEqual(t.read_post(self.s)["action"], "posted")
        # Empty string removes it.
        t.t_set_post({"session": self.s, "first_comment": ""})
        self.assertIsNone(t.read_post(self.s)["first_comment"])
