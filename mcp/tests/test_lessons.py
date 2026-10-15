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

os.environ["TAKES_NO_REVIEW"] = "1"  # never let a real Gemini key watch a test edit


class Lessons(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-a-0001"
        t.forget_seen()
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
        os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
        t.SEEN.clear()
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
        with self.assertRaises(ValueError):  # after the rule: missed must say if the edit broke it
            t.t_reply_comment({"session": self.s, "replies": [{"id": "c2", "resolve": True, "lesson": "cut-1"}]})
        t.t_reply_comment({"session": self.s, "replies": [{"id": "c2", "resolve": True, "lesson": "cut-1",
                                                          "missed": True}]})
        self.assertTrue(self.comment("c2")["repeat"])
        self.assertEqual(t.t_get_rules({"area": "all"})["rules"][0]["repeated"], 1)
        self.assertEqual(t.read_lessons()["rules"][0]["from"], ["Proj/2026-10-08-idea#c1"])
        # One file per area: the app reads rules/cut.json.
        with open(os.path.join(self.root, "_library", "rules", "cut.json")) as f:
            self.assertEqual(json.load(f)["rules"][0]["id"], "cut-1")

    def test_a_new_ask_near_a_rule_is_no_repeat(self):
        t.t_reply_comment({"session": self.s, "replies": [
            {"id": "c1", "resolve": True, "lesson": "new", "rule": {"area": "graphics", "text": "Real logos only."}}]})
        t.t_reply_comment({"session": self.s, "replies": [{"id": "c3", "resolve": True, "lesson": "graphics-1",
                                                          "missed": False}]})
        c = self.comment("c3")
        self.assertNotIn("repeat", c)
        self.assertTrue(c["request"])
        rule = t.read_lessons()["rules"][0]
        self.assertEqual(rule["repeats"], [])
        self.assertIn("Proj/2026-10-08-idea#c3", rule["from"])

    def test_unknown_lesson_writes_nothing(self):
        with self.assertRaises(ValueError):
            t.t_reply_comment({"session": self.s, "replies": [{"id": "c1", "resolve": True, "lesson": "cut-9"}]})
        self.assertEqual(self.comment("c1")["status"], "open")

    def test_area_cap_and_length(self):
        for i in range(t.AREA_MAX):
            t.t_set_rule({"area": "sound", "text": "Rule %d." % i})
        with self.assertRaises(ValueError) as e:
            t.t_set_rule({"area": "sound", "text": "One more."})
        # The refusal lists the area's rules, so the agent can pick the one to merge into.
        self.assertIn("- sound-1: Rule 0.", str(e.exception))
        self.assertIn("- sound-10: Rule 9.", str(e.exception))
        self.assertIn("merge_into", str(e.exception))
        t.t_set_rule({"id": "sound-1", "on": False})
        self.assertEqual(t.t_set_rule({"area": "sound", "text": "One more."})["added"]["id"], "sound-11")
        # No sentence end: it cannot split.
        with self.assertRaises(ValueError) as e:
            t.t_set_rule({"area": "cut", "text": "x" * (t.RULE_MAX + 1)})
        self.assertIn("details", str(e.exception))
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "nope", "text": "x"})

    def test_a_long_rule_splits_at_its_first_sentence(self):
        first = "Cut every pause to 0.25 s or less, e.g. between two sentences of one thought."
        rest = "Keep a breath before a punchline. " + "The user likes that beat. " * 6
        out = t.t_set_rule({"area": "cut", "text": first + " " + rest})
        self.assertEqual(out["added"]["text"], first)
        self.assertEqual(out["added"]["details"], rest.strip())
        self.assertIn("split", out)
        # "0.25 s. then" is not a sentence end; the first real one comes too late.
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "cut", "text": "Cut to 0.25 s. then " + "y" * 230 + ". Next one."})
        # A first sentence under 40 characters is no rule on its own.
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "cut", "text": "Short one. " + "z" * 230})
        # With details given, a long text does not split.
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "cut", "text": first + " " + rest, "details": "More."})

    def full_cut(self):
        d = t.read_lessons()
        for i in range(t.AREA_MAX):
            t.new_rule(d, "cut", "Cut rule %d." % (i + 1))
        t.write_lessons(d)

    def test_full_area_merge_waits_on_the_board(self):
        self.full_cut()
        out = t.t_reply_comment({"session": self.s, "replies": [{"id": "c1", "text": "Done", "resolve": True,
                                 "lesson": "new", "rule": {"area": "cut", "text": "Cut the breath before the hook.",
                                                           "merge_into": "cut-3",
                                                           "merged": "Cut rule 3, and the breath before the hook."}}]})
        self.assertEqual(self.comment("c1")["status"], "resolved")
        self.assertEqual(self.comment("c1")["lesson"], "cut-11")
        rules = {r["id"]: r for r in t.read_lessons()["rules"]}
        self.assertTrue(rules["cut-11"]["on"])
        self.assertEqual(rules["cut-11"]["merge"], {"into": "cut-3", "text": "Cut rule 3, and the breath before the hook.",
                                                    "was": "Cut rule 3."})
        self.assertEqual(rules["cut-3"]["text"], "Cut rule 3.")
        view = next(r for r in t.t_get_rules({"area": "cut"})["rules"] if r["id"] == "cut-11")
        self.assertEqual(view["waiting_merge"]["into"], "cut-3")
        self.assertIn("Cut the breath before the hook.", out["merge"])
        self.assertIn("Cut rule 3.", out["merge"])
        self.assertNotIn("cut-", out["merge"])

    def test_full_area_without_merge_writes_nothing(self):
        self.full_cut()
        cut = os.path.join(self.root, "_library", "rules", "cut.json")
        with open(cut, "rb") as f:
            before = f.read()
        with self.assertRaises(ValueError) as e:
            t.t_reply_comment({"session": self.s, "replies": [{"id": "c1", "resolve": True, "lesson": "new",
                                                               "rule": {"area": "cut", "text": "One more."}}]})
        for i in range(1, 11):
            self.assertIn("- cut-%d:" % i, str(e.exception))
        self.assertEqual(self.comment("c1")["status"], "open")
        with open(cut, "rb") as f:
            self.assertEqual(f.read(), before)

    def test_a_raise_in_one_reply_writes_nothing(self):
        self.full_cut()
        with self.assertRaises(ValueError):
            t.t_reply_comment({"session": self.s, "replies": [
                {"id": "c3", "resolve": True, "lesson": "one-off"},
                {"id": "c1", "resolve": True, "lesson": "new", "rule": {"area": "cut", "text": "One more."}}]})
        self.assertEqual(self.comment("c3")["status"], "open")
        self.assertNotIn("lesson", self.comment("c3"))

    def test_merge_into_must_be_same_area_and_on(self):
        self.full_cut()
        t.t_set_rule({"area": "sound", "text": "Loud."})
        t.t_set_rule({"id": "cut-2", "on": False})
        t.t_set_rule({"area": "cut", "text": "Fill the gap."})  # 10 counting again
        for into in ("sound-1", "cut-99", "cut-2"):
            with self.assertRaises(ValueError) as e:
                t.t_set_rule({"area": "cut", "text": "New one.", "merge_into": into, "merged": "Both."})
            self.assertIn("merge_into is a rule in the cut area", str(e.exception))
        with self.assertRaises(ValueError):
            t.t_set_rule({"area": "cut", "text": "New one.", "merge_into": "cut-3", "merged": ""})
        with self.assertRaises(ValueError):
            t.t_set_rule({"id": "cut-3", "merge_into": "cut-4", "merged": "Both."})

    def test_waiting_merges_are_capped(self):
        self.full_cut()
        for i in range(t.WAITING_MAX):
            t.t_set_rule({"area": "cut", "text": "Wait %d." % i, "merge_into": "cut-1", "merged": "Both %d." % i})
        with self.assertRaises(ValueError) as e:
            t.t_set_rule({"area": "cut", "text": "Wait more.", "merge_into": "cut-1", "merged": "Both."})
        self.assertIn("Feedback board", str(e.exception))
        self.assertIn("'cut-1'", str(e.exception))

    def test_merged_rule_is_history(self):
        # As the board leaves it after Merge: the source off, merged_into the target.
        rules = [{"id": "cut-%d" % i, "area": "cut", "text": "Rule %d." % i, "on": True} for i in range(1, 10)]
        rules.append({"id": "cut-10", "area": "cut", "text": "Old.", "on": False, "merged_into": "cut-3"})
        rules.append({"id": "cut-11", "area": "cut", "text": "Waits.", "on": True,
                      "merge": {"into": "cut-1", "text": "Both.", "was": "Rule 1."}})
        t.write_lessons({"rules": rules})
        ids = [r["id"] for r in t.t_get_rules({"area": "cut"})["rules"]]
        self.assertNotIn("cut-10", ids)
        self.assertIn("cut-11", ids)
        self.assertFalse(t.counts(rules[-2]))
        self.assertFalse(t.counts(rules[-1]))
        # 9 counting rules: not full, and a new rule needs no merge.
        self.assertNotIn("full", t.t_get_rules({})["steps"][0])
        self.assertEqual(t.t_set_rule({"area": "cut", "text": "Tenth."})["added"]["id"], "cut-12")
        self.assertTrue(t.t_get_rules({})["steps"][0]["full"])
        props = next(p for n, d, p, r, f in t.TOOLS if n == "set_rule")
        self.assertNotIn("merge", props)

    def test_details(self):
        out = t.t_set_rule({"area": "cut", "text": "Tight pauses.", "details": "  Keep   a breath. "})
        self.assertEqual(out["added"]["details"], "Keep a breath.")
        self.assertEqual(t.t_get_rules({"area": "cut"})["rules"][0]["details"], "Keep a breath.")
        t.forget_seen()
        lines = t.t_next_path({"kind": "edit", "session": self.s, "name": "a"})["rules"]["new"]
        self.assertIn("  details: Keep a breath.", lines)
        # A details change shows the rule again (the hash covers details).
        t.t_set_rule({"id": "cut-1", "details": "Keep two breaths."})
        self.assertIn("  details: Keep two breaths.", t.t_next_path({"kind": "edit", "session": self.s, "name": "a"})["rules"]["new"])
        t.t_set_rule({"id": "cut-1", "details": ""})
        self.assertNotIn("details", t.read_lessons()["rules"][0])
        with self.assertRaises(ValueError):
            t.t_set_rule({"id": "cut-1", "details": "x" * (t.DETAILS_MAX + 1)})

    def test_full_flag_in_steps(self):
        self.full_cut()
        t.t_set_rule({"area": "sound", "text": "Loud."})
        steps = {x["area"]: x for x in t.t_get_rules({})["steps"]}
        self.assertTrue(steps["cut"]["full"])
        self.assertNotIn("full", steps["sound"])

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
        # Built-in checks come first ("check"); the rules keep "rule".
        by = {x["rule"]: x for x in r["results"] if "rule" in x}
        self.assertFalse(by["cut-1"]["pass"])
        self.assertAlmostEqual(by["cut-1"]["at"][0], 1.0, delta=0.1)
        self.assertTrue(by["other-1"]["pass"])
        self.assertIn(by["sound-1"]["pass"], (True, False))
        self.assertFalse(r["passed"])
        with open(os.path.join(self.s, "checks.json")) as fh:
            saved = json.load(fh)
        self.assertEqual(len([x for x in saved["edits/a-v1.m4a"]["results"] if "rule" in x]), 3)
        self.assertEqual(by["cut-1"]["label"], "Rule: Pauses under 0.4 s.")
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
        os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-a-0001"
        t.forget_seen()
        self.lib = os.path.join(self.root, "_library")
        os.makedirs(os.path.join(self.lib, "comments"))
        self.s = os.path.join(self.root, "Proj", "2026-10-09-post")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "Post", "createdAt": "2026-10-09T00:00:00Z", "named": True, "takes": []})

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
        t.SEEN.clear()
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
        t.forget_seen()
        with self.assertRaises(ValueError) as e:
            t.t_set_post({"session": self.s, "platform": "x", "text": "Hi"})
        self.assertIn("Short.", str(e.exception))
        self.assertIn("True.", str(e.exception))
        self.assertNotIn("Hook first.", str(e.exception))
        self.assertIsNone(t.read_post(self.s, "x"))
        t.t_set_post({"session": self.s, "platform": "x", "text": "Hi"})
        self.assertIsNotNone(t.read_post(self.s, "x"))
        self.assertTrue(os.path.exists(t.seen_file()))
        # get_rules first: no refusal.
        t.forget_seen()
        t.t_get_rules({"area": "post"})
        t.t_set_post({"session": self.s, "text": "Hello"})

    def test_steps_with_no_rules_do_not_refuse(self):
        t.t_set_post({"session": self.s, "text": "Hello"})
        t.t_update_session({"session": self.s, "script": "Hi."})

    def test_edit_and_script_steps(self):
        t.t_set_rule({"area": "cut", "text": "Tight."})
        t.t_set_rule({"area": "script", "text": "Plain."})
        t.forget_seen()
        # A path refuses nothing: the rules come with it, once.
        self.assertEqual(t.t_next_path({"kind": "edit", "session": self.s, "name": "a"})["rules"]["new"], ["- cut-1: Tight."])
        self.assertNotIn("rules", t.t_next_path({"kind": "edit", "session": self.s, "name": "a"}))
        # A title change writes no script: no rules needed.
        t.t_update_session({"session": self.s, "title": "Post two"})
        with self.assertRaises(ValueError):
            t.t_update_session({"session": self.s, "script": "Hi."})

    def test_no_area_lists_the_steps_only(self):
        t.write_lessons({"rules": [{"id": "cut-1", "area": "cut", "text": "Tight."},
                                   {"id": "cut-2", "area": "cut", "text": "Off.", "on": False},
                                   {"id": "post-x-1", "area": "post-x", "text": "Short."}]})
        out = t.t_get_rules({})
        self.assertNotIn("rules", out)
        self.assertEqual(out["steps"][:2], [{"area": "cut", "rules": 1}, {"area": "post-x", "rules": 1}])
        self.assertEqual(out["steps"][-1]["area"], "comments")
        self.assertEqual(t.read_seen()["rules"], {})  # a list is not a read

    def test_copilot_lessons_move_into_rules(self):
        with open(os.path.join(self.lib, "comments", "lessons.md"), "w") as f:
            f.write("# Comment lessons\n\n- No polish.\n")
        p = t.lessons_path()
        self.assertEqual(p, os.path.join(self.lib, "rules", "comments.md"))
        self.assertFalse(os.path.exists(os.path.join(self.lib, "comments", "lessons.md")))
        self.assertIn("No polish.", t.t_get_rules({"area": "all"})["comments"])
        t.forget_seen()
        with self.assertRaises(ValueError) as e:
            t.need_rules("comments")
        self.assertIn("No polish.", str(e.exception))

