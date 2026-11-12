"""The pointer (2026-10-30): screen takes that left the pointer out of their video get it drawn back by
render_edit from the cursor log, where it was by default, with opt-in smooth and hide_idle."""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = shutil.which("ffmpeg")

EV = {"v": 1, "size": [400, 200], "scale": 2, "pointer": False,
      "arrow": {"png": "", "hot": [5, 5], "size": [28, 40], "zoom": 1},
      "moves": [[0, 100, 50], [1.0, 200, 50], [1.5, 300, 150]],
      "clicks": [{"t": 1.0, "x": 200, "y": 50, "button": "left", "down": True},
                 {"t": 1.1, "x": 200, "y": 50, "button": "left", "down": False}]}


class Track(unittest.TestCase):
    def test_by_default_it_is_exactly_where_it_was(self):
        got = t.pointer_track(EV, [0.0, 0.99, 1.0, 1.4, 1.5, 9.0])
        self.assertEqual([(x, y) for x, y, _, _ in got], [(100, 50), (100, 50), (200, 50), (200, 50), (300, 150), (300, 150)])
        self.assertTrue(all(a == 1.0 and sh == 0 for _, _, a, sh in got))

    def test_smooth_eases_but_is_on_the_click_at_click_time(self):
        times = [i / 60.0 for i in range(180)]
        got = t.pointer_track(EV, times, smooth=True)
        click = got[60]
        self.assertEqual(click[:2], (200, 50))
        # Away from clicks it eases: halfway through the jump at 1.5 s it is between the two places.
        x = got[90][0]
        self.assertTrue(200 < x < 300, x)
        self.assertEqual(got[0][:2], (100, 50))

    def test_hide_idle_fades_after_two_still_seconds_and_comes_back_on_a_move(self):
        ev = dict(EV, moves=[[0, 10, 10], [5.0, 20, 20]], clicks=[])
        got = dict(zip([0.0, 1.9, 2.15, 2.5, 4.9, 5.0], t.pointer_track(ev, [0.0, 1.9, 2.15, 2.5, 4.9, 5.0], hide_idle=True)))
        self.assertEqual(got[1.9][2], 1.0)
        self.assertAlmostEqual(got[2.15][2], 0.5)
        self.assertEqual(got[2.5][2], 0.0)
        self.assertEqual(got[4.9][2], 0.0)
        self.assertEqual(got[5.0][2], 1.0)


class Fit(unittest.TestCase):
    def test_crop_and_cover_scale(self):
        k, dx, dy = t.pointer_fit((3456, 2234), (3456, 2234), {"x": 1300, "y": 100, "w": 1000, "h": 1778}, 1080, 1920)
        self.assertAlmostEqual(1837 * k + dx, 580.0, places=0)
        self.assertAlmostEqual(289 * k + dy, 204.1, places=0)

    def test_a_take_smaller_than_the_cut_is_scaled_and_padded_as_render_cut_does(self):
        # A 1000x1000 screen in a 2000x1000 cut: scale 1, padded 500 px left and right.
        k, dx, dy = t.pointer_fit((1000, 1000), (2000, 1000), None, 2000, 1000)
        self.assertEqual((k, dx, dy), (1.0, 500.0, 0.0))


