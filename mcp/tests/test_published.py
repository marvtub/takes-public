"""set_published: agents mark a session as live on social media, in the shape the app reads."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class SetPublished(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-09-28-test")
        os.makedirs(self.s)

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def meta(self):
        with open(os.path.join(self.s, "session.json")) as f:
            return json.load(f)

    def test_marks_and_lists(self):
        self.assertFalse(t.t_get_session({"session": self.s})["published"])
        t.t_set_published({"session": self.s})
        t.t_set_published({"session": self.s, "platform": "LinkedIn", "url": "https://l.in/p"})
        t.t_set_published({"session": self.s, "platform": "X"})
        posts = self.meta()["published"]
        self.assertEqual([p.get("platform") for p in posts], ["LinkedIn", "X"])
        self.assertRegex(posts[0]["at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")  # the app's date format
        self.assertEqual(t.t_list_sessions({"project": "Proj"})["sessions"][0]["published"], posts)
        with open(os.path.join(self.s, "SESSION.md")) as f:
            self.assertIn("Published: LinkedIn (", f.read())

    def test_unmark_one_platform_or_all(self):
        for p in ("LinkedIn", "X"):
            t.t_set_published({"session": self.s, "platform": p})
        t.t_set_published({"session": self.s, "platform": "x", "published": False})
        self.assertEqual([p["platform"] for p in self.meta()["published"]], ["LinkedIn"])
        t.t_set_published({"session": self.s, "published": False})
        self.assertNotIn("published", self.meta())
        self.assertFalse(t.t_get_session({"session": self.s})["published"])


    def test_stats_add_readings_and_keep_them(self):
        t.t_set_published({"session": self.s, "platform": "LinkedIn"})
        first_at = self.meta()["published"][0]["at"]
        t.t_set_post_stats({"session": self.s, "platform": "linkedin", "impressions": 900, "likes": 20,
                            "url": "https://www.linkedin.com/feed/update/1"})
        t.t_set_post_stats({"session": self.s, "platform": "LinkedIn", "impressions": 1500, "likes": 31})
        post = self.meta()["published"][0]
        self.assertEqual([r["impressions"] for r in post["stats"]], [900, 1500])
        self.assertEqual(post["url"], "https://www.linkedin.com/feed/update/1")
        # Marking it again keeps the date, the link and the numbers.
        t.t_set_published({"session": self.s, "platform": "LinkedIn"})
        post = self.meta()["published"][0]
        self.assertEqual((post["at"], len(post["stats"])), (first_at, 2))
        self.assertEqual(post["url"], "https://www.linkedin.com/feed/update/1")
        with self.assertRaises(ValueError):
            t.t_set_post_stats({"session": self.s, "platform": "LinkedIn"})

    def test_performance_lists_what_needs_a_reading(self):
        t.t_set_published({"session": self.s, "platform": "X"})
        t.t_set_post_stats({"session": self.s, "platform": "YouTube", "views": 40, "url": "https://youtu.be/x"})
        perf = {p["platform"]: p for p in t.t_get_performance({})["posts"]}
        self.assertTrue(perf["X"]["needs_url"])
        self.assertFalse(perf["YouTube"]["needs_reading"])
        self.assertEqual(perf["YouTube"]["latest"]["views"], 40)

    def test_performance_says_how_old_the_dashboard_is(self):
        from datetime import date
        self.assertEqual(t.social_freshness()["stale"], ["linkedin", "followers", "x"])  # no social.json yet
        os.makedirs(os.path.join(self.root, "_library"), exist_ok=True)
        with open(os.path.join(self.root, "_library", "social.json"), "w") as f:
            json.dump({"sources": {"linkedin": "2026-09-27", "followers": "2026-09-27", "x": "2026-09-19"}}, f)
        fresh = t.social_freshness(today=date(2026, 9, 29))
        self.assertEqual((fresh["linkedin"]["days_old"], fresh["x"]["days_old"]), (2, 10))
        self.assertEqual(fresh["stale"], ["x"])
        self.assertIn("refresh_social.py", fresh["refresh"])
        self.assertIn("dashboard", t.t_get_performance({}))


if __name__ == "__main__":
    unittest.main()
