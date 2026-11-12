"""The zoom and the pointer looks (2026-10-31): opt-in recipe zoom {auto, level, follow, spans} zooms the screen
in on clicks and follows the pointer; pointer {look, size, hot} changes how the drawn pointer looks."""
import base64
import importlib.util
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = shutil.which("ffmpeg")
SRC = os.path.join(os.path.dirname(__file__), "..", "..", "effects", "click-ring", "src")
spec = importlib.util.spec_from_file_location("clicks", os.path.join(SRC, "clicks.py"))
clicks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clicks)

EV = {"v": 1, "size": [400, 200], "scale": 2, "pointer": False,
      "arrow": {"png": "", "hot": [5, 5], "size": [28, 40], "zoom": 1},
      "moves": [[0, 100, 50], [1.0, 200, 50], [1.5, 300, 150]], "clicks": []}


class Recipe(unittest.TestCase):
    def test_zoom_is_checked(self):
        f = {"shape": "16:9"}
        self.assertEqual(t.norm_zoom(None, f), {})
        self.assertEqual(t.norm_zoom({"auto": True}, f), {"auto": True})
        self.assertEqual(t.norm_zoom({"spans": [{"at": 4, "end": 2.5 + 4, "x": 0.2, "y": 0.3, "level": 2.5}]}, f),
                         {"spans": [{"at": 4.0, "end": 6.5, "level": 2.5, "x": 0.2, "y": 0.3}]})
        for bad in ({"level": 2}, {"auto": True, "speed": 2}, {"spans": [{"at": 1, "end": 1.5}]},
                    {"spans": [{"at": 1, "end": 4, "x": 0.5}]}, {"auto": True, "level": 9},
                    {"spans": [{"at": 1, "end": 4}, {"at": 3, "end": 6}]}):
            with self.assertRaises(ValueError, msg=bad):
                t.norm_zoom(bad, f)
        with self.assertRaises(ValueError):
            t.norm_zoom({"auto": True}, {"crop": {"x": 0, "y": 0, "w": 9, "h": 9, "follow_face": True}})
        self.assertIn("zoom", t.AGENT_FIELDS)


class Auto(unittest.TestCase):
    def test_one_zoom_per_run_of_clicks_inside_its_part(self):
        got = t.zoom_auto([(0.0, 20.0), (20.0, 30.0)], [2.0, 3.0, 10.0, 20.5])
        self.assertEqual([(round(e["at"], 2), round(e["end"], 2), e["click"]) for e in got],
                         [(1.1, 4.6, 2.0), (9.1, 11.6, 10.0), (20.0, 22.1, 20.5)])

    def test_runs_close_together_stay_in(self):
        got = t.zoom_auto([(0.0, 20.0)], [2.0, 6.0])  # 3.6 out, 5.1 in: too close to go out and back
        self.assertEqual([(round(e["at"], 2), round(e["end"], 2)) for e in got], [(1.1, 7.6)])

    def test_typing_zooms_in_just_before_the_first_key_and_out_just_after_the_last(self):
        got = t.zoom_auto([(0.0, 30.0)], [], [(5.0, 9.0)])
        self.assertEqual([(round(e["at"], 2), round(e["end"], 2), e.get("typing")) for e in got], [(4.3, 10.3, True)])
        e = got[0]
        self.assertAlmostEqual(e["at"] + t.ZOOM_IN_S, 5.0 - t.TYPE_EARLY)  # fully in before the first key
        self.assertAlmostEqual(e["end"] - t.ZOOM_OUT_S, 9.0 + t.TYPE_LATE)  # out only after the last

    def test_a_click_into_a_field_then_typing_is_one_zoom(self):
        got = t.zoom_auto([(0.0, 30.0)], [4.0], [(5.0, 8.0)])
        self.assertEqual([(round(e["at"], 2), round(e["end"], 2), e["click"]) for e in got], [(3.1, 9.3, 4.0)])

    def test_a_click_right_after_typing_gets_no_zoom(self):
        got = t.zoom_auto([(0.0, 30.0)], [(10.0, 900, 100)], [(5.0, 9.0)], far=700)
        self.assertEqual(len(got), 1)
        self.assertTrue(got[0]["typing"])
        self.assertAlmostEqual(got[0]["end"], 9.0 + t.TYPE_LATE + t.ZOOM_OUT_S)

    def test_a_click_in_a_new_place_is_a_new_zoom_not_a_swing(self):
        got = t.zoom_auto([(0.0, 30.0)], [(2.0, 100, 100), (3.5, 1200, 600)], far=700)
        self.assertEqual(len(got), 2)
        self.assertLessEqual(got[0]["end"], got[1]["at"])
        near = t.zoom_auto([(0.0, 30.0)], [(2.0, 100, 100), (3.5, 300, 150)], far=700)
        self.assertEqual(len(near), 1)
        self.assertEqual([p[0] for p in near[0]["places"]], [2.0, 3.5])

    def test_a_click_zoom_holds_on_the_click_not_the_mouse(self):
        sp = {"at": 1.0, "end": 4.0, "click": 2.0, "places": [(2.0, 400.0, 300.0)]}
        away = lambda n: (50.0 + 10 * n, 50.0)  # the mouse travels off after the click
        v = t.zoom_view([sp], 800, 600, 30, 150, away, 2.0)
        z, l, top = v[75]
        self.assertAlmostEqual(l + 800 / z / 2, 400.0, delta=1)
        self.assertAlmostEqual(top + 600 / z / 2, 300.0, delta=1)

    def test_a_click_at_the_end_of_a_part_too_short_to_zoom_gets_none(self):
        self.assertEqual(t.zoom_auto([(0.0, 5.0)], [4.9]), [])


