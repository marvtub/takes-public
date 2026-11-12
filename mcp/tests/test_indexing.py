"""The indexing tool (2026-11-05, admin only): Google's state and our Request indexing asks per page, and the day's
quota. A page asked in the last 14 days is held, so the daily check stops filing the same page again (T-1 → T-14).
Each test has its own temp TAKES_ROOT and TAKES_SITE_DIR, no network, and a fixed now."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

NOW = "2026-11-05T09:00:00"


@unittest.skipUnless(hasattr(t, "t_add_ticket"), "the indexing tool is admin only")
class Indexing(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.site = os.path.join(self.root, "site")
        os.environ["TAKES_SITE_DIR"] = self.site
        self.real_now = t.work_now
        self.at(NOW)

    def tearDown(self):
        t.work_now = self.real_now
        for k in ("TAKES_ROOT", "TAKES_SITE_DIR"):
            os.environ.pop(k, None)
        shutil.rmtree(self.root, ignore_errors=True)

    # ---- helpers ----

    def at(self, iso):
        now = t.work_date(iso)
        t.work_now = lambda: now
        return now

    def write(self, name, d):
        path = t.work_path(name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(d, f)
        return path

    def html(self, name, title, links=()):
        os.makedirs(os.path.join(self.site, "public"), exist_ok=True)
        body = "".join('<a href="%s">x</a>' % h for h in links)
        with open(os.path.join(self.site, "public", name + ".html"), "w") as f:
            f.write("<html><head><title>%s</title></head><body>%s</body></html>" % (title, body))

    def index(self, pages, quota=None):
        return {"pages": pages, "quota": quota or {}}

    def verdict(self, doc, page="/x", links=(None, [])):
        return t.work_index_verdict(doc, page, t.work_now(), links)

    # ---- the verdict ----

    def test_verdict_holds_a_page_asked_9_days_ago(self):
        doc = self.index({"/x": {"state": "Discovered - currently not indexed", "asked": ["2026-10-27T10:00:00"]}})
        v = self.verdict(doc)
        self.assertFalse(v["may_request"])
        self.assertIn("Asked Oct 27", v["why"])
        self.assertIn("Ask again from Nov 10", v["why"])
        self.assertEqual((v["asks"], v["asked_last"]), (1, "2026-10-27"))
        doc["pages"]["/x"]["asked"] = ["2026-10-21T10:00:00"]  # 15 days
        self.assertTrue(self.verdict(doc)["may_request"])

    def test_never_asked_pages_come_first(self):
        self.write(t.WORK_INDEX, self.index({
            "/old": {"state": "Discovered - currently not indexed", "asked": ["2026-10-01T10:00:00"]},
            "/new": {"state": "URL is unknown to Google"},
            "/held": {"state": "Discovered - currently not indexed", "asked": ["2026-11-01T10:00:00"]},
            "/in": {"state": "indexed"}}))
        out = t.t_indexing({})
        self.assertEqual([v["page"] for v in out["pages"]], ["/new", "/old", "/held"])
        self.assertEqual([v["may_request"] for v in out["pages"]], [True, True, False])

    def test_quota_full_today_holds_every_page_and_clears_tomorrow(self):
        self.write(t.WORK_INDEX, self.index({"/x": {"state": "URL is unknown to Google"}}))
        out = t.t_indexing({"quota_full": True})
        self.assertFalse(out["pages"][0]["may_request"])
        self.assertIn("quota is used up today", out["pages"][0]["why"])
        self.assertEqual(out["quota"], {"day": "2026-11-05", "asked": 0, "full": True, "left": 0})
        self.at("2026-11-06T09:00:00")
        out = t.t_indexing({})
        self.assertTrue(out["pages"][0]["may_request"])
        self.assertEqual(out["quota"], {"day": "2026-11-06", "asked": 0, "full": False, "left": t.WORK_INDEX_DAY_CAP})

    def test_ten_asks_today_is_the_cap(self):
        doc = self.index({"/x": {"state": "URL is unknown to Google"}}, {"day": "2026-11-05", "asked": 9})
        self.assertTrue(self.verdict(doc)["may_request"])
        doc["quota"]["asked"] = t.WORK_INDEX_DAY_CAP
        self.assertFalse(self.verdict(doc)["may_request"])
        doc["quota"]["day"] = "2026-11-04"  # yesterday's count is no limit today
        self.assertTrue(self.verdict(doc)["may_request"])

    def test_crawled_not_indexed_says_rewrite_not_request(self):
        v = self.verdict(self.index({"/x": {"state": "Crawled – currently not indexed"}}))
        self.assertIn("a request does not change that", v["why"])
        self.assertIn("rewrite", v["why"])
        self.assertNotIn("rewrite", self.verdict(self.index({"/x": {"state": "Discovered - currently not indexed"}}))["why"])
        # U10 review: the why says a request does not help, so no click spends a quota slot on it.
        self.assertFalse(v["may_request"])

    # ---- links ----

    def test_link_from_lists_indexed_pages_that_do_not_link_yet(self):
        self.html("x", "Teleprompter for OBS on Mac")
        self.html("a", "Takes", links=["https://gettakes.app/x"])
        self.html("b", "OBS teleprompter alternative for Mac")
        self.html("c", "Pricing")
        self.html("privacy", "OBS teleprompter privacy", links=["/x"])  # skipped: not a page to link from
        self.write("climb.json", {"pages": [{"page": "/a", "clicks": 9}, {"page": "/b", "clicks": 1}]})
        self.write(t.WORK_INDEX, self.index({"/x": {"state": "Discovered - currently not indexed"}}))
        v = t.t_indexing({})["pages"][0]
        self.assertEqual((v["links_in"], v["link_from"]), (1, ["/b"]))  # /c is not in Google
        for n in range(6):
            self.html("l%d" % n, "Page %d" % n, links=['/x?ref=%d' % n if n % 2 else "/x.html#top"])
        v = t.t_indexing({})["pages"][0]
        self.assertEqual((v["links_in"], v["link_from"]), (7, []))
        self.assertIn("Already linked from 7 of our pages", v["why"])
        shutil.rmtree(self.site)
        v = t.t_indexing({})["pages"][0]
        self.assertIsNone(v["links_in"])
        self.assertIn("could not be read", v["why"])

    def test_a_link_to_a_longer_path_is_no_link(self):
        self.html("x", "X")
        self.html("a", "A", links=["/x-more", "/x/y"])
        self.assertEqual(t.work_index_links("/x", t.work_index_site())[0], 0)

    # ---- what it records ----

    def test_requested_records_asks_and_counts_quota(self):
        out = t.t_indexing({"pages": [{"path": "https://gettakes.app/x/", "state": "URL is unknown to Google"},
                                      {"path": "/y", "state": "Discovered - currently not indexed"}],
                            "requested": ["/x"]})
        self.assertEqual(out["quota"]["asked"], 1)
        x = {v["page"]: v for v in out["pages"]}["/x"]
        self.assertFalse(x["may_request"])
        self.assertIn("Ask again from Nov 19", x["why"])
        again = t.t_indexing({"requested": ["/x"]})  # the same page twice in one day counts once
        self.assertEqual(again["quota"]["asked"], 1)
        old = t.t_indexing({"requested": ["/y"], "at": "2026-10-29"})  # a backfill is not today's quota
        self.assertEqual(old["quota"]["asked"], 1)
        y = {v["page"]: v for v in old["pages"]}["/y"]
        self.assertEqual(y["asked_last"], "2026-10-29")
        self.assertIn("Ask again from Nov 12", y["why"])
        with self.assertRaises(ValueError):
            t.t_indexing({"requested": ["/y"], "at": "2026-11-09"})  # not in the future

    def test_seed_from_index_tickets(self):
        self.write("tickets.json", {"next": 3, "tickets": [
            {"id": "T-1", "title": "Request indexing: /x", "kind": "index", "state": "done", "closed": "2026-10-19T11:00:00"},
            {"id": "T-2", "title": "Reply to issue #4", "kind": "reply", "state": "done", "closed": "2026-10-19T11:00:00"}]})
        out = t.t_indexing({})
        self.assertTrue(out["seeded"])
        self.assertIn("T-35: Oct 29", out["note"])
        self.assertIn("gtm/aeo-log.md", out["note"])  # most asks are logged only there
        doc = json.load(open(t.work_path(t.WORK_INDEX)))
        self.assertEqual(list(doc["pages"]), ["/x"])
        self.assertTrue(doc["pages"]["/x"]["asked"][0].startswith("2026-10-19"))
        self.at("2026-11-06T09:00:00")
        self.assertNotIn("seeded", t.t_indexing({}))  # the note is for the first day only

    def test_corrupt_index_json_is_left_alone(self):
        path = self.write(t.WORK_INDEX, {})
        with open(path, "w") as f:
            f.write('{"pages": {')
        with self.assertRaises(ValueError):
            t.t_indexing({"requested": ["/x"]})
        self.assertEqual(open(path).read(), '{"pages": {')
        # The daily check goes on: it only leaves the file as it is.
        t.work_save_pages({"pages": [{"path": "/x", "indexed": False, "google": "URL is unknown to Google"}]}, t.work_now())
        self.assertEqual(open(path).read(), '{"pages": {')

    def test_save_pages_records_google_state(self):
        now = t.work_now()
        t.work_save_pages({"pages": [{"path": "/x", "status": 200, "indexed": False,
                                      "google": "Discovered - currently not indexed"}]}, now)
        doc = json.load(open(t.work_path(t.WORK_INDEX)))
        self.assertEqual(doc["pages"]["/x"]["state"], "Discovered - currently not indexed")
        self.assertEqual([v["page"] for v in t.t_indexing({})["pages"]], ["/x"])
        t.work_save_pages({"pages": [{"path": "/x", "status": 200, "indexed": True}]}, now)
        self.assertEqual(json.load(open(t.work_path(t.WORK_INDEX)))["pages"]["/x"]["state"], "indexed")
        self.assertEqual(t.t_indexing({})["pages"], [])

    def test_daily_facts_carry_the_asks(self):
        self.write(t.WORK_INDEX, self.index({"/x": {"asked": ["2026-11-01T10:00:00"]}}))
        snap = t.work_daily_facts({"day": "2026-11-05", "tickets": [], "launches": [], "listings": [], "shipped": []},
                                  t.work_now())
        self.assertEqual(snap["index"]["/x"]["asked"], ["2026-11-01T10:00:00"])


if __name__ == "__main__":
    unittest.main()
