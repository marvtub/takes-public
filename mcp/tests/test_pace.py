"""Pace: how often a video cuts, kept in a style from its source, and check_edit holding edits to it."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


def shots(path, colours, each):
    """A small video of solid colour shots, each `each` seconds: a hard cut between them."""
    ins = []
    for c in colours:
        ins += ["-f", "lavfi", "-i", "color=c=%s:s=128x72:r=30:d=%g" % (c, each)]
    n = len(colours)
    subprocess.run([t.need_ffmpeg(), "-v", "error", "-y"] + ins + [
        "-filter_complex", "".join("[%d:v]" % i for i in range(n)) + "concat=n=%d:v=1:a=0[v]" % n,
        "-map", "[v]", "-pix_fmt", "yuv420p", path], check=True, capture_output=True)


class Pace(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-11-04-test")
        os.makedirs(os.path.join(self.s, "edits"))
        t.write_meta(self.s, t.read_meta(self.s))
        os.makedirs(os.path.join(self.root, "_library", "styles", "Magazine"))

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_a_cut_stands_far_above_the_changes_around_it(self):
        diffs = [2.0] * 80
        diffs[20] = diffs[21] = 40.0   # a two-frame whip: one cut
        diffs[50] = 30.0
        diffs[65] = 9.0                # a move, not a cut
        self.assertEqual(t.cut_times(diffs), [2.0, 5.0])
        self.assertEqual(t.pace_numbers([2.0, 5.0], 8.0)["longest_hold_s"], 3.0)
        self.assertEqual(t.pace_numbers([2.0, 5.0], 8.0)["longest_at"], 2.0)

    def test_measure_pace_keeps_it_in_the_style(self):
        src = os.path.join(self.root, "source.mp4")
        shots(src, ["red", "blue", "green", "white"], 1.5)
        got = t.t_measure_pace({"file": src})
        self.assertEqual((got["cuts"], got["cuts_per_min"], got["longest_hold_s"]), (3, 30.0, 1.5))
        self.assertNotIn("style", got)
        t.t_measure_pace({"file": src, "style": "Magazine"})
        card = next(x for x in t.t_get_library({})["styles"] if x["name"] == "Magazine")
        self.assertEqual((card["pace"]["cuts_per_min"], card["pace"]["source"]), (30.0, "source.mp4"))
        with self.assertRaises(ValueError):
            t.t_measure_pace({"file": src, "style": "Nope"})

    def test_check_edit_holds_an_edit_to_its_styles_pace(self):
        meta = os.path.join(self.root, "_library", "styles", "Magazine", "style.json")
        edit = os.path.join(self.s, "edits", "cut-v1.mp4")
        shots(edit, ["red", "blue"], 8)    # one cut in 16 s: 3.8 a minute, an 8 s hold
        self.assertIsNone(t.style_pace(self.s)[1])
        ctx = {"s": self.s, "path": edit}
        with open(meta, "w") as f:
            json.dump({"pace": {"cuts_per_min": 4, "longest_hold_s": 8}}, f)
        self.assertIsNone(t.chk_style_pace(ctx)[2])
        with open(meta, "w") as f:
            json.dump({"pace": {"cuts_per_min": 20, "longest_hold_s": 3}}, f)
        value, at, say, extra = t.chk_style_pace(ctx)
        self.assertIn("Magazine cuts 20", say)
        self.assertIn("Never add zooms", extra["fix"])
        with open(meta, "w") as f:
            json.dump({"pace": {"cuts_per_min": 4, "longest_hold_s": 3}}, f)
        value, at, say, extra = t.chk_style_pace(ctx)
        self.assertIn("holds 8 s", say)
        self.assertEqual(at, [0.0])

    def test_new_style_steps_measure_first_and_compare_once(self):
        steps = t.t_create_style({"name": "Bold", "description": "Big yellow type"})["next"]
        self.assertIn("measure_pace style='Bold'", steps[0])
        self.assertTrue(any(x.startswith("Compare once") for x in steps))


if __name__ == "__main__":
    unittest.main()
