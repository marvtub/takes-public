"""take_cut: Gemini (stand-in) picks the best range of a storyboard take; get_session shows it."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"


class TakeCut(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-03-shot")
        os.makedirs(os.path.join(self.s, "storyboard"))
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x96:d=4", "-y",
                        os.path.join(self.s, "take-01-hook-1-camera.mov")], check=True)
        t.write_meta(self.s, {"title": "Shot", "createdAt": "2026-10-03T00:00:00Z", "named": True,
                              "takes": [{"number": 1, "kind": "camera", "file": "take-01-hook-1-camera.mov",
                                         "startedAt": "2026-10-03T00:00:00Z", "duration": 4, "shot": "s1"}]})
        json.dump({"shots": [{"id": "s1", "section": "hook", "kind": "DESK", "say": "I do my books with an agent."}]},
                  open(os.path.join(self.s, "storyboard", "storyboard.json"), "w"))
        fake = os.path.join(self.root, "fake.py")
        open(fake, "w").write('import json\nprint(json.dumps({"start": 1.2, "end": 9.5, "clean": True, "why": "second try"}))\n')
        os.environ["TAKES_DESCRIBE_CMD"] = json.dumps([sys.executable, fake])
        self.wait, t.TRANSCRIPT_WAIT = t.TRANSCRIPT_WAIT, 0

    def tearDown(self):
        t.TRANSCRIPT_WAIT = self.wait
        shutil.rmtree(self.root)
        for k in ("TAKES_ROOT", "TAKES_DESCRIBE_CMD"):
            os.environ.pop(k, None)

    def test_cut_is_kept_within_the_take(self):
        t.take_cut(self.s, "1")
        c = t.read_cuts(self.s)["1"]
        self.assertEqual(c["state"], "done", c.get("error"))
        self.assertEqual(c["start"], 1.2)
        self.assertAlmostEqual(c["end"], 4.0, places=1)  # clamped to the take's length
        self.assertNotIn("pid", c)
        take = t.t_get_session({"session": self.s})["takes"][0]
        self.assertEqual(take["best_cut"]["why"], "second try")
        self.assertNotIn("cuts.json", [a["file"] for a in t.t_get_session({"session": self.s})["assets"]])

    def test_agent_changes_the_suggestion(self):
        t.take_cut(self.s, "1")
        self.assertEqual(t.read_cuts(self.s)["1"]["by"], "gemini")
        out = t.t_set_best_cut({"session": self.s, "take": 1, "start": 0.5, "end": 3.1,
                                "why": "Word times show the first try is clean."})["best_cut"]
        self.assertEqual((out["by"], out["start"], out["end"]), ("agent", 0.5, 3.1))
        self.assertEqual(out["gemini"]["start"], 1.2)
        out = t.t_set_best_cut({"session": self.s, "take": 1, "start": 0.6, "end": 3.0, "why": "Tighter."})["best_cut"]
        self.assertEqual(out["gemini"]["start"], 1.2)  # Gemini's first range stays
        with self.assertRaises(ValueError):
            t.t_set_best_cut({"session": self.s, "take": 1, "start": 5, "end": 6, "why": "x"})

    def test_failure_is_written(self):
        os.environ["TAKES_DESCRIBE_CMD"] = json.dumps(["/usr/bin/false"])
        t.take_cut(self.s, "1")
        self.assertEqual(t.read_cuts(self.s)["1"]["state"], "failed")

    def words(self, ws):
        with open(os.path.join(self.s, "take-01-hook-1-camera.words.json"), "w") as f:
            json.dump({"words": [{"word": w, "start": a, "end": b} for w, a, b in ws]}, f)

    def test_gemini_edges_snap_to_the_words(self):
        # Gemini's 1.2-9.5 starts inside "I" (1.1-1.3); the cut moves to just before it and after "agent."
        self.words([("I", 1.1, 1.3), ("do", 1.3, 1.5), ("my", 1.5, 1.7), ("books", 1.7, 2.0), ("with", 2.0, 2.2),
                    ("an", 2.2, 2.3), ("agent.", 2.3, 2.8)])
        t.take_cut(self.s, "1")
        c = t.read_cuts(self.s)["1"]
        self.assertEqual((c["start"], c["end"], c["by"]), (1.02, 3.0, "gemini"))

    def test_no_key_picks_from_the_transcript(self):
        os.environ.pop("TAKES_DESCRIBE_CMD")
        key, t.gemini_key = t.gemini_key, lambda: None
        try:
            # First try stumbles ("my my"), second is clean: the second wins.
            self.words([("I", 0.1, 0.2), ("do", 0.2, 0.4), ("my", 0.4, 0.6), ("my", 0.6, 0.8), ("books", 0.8, 1.0),
                        ("I", 1.6, 1.7), ("do", 1.7, 1.9), ("my", 1.9, 2.1), ("books", 2.1, 2.4), ("with", 2.4, 2.6),
                        ("an", 2.6, 2.7), ("agent.", 2.7, 3.2)])
            t.take_cut(self.s, "1")
        finally:
            t.gemini_key = key
        c = t.read_cuts(self.s)["1"]
        self.assertEqual(c["state"], "done", c.get("error"))
        self.assertEqual((c["by"], c["start"], c["end"], c["clean"]), ("transcript", 1.52, 3.4, True))
        self.assertIn("attempt 2 of 2", c["why"])
        out = t.t_set_best_cut({"session": self.s, "take": 1, "start": 1.5, "end": 3.3, "why": "Checked."})["best_cut"]
        self.assertEqual(out["gemini"]["start"], 1.52)  # the transcript's first range stays too

    def test_gemini_fails_then_the_transcript(self):
        os.environ["TAKES_DESCRIBE_CMD"] = json.dumps(["/usr/bin/false"])
        self.words([("I", 0.5, 0.6), ("do", 0.6, 0.8), ("my", 0.8, 1.0), ("books", 1.0, 1.3)])
        t.take_cut(self.s, "1")
        c = t.read_cuts(self.s)["1"]
        self.assertEqual((c["state"], c["by"], c["clean"]), ("done", "transcript", False))
        self.assertIn("Gemini failed", c["why"])

    def test_broll_without_lines_takes_the_middle(self):
        out = t.transcript_cut([], "", 2, 10.0)
        self.assertEqual((out["start"], out["end"]), (4.0, 6.0))


if __name__ == "__main__":
    unittest.main()
