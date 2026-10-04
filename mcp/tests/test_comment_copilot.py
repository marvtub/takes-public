"""Comment copilot: agents add LinkedIn comment drafts, the app records the user's decisions."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

# A stand-in for the anti-slop linter: it refuses "fascinating".
LINT = """import sys
text = sys.stdin.read()
if "fascinating" in text.lower():
    print("  \\u274c Hard-ban words")
    print("    Line 1: fascinating")
    sys.exit(1)
"""


class CommentCopilot(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.life = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_LIFE"] = self.life
        lint = os.path.join(self.root, "lint.py")
        with open(lint, "w") as f:
            f.write(LINT)
        os.environ["TAKES_LINT"] = lint
        ref = os.path.join(self.life, "reference-docs", "communication", "linkedin")
        os.makedirs(ref)
        with open(os.path.join(ref, "commenting-targets.md"), "w") as f:
            f.write("# Targets\n| [Jane](https://linkedin.com/in/jane-doe/) |\n")

    def tearDown(self):
        shutil.rmtree(self.root)
        shutil.rmtree(self.life)
        for k in ("TAKES_ROOT", "TAKES_LIFE", "TAKES_LINT"):
            os.environ.pop(k, None)

    V = ["ngl the naming part is the hard bit", "What did you name the first one?", "We tried this with 40 agents. Names broke first."]

    def add(self, url="https://www.linkedin.com/feed/update/urn:li:activity:1/", variants=None, **kw):
        a = {"post_url": url, "author": "Jane Doe", "post_text": "AI post", "angle": "His own story",
             "variants": variants or self.V}
        a.update(kw)
        return t.t_add_comment_suggestion(a)

    def file(self, sid):
        with open(os.path.join(self.root, "_library", "comments", "suggestions", sid + ".json")) as f:
            return json.load(f)

    def test_add_writes_the_app_format(self):
        sid = self.add(comments=12, posted="3h", headline="Founder")["id"]
        s = self.file(sid)
        self.assertEqual(s["status"], "review")
        self.assertEqual(s["post"]["comments"], 12)
        self.assertEqual(s["drafts"][0]["by"], "agent")
        self.assertEqual(s["drafts"][0]["variants"], self.V)
        self.assertEqual(s["drafts"][0]["text"], self.V[0])
        self.assertRegex(s["created"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")  # the app's date format

    def test_post_keeps_its_line_breaks(self):
        sid = self.add(post_text="  Hook line.  \r\n\nSecond paragraph.\n\n\n\n- one\n- two  \n")["id"]
        self.assertEqual(self.file(sid)["post"]["text"], "Hook line.\n\nSecond paragraph.\n\n- one\n- two")

    def test_slop_gate_refuses(self):
        with self.assertRaisesRegex(ValueError, "Variant 2: The slop gate"):
            self.add(variants=[self.V[0], "This is fascinating.", self.V[2]])
        self.assertEqual(t.t_list_comment_suggestions({})["suggestions"], [])

    def test_needs_three_different_variants(self):
        with self.assertRaisesRegex(ValueError, "exactly 3"):
            self.add(variants=self.V[:2])
        with self.assertRaisesRegex(ValueError, "same"):
            self.add(variants=[self.V[0], self.V[1], "  NGL the naming part is the hard bit"])

    def test_needs_an_angle(self):
        with self.assertRaisesRegex(ValueError, "angle"):
            self.add(angle=" ")

    def test_one_suggestion_per_post(self):
        self.add()
        with self.assertRaisesRegex(ValueError, "Already suggested"):
            self.add(url="https://www.linkedin.com/feed/update/urn:li:activity:1?utm=x")

    def test_scouts_carry_the_rules_and_skips(self):
        sid = self.add(source="feed")["id"]
        self.assertEqual(self.file(sid)["post"]["source"], "feed")
        sc = t.t_get_comment_context({})["scouts"]
        self.assertEqual(set(sc), {"feed", "list", "search", "commenters"})
        for brief in sc.values():
            self.assertIn("tabs_create_mcp", brief)        # a subagent sees only its brief
            self.assertIn("Pass that tabId on every browser call", brief)  # one tab per scout
            self.assertIn("never open a second one", brief)  # navigate it, no tab per post
            self.assertIn("Never click Like", brief)
            self.assertIn("urn:li:activity:1", brief)       # the post already drafted
            self.assertIn('"candidates"', brief)
        self.assertIn("commenting-targets.md", sc["list"])
        self.assertIn("24 hours", sc["list"])
        self.assertIn("new_targets", sc["feed"])
        for name in ("feed", "search"):
            self.assertIn("recent-activity/all/", sc[name])  # where a post's link is found
        self.assertIn("Skip anyone on his target list", sc["search"])
        self.assertIn("Skip anyone on his target list", sc["commenters"])

    def test_redraft_after_feedback(self):
        sid = self.add()["id"]
        s = self.file(sid)
        s["status"] = "redraft"
        s["drafts"][-1]["feedback"] = "shorter"
        t.write_suggestion(s)
        ctx = t.t_get_comment_context({})
        self.assertEqual(ctx["waiting_for_redraft"][0]["id"], sid)
        self.assertEqual(ctx["examples"]["feedback_given"][0]["feedback"], "shorter")
        t.t_redraft_comment({"id": sid, "variants": ["same lol", "short one?", "we cut ours to 3 lines"]})
        s = self.file(sid)
        self.assertEqual((s["status"], len(s["drafts"])), ("review", 2))

    def test_context_learns_from_decisions(self):
        a = self.add()["id"]
        b = self.add(url="https://l.in/2", author="Sam Parr")["id"]
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        s = self.file(a)
        s.update(status="approved", final="mine instead", decision={"kind": "edited", "variant": 1, "at": now})
        t.write_suggestion(s)
        s = self.file(b)
        s.update(status="declined", decision={"kind": "bad_comment", "reason": "too long", "at": now})
        t.write_suggestion(s)
        ctx = t.t_get_comment_context({})
        self.assertEqual(ctx["examples"]["edited_by_user"][0]["user_wrote"], "mine instead")
        self.assertEqual(ctx["examples"]["edited_by_user"][0]["draft"], self.V[1])
        self.assertEqual(ctx["examples"]["variant_picks"][0]["picked"], self.V[1])
        self.assertEqual(ctx["examples"]["variant_picks"][0]["passed_over"], [self.V[0], self.V[2]])
        self.assertEqual(ctx["examples"]["declined"][0]["reason"], "too long")
        self.assertEqual(ctx["skip_authors"], ["Jane Doe"])
        self.assertEqual(len(ctx["skip_post_urls"]), 2)
        self.assertIn("Jane", ctx["targets"])
        self.assertIn("Comment lessons", ctx["lessons"])

    def test_posted_and_stats(self):
        sid = self.add()["id"]
        with self.assertRaisesRegex(ValueError, "approved"):
            t.t_set_comment_posted({"id": sid})
        s = self.file(sid)
        s.update(status="approved", final="x", decision={"kind": "approved", "at": t.now_iso()})
        t.write_suggestion(s)
        t.t_set_comment_posted({"id": sid, "url": "https://l.in/c"})
        v = t.t_set_comment_stats({"id": sid, "impressions": 900, "likes": 4})
        self.assertEqual((v["status"], v["stats"]["impressions"]), ("posted", 900))

    def test_tools_registered(self):
        names = {n for n, *_ in t.TOOLS}
        for n in ("get_comment_context", "add_comment_suggestion", "redraft_comment",
                  "list_comment_suggestions", "set_comment_posted", "set_comment_stats"):
            self.assertIn(n, names)


if __name__ == "__main__":
    unittest.main()
