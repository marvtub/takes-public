"""Higgsfield: a job starts at once, runs detached, lands in generated/ and on its storyboard shot."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

# A stand-in CLI: records its args, then prints a job like `generate create --wait --json`, or fails.
FAKE = r"""
import json, os, sys
root = os.environ["HF_FAKE_DIR"]
open(os.path.join(root, "args.json"), "w").write(json.dumps(sys.argv[1:]))
if sys.argv[1:3] == ["account", "status"]:
    print("me@example.com — Basic plan, 120 credits")
    sys.exit(0)
if os.path.exists(os.path.join(root, "fail")):
    print("Error: Session expired.", file=sys.stderr)
    sys.exit(1)
out = os.path.join(root, "result.mp4")
open(out, "wb").write(b"fake mp4")
print(json.dumps([{"id": "job1", "status": "completed",
                   "result": {"preview": "https://higgsfield.ai/job/job1", "url": "file://" + out}}]))
"""


class Higgsfield(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["HF_FAKE_DIR"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-06-idea")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-06T00:00:00Z", "named": True, "takes": []})
        fake = os.path.join(self.root, "fake_hf.py")
        open(fake, "w").write(FAKE)
        os.environ["TAKES_HIGGSFIELD_CMD"] = json.dumps([sys.executable, fake])
        self.started = []
        t.start_higgsfield = lambda s, p: self.started.append(p)  # tests run the job in the foreground
        t.start_sketches = lambda s: None

    def tearDown(self):
        for k in ("TAKES_ROOT", "TAKES_HIGGSFIELD_CMD", "HF_FAKE_DIR"):
            os.environ.pop(k, None)

    def args(self):
        return json.load(open(os.path.join(self.root, "args.json")))

    def board(self):
        shots = [{"kind": "B-ROLL", "say": "Receipts pile up every single month.", "sketch": "A shoebox of receipts.",
                  "do": "Close-up, slow push in."}]
        t.t_set_storyboard({"session": self.s, "shots": shots, "format": "9:16"})
        d = t.read_storyboard(self.s)
        d["shots"][0]["image"] = "sketch.png"
        t.write_storyboard(self.s, d)
        open(os.path.join(self.s, "storyboard", "sketch.png"), "wb").write(b"png")
        return d["shots"][0]["id"]

    def test_a_shot_clip_lands_on_the_shot(self):
        sid = self.board()
        r = t.t_higgsfield({"session": self.s, "shot": sid, "prompt": "Real footage of a shoebox of receipts.",
                            "image": "sketch", "params": {"mode": "omni_reference"}})
        self.assertEqual(r["file"], os.path.join("generated", "shot-%s-v1.mp4" % sid))
        self.assertEqual(r["model"], "seedance_2_5")
        self.assertEqual(t.read_storyboard(self.s)["shots"][0]["generating"], r["file"])
        self.assertEqual(t.storyboard_view(self.s)["list"][0]["generating"], r["file"])
        t.higgsfield_run(self.s, self.started[0])
        a = self.args()
        self.assertEqual(a[:3], ["generate", "create", "seedance_2_5"])
        self.assertEqual(a[a.index("--aspect_ratio") + 1], "9:16")  # the storyboard format
        self.assertEqual(a[a.index("--duration") + 1], "4")  # 6 words: the 4 s minimum
        self.assertTrue(a[a.index("--image") + 1].endswith("storyboard/sketch.png"))
        self.assertEqual(a[a.index("--mode") + 1], "omni_reference")
        self.assertIn("--wait", a)
        shot = t.read_storyboard(self.s)["shots"][0]
        self.assertEqual(shot["video"], r["file"])
        self.assertNotIn("generating", shot)
        self.assertEqual(open(os.path.join(self.s, r["file"]), "rb").read(), b"fake mp4")
        self.assertEqual(t.t_higgsfield_status({"session": self.s})["jobs"][0]["status"], "done")

    def test_a_failure_says_why_and_how_to_fix_it(self):
        sid = self.board()
        open(os.path.join(self.root, "fail"), "w").close()
        t.t_higgsfield({"session": self.s, "shot": sid, "prompt": "Receipts."})
        t.higgsfield_run(self.s, self.started[0])
        shot = t.read_storyboard(self.s)["shots"][0]
        self.assertNotIn("generating", shot)
        self.assertNotIn("video", shot)
        self.assertIn("Session expired", shot["clip_error"])
        self.assertIn("Plugins › Higgsfield", shot["clip_error"])
        self.assertEqual(t.hf_jobs(self.s)[0]["status"], "error")

    def test_a_storyboard_rewrite_keeps_the_running_clip(self):
        sid = self.board()
        t.t_higgsfield({"session": self.s, "shot": sid, "prompt": "Receipts."})
        d = t.read_storyboard(self.s)["shots"][0]
        t.t_set_storyboard({"session": self.s, "shots": [{"id": sid, "kind": "B-ROLL", "say": d["say"],
                                                           "sketch": d["sketch"], "do": "Wider."}]})
        self.assertTrue(t.read_storyboard(self.s)["shots"][0].get("generating"))

    def test_reframe_a_session_video(self):
        os.makedirs(os.path.join(self.s, "edits"))
        open(os.path.join(self.s, "edits", "cut-v1.mp4"), "wb").write(b"v")
        r = t.t_higgsfield({"session": self.s, "workflow": "reframe", "video": "edits/cut-v1.mp4",
                            "aspect_ratio": "9:16", "name": "cut vertical"})
        self.assertEqual(r["file"], os.path.join("generated", "cut-vertical-v1.mp4"))
        t.higgsfield_run(self.s, self.started[0])
        a = self.args()
        self.assertEqual(a[:3], ["generate", "workflow", "reframe"])
        self.assertEqual(a[a.index("--aspect-ratio") + 1], "9:16")
        self.assertNotIn("--prompt", a)
        r2 = t.t_higgsfield({"session": self.s, "workflow": "reframe", "video": "edits/cut-v1.mp4",
                             "aspect_ratio": "9:16", "name": "cut vertical"})
        self.assertTrue(r2["file"].endswith("cut-vertical-v2.mp4"))

    def test_bad_input_is_refused_before_any_credit_is_spent(self):
        with self.assertRaisesRegex(ValueError, "prompt"):
            t.t_higgsfield({"session": self.s})
        with self.assertRaisesRegex(ValueError, "No shot"):
            t.t_higgsfield({"session": self.s, "shot": "zz", "prompt": "x"})
        with self.assertRaisesRegex(ValueError, "not inside the session"):
            t.t_higgsfield({"session": self.s, "prompt": "x", "image": "/etc/hosts"})
        self.assertEqual(self.started, [])

    def test_not_installed(self):
        os.environ.pop("TAKES_HIGGSFIELD_CMD")
        t.higgsfield_cli, real = (lambda: None), t.higgsfield_cli
        try:
            self.assertFalse(t.t_higgsfield_status({})["installed"])
            with self.assertRaisesRegex(ValueError, "Plugins › Higgsfield"):
                t.t_higgsfield({"session": self.s, "prompt": "x"})
        finally:
            t.higgsfield_cli = real

    def test_status_reads_the_account(self):
        st = t.t_higgsfield_status({})
        self.assertTrue(st["signed_in"])
        self.assertIn("credits", st["account"])

    def test_the_result_url_prefers_a_media_file(self):
        out = json.dumps({"page": "https://higgsfield.ai/x", "result": {"raw": "https://cdn.x/a.mp4?sig=1"}})
        self.assertEqual(t.hf_result_url(out, "video"), "https://cdn.x/a.mp4?sig=1")
        self.assertEqual(t.hf_result_url("Done: https://cdn.x/b.png\n", "image"), "https://cdn.x/b.png")


if __name__ == "__main__":
    unittest.main()