class Layers(unittest.TestCase):
    def test_old_takes_and_takes_with_the_pointer_in_the_video_get_none(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        v = os.path.join(d, "take-01-screen.mov")
        self.assertIsNone(t.pointer_events(v))
        for doc in (dict(EV, pointer=True), {k: v for k, v in EV.items() if k != "pointer"}, dict(EV, arrow=None)):
            with open(os.path.join(d, "take-01-screen.events.json"), "w") as f:
                json.dump(doc, f)
            self.assertIsNone(t.pointer_events(v))
        with open(os.path.join(d, "take-01-screen.events.json"), "w") as f:
            json.dump(EV, f)
        self.assertEqual(t.pointer_events(v)["size"], [400, 200])

    def test_the_layer_moves_with_the_hot_spot_and_hides_outside_its_parts(self):
        part = {"start": 1.0, "len": 1.0, "in": 0.5, "ev": EV, "fit": (0.5, 0.0, 0.0)}
        (L,) = t.pointer_layers([part], 10, 3.0, {}, "pb")
        self.assertEqual((L["w"], L["h"]), (28, 40))  # 28 pt x 2 px/pt x 0.5
        lines = L["cmd"].splitlines()
        self.assertEqual(lines[0], "0.000 overlay@pb0_0 x -10000, overlay@pb0_0 y -10000;")
        # 0.5 s in the take = (100, 50) take px = (50, 25) edit px, minus the hot spot (5 pt = 5 px here).
        self.assertTrue(lines[1].startswith("0.9500 overlay@pb0_0 x 45, overlay@pb0_0 y 20, colorchannelmixer@pb0_0 aa 1.00;"), lines[1])
        self.assertIn("1.4500 overlay@pb0_0 x 95, overlay@pb0_0 y 20", L["cmd"])
        self.assertEqual(lines[-1], "1.9500 overlay@pb0_0 x -10000;")

    def test_each_shape_has_its_layer_and_only_one_shows(self):
        ev = dict(EV, shapes=[dict(EV["arrow"], png="a"), {"png": "b", "hot": [12, 11], "size": [23, 22], "zoom": 1}],
                  moves=[[0, 100, 50, 0], [1.0, 100, 50, 1], [2.0, 200, 50, 0]])
        self.assertEqual([x[3] for x in t.pointer_track(ev, [0.5, 1.5, 2.5])], [0, 1, 0])
        a, b = t.pointer_layers([{"start": 0.0, "len": 3.0, "in": 0.0, "ev": ev, "fit": (1.0, 0.0, 0.0)}], 10, 3.0, {}, "pb")
        self.assertEqual((a["name"], b["name"]), ("pb0_0", "pb0_1"))
        self.assertEqual((b["w"], b["h"], b["arrow"]["png"]), (46, 44, "b"))
        # At 1 s the arrow goes off and the I-beam comes on, its hot spot (12, 11) pt x 2 on the point.
        self.assertIn("0.9500 overlay@pb0_0 x -10000;", a["cmd"])
        self.assertIn("0.9500 overlay@pb0_1 x 76, overlay@pb0_1 y 28", b["cmd"])
        self.assertIn("1.9500 overlay@pb0_1 x -10000;", b["cmd"])
        # A shape id the log does not have draws the arrow.
        self.assertEqual(t.pointer_track(dict(ev, moves=[[0, 1, 1, 7]]), [0.0])[0][3], 0)

    def test_recipe_options(self):
        self.assertIn("pointer", t.AGENT_FIELDS)

    def test_look_none_draws_no_pointer(self):
        # 2026-10-31: the cursor-looks effect draws its own pointer over the edit.
        part = {"start": 0.0, "len": 1.0, "in": 0.0, "ev": EV, "fit": (1.0, 0.0, 0.0)}
        self.assertEqual(t.pointer_layers([part], 10, 1.0, {"look": "none"}, "pb"), [])


@unittest.skipUnless(FFMPEG, "no ffmpeg")
class Render(unittest.TestCase):
    def test_render_plan_draws_the_arrow_where_the_log_says(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        # A white square "arrow" with its hot spot at its top-left, on a blue cut.
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=white:s=8x8", "-frames:v", "1",
                        os.path.join(d, "a.png")], check=True)
        with open(os.path.join(d, "a.png"), "rb") as f:
            png = base64.b64encode(f.read()).decode()
        ev = dict(EV, arrow={"png": png, "hot": [0, 0], "size": [10, 10], "zoom": 1}, moves=[[0, 20, 20], [1.0, 300, 120]])
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=blue:s=400x200:r=30:d=2", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", os.path.join(d, "cut.mov")], check=True)
        r = {"frame": {"w": 400, "h": 200, "fps": 30}, "over": []}
        layers = t.pointer_write(t.pointer_layers(
            [{"start": 0.0, "len": 2.0, "in": 0.0, "ev": ev, "fit": t.pointer_fit((400, 200), (400, 200), None, 400, 200)}],
            30, 2.0, {}, "pb"), d)
        plan = t.render_plan(d, r, d, os.path.join(d, "out.mp4"), {"length": 2.0, "pointer": {"base": layers}})
        subprocess.run(plan["picture"], check=True, capture_output=True)

        def px(sec, x, y):
            raw = subprocess.run([FFMPEG, "-v", "error", "-ss", "%.3f" % sec, "-i", os.path.join(d, "picture.mp4"),
                                  "-frames:v", "1", "-vf", "format=rgb24,crop=2:2:%d:%d" % (x, y), "-f", "rawvideo", "-pix_fmt",
                                  "rgb24", "-"], capture_output=True).stdout
            return tuple(raw[:3])
        self.assertGreater(min(px(0.5, 30, 30)), 200)  # the arrow (20 pt x 2 px/pt = 20 px wide from 20, 20)
        self.assertLess(px(0.5, 310, 130)[0], 80)      # not yet at its later place
        self.assertGreater(min(px(1.5, 310, 130)), 200)
        self.assertLess(px(1.5, 30, 30)[0], 80)



