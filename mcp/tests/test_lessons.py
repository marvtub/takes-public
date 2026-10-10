"""Lessons: a resolved comment needs its lesson, rules stay few, a repeat is counted, checks measure."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class Lessons(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        t.RULES_SEEN.clear()
        self.s = os.path.join(self.root, "Proj", "2026-10-08-idea")
        os.makedirs(os.path.join(self.s, "edits"))
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-08T00:00:00Z", "named": True, "takes": []})
        open(os.path.join(self.s, "edits", "a-v1.mp4"), "wb").close()
        t.write_comments(self.s, {"comments": [
            {"id": "c1", "file": "edits/a-v1.mp4", "start": 1.0, "text": "pause too long", "status": "open",
             "by": "user", "at": "2020-01-01T00:00:00.000Z"},
            {"id": "c2", "file": "edits/a-v1.mp4", "start": 2.0, "text": "pause again", "status": "open",
             "by": "user", "at": "2999-01-01T00:00:00.000Z"},
            {"id": "c3", "file": "edits/a-v1.mp4", "start": 3.0, "text": "logo", "status": "open",
             "by": "user", "at": "2999-01-01T00:00:00.000Z"}]})

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(self.root, ignore_errors=True)

    def comment(self, cid):
        return next(c for c in t.read_comments(self.s)["comments"] if c["id"] == cid)

    def test_resolve_needs_a_lesson(self):
        with self.assertRaises(ValueError):
            t.t_reply_comment({"session": self.s, "replies": [{"id": "c1", "text": "Fixed", "resolve": True}]})
        self.assertEqual(self.comment("c1")["status"], "open")
        # A question (no resolve) needs none.
        t.t_reply_comment({"session": self.s, "replies": [{"id": "c1", "text": "Which one?"}]})

    def test_new_rule_then_repeat(self):
        t.t_reply_comment({"session": self.s, "replies": [
            {"id": "c1", "text": "Shorter", "resolve": True, "lesson": "new",
             "rule": {"area": "cut", "text": "Pauses under 0.25 s.", "check": {"kind": "pauses", "max": 0.25}}},
            {"id": "c3", "text": "Gone", "resolve": True, "lesson": "one-off"}]})
        r = t.t_get_rules({"area": "all"})["rules"]
        self.assertEqual([x["id"] for x in r], ["cut-1"])
        self.assertEqual(r[0]["check"], {"kind": "pauses", "max": 0.25})
        self.assertEqual(self.comment("c1")["lesson"], "cut-1")
        self.assertNotIn("repeat", self.comment("c1"))
        self.assertEqual(self.comment("c3")["lesson"], "one-off")
        # c2 was written after the rule existed: the same mistake again.
        t.t_reply_comment({"session": self.s, "replies": [{"id": "c2", "resolve": True, "lesson": "cut-1"}]})
        self.assertTrue(self.comment("c2")["repeat"])
        self.assertEqual(t.t_get_rules({"area": "all"})["rules"][0]["repeated"], 1)
        self.assertEqual(t.read_lessons()["rules"][0]["from"], ["Proj/2026-10-08-idea#c1"])
        # One file per area: the app reads rules/cut.json.
        with open(os.path.join(self.root, "_library", "rules", "cut.json")) as f:
            self.assertEqual(json.load(f)["rules"][0]["id"], "cut-1")

    def test_unknown_lesson_writes_nothing(self):
        with self.assertRaises(ValueError):
            t.t_reply_comment({"session": self.s, "replies": [{"id": "c1", "resolve": True, "lesson": "cut-9"}]})
        self.assertEqual(self.comment("c1")["status"], "open")

    def test_area_cap_and_length(self):
        for i in range(t.AREA_MAX):
            t.t_set_rule({"area": "sound", "text": "Rule %d." % i})
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "sound", "text": "One more."})
        t.t_set_rule({"id": "sound-1", "on": False})
        self.assertEqual(t.t_set_rule({"area": "sound", "text": "One more."})["added"]["id"], "sound-11")
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "cut", "text": "x" * (t.RULE_MAX + 1)})
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "nope", "text": "x"})

    def test_the_users_rule_is_theirs(self):
        d = t.read_lessons()
        r = t.new_rule(d, "captions", "Bottom third.", by="you")
        t.write_lessons(d)
        with self.assertRaises(ValueError):
            t.t_set_rule({"id": r["id"], "text": "Top."})
        with self.assertRaises(ValueError):
            t.t_set_rule({"id": r["id"], "remove": True})
        self.assertTrue(t.t_get_rules({"area": "captions"})["rules"][0]["by_user"])

    def test_library_comments_need_no_lesson(self):
        lib = os.path.join(self.root, "_library", "styles", "Mag")
        os.makedirs(lib)
        t.write_comments(lib, {"comments": [{"id": "c1", "file": "README.md", "text": "x", "status": "open",
                                             "by": "user", "at": "2026-10-08T00:00:00.000Z"}]})
        t.t_reply_comment({"library": "style:Mag", "replies": [{"id": "c1", "text": "Done", "resolve": True}]})


@unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg")
class Checks(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-08-idea")
        os.makedirs(os.path.join(self.s, "edits"))
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-08T00:00:00Z", "named": True, "takes": []})
        # 1 s tone, 1.2 s silence, 1 s tone: one long pause at 1 s.
        self.f = os.path.join(self.s, "edits", "a-v1.m4a")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=440:d=1", "-f", "lavfi",
                        "-i", "anullsrc=r=44100:cl=mono", "-f", "lavfi", "-i", "sine=f=440:d=1",
                        "-filter_complex", "[1]atrim=0:1.2[s];[0][s][2]concat=n=3:v=0:a=1", self.f], check=True)

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(self.root, ignore_errors=True)

    def test_checks_measure_and_save(self):
        self.assertIn("No rule has a check", t.t_check_edit({"session": self.s, "file": "edits/a-v1.m4a"})["note"])
        t.t_set_rule({"area": "cut", "text": "Pauses under 0.4 s.", "check": {"kind": "pauses", "max": 0.4}})
        t.t_set_rule({"area": "other", "text": "Under 10 s.", "check": {"kind": "length", "max": 10}})
        t.t_set_rule({"area": "sound", "text": "Loud.", "check": {"kind": "loudness"}})
        r = t.t_check_edit({"session": self.s, "file": "edits/a-v1.m4a"})
        by = {x["rule"]: x for x in r["results"]}
        self.assertFalse(by["cut-1"]["pass"])
        self.assertAlmostEqual(by["cut-1"]["at"][0], 1.0, delta=0.1)
        self.assertTrue(by["other-1"]["pass"])
        self.assertIn(by["sound-1"]["pass"], (True, False))
        self.assertFalse(r["passed"])
        with open(os.path.join(self.s, "checks.json")) as fh:
            saved = json.load(fh)
        self.assertEqual(len(saved["edits/a-v1.m4a"]["results"]), 3)
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "cut", "text": "x", "check": {"kind": "vibes"}})


if __name__ == "__main__":
    unittest.main()


class RulesBySteps(unittest.TestCase):
    """2026-10-09: one file per step of the content journey, post rules per platform, and the tools that
    write for a step refuse once until the agent has its rules."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        t.RULES_SEEN.clear()
        self.lib = os.path.join(self.root, "_library")
        os.makedirs(os.path.join(self.lib, "comments"))
        self.s = os.path.join(self.root, "Proj", "2026-10-09-post")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "Post", "createdAt": "2026-10-09T00:00:00Z", "named": True, "takes": []})

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        t.RULES_SEEN.clear()
        shutil.rmtree(self.root, ignore_errors=True)

    def test_rules_an_old_chat_writes_after_the_split_move_in(self):
        with open(os.path.join(self.lib, "lessons.json"), "w") as f:
            json.dump({"rules": [{"id": "cut-1", "area": "cut", "text": "Tight."}]}, f)
        t.read_lessons()
        # A chat on the old server sees no lessons.json and starts again at cut-1.
        t.write_comments(self.s, {"comments": [{"id": "c1", "lesson": "cut-1", "file": "edits/a-v1.mp4"}]})
        with open(os.path.join(self.lib, "lessons.json"), "w") as f:
            json.dump({"rules": [{"id": "cut-1", "area": "cut", "text": "No jump cuts mid-word.",
                                  "from": ["Proj/2026-10-09-post#c1"], "repeats": []},
                                 {"id": "post-1", "area": "post", "text": "Tight."}]}, f)
        rules = {r["id"]: r["text"] for r in t.read_lessons()["rules"]}
        self.assertEqual(rules["cut-1"], "Tight.")
        self.assertEqual(rules["cut-2"], "No jump cuts mid-word.")
        self.assertEqual(len(rules), 2)  # the same text twice is one rule
        self.assertEqual(t.read_comments(self.s)["comments"][0]["lesson"], "cut-2")
        self.assertFalse(os.path.exists(os.path.join(self.lib, "lessons.json")))
        self.assertTrue(any(f.startswith("lessons-absorbed-") for f in os.listdir(self.lib)))

    def test_a_file_that_does_not_read_is_never_emptied(self):
        t.write_lessons({"rules": [{"id": "cut-1", "area": "cut", "text": "Tight."}]})
        bad = os.path.join(self.lib, "rules", "sound.json")
        with open(bad, "w") as f:
            f.write('{"rules": [ oops')
        d = t.read_lessons()
        t.new_rule(d, "cut", "Cut on the breath.")
        t.write_lessons(d)
        with open(bad) as f:
            self.assertEqual(f.read(), '{"rules": [ oops')
        self.assertEqual(len([r for r in t.read_lessons()["rules"] if r["area"] == "cut"]), 2)

    def test_old_copilot_lessons_file_is_merged(self):
        t.lessons_path()
        with open(os.path.join(self.lib, "comments", "lessons.md"), "w") as f:
            f.write(t.LESSONS_SEED + "\n- Never open with a compliment.\n")
        with open(t.lessons_path()) as f:
            self.assertIn("- Never open with a compliment.", f.read())
        self.assertFalse(os.path.exists(os.path.join(self.lib, "comments", "lessons.md")))

    def test_linkedin_hooks_are_linkedin(self):
        self.assertEqual(t.post_area("posts/hooks.json"), "post-linkedin")
        self.assertEqual(t.post_area("posts/x/hooks.json"), "post-x")

    def test_old_file_splits_by_area(self):
        old = [{"id": "cut-1", "area": "cut", "text": "Tight."}, {"id": "post-1", "area": "post", "text": "Hook."},
               {"id": "post-3", "area": "post", "text": "True claims."}, {"id": "odd-1", "area": "odd", "text": "?"}]
        with open(os.path.join(self.lib, "lessons.json"), "w") as f:
            json.dump({"rules": old}, f)
        areas = {r["id"]: r["area"] for r in t.read_lessons()["rules"]}
        self.assertEqual(areas, {"cut-1": "cut", "post-1": "post-linkedin", "post-3": "post-all", "odd-1": "other"})
        self.assertEqual(sorted(os.listdir(os.path.join(self.lib, "rules"))),
                         ["cut.json", "other.json", "post-all.json", "post-linkedin.json"])
        self.assertFalse(os.path.exists(os.path.join(self.lib, "lessons.json")))
        self.assertTrue(os.path.exists(os.path.join(self.lib, "lessons-before-split.json")))

    def test_post_comment_lands_in_its_platform(self):
        for f in ("posts/x.md", "posts/x/variants/b.md", "posts/linkedin.md", "posts/variants/a.md",
                  "posts/youtube.md", "posts/vertical.md", "posts/article.md"):
            self.assertEqual(t.post_area(f), {"posts/x.md": "post-x", "posts/x/variants/b.md": "post-x",
                                              "posts/youtube.md": "post-youtube", "posts/vertical.md": "post-vertical",
                                              "posts/article.md": "post-all"}.get(f, "post-linkedin"))
        t.write_comments(self.s, {"comments": [{"id": "c1", "file": "posts/x.md", "quote": "so", "text": "no",
                                                 "status": "open", "by": "user", "at": "2026-10-09T00:00:00.000Z"}]})
        t.t_reply_comment({"session": self.s, "replies": [{"id": "c1", "resolve": True, "lesson": "new",
                                                           "rule": {"area": "post", "text": "No 'so' openers on X."}}]})
        self.assertEqual(t.t_get_rules({"area": "post-x"})["rules"][0]["id"], "post-x-1")

    def test_writing_a_post_needs_its_rules_once(self):
        t.t_set_rule({"area": "post-x", "text": "Short."})
        t.t_set_rule({"area": "post-all", "text": "True."})
        t.t_set_rule({"area": "post-linkedin", "text": "Hook first."})
        t.RULES_SEEN.clear()
        with self.assertRaises(ValueError) as e:
            t.t_set_post({"session": self.s, "platform": "x", "text": "Hi"})
        self.assertIn("Short.", str(e.exception))
        self.assertIn("True.", str(e.exception))
        self.assertNotIn("Hook first.", str(e.exception))
        self.assertIsNone(t.read_post(self.s, "x"))
        t.t_set_post({"session": self.s, "platform": "x", "text": "Hi"})
        self.assertIsNotNone(t.read_post(self.s, "x"))
        # get_rules first: no refusal.
        t.RULES_SEEN.clear()
        t.t_get_rules({"area": "post"})
        t.t_set_post({"session": self.s, "text": "Hello"})

    def test_steps_with_no_rules_do_not_refuse(self):
        t.t_set_post({"session": self.s, "text": "Hello"})
        t.t_update_session({"session": self.s, "script": "Hi."})

    def test_edit_and_script_steps(self):
        t.t_set_rule({"area": "cut", "text": "Tight."})
        t.t_set_rule({"area": "script", "text": "Plain."})
        t.RULES_SEEN.clear()
        with self.assertRaises(ValueError):
            t.t_next_path({"kind": "edit", "session": self.s, "name": "a"})
        t.t_next_path({"kind": "edit", "session": self.s, "name": "a"})
        with self.assertRaises(ValueError):
            t.t_update_session({"session": self.s, "script": "Hi."})
        # A title change writes no script: no rules needed.
        t.RULES_SEEN.discard("script")
        t.t_update_session({"session": self.s, "title": "Post two"})

    def test_no_area_lists_the_steps_only(self):
        t.write_lessons({"rules": [{"id": "cut-1", "area": "cut", "text": "Tight."},
                                   {"id": "cut-2", "area": "cut", "text": "Off.", "on": False},
                                   {"id": "post-x-1", "area": "post-x", "text": "Short."}]})
        out = t.t_get_rules({})
        self.assertNotIn("rules", out)
        self.assertEqual(out["steps"][:2], [{"area": "cut", "rules": 1}, {"area": "post-x", "rules": 1}])
        self.assertEqual(out["steps"][-1]["area"], "comments")
        self.assertNotIn("cut", t.RULES_SEEN)  # a list is not a read

    def test_copilot_lessons_move_into_rules(self):
        with open(os.path.join(self.lib, "comments", "lessons.md"), "w") as f:
            f.write("# Comment lessons\n\n- No polish.\n")
        p = t.lessons_path()
        self.assertEqual(p, os.path.join(self.lib, "rules", "comments.md"))
        self.assertFalse(os.path.exists(os.path.join(self.lib, "comments", "lessons.md")))
        self.assertIn("No polish.", t.t_get_rules({"area": "all"})["comments"])
        t.RULES_SEEN.clear()
        with self.assertRaises(ValueError) as e:
            t.need_rules("comments")
        self.assertIn("No polish.", str(e.exception))

