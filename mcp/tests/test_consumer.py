"""The weekly consumer check (2026-10-23, T-41, admin only): once a week, from Friday, the agent asks one topic's North
Star questions in logged-out ChatGPT and Google AI Mode in Ego and sends what each answer names in the daily_findings
snapshot. climb_status says when it is due and how the last run agreed with the slice."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

Q1 = "What is a free alternative to Screen Studio?"
Q2 = "What is a good alternative to Tella for recording videos?"


@unittest.skipUnless(hasattr(t, "t_climb_status"), "admin only")
class Consumer(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.makedirs(os.path.join(self.root, "_library", "work"))
        self.real_now = t.work_now

    def tearDown(self):
        t.work_now = self.real_now
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(self.root, ignore_errors=True)

    def set_now(self, d, h=10):
        """October 2026: the 19th is a Monday, ISO week 43 (Alternatives)."""
        self.now = datetime(2026, 10, d, h, 0, tzinfo=self.real_now().tzinfo)
        t.work_now = lambda: self.now
        return self.now

    def climb(self, rows):
        """climb.json: rows (question, engine, named, first, days_ago) as slice answers, topic Alternatives."""
        answers = {}
        for q, engine, named, first, ago in rows:
            at = self.now - timedelta(days=ago)
            e = answers.setdefault(q, {"topic": "Alternatives", "days": []})
            e["days"].append({"day": at.date().isoformat(), "at": t.work_iso(at), "run": "daily", "engine": engine,
                              "via": "api" if engine == "Gemini" else "cli", "named": named, "first": first,
                              "rivals": [], "skipped": False})
        with open(t.work_path("climb.json"), "w") as f:
            json.dump({"answers": answers}, f)

    def test_due_from_friday_until_the_run_is_in(self):
        self.set_now(21)
        self.climb([(Q1, "ChatGPT", False, False, 1), (Q2, "ChatGPT", False, False, 1)])
        c = t.work_consumer_status(t.work_climb(), self.now)
        self.assertEqual((c["due"], c["topic"], c["questions"]), (False, "Alternatives", sorted([Q1, Q2])))
        self.set_now(23)
        c = t.work_consumer_status(t.work_climb(), self.now)
        self.assertTrue(c["due"])
        self.assertIn("temporary-chat=true", c["how"])
        t.work_save_consumer({"consumer": {"answers": [
            {"surface": "ChatGPT web", "question": Q1, "named": False, "apps": ["OpenScreen", "Recordly"]}]}},
            t.work_climb(), self.now)
        self.assertFalse(t.work_consumer_status(t.work_climb(), self.now)["due"])
        # The next week has its own topic.
        self.set_now(30)
        c = t.work_consumer_status(t.work_climb(), self.now)
        self.assertEqual((c["due"], c["topic"]), (False, "Teleprompter"))  # no Teleprompter questions in this climb.json

    def test_agreement_with_the_slice(self):
        self.set_now(23)
        self.climb([(Q1, "ChatGPT", True, True, 2), (Q2, "ChatGPT", True, False, 1),
                    (Q1, "Gemini", False, False, 3), (Q2, "Gemini", False, False, 9)])  # 9 days: too old to compare
        run = t.work_save_consumer({"consumer": {"answers": [
            {"surface": "ChatGPT web", "question": Q1, "apps": ["Takes", "OpenScreen"]},
            {"surface": "ChatGPT web", "question": Q2, "apps": ["Loom", "Takes for Mac"]},
            {"surface": "Google AI Mode", "question": Q1, "named": False, "apps": ["Recordly", "Cap"]},
            {"surface": "Google AI Mode", "question": Q2, "named": False, "apps": ["Loom"]}]}}, t.work_climb(), self.now)
        self.assertEqual([(x["named"], x["first"]) for x in run["answers"]],
                         [(True, True), (True, False), (False, False), (False, False)])
        got = t.work_consumer_agreement(run, t.work_climb())
        self.assertEqual({k: got["ChatGPT web"][k] for k in ("named", "first", "slice_named", "slice_first", "agree")},
                         {"named": "2 of 2", "first": "1 of 2", "slice_named": "2 of 2", "slice_first": "1 of 2",
                          "agree": "2 of 2"})
        self.assertEqual((got["Google AI Mode"]["agree"], got["Google AI Mode"]["vs"]), ("1 of 1", "Gemini"))
        self.assertEqual(got["Google AI Mode"]["apps"], ["Recordly", "Cap", "Loom"])
        self.assertEqual(t.t_climb_status({})["consumer"]["last"]["surfaces"], got)

    def test_bad_answers_are_refused(self):
        self.set_now(23)
        self.climb([])
        for bad in ({"answers": [{"surface": "Perplexity", "question": Q1}]}, {"answers": [{"surface": "ChatGPT web"}]},
                    {"answers": []}, {"rows": []}):
            with self.assertRaises(ValueError):
                t.work_save_consumer({"consumer": bad}, t.work_climb(), self.now)
        self.assertEqual(t.work_consumer_runs(), [])


if __name__ == "__main__":
    unittest.main()