class TypingSpots(unittest.TestCase):
    def test_finds_the_small_spot_that_changes_and_follows_it(self):
        import shutil, subprocess, tempfile, os
        ff = shutil.which("ffmpeg")
        if not ff:
            self.skipTest("no ffmpeg")
        d = tempfile.mkdtemp()
        v = os.path.join(d, "caret.mov")  # a 12x16 "caret" moving right 100 px/s on a 640x400 screen
        subprocess.run([ff, "-v", "error", "-y", "-f", "lavfi", "-i", "color=black:s=640x400:d=3:r=30", "-f", "lavfi",
                        "-i", "color=white:s=12x16:d=3:r=30", "-filter_complex", "[0][1]overlay=x='100+100*t':y=300", v],
                       check=True)
        got = t.typing_spots(v, 0.5, 2.5)
        self.assertGreater(len(got), 20)
        for at, fx, fy in got:
            self.assertAlmostEqual(fx, (106 + 100 * at) / 640.0, delta=0.03)
            self.assertAlmostEqual(fy, 308 / 400.0, delta=0.02)


class View(unittest.TestCase):
    def test_eases_in_holds_and_out_and_never_shows_past_the_edge(self):
        v = t.zoom_view([{"at": 1.0, "end": 4.0, "x": 0.0, "y": 0.0}], 400, 200, 10, 60, level=2)
        self.assertEqual(sorted(v)[0], 10)
        self.assertEqual(sorted(v)[-1], 40)
        self.assertAlmostEqual(v[10][0], 1.0)
        self.assertAlmostEqual(v[20][0], 2.0)  # fully in from 1.6 s
        self.assertEqual(v[25], (2.0, 0.0, 0.0))  # the corner asked for: the view stays in the frame
        self.assertAlmostEqual(v[40][0], 1.0)
        self.assertTrue(1 < v[35][0] < 2)

    def test_follows_the_pointer_only_when_it_leaves_the_middle(self):
        pos = {n: (200.0, 100.0) if n < 30 else (380.0, 100.0) for n in range(100)}
        v = t.zoom_view([{"at": 0.0, "end": 8.0}], 400, 200, 10, 100, pos.get, level=2)
        z, L, T = v[18]
        self.assertEqual((z, round(L), round(T)), (2.0, 100, 50))  # centred on the pointer
        # The render knows the pointer's path: the pan starts before the pointer leaves the middle (frame 30).
        self.assertTrue(100 < v[28][1] < 150)
        z, L, T = v[70]
        self.assertEqual(round(L), 200)  # panned right as far as the frame allows (380 is past the middle)
        self.assertTrue(100 < v[33][1] < 200)  # an eased pan, not a jump

    def test_a_shaking_hand_does_not_shake_the_pan(self):
        # The pointer pushes the view right at 1 px a frame and shakes 8 px twice a second (a hand). The old
        # one-way smoothing passed the shake on: the pan's speed swung by half (2026-11-02).
        pos = {n: (150.0 + n + 8 * math.sin(2 * math.pi * 2 * n / 30.0), 100.0) for n in range(300)}
        v = t.zoom_view([{"at": 0.0, "end": 10.0}], 800, 200, 30, 300, pos.get, level=2)
        speed = [v[n + 1][1] - v[n][1] for n in range(205, 240)]
        self.assertLess(max(speed) - min(speed), 0.05)

    def test_the_zoomed_cut_maps_back_to_the_source(self):
        self.assertEqual(t.zoom_quad((1.0, 0.0, 0.0), (400, 200), None, 400, 200), (0.0, 400.0, 0.0, 200.0))
        self.assertEqual(t.zoom_quad((2.0, 0.0, 0.0), (400, 200), None, 400, 200), (0.0, 200.0, 0.0, 100.0))
        # A 2x screen cut (800x400) in a 400x200 frame: the view's edit pixels are half its cut pixels.
        self.assertEqual(t.zoom_quad((2.0, 100.0, 50.0), (800, 400), None, 400, 200), (200.0, 600.0, 100.0, 300.0))
        # A crop of the cut's right half in a 200x200 frame.
        self.assertEqual(t.zoom_quad((2.0, 0.0, 0.0), (400, 200), {"x": 200, "y": 0, "w": 200, "h": 200}, 200, 200),
                         (100.0, 300.0, 0.0, 100.0))

    def test_keys_are_few_and_close(self):
        frames = list(range(100))
        vals = [(n * 2.0, 5.0) for n in range(50)] + [(100.0 - (n - 50), 5.0) for n in range(50, 100)]
        keys = t.zoom_keys(frames, vals)
        self.assertLessEqual(len(keys), 5)
        self.assertEqual(keys[0], (0, 0.0, 5.0))
        self.assertEqual(keys[-1], (99, 51.0, 5.0))


