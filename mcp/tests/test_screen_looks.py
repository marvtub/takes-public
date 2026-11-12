"""Screen + camera looks (2026-10-30), both opt in: a picture layer that steps aside in the pauses
(over[i].hide_in_silence) and a crop that follows the face (frame.crop.follow_face). A cut of the screen file
borrows the camera file's words, moved by the lag of the two files' sound."""
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import takes_mcp as t  # noqa: E402
from test_edit_recipe import Base, rgb_at  # noqa: E402
from test_edit_ready import ff  # noqa: E402


def W(*spans):
    return [{"word": "w", "start": a, "end": b} for a, b in spans]


def at(keys, i, x):
    """The value of follow_expr's expression at t = x, worked out in Python."""
    return eval(t.follow_expr(keys, i).replace("if(", "iff("),
                {"iff": lambda c, a, b: a if c else b, "lt": lambda a, b: float(a < b), "t": x})


class Silence(unittest.TestCase):
    def test_a_long_pause_hides_the_layer_and_a_short_one_does_not(self):
        shown = t.silence_shown(W((1, 3), (5, 7), (7.8, 9)), 0, 10)
        # Silence 0-1 at the start: hidden until it is back 0.15 s before the first word.
        # 3-5 (2 s): out from 3.6 (0.3 after + 0.3 fade), back in by 4.85. 7-7.8: too short.
        self.assertEqual([(round(a, 2), round(b, 2)) for a, b in shown], [(0.55, 3.6), (4.55, 9.6)])

    def test_the_end_after_the_last_word_is_hidden(self):
        shown = t.silence_shown(W((0, 2)), 0, 6)
        self.assertEqual([(round(a, 2), round(b, 2)) for a, b in shown], [(0, 2.6)])

    def test_no_words_keeps_it_shown(self):
        self.assertEqual(t.silence_shown([], 2, 8), [(2, 8)])

    def test_only_the_layers_own_window_counts(self):
        shown = t.silence_shown(W((0, 1), (9, 10)), 4, 6)
        self.assertEqual(shown, [])


class Follow(unittest.TestCase):
    CROP = {"x": 100, "y": 100, "w": 400, "h": 400}

    def samples(self, path):
        return [(i * t.FOLLOW_EVERY, cx, cy) for i, (cx, cy) in enumerate(path)]

    def test_a_still_face_gives_a_still_crop(self):
        keys = t.follow_keys(self.samples([(500, 400)] * 20), [(0, 10, "camera")], self.CROP, (1920, 1080))
        self.assertEqual(len(keys), 2)
        self.assertEqual(keys[0][1:], keys[1][1:])
        self.assertEqual(keys[0][1], 300)  # the face in the middle across

    def test_a_small_drift_stays_and_a_big_one_pans_smoothly(self):
        path = [(500, 400)] * 10 + [(510, 400)] * 10 + [(800, 400)] * 20
        keys = t.follow_keys(self.samples(path), [(0, 20, "camera")], self.CROP, (1920, 1080))
        xs = [round(at(keys, 1, x / 10.0)) for x in range(0, 200)]
        self.assertEqual(set(xs[:80]), {300})  # 10 px is inside the slack (the median looks 1 s ahead)
        self.assertEqual(xs[-1], 600)
        steps = [b - a for a, b in zip(xs, xs[1:])]
        self.assertTrue(all(s >= 0 for s in steps), steps)  # one way, no back and forth
        self.assertLess(max(steps), 40)  # no jump: at most 40 px in 0.1 s

    def test_the_crop_stays_inside_the_take_and_keeps_its_size(self):
        path = [(30, 1000)] * 10
        keys = t.follow_keys(self.samples(path), [(0, 5, "camera")], self.CROP, (1920, 1080))
        self.assertEqual(keys[0][1:], (0, 680))
        self.assertTrue(t.crop_filter(self.CROP, keys).startswith("crop=w=400:h=400:"))

    def test_a_screen_part_keeps_the_recipes_crop(self):
        path = [(900, 500)] * 20
        keys = t.follow_keys(self.samples(path), [(0, 4, "screen"), (4, 10, "camera")], self.CROP, (1920, 1080))
        self.assertEqual(keys[0], (0, 100, 100))
        self.assertEqual(at(keys, 1, 2.0), 100)
        self.assertEqual(at(keys, 1, 5.0), 700)

    def test_without_keys_the_crop_is_the_plain_one(self):
        self.assertEqual(t.crop_filter(self.CROP), "crop=400:400:100:100,")


