"""Ticket evals (2026-10-20, admin only): the step code checks before a step is filed (evidence matches, page is live
and indexed, not a repeat of an open step, lift has a reason), the live page read, the ticket judge that learns from
the owner's Good step / Bad step labels, the lever mix and the daily recheck of proposed steps. The fixtures are the
real failures of T-6..T-11: a rival the answers did not name, a page that is not in Google, three steps on one idea,
copied lift and effort."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

Q = "What is the best teleprompter app for Mac?"
Q2 = "Which app records a teleprompter script and the webcam at once?"


@unittest.skipUnless(hasattr(t, "t_propose_steps"), "admin only")
class TicketEvals(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_JUDGE"] = "off"
        os.environ["TAKES_LINT"] = os.path.join(self.root, "no-linter.py")
        os.environ["TAKES_GTM_DIR"] = os.path.join(self.root, "gtm")
        os.makedirs(os.environ["TAKES_GTM_DIR"])
        self.real = (t.gemini_text, t.gemini_key, t.work_fetch_page, t.work_now)

        def no_gemini(system, ask, **kw):
            raise AssertionError("a test reached the real Gemini")

        def no_fetch(url):
            raise AssertionError("a test reached the network")
        t.gemini_text, t.gemini_key, t.work_fetch_page = no_gemini, lambda: None, no_fetch
        self.now = datetime(2026, 10, 21, 10, 0).astimezone()
        t.work_now = lambda: self.now
        os.makedirs(os.path.join(self.root, "_library", "work"), exist_ok=True)
        # The real answers to Q: ChatGPT and Claude name Teleprompter.com and Riverside, Gemini names Takes.
        self.climb({Q: [("ChatGPT", False, ["Teleprompter.com", "Riverside"]), ("Claude", False, ["Teleprompter.com"]),
                        ("Gemini", True, [])],
                    Q2: [("ChatGPT", False, ["Descript"]), ("Claude", False, ["Descript"]), ("Gemini", False, ["Descript"])]})
        t.work_save_pages({"pages": [{"path": "/teleprompter", "status": 200, "indexed": True},
                                     {"path": "/linkedin-video", "status": 200, "indexed": False},
                                     {"path": "/webcam-teleprompter", "status": 200, "indexed": True}]}, self.now)

    def tearDown(self):
        t.gemini_text, t.gemini_key, t.work_fetch_page, t.work_now = self.real
        for k in ("TAKES_ROOT", "TAKES_JUDGE", "TAKES_LINT", "TAKES_GTM_DIR"):
            os.environ.pop(k, None)
        shutil.rmtree(self.root, ignore_errors=True)

    # ---- fixtures ----

    def climb(self, answers, hours=3):
        doc = {"answers": {}}
        at = self.now - timedelta(hours=hours)
        for q, rows in answers.items():
            doc["answers"][q] = {"days": [{"day": at.date().isoformat(), "at": t.work_iso(at), "run": "daily",
                                           "engine": e, "via": "api" if e == "Gemini" else "cli", "named": named,
                                           "rivals": rivals, "skipped": False} for e, named, rivals in rows]}
        with open(t.work_path("climb.json"), "w") as f:
            json.dump(doc, f)

    def good(self, **change):
        """A step that passes every check: what an agent should send."""
        a = {"title": "Lead /teleprompter with the Mac answer", "lever": "answer", "kind": "page", "page": "/teleprompter",
             "targets": [{"type": "question", "value": Q}],
             "why": "2 of 3 assistants name Teleprompter.com, not Takes. Claude names Teleprompter.com.",
             "lead": {"name": "AI answers to this question that name Takes", "now": "1 of 3", "expect": "2 of 3"},
             "lift": 1.5, "lift_why": "Moves 1 question: two answers cite a page like this one", "confidence": 0.6,
             "effort": 2, "source": ""}
        a.update(change)
        # T-40: a page step on one question carries 2 more wordings of it.
        qs = [x for x in a.get("targets") or [] if x.get("type") == "question"]
        if a.get("lever") == "answer" and a.get("page") and len(qs) == 1:
            a["targets"] = a["targets"] + [{"type": "question", "value": "%s (said another way %d)" % (qs[0]["value"], i)}
                                           for i in (1, 2)]
        return a

    def checks(self, a, tickets=()):
        out = t.work_ticket_checks(dict(a, kpi=a["lead"]["name"], before=a["lead"]["now"]), list(tickets), self.now)
        return {c["name"]: c for c in out["checks"]}, out["pass"]

    def read(self):
        with open(t.work_file()) as f:
            return json.load(f)

    def ticket(self, tid):
        return next(x for x in self.read()["tickets"] if x["id"] == tid)

    def put(self, *tickets):
        """Tickets already on the board."""
        d = {"next": 1 + len(tickets), "tickets": list(tickets)}
        with open(t.work_file(), "w") as f:
            json.dump(d, f)

    def board_step(self, tid, state="proposed", **change):
        s = dict(self.good(), id=tid, state=state, kpi="AI answers", before="1 of 3", source="Daily check Oct 20",
                 created=t.work_iso(self.now - timedelta(days=1)))
        s.update(change)
        return s

    # ---- 1a. Evidence matches ----

    def test_evidence_matches_the_stored_answers(self):
        c, ok = self.checks(self.good())
        self.assertTrue(ok)
        self.assertEqual(c["Evidence matches"]["why"], "Matches the newest answers (today)")
        # T-9: the why said Claude names "Teleprompter Premium"; Claude named Teleprompter.com.
        c, ok = self.checks(self.good(why="1 of 3 name Takes. Claude names Teleprompter Premium for this."))
        self.assertFalse(ok)
        self.assertEqual(c["Evidence matches"]["why"],
                         "Says Claude names Teleprompter Premium, but its newest answer names Teleprompter.com")
        # A list after the verb: every name is checked, Riverside is ChatGPT's.
        c, _ = self.checks(self.good(why="ChatGPT names Teleprompter.com and Riverside."))
        self.assertTrue(c["Evidence matches"]["pass"])
        c, _ = self.checks(self.good(why="The assistants name Riverside, Descript and Teleprompter.com."))
        self.assertEqual(c["Evidence matches"]["why"], "Says the assistants name Descript, but the newest answers name Riverside and Teleprompter.com")
        # A wrong count: the answers are 1 of 3 naming Takes.
        c, ok = self.checks(self.good(lead={"name": "AI answers", "now": "0 of 3", "expect": "2 of 3"}))
        self.assertFalse(ok)
        self.assertEqual(c["Evidence matches"]["why"], "Says “0 of 3”, but the newest answers are 1 of 3 naming Takes")

    def test_evidence_must_be_fresh(self):
        self.climb({Q: [("ChatGPT", False, ["Teleprompter.com"]), ("Claude", False, ["Teleprompter.com"]),
                        ("Gemini", True, [])]}, hours=24 * 8)
        c, ok = self.checks(self.good())
        self.assertFalse(ok)
        self.assertEqual(c["Evidence matches"]["why"],
                         "The newest answer to “%s” is 8 days old (over 7): ask again first" % Q)
        self.climb({Q: [("ChatGPT", False, ["Teleprompter.com"]), ("Claude", False, ["Teleprompter.com"]),
                        ("Gemini", True, [])]}, hours=24 * 7)
        self.assertTrue(self.checks(self.good())[0]["Evidence matches"]["pass"])
        # A question with no stored answer cannot be checked: it fails, it never passes quietly.
        c, _ = self.checks(self.good(targets=[{"type": "question", "value": "Is there a teleprompter for iPad?"}]))
        self.assertIn("has no answers to", c["Evidence matches"]["why"])
        # No climb.json at all: skipped, said, not counted.
        os.remove(t.work_path("climb.json"))
        c, ok = self.checks(self.good())
        self.assertEqual((c["Evidence matches"]["pass"], c["Evidence matches"]["why"]),
                         (None, "skipped · no climb.json answers yet"))

    def test_cited_apps_reads_only_names_after_a_naming_verb(self):
        self.assertEqual(t.work_cited_apps("Claude names Teleprompter Premium and Descript, not Takes."),
                         [("Claude", "Teleprompter Premium"), ("Claude", "Descript")])
        self.assertEqual(t.work_cited_apps("The page names Takes for Mac. A search at rank 12."), [])
        self.assertTrue(t.work_same_app("Teleprompter", "Teleprompter.com"))
        self.assertFalse(t.work_same_app("Teleprompter Premium", "Teleprompter.com"))

    # ---- 1b. Page is live and indexed ----

    def test_page_live_and_indexed(self):
        # T-11: /linkedin-video is live but not in Google: its indexing ticket comes first.
        c, ok = self.checks(self.good(page="/linkedin-video"))
        self.assertFalse(ok)
        self.assertEqual(c["Page is live and indexed"]["why"], "/linkedin-video is not in Google yet: its indexing ticket comes first")
        # T-9: no page at all.
        c, ok = self.checks(self.good(page=""))
        self.assertFalse(ok)
        self.assertIn("No page: a step on the answer lever names the page", c["Page is live and indexed"]["why"])
        c, _ = self.checks(self.good(page="https://gettakes.app/nope/"))
        self.assertEqual(c["Page is live and indexed"]["why"], "/nope is not on the site")
        # A listing step needs no page; a new page is not live yet; Google's pages in climb.json count as indexed.
        c, _ = self.checks(self.good(lever="named", kind="listing", page="", targets=[{"type": "listing", "value": "AlternativeTo"}],
                                     why="AlternativeTo does not name Takes yet."))
        self.assertEqual(c["Page is live and indexed"]["why"], "A step on the named lever needs no page")
        c, _ = self.checks(self.good(page="/mac-teleprompter-free", new_page=True))
        self.assertTrue(c["Page is live and indexed"]["pass"])
        c, _ = self.checks(self.good(page="/linkedin-video", new_page=True))
        self.assertFalse(c["Page is live and indexed"]["pass"])  # live already: it is an edit, and not indexed
        self.assertEqual(c["Page is live and indexed"]["why"], "/linkedin-video is not in Google yet: its indexing ticket comes first")

    def test_daily_findings_keeps_the_page_rows(self):
        os.remove(t.work_path("pages.json"))
        self.assertIsNone(t.work_site_pages({}))
        self.assertEqual(self.checks(self.good())[0]["Page is live and indexed"]["why"],
                         "skipped · no page list yet (the daily check saves it)")
        t.t_daily_findings({"snapshot": {"day": "2026-10-21", "pages": [{"path": "/teleprompter", "status": 200,
                                                                          "indexed": True}]}})
        self.assertEqual(t.work_site_pages({})["/teleprompter"]["indexed"], True)

    # ---- 1c. Not a repeat: open steps too ----

    def test_not_a_repeat_checks_open_steps(self):
        t6 = self.board_step("T-6", title="Best teleprompter app for Mac page")
        # Same page and question as an open step (T-8 on T-6's page).
        c, ok = self.checks(self.good(title="Add a comparison table"), [t6])
        self.assertFalse(ok)
        self.assertEqual(c["Not a repeat"]["why"], "T-6 is open on the same page and question")
        # A title that overlaps 0.7 or more with an open step, on another page.
        c, ok = self.checks(self.good(title="Best teleprompter app for Mac page", page="/webcam-teleprompter",
                                      targets=[{"type": "question", "value": Q2}],
                                      why="3 of 3 assistants name Descript, not Takes.",
                                      lead={"name": "AI answers", "now": "0 of 3", "expect": "1 of 3"}), [t6])
        self.assertEqual(c["Not a repeat"]["why"], "T-6 is open: Best teleprompter app for Mac page")
        # A skipped or done step is no open repeat; an approved one is.
        for state, want in (("skipped", True), ("approved", False), ("needs_you", False)):
            c, _ = self.checks(self.good(title="Add a comparison table"), [dict(t6, state=state)])
            self.assertEqual(c["Not a repeat"]["pass"], want, state)

    # ---- 1d. Lift has a reason ----

    def test_lift_has_a_reason(self):
        c, ok = self.checks(self.good(lift_why=""))
        self.assertFalse(ok)
        self.assertIn("No lift_why", c["Lift has a reason"]["why"])
        no_lift = self.good()
        no_lift.pop("lift")
        self.assertIn("No lift:", self.checks(no_lift)[0]["Lift has a reason"]["why"])
        no_effort = self.good()
        no_effort.pop("effort")
        self.assertIn("No effort", self.checks(no_effort)[0]["Lift has a reason"]["why"])
        # T-6..T-11: lift 2 and effort 3, the answer lever's defaults, whatever the confidence (0.55, 0.5, 0.4).
        for conf in (0.5, 0.55, 0.4):
            c, _ = self.checks(self.good(lift=2, confidence=conf, effort=3))
            self.assertEqual(c["Lift has a reason"]["why"],
                             "Lift 2 and effort 3 are the answer defaults: estimate them for this step")
            self.assertEqual(c["Lift has a reason"]["pass"], False)
        # Its own lift with the default effort, or the default lift with its own effort, is an estimate.
        self.assertTrue(self.checks(self.good(lift=2, effort=2))[0]["Lift has a reason"]["pass"])
        self.assertTrue(self.checks(self.good(lift=1, effort=3))[0]["Lift has a reason"]["pass"])
        self.assertEqual(self.checks(self.good())[0]["Lift has a reason"]["why"],
                         "Lift 1.5: Moves 1 question: two answers cite a page like this one")

    def test_a_plain_ticket_gets_no_step_checks(self):
        out = t.work_ticket_checks({"title": "Reply to issue #42", "kind": "reply", "kpi": "Issues", "before": "1"}, [], self.now)
        self.assertEqual([c["name"] for c in out["checks"]], ["Names one number", "Not a repeat"])

    def test_propose_steps_refuses_each_real_failure(self):
        got = t.t_propose_steps({"steps": [
            self.good(title="Claude names a rival", why="Claude names Teleprompter Premium."),
            self.good(title="LinkedIn video page", page="/linkedin-video"),
            self.good(title="Best alternative page", page=""),
            self.good(title="Copied defaults", lift=2, confidence=0.5, effort=3, page="/webcam-teleprompter",
                      targets=[{"type": "question", "value": Q2}], why="3 of 3 assistants name Descript.",
                      lead={"name": "AI answers", "now": "0 of 3", "expect": "1 of 3"}),
            self.good()]})
        self.assertEqual([x["title"] for x in got["filed"]], ["Lead /teleprompter with the Mac answer"])
        reasons = {w["title"]: w["reason"] for w in got["waiting"]}
        self.assertIn("Evidence matches (Says Claude names Teleprompter Premium", reasons["Claude names a rival"])
        self.assertIn("Page is live and indexed (/linkedin-video is not in Google yet", reasons["LinkedIn video page"])
        self.assertIn("Page is live and indexed (No page", reasons["Best alternative page"])
        self.assertIn("Lift has a reason (Lift 2 and effort 3 are the answer defaults", reasons["Copied defaults"])
        stored = self.ticket(got["filed"][0]["id"])
        self.assertEqual(stored["lift_why"], "Moves 1 question: two answers cite a page like this one")
        self.assertEqual([c["name"] for c in stored["ticket_checks"]["checks"]],
                         ["Names one number", "Evidence matches", "Page is live and indexed", "Not a repeat",
                          "Lift has a reason", "Page read"])
        self.assertEqual(stored["ticket_checks"]["checks"][-1]["why"], "skipped · the judge is off")
        self.assertTrue(stored["ticket_checks"]["pass"])
        # Each filed step is an unlabeled case in the ticket suite.
        case = t.work_suite_file("ticket")["cases"][0]
        self.assertEqual((case["id"], case["ticket"], case["question"], case["url"]),
                         ("ticket:%s" % stored["id"], stored["id"], Q, "https://gettakes.app/teleprompter"))
        self.assertNotIn("label", case)
        self.assertIn("Lift: 1.5 (Moves 1 question", case["text"])

    def test_two_of_todays_ideas_on_one_page_are_one(self):
        got = t.t_propose_steps({"steps": [self.good(), self.good(title="Add a comparison table to /teleprompter")]})
        self.assertEqual(len(got["filed"]), 1)
        self.assertIn("is open on the same page and question", got["waiting"][0]["reason"])

    # ---- 2. The page read ----

    def gemini(self, page_answers=False, judge_pass=True):
        """A fake Gemini: the page read, the small-enough judge and the ticket judge each get their own reply."""
        calls = []

        def fake(system, ask, **kw):
            calls.append(system)
            if system == t.WORK_PAGE_READ_SYSTEM:
                self.assertIn("Question: ", ask)
                self.assertIn("Teleprompter for Mac page text", ask)
                return json.dumps({"answers": page_answers, "now": "The page lists features but never answers the question.",
                                   "new": "The first 2 sentences answer it and name Takes for Mac."})
            if "One agent can finish this in one ticket" in ask:
                return json.dumps([{"pass": True, "why": "one page"}])  # Small enough
            n = sum(1 for line in ask.splitlines() if line[:3].rstrip(". ").isdigit())
            return json.dumps([{"pass": judge_pass, "why": "ok" if judge_pass else "Not likely to move any question"}] * n)
        t.gemini_text = fake
        t.gemini_key = lambda: "test-key"
        os.environ["TAKES_JUDGE"] = "on"
        return calls

    def test_page_read_adds_now_and_new(self):
        fetched = []

        def page(url):
            fetched.append(url)
            return "Teleprompter for Mac page text"
        t.work_fetch_page = page
        self.gemini()
        got = t.t_propose_steps({"steps": [self.good()]})
        stored = self.ticket(got["filed"][0]["id"])
        self.assertEqual(stored["page_read"], {"now": "The page lists features but never answers the question.",
                                               "new": "The first 2 sentences answer it and name Takes for Mac.",
                                               "page": "/teleprompter"})
        rows = {c["name"]: c for c in stored["ticket_checks"]["checks"]}
        self.assertEqual((rows["Page read"]["pass"], rows["Small enough"]["pass"]), (True, True))
        self.assertEqual(fetched, ["https://gettakes.app/teleprompter"])
        self.assertEqual(t.t_list_tickets({"id": stored["id"]})["page_read"]["page"], "/teleprompter")

    def test_page_that_already_answers_is_not_filed(self):
        t.work_fetch_page = lambda url: "Teleprompter for Mac page text"
        self.gemini(page_answers=True)
        got = t.t_propose_steps({"steps": [self.good()]})
        self.assertEqual(got["filed"], [])
        self.assertEqual(got["waiting"][0]["reason"], "Not filed: /teleprompter already answers “%s”. The page lists "
                                                      "features but never answers the question." % Q)
        with open(t.work_path("looked.json")) as f:
            looked = json.load(f)
        self.assertTrue(looked["nothing"].startswith("/teleprompter already answers"))
        self.assertFalse(os.path.exists(t.work_file()) and self.read()["tickets"])

    def test_page_read_skips_without_a_key_or_a_page(self):
        os.environ["TAKES_JUDGE"] = "on"
        t.gemini_key = lambda: None
        t.gemini_text = lambda system, ask, **kw: (_ for _ in ()).throw(ValueError("No Gemini key."))
        got = t.t_propose_steps({"steps": [self.good()]})
        row = self.ticket(got["filed"][0]["id"])["ticket_checks"]["checks"][-1]
        self.assertEqual((row["name"], row["pass"], row["why"]), ("Page read", None, "skipped · no Gemini key"))

        def broken(url):
            raise OSError("timed out")
        t.work_fetch_page = broken
        t.gemini_key = lambda: "test-key"
        t.gemini_text = lambda system, ask, **kw: (_ for _ in ()).throw(ValueError("No Gemini key."))
        got = t.t_propose_steps({"steps": [self.good(title="Answer the webcam question on its page", page="/webcam-teleprompter",
                                                     targets=[{"type": "question", "value": Q2}],
                                                     why="3 of 3 assistants name Descript, not Takes.",
                                                     lead={"name": "AI answers", "now": "0 of 3", "expect": "1 of 3"})]})
        stored = self.ticket(got["filed"][0]["id"])
        row = [c for c in stored["ticket_checks"]["checks"] if c["name"] == "Page read"][0]
        self.assertEqual(row["why"], "skipped · page did not load")
        self.assertNotIn("page_read", stored)

    # ---- 3. The ticket judge ----

    def label_cases(self, n, agree=True, verdict="good"):
        """n labeled ticket cases with a judge verdict for the current prompt."""
        prompt = t.work_judge_rules("ticket")[1]

        def put(d):
            for i in range(n):
                d["cases"].append({"id": "ticket:T-%d" % (100 + len(d["cases"])), "suite": "ticket", "text": "x",
                                   "label": {"verdict": verdict, "why": ""},
                                   "judge": {"verdict": verdict if agree else ("bad" if verdict == "good" else "good"),
                                             "prompt": prompt}})
        t.work_suite_save("ticket", put)

    def test_ticket_judge_scores_but_does_not_block_until_trusted(self):
        t.work_fetch_page = lambda url: "Teleprompter for Mac page text"
        self.gemini(judge_pass=False)
        got = t.t_propose_steps({"steps": [self.good()]})
        stored = self.ticket(got["filed"][0]["id"])
        self.assertEqual((stored["ticket_judge"]["score"], stored["ticket_judge"]["pass"], stored["ticket_judge"]["trusted"]),
                         (0.0, False, False))
        case = t.work_suite_file("ticket")["cases"][-1]
        self.assertEqual(case["judge"]["verdict"], "bad")
        # Trusted (8 good and 8 bad labels, the judge agrees on each): a failing step is not filed.
        self.label_cases(8)
        self.label_cases(8, verdict="bad")
        self.assertTrue(t.work_trusted("ticket"))
        got = t.t_propose_steps({"steps": [self.good(title="Answer the webcam question on its page", page="/webcam-teleprompter",
                                                     targets=[{"type": "question", "value": Q2}],
                                                     why="3 of 3 assistants name Descript, not Takes.",
                                                     lead={"name": "AI answers", "now": "0 of 3", "expect": "1 of 3"})]})
        self.assertEqual(got["filed"], [])
        self.assertIn("the ticket judge (trusted: it agrees with the user beyond chance) failed it", got["waiting"][0]["reason"])

    def test_ticket_suite_is_a_judge_suite(self):
        self.assertIn("ticket", t.WORK_EVAL_SUITES)
        self.assertEqual(len(t.WORK_JUDGE_RULES["ticket"]), 4)
        self.assertEqual(t.work_code_checks("ticket", "Title: x", {}), [])
        self.assertEqual(t.work_case_draft({"suite": "ticket", "text": "Title: x"}), "Title: x")
        # 9 labels: not trusted, and judge_status says how many labels it has.
        self.label_cases(9)
        self.assertFalse(t.work_trusted("ticket"))
        self.assertEqual(t.t_judge_status({"suite": "ticket"})["labels"], 9)
        # The planted case: a labeled bad step the judge calls good is a disagreement. 9 of 10 agree, but with one
        # bad label the judge is not trusted: it needs 8 of each kind.
        self.label_cases(1, agree=False, verdict="bad")
        ag = t.work_agreement(t.work_suite_file("ticket"))
        self.assertEqual((ag["agree"], ag["of"], ag["good"], ag["bad"], ag["trusted"]), (9, 10, 9, 1, False))
        self.assertEqual(ag["disagree"][0]["label"], "bad")
        self.assertIn("needs 8 good and 8 bad labels", ag["why"])

    def test_seed_ticket_cases_from_the_board(self):
        self.put(self.board_step("T-6"), self.board_step("T-7", undoes="T-6"),
                 {"id": "T-8", "title": "Reply", "kind": "reply", "state": "needs_you"})
        out = t.t_seed_cases({"suite": "ticket"})
        self.assertEqual((out["added"], out["suite"]), (1, "ticket"))
        self.assertEqual(t.work_suite_file("ticket")["cases"][0]["id"], "ticket:T-6")

    # ---- 4. The lever mix ----

    def test_lever_cap_and_mix(self):
        steps = [dict(self.good(), title="Answer %d" % i, lever="answer", targets=[{"type": "question", "value": "q%d" % i}],
                      page="/p%d" % i, lift=3, confidence=0.9, effort=1) for i in range(3)]
        listing = dict(self.good(), title="List Takes on AlternativeTo", lever="named", kind="listing", page="",
                       targets=[{"type": "listing", "value": "AlternativeTo"}], lift=1, confidence=0.4, effort=2)
        # Two answer steps open: a third waits, the listing goes.
        held = [self.board_step("T-%d" % (i + 1), title="Held %d" % i, page="/h%d" % i,
                                targets=[{"type": "question", "value": "h%d" % i}]) for i in range(2)]
        filed, waiting = t.work_pick_steps([steps[0], listing], held, {}, self.now, next_id=3)
        self.assertEqual([s["title"] for s in filed], ["List Takes on AlternativeTo"])
        self.assertEqual((waiting[0]["code"], waiting[0]["reason"]),
                         ("lever_cap", "Waits: 2 answer steps are open (T-1, T-2). At most 2 per lever, so other levers get a turn."))
        # Nothing open: the lever with fewer open steps goes first, then the score; the cap holds within one call.
        filed, waiting = t.work_pick_steps(steps + [listing], [], {}, self.now, next_id=1)
        self.assertEqual([s["title"] for s in filed], ["Answer 0", "List Takes on AlternativeTo", "Answer 1"])
        self.assertEqual([(s["title"], s["code"]) for s in waiting], [("Answer 2", "lever_cap")])
        # No named idea: no lever is forced, the answer steps fill to the cap.
        filed, _ = t.work_pick_steps(steps, [], {}, self.now)
        self.assertEqual(len(filed), 2)
        # A skipped step does not count as open.
        filed, _ = t.work_pick_steps([steps[0]], [dict(h, state="skipped") for h in held], {}, self.now)
        self.assertEqual(len(filed), 1)

    # ---- 5. The daily recheck ----

    def test_recheck_skips_failing_proposed_steps_only(self):
        bad = self.board_step("T-9", title="Best alternative page", page="")          # no page: fails now
        approved = self.board_step("T-10", state="approved", page="")                  # fails too, but approved
        mine = self.board_step("T-11", page="", source="The user")                       # the owner's: never rechecked
        fine = self.board_step("T-12", title="Webcam teleprompter answer", page="/webcam-teleprompter",
                               targets=[{"type": "question", "value": Q2}], why="3 of 3 assistants name Descript.",
                               lead={"name": "AI answers", "now": "0 of 3", "expect": "1 of 3"})
        twin = self.board_step("T-13", title="Webcam teleprompter answer page", page="/webcam-teleprompter",
                               targets=[{"type": "question", "value": Q2}], why="3 of 3 assistants name Descript.",
                               lead={"name": "AI answers", "now": "0 of 3", "expect": "1 of 3"})
        self.put(bad, approved, mine, fine, twin)
        out = t.t_daily_findings({"snapshot": {"day": "2026-10-21"}})
        self.assertEqual([r["id"] for r in out["rechecked"]], ["T-9", "T-13"])
        self.assertEqual(out["rechecked"][0]["failed"], ["Page is live and indexed"])
        self.assertIn("Skipped 2 proposed steps that now fail a check: say one line each in the chat", out["note"])
        self.assertEqual(out["rechecked"][1]["failed"], ["Not a repeat"])  # the older twin T-12 stays
        t9 = self.ticket("T-9")
        self.assertEqual((t9["state"], t9["activity"][-1]["act"]), ("skipped", "recheck"))
        self.assertIn("Page is live and indexed failed: No page", t9["activity"][-1]["text"])
        self.assertEqual(t9["recheck"]["failed"], ["Page is live and indexed"])
        self.assertEqual([self.ticket(x)["state"] for x in ("T-10", "T-11", "T-12")], ["approved", "proposed", "proposed"])
        # Nothing fails the next day: nothing moves, and the note says nothing about it.
        out = t.t_daily_findings({"snapshot": {"day": "2026-10-22"}})
        self.assertNotIn("rechecked", out)

    def test_recheck_never_moves_a_step_on_a_skipped_check(self):
        os.remove(t.work_path("climb.json"))
        os.remove(t.work_path("pages.json"))
        self.put(self.board_step("T-9"))
        self.assertEqual(t.work_recheck_proposed(self.now), [])
        self.assertEqual(self.ticket("T-9")["state"], "proposed")

    # ---- review fixes (2026-10-20) ----

    def test_lift_why_and_north_star_counts_are_not_answer_counts(self):
        # The tool asks lift_why for "how many of the 21 questions it can move": that is no evidence to match.
        c, ok = self.checks(self.good(lift_why="Moves 2 of 21 questions: both answers cite this page"))
        self.assertTrue(ok, c)
        c, ok = self.checks(self.good(why="Takes is named for 4 of 21 questions. 2 of 3 assistants name Teleprompter.com."))
        self.assertTrue(c["Evidence matches"]["pass"], c["Evidence matches"])
        # A wrong per-question count in the why still fails.
        c, _ = self.checks(self.good(why="3 of 3 assistants name Teleprompter.com."))
        self.assertFalse(c["Evidence matches"]["pass"])

    def test_cited_apps_need_an_assistant_as_subject(self):
        self.assertEqual(t.work_cited_apps("The page names Final Cut Pro in its table; Claude names Teleprompter.com."),
                         [("Claude", "Teleprompter.com")])
        self.assertEqual(t.work_cited_apps("AlternativeTo lists Descript as the top pick."), [])
        c, _ = self.checks(self.good(why="The page names Final Cut Pro in its table; Claude names Teleprompter.com."))
        self.assertTrue(c["Evidence matches"]["pass"], c["Evidence matches"])
        c, _ = self.checks(self.good(why="AlternativeTo lists Descript. 2 of 3 answers name Teleprompter.com."))
        self.assertTrue(c["Evidence matches"]["pass"], c["Evidence matches"])

    def test_cited_apps_stop_at_a_sentence_and_read_engine_lists(self):
        self.assertEqual(t.work_cited_apps("ChatGPT names Riverside. Claude names Descript."),
                         [("ChatGPT", "Riverside"), ("Claude", "Descript")])
        self.assertEqual(t.work_cited_apps("Gemini and Claude name Descript and Teleprompter Premium."),
                         [("Gemini and Claude", "Descript"), ("Gemini and Claude", "Teleprompter Premium")])
        # Each app is checked against the joined answers of the engines named: Riverside is ChatGPT's alone.
        c, _ = self.checks(self.good(why="ChatGPT and Claude name Riverside and Teleprompter.com."))
        self.assertTrue(c["Evidence matches"]["pass"], c["Evidence matches"])
        c, _ = self.checks(self.good(why="ChatGPT and Claude name Riverside and Teleprompter Premium."))
        self.assertEqual(c["Evidence matches"]["why"], "Says ChatGPT and Claude name Teleprompter Premium, but their newest "
                                                       "answers name Riverside and Teleprompter.com")
        c, _ = self.checks(self.good(why="ChatGPT names Riverside. Claude names Teleprompter.com."))
        self.assertTrue(c["Evidence matches"]["pass"], c["Evidence matches"])

    def test_page_check_skips_when_the_page_list_is_unknown(self):
        # The real state today: no pages.json yet and climb.json "pages": [].
        os.remove(t.work_path("pages.json"))
        with open(t.work_path("climb.json")) as f:
            doc = json.load(f)
        doc["pages"] = []
        with open(t.work_path("climb.json"), "w") as f:
            json.dump(doc, f)
        self.assertIsNone(t.work_site_pages())
        c, ok = self.checks(self.good())
        self.assertEqual((c["Page is live and indexed"]["pass"], ok), (None, True))
        # Only Google's pages: a page it does not list is unknown, not missing.
        doc["pages"] = [{"page": "/screen-recorder"}]
        with open(t.work_path("climb.json"), "w") as f:
            json.dump(doc, f)
        c, ok = self.checks(self.good())
        self.assertEqual(c["Page is live and indexed"]["why"],
                         "skipped · only Google's pages are known, and /teleprompter is not one of them")
        self.assertTrue(ok)
        # A row with no Google status is unknown; only indexed False fails.
        t.work_save_pages({"pages": [{"path": "/teleprompter", "status": 200}]}, self.now)
        c, _ = self.checks(self.good())
        self.assertEqual(c["Page is live and indexed"]["why"],
                         "skipped · /teleprompter is on the site; its Google status is not known")

    def test_an_old_page_list_is_not_used(self):
        t.work_save_pages({"pages": [{"path": "/linkedin-video", "status": 200, "indexed": False}]},
                          self.now - timedelta(days=3))
        c, _ = self.checks(self.good(page="/linkedin-video"))
        self.assertIsNone(c["Page is live and indexed"]["pass"])
        t.work_save_pages({"pages": [{"path": "/linkedin-video", "status": 200, "indexed": False}]},
                          self.now - timedelta(days=1))
        self.assertFalse(self.checks(self.good(page="/linkedin-video"))[0]["Page is live and indexed"]["pass"])

    def test_same_topic_on_the_same_lever_is_a_repeat(self):
        # T-8 and T-9 (real questions): other pages, other questions, one topic.
        t8 = self.board_step("T-8", title="Answer “CapCut alternative for talking-head videos on Mac” on /capcut-alternative",
                             page="/capcut-alternative",
                             targets=[{"type": "question", "value": "What is a good alternative to CapCut for talking-head videos on a Mac?"}])
        t9 = self.good(title="Answer “best Mac app for talking heads with a teleprompter”", page="/webcam-teleprompter",
                       targets=[{"type": "question", "value": "What is the best Mac app for recording talking-head videos with a teleprompter?"}])
        c, _ = self.checks(t9, [t8])
        self.assertTrue(c["Not a repeat"]["why"].startswith("T-8 is open on the same topic"), c["Not a repeat"])
        # Another lever, or another topic (T-10's screen recorder), is no repeat.
        c, _ = self.checks(t9, [dict(t8, lever="named")])
        self.assertTrue(c["Not a repeat"]["pass"])
        c, _ = self.checks(self.good(targets=[{"type": "question", "value": "What is the best screen recorder with camera for Mac?"}]), [t8])
        self.assertTrue(c["Not a repeat"]["pass"])

    def test_recheck_leaves_old_steps_without_lift_why(self):
        legacy = self.board_step("T-7", lift=2, confidence=0.55, effort=3)
        legacy.pop("lift_why")
        self.put(legacy, self.board_step("T-9", title="Best alternative page", page=""))
        out = t.work_recheck_proposed(self.now)
        self.assertEqual([r["id"] for r in out], ["T-9"])
        self.assertEqual(self.ticket("T-7")["state"], "proposed")
        t9 = self.ticket("T-9")
        self.assertEqual((t9["skipped_by"], [c["name"] for c in t9["recheck"]["checks"]]),
                         ("recheck", ["Evidence matches", "Page is live and indexed", "Not a repeat"]))

    def test_looked_keeps_every_page_already_answers_reason(self):
        t.work_fetch_page = lambda url: "Teleprompter for Mac page text"
        calls = self.gemini()

        def fake(system, ask, **kw):
            if system == t.WORK_PAGE_READ_SYSTEM:
                answers = "/teleprompter" in ask
                return json.dumps({"answers": answers, "now": "It answers it already." if answers else "It does not.",
                                   "new": "x"})
            if "One agent can finish this in one ticket" in ask:
                return json.dumps([{"pass": True, "why": "one page"}])
            n = sum(1 for line in ask.splitlines() if line[:3].rstrip(". ").isdigit())
            return json.dumps([{"pass": True, "why": "ok"}] * n)
        t.gemini_text = fake
        got = t.t_propose_steps({"steps": [self.good(), self.good(
            title="Answer the webcam question on its page", page="/webcam-teleprompter",
            targets=[{"type": "question", "value": Q2}], why="3 of 3 assistants name Descript, not Takes.",
            lead={"name": "AI answers", "now": "0 of 3", "expect": "1 of 3"})]})
        self.assertEqual(len(got["filed"]), 1)
        with open(t.work_path("looked.json")) as f:
            looked = json.load(f)
        self.assertNotIn("nothing", looked)
        self.assertEqual(looked["answered"], ["/teleprompter already answers “%s”. It answers it already." % Q])
        del calls


if __name__ == "__main__":
    unittest.main()


@unittest.skipUnless(hasattr(t, "work_code_checks"), "admin only")
class PageSlop(unittest.TestCase):
    """2026-10-20: check_draft linted pages with the comment rules (at most 6 sentences), so no page could pass."""

    def test_page_uses_long_form_rules_and_reply_uses_comment_rules(self):
        seen = []
        real = t.lint_comment
        t.lint_comment = lambda text, platform="comment": seen.append(platform)
        try:
            page = "<html><title>Free Descript alternative for Mac</title><body><main>" + \
                   "<p>Takes for Mac is a free Descript alternative. It cuts silences.</p>" * 10 + "</main></body></html>"
            t.work_code_checks("page", page, {"question": "free Descript alternative for Mac"})
            t.work_code_checks("reply", "Thanks, that is fixed in the next build.", {})
        finally:
            t.lint_comment = real
        self.assertEqual(seen, ["eng-blog", "comment"])