@unittest.skipUnless(FFMPEG, "no ffmpeg")
class Clips(unittest.TestCase):
    """cut_take/rough_cut clips and the split-screen effect's screen cut draw the pointer too."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        a = os.path.join(self.d, "a.png")
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=white:s=8x8", "-frames:v", "1", a], check=True)
        with open(a, "rb") as f:
            png = base64.b64encode(f.read()).decode()
        self.take = os.path.join(self.d, "take-01-screen.mov")
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=blue:s=400x200:r=30:d=4", "-f", "lavfi",
                        "-i", "sine=d=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", self.take], check=True)
        with open(os.path.join(self.d, "take-01-screen.events.json"), "w") as f:
            json.dump(dict(EV, arrow={"png": png, "hot": [0, 0], "size": [10, 10], "zoom": 1},
                           moves=[[0, 20, 20], [2.0, 300, 120]]), f)

    def px(self, path, sec, x, y):
        raw = subprocess.run([FFMPEG, "-v", "error", "-ss", "%.3f" % sec, "-i", path, "-frames:v", "1", "-vf",
                              "format=rgb24,crop=2:2:%d:%d" % (x, y), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                             capture_output=True).stdout
        return tuple(raw[:3])

    def test_the_takes_screen_step_cuts_with_the_pointer(self):
        t.screen_step(["take-01-screen.mov", "1.5", "1.0", "out/screen.mp4", "30"], self.d)
        out = os.path.join(self.d, "out", "screen.mp4")
        self.assertGreater(min(self.px(out, 0.2, 30, 30)), 200)  # take 1.7 s: at (20, 20), 20 px wide
        self.assertGreater(min(self.px(out, 0.8, 310, 130)), 200)  # take 2.3 s: moved
        self.assertLess(self.px(out, 0.8, 30, 30)[0], 80)

    def test_a_cut_clip_gets_the_pointer_and_keeps_its_sound(self):
        clip = os.path.join(self.d, "clip.part.mp4")
        subprocess.run([FFMPEG, "-v", "error", "-ss", "1.5", "-t", "1", "-i", self.take, "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-c:a", "aac", clip], check=True)
        c = t.take_clock(self.take)
        t.pointer_pass(clip, [{"take": 1, "kind": "screen", "in": 1.5, "out": 2.5}], [self.take], [c])
        self.assertGreater(min(self.px(clip, 0.2, 30, 30)), 200)
        self.assertGreater(min(self.px(clip, 0.8, 310, 130)), 200)
        streams = subprocess.run([FFMPEG, "-v", "error", "-i", clip, "-map", "0:a", "-f", "null", "-"], capture_output=True)
        self.assertEqual(streams.returncode, 0)
        # A camera part is left alone.
        before = os.path.getmtime(clip)
        t.pointer_pass(clip, [{"take": 1, "kind": "camera", "in": 1.5, "out": 2.5}], [self.take], [c])
        self.assertEqual(os.path.getmtime(clip), before)


class Keys(unittest.TestCase):
    """Shortcuts (2026-10-30): recipe keys: true shows the logged ones as badges."""

    def test_badges_follow_the_cut_and_end_at_the_next_key(self):
        keys = [{"t": 1.0, "keys": "⌘K"}, {"t": 1.5, "keys": "↩"}, {"t": 9.0, "keys": "⌘S"}, {"t": 20.0, "keys": "⌘Q"}]
        parts = [{"start": 0.5, "len": 2.0, "in": 0.5, "keys": keys}, {"start": 2.5, "len": 2.0, "in": 8.5, "keys": keys}]
        self.assertEqual(t.key_badges(parts, 4.5), {"⌘K": [(1.0, 1.5)], "↩": [(1.5, 2.7)], "⌘S": [(3.0, 4.2)]})

    def test_the_recipe_option(self):
        self.assertIn("keys", t.AGENT_FIELDS)

    @unittest.skipUnless(FFMPEG and shutil.which("osascript"), "needs ffmpeg and macOS")
    def test_a_badge_is_drawn_in_its_window(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        badges = t.keys_write({"⌘K": [(0.5, 1.0)]}, d, 400, 200)
        self.assertEqual(len(badges), 1)
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=blue:s=400x200:r=30:d=2", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", os.path.join(d, "cut.mov")], check=True)
        plan = t.render_plan(d, {"frame": {"w": 400, "h": 200, "fps": 30}, "over": []}, d, os.path.join(d, "out.mp4"),
                             {"length": 2.0, "pointer": {"keys": badges}})
        subprocess.run(plan["picture"], check=True, capture_output=True)

        def px(sec):  # a point inside the badge: the bottom middle, just over its lower edge
            raw = subprocess.run([FFMPEG, "-v", "error", "-ss", "%.3f" % sec, "-i", os.path.join(d, "picture.mp4"),
                                  "-frames:v", "1", "-vf", "format=rgb24,crop=2:2:199:168", "-f", "rawvideo", "-pix_fmt",
                                  "rgb24", "-"], capture_output=True).stdout
            return tuple(raw[:3])
        self.assertGreater(px(0.2)[2], 200)  # blue: no badge yet
        self.assertLess(px(0.7)[2], 120)     # the dark badge
        self.assertGreater(px(1.5)[2], 200)  # gone again


if __name__ == "__main__":
    unittest.main()