class Looks(unittest.TestCase):
    def test_the_dot_is_a_png_and_one_layer_for_every_shape(self):
        png = base64.b64decode(t.dot_png())
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        ev = dict(EV, shapes=[dict(EV["arrow"], png="a"), {"png": "b", "hot": [12, 11], "size": [23, 22], "zoom": 1}],
                  moves=[[0, 100, 50, 0], [1.0, 100, 50, 1]])
        (L,) = t.pointer_layers([{"start": 0.0, "len": 2.0, "in": 0.0, "ev": ev, "fit": (1.0, 0.0, 0.0)}], 10, 2.0,
                                {"look": "dot", "size": 1.5}, "pb")
        self.assertEqual((L["w"], L["h"]), (66, 66))  # 22 pt x 2 px/pt x 1.5
        self.assertIn("overlay@pb0_0 x 67, overlay@pb0_0 y 17", L["cmd"])  # centred on (100, 50)
        self.assertNotIn("x -10000", L["cmd"].splitlines()[-1])  # it does not go off for the I-beam

    def test_a_png_look_is_as_tall_as_the_arrow_with_its_tip_on_the_point(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        p = os.path.join(d, "hand.png")
        with open(p, "wb") as f:
            f.write(base64.b64decode(t.png_b64(20, 80, [[255, 0, 0, 255] * 20] * 80)))
        (shape,) = t.look_shapes(EV, {"look": "hand.png", "look_file": p, "hot": [10, 40]})
        self.assertEqual((shape["size"], shape["hot"]), ([10.0, 40], [5.0, 20.0]))


@unittest.skipUnless(FFMPEG, "no ffmpeg")
class Render(unittest.TestCase):
    def test_the_screen_and_its_pointer_zoom_together(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        # A blue 400x200 cut with a white 20x20 square at (40, 20), and a white 10x10 pointer at (100, 60).
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=blue:s=400x200:r=10:d=3", "-vf",
                        "drawbox=x=40:y=20:w=20:h=20:color=white:t=fill", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        os.path.join(d, "cut.mov")], check=True)
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=white:s=8x8", "-frames:v", "1",
                        os.path.join(d, "a.png")], check=True)
        with open(os.path.join(d, "a.png"), "rb") as f:
            png = base64.b64encode(f.read()).decode()
        ev = dict(EV, arrow={"png": png, "hot": [0, 0], "size": [5, 5], "zoom": 1}, moves=[[0, 100, 60]])
        layers = t.pointer_write(t.pointer_layers(
            [{"start": 0.0, "len": 3.0, "in": 0.0, "ev": ev, "fit": (1.0, 0.0, 0.0)}], 10, 3.0, {}, "pb"), d)
        view = t.zoom_view([{"at": 1.0, "end": 3.0, "x": 0.0, "y": 0.0}], 400, 200, 10, 30, level=2)
        r = {"frame": {"w": 400, "h": 200, "fps": 10}, "over": []}
        plan = t.render_plan(d, r, d, os.path.join(d, "out.mp4"),
                             {"length": 3.0, "pointer": {"base": layers}, "zoom": view, "cut_size": (400, 200)})
        subprocess.run(plan["picture"], check=True, capture_output=True)

        def px(sec, x, y):
            raw = subprocess.run([FFMPEG, "-v", "error", "-ss", "%.3f" % sec, "-i", os.path.join(d, "picture.mp4"),
                                  "-frames:v", "1", "-vf", "format=rgb24,crop=2:2:%d:%d" % (x, y), "-f", "rawvideo",
                                  "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
            return tuple(raw[:3])
        self.assertGreater(min(px(0.5, 50, 30)), 200)  # before the zoom: where it is
        self.assertLess(px(0.5, 100, 60)[0] + 0, 256)
        self.assertLess(px(0.5, 110, 70)[0], 80)
        # At 2.2 s the view is 2x on the top-left: the square is at (80, 40) and 40 px wide; the pointer at (200, 120).
        self.assertGreater(min(px(2.2, 110, 70)), 200)
        self.assertLess(px(2.2, 50, 30)[0], 80)
        self.assertGreater(min(px(2.2, 212, 132)), 200)
        self.assertLess(px(2.2, 225, 145)[0], 80)


class ClickRing(unittest.TestCase):
    def test_rings_move_and_grow_with_the_zoom(self):
        zoom = {"size": [400, 200], "fps": 10, "frames": [[1.0, 2.0, 100.0, 50.0], [1.1, 2.0, 100.0, 50.0]]}
        got = clicks.zoomed([[0.5, 150, 80, 20], [1.0, 150, 80, 20], [1.1, 10, 10, 20]], zoom, 400, 200)
        self.assertEqual(got, [[0.5, 150, 80, 20], [1.0, 100.0, 60.0, 40]])  # the third is out of the view


if __name__ == "__main__":
    unittest.main()