class Recipe(Base):
    def test_the_options_are_kept_and_render_plan_uses_them(self):
        self.add_take()
        self.clip("_edit/hook/bubble.mov", secs=4, color="red")
        r = t.norm_recipe(self.s, {"name": "hook", "cut": [{"take": 1, "in": 0, "out": 4}],
                                   "frame": {"crop": {"x": 0, "y": 0, "w": 100, "h": 100, "follow_face": True}},
                                   "over": [{"file": "_edit/hook/bubble.mov", "at": 0, "hide_in_silence": True}]})
        self.assertTrue(r["frame"]["crop"]["follow_face"])
        self.assertTrue(r["over"][0]["hide_in_silence"])
        t.fill_recipe(self.s, r)
        p = " ".join(t.render_plan(self.s, r, "TMP", "OUT.mp4", {
            "length": 4.0, "words": W((0.2, 1.0), (3.0, 3.8)), "over": {"_edit/hook/bubble.mov": 4.0},
            "follow": [(0, 0, 0), (2, 10, 0)]})["picture"])
        self.assertIn("crop=w=100:h=100:x='", p)
        self.assertIn("split=2", p)
        self.assertIn("fade=t=out:st=1.300:d=0.300:alpha=1", p)
        self.assertIn("fade=t=in:st=2.550:d=0.300:alpha=1", p)

    def test_the_layer_is_gone_in_the_pause_of_a_real_render(self):
        self.add_take()
        self.clip("_edit/hook/bubble.mov", size="160x120", secs=6, color="red")
        r = t.norm_recipe(self.s, {"name": "hook", "cut": [{"take": 1, "in": 0, "out": 6}],
                                   "over": [{"file": "_edit/hook/bubble.mov", "at": 0, "hide_in_silence": True}]})
        t.fill_recipe(self.s, r)
        tmp = tempfile.mkdtemp(dir=self.root)
        ff("-f", "lavfi", "-i", "color=blue:s=%dx%d:r=%d:d=6" % (r["frame"]["w"], r["frame"]["h"], r["frame"]["fps"]),
           "-c:v", "libx264", "-pix_fmt", "yuv420p", os.path.join(tmp, "cut.mov"))
        plan = t.render_plan(self.s, r, tmp, os.path.join(tmp, "out.mp4"), {
            "length": 6.0, "words": W((0.0, 1.5), (4.5, 6.0)), "over": {"_edit/hook/bubble.mov": 6.0}})
        subprocess.run(plan["picture"], check=True, capture_output=True)
        pic = os.path.join(tmp, "picture.mp4")
        red, blue = rgb_at(pic, 0.8), rgb_at(pic, 3.0)
        self.assertGreater(red[0], 200, red)   # said: the layer
        self.assertGreater(blue[2], 200, blue)  # the pause: the cut under it
        self.assertLess(blue[0], 60, blue)
        self.assertGreater(rgb_at(pic, 5.0)[0], 200)  # back for the next words

    def test_a_screen_cut_borrows_the_camera_words_moved_by_the_lag(self):
        self.add_take()
        self.add_take(kind="screen")
        cam = os.path.join(self.s, "take-01-camera.words.json")
        t.write_json(cam, {"v": 2, "clock": "video", "words": [{"word": "hi", "start": 1.0, "end": 1.4}]})
        real = t.screen_lag_measured
        t.screen_lag_measured = lambda s, n: 0.25
        try:
            if not t.is_ready(t.words_doc(os.path.join(self.s, "take-01-camera.mov"))):
                self.skipTest("this words file is not ready in this copy")
            self.assertEqual(t.screen_lag(self.s, 1, measure=False), None)
            doc, lag = t.take_words(self.s, 1, "screen")
            self.assertEqual(lag, 0.25)
            self.assertEqual(doc["words"][0]["word"], "hi")
            self.assertEqual(t.screen_lag(self.s, 1, measure=False), 0.25)  # cached
            shown = [x for x in t.t_get_session({"session": self.s})["takes"] if x["kind"] == "screen"][0]
            self.assertEqual(shown["screen_lag_s"], 0.25)
        finally:
            t.screen_lag_measured = real


if __name__ == "__main__":
    unittest.main()
