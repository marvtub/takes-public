"""Posting plan (get_plan, set_plan) and live posts that still said draft or ready."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def session(self, name, title, status="draft", at=None, p="linkedin"):
        s = os.path.join(self.root, "Proj", name)
        os.makedirs(s, exist_ok=True)
        t.write_meta(s, {"title": title, "createdAt": "2026-10-01T10:00:00Z", "named": True, "takes": []})
        fm = {"status": status}
        if at:
            fm["at"], fm["tz"] = at, "America/Los_Angeles"
        t.write_post_file(s, fm, "Hook.\n", p)
        return s


class LivePost(Base):
    def test_stats_with_url_mark_the_post_posted(self):
        s = self.session("2026-09-28-a", "A", "ready")
        t.t_set_post_stats({"session": s, "platform": "LinkedIn", "impressions": 200,
                            "url": "https://www.linkedin.com/posts/a"})
        post = t.read_post(s)
        self.assertEqual(post["status"], "posted")
        self.assertEqual(post["url"], "https://www.linkedin.com/posts/a")
        self.assertIsNotNone(post["at"])
        self.assertEqual(t.t_get_post_queue({})["posts"], [])  # no longer "schedule on LinkedIn"

    def test_set_published_marks_only_that_platform(self):
        s = self.session("2026-09-28-b", "B", "draft")
        t.write_post_file(s, {"status": "ready"}, "x post\n", "x")
        t.t_set_published({"session": s, "platform": "X", "url": "https://x.com/1"})
        self.assertEqual(t.read_post(s, "x")["status"], "posted")
        self.assertEqual(t.read_post(s)["status"], "draft")

    def test_keeps_its_own_time(self):
        s = self.session("2026-09-28-c", "C", "scheduled", "2026-09-29T09:02:00-07:00")
        t.t_set_published({"session": s, "platform": "LinkedIn"})
        post = t.read_post(s)
        self.assertEqual((post["status"], post["at"]["iso"]), ("posted", "2026-09-29T09:02:00-07:00"))


class Plan(Base):
    def test_slots_gaps_and_buffer(self):
        # No plan yet: get_plan and get_session say nothing about one.
        self.assertIsNone(t.t_get_plan({})["plan"])
        s = self.session("2026-09-30-z", "Z")
        self.assertNotIn("posting_plan", t.t_get_session({"session": s}))
        today = datetime.now().astimezone().date()
        days = [t.PLAN_DAYS[(today + timedelta(days=i)).weekday()] for i in (1, 3)]
        v = t.t_set_plan({"days": [d.title() for d in days], "time": "08:02"})
        self.assertEqual(v["time"], "08:02")
        self.assertEqual(len(v["slots"]), 4)  # two days a week, 14 days
        self.assertEqual(v["buffer"], 0)
        first = today + timedelta(days=1)
        self.session("2026-10-01-a", "Shop", "scheduled", "%sT08:02:00-07:00" % first.isoformat())
        self.session("2026-10-01-b", "WebMCP", "ready")
        v = t.t_get_plan({})
        self.assertIn("Shop", v["slots"][0]["filled_by"][0])
        self.assertEqual(v["buffer"], 1)
        self.assertEqual(v["next_gap"], v["slots"][1]["day"])
        self.assertEqual(v["ready_without_time"], ["WebMCP"])
        brief = t.t_get_session({"session": os.path.join(self.root, "Proj", "2026-10-01-a")})["posting_plan"]
        self.assertEqual((brief["buffer"], brief["ready_without_time"]), (1, 1))
        # A video card covers its slot as planned: the buffer grows, the next gap moves on.
        t.t_plan_video({"session": os.path.join(self.root, "Proj", "2026-10-01-b"), "day": v["slots"][1]["date"]})
        v = t.t_get_plan({})
        self.assertEqual(v["slots"][1]["planned"], ["WebMCP"])
        self.assertEqual((v["buffer"], v["buffer_ready"]), (2, 1))
        self.assertEqual(v["next_gap"], v["slots"][2]["day"])
        with open(os.path.join(self.root, "_library", "plan.json")) as f:
            self.assertEqual(json.load(f)["platforms"], ["linkedin"])

    def test_bad_input(self):
        for a in ({"days": []}, {"days": ["someday"]}, {"days": ["tue"], "time": "9am"},
                  {"days": ["tue"], "platforms": ["myspace"]}):
            with self.assertRaises(ValueError):
                t.t_set_plan(a)



class PlanFile(Base):
    def test_off_hides_the_plan_and_set_keeps_since(self):
        path = os.path.join(self.root, t.LIB, "plan.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"days": ["tue"], "time": "08:02", "platforms": ["linkedin"], "since": "2026-09-01", "off": True}, f)
        self.assertIsNone(t.read_plan())
        self.assertIsNone(t.t_get_plan({})["plan"])
        t.t_set_plan({"days": ["thu"]})
        with open(path) as f:
            d = json.load(f)
        self.assertEqual(d["since"], "2026-09-01")
        self.assertNotIn("off", d)
        self.assertEqual(t.read_plan()["days"], ["thu"])


class PlanVideos(Base):
    def test_cards_order_move_weeks_and_set_plan_keeps_them(self):
        with self.assertRaises(ValueError):
            t.t_plan_video({"session": "Proj/x", "day": "2026-10-13"})  # no plan yet
        t.t_set_plan({"days": ["tue", "thu"]})
        a = self.session("2026-10-01-a", "Shop")
        self.session("2026-10-01-b", "WebMCP")
        self.session("2026-10-01-c", "Bezos")
        today = datetime.now().astimezone().date()
        day = (today + timedelta(days=2)).isoformat()
        t.t_plan_video({"session": a, "day": day})
        t.t_plan_video({"session": "Proj/2026-10-01-b", "day": day})
        v = t.t_plan_video({"session": "Proj/2026-10-01-c", "day": day, "before": "Proj/2026-10-01-b"})
        self.assertEqual([x["title"] for x in v["videos"]], ["Shop", "Bezos", "WebMCP"])
        self.assertEqual(v["videos"][0]["session"], "Proj/2026-10-01-a")
        # Far ahead: the board grows to show that week.
        far = (today + timedelta(days=30)).isoformat()
        v = t.t_plan_video({"session": a, "day": far})
        self.assertEqual(v["weeks"], 5)
        self.assertEqual([x["title"] for x in v["videos"]], ["Bezos", "WebMCP", "Shop"])
        with self.assertRaises(ValueError):
            t.t_plan_video({"session": a, "day": (today + timedelta(days=7 * 13)).isoformat()})
        with self.assertRaises(ValueError):
            t.t_plan_video({"session": a, "day": "next tuesday"})
        # set_plan changes the days and keeps the cards and the weeks.
        v = t.t_set_plan({"days": ["mon"]})
        self.assertEqual((len(v["videos"]), v["weeks"]), (3, 5))
        v = t.t_plan_video({"session": a, "day": ""})
        self.assertEqual([x["title"] for x in v["videos"]], ["Bezos", "WebMCP"])
        # A trashed session drops out of the view.
        shutil.rmtree(os.path.join(self.root, "Proj", "2026-10-01-b"))
        self.assertEqual([x["title"] for x in t.t_get_plan({})["videos"]], ["Bezos"])

    def test_card_follows_a_moved_session(self):
        t.t_set_plan({"days": ["tue", "thu"]})
        a = self.session("2026-10-01-a", "Shop")
        day = (datetime.now().astimezone().date() + timedelta(days=2)).isoformat()
        t.t_plan_video({"session": a, "day": day})
        t.t_move_sessions({"sessions": [a], "project": "Elsewhere"})
        v = t.t_get_plan({})["videos"]
        self.assertEqual([(x["session"], x["title"], x["date"]) for x in v], [("Elsewhere/2026-10-01-a", "Shop", day)])

    def test_cards_say_posted_or_scheduled(self):
        t.t_set_plan({"days": ["tue", "thu"]})
        today = datetime.now().astimezone().date()
        a = self.session("2026-10-01-a", "Shop", "scheduled", "%sT08:02:00-07:00" % (today + timedelta(days=3)).isoformat())
        b = self.session("2026-10-01-b", "Books", "ready")
        self.session("2026-10-01-c", "Plain")
        for s in (a, b, "Proj/2026-10-01-c"):
            t.t_plan_video({"session": s, "day": today.isoformat()})
        t.t_set_post_status({"session": b, "status": "posted"})
        v = {x["title"]: x.get("post") for x in t.t_get_plan({})["videos"]}
        self.assertEqual(v, {"Shop": "scheduled", "Books": "posted", "Plain": None})


if __name__ == "__main__":
    unittest.main()
