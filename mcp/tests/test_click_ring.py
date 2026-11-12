import importlib.util
import os
import shutil
import tempfile
import unittest

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "effects", "click-ring", "src")
spec = importlib.util.spec_from_file_location("clicks", os.path.join(SRC, "clicks.py"))
clicks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clicks)

EVENTS = {"v": 1, "size": [3456, 2234], "clicks": [
    {"t": 10.0, "x": 1837, "y": 289, "button": "left", "down": True},
    {"t": 10.08, "x": 1837, "y": 289, "button": "left", "down": False},
    {"t": 20.0, "x": 100, "y": 100, "button": "right", "down": True},
    {"t": 30.0, "x": 1803, "y": 387, "button": "left", "down": True},
    {"t": 31.0, "x": 50, "y": 50, "button": "left", "down": True}]}


class ClickRingTests(unittest.TestCase):
    """The click ring effect's clicks.py: cursor log pixels and times to the edit's (2026-10-30)."""

    def test_clicks_follow_the_cut_crop_and_scale(self):
        # Checked on a real screen take: these rings sit on the pointer in render_edit's picture.
        cut = [{"take": 1, "kind": "screen", "in": 8, "out": 12}, {"take": 1, "kind": "camera", "in": 12, "out": 14},
               {"take": 1, "kind": "screen", "in": 28, "out": 36}]
        found, length = clicks.rings(EVENTS, 1, cut, 1080, 1920, {"x": 1300, "y": 100, "w": 1000, "h": 1778})
        self.assertEqual(length, 14)
        # Only button-down left clicks inside the crop; the camera part moves later parts on by 2 s.
        self.assertEqual([r[:3] for r in found], [[2.0, 580.0, 204.1], [8.0, 543.2, 310.0]])
        self.assertEqual(found[0][3], 43)

    def test_no_crop_covers_the_frame_from_the_centre(self):
        cut = [{"take": 1, "kind": "screen", "in": 8, "out": 12}]
        self.assertEqual(clicks.rings(EVENTS, 1, cut, 1920, 1080)[0], [[2.0, 1020.6, 80.6, 22]])
        self.assertEqual(clicks.rings(EVENTS, 1, [dict(cut[0], **{"in": 28, "out": 32})], 1080, 1080)[0],
                         [[2.0, 576.6, 187.1, 19]])
        # Another take's cut shows none of these clicks.
        self.assertEqual(clicks.rings(EVENTS, 2, cut, 1920, 1080)[0], [])

    def test_each_ring_gets_the_real_click_sound(self):
        # 2026-10-30: a real mouse click, its press on the click's frame, in the edit's folder.
        sfx = clicks.click_sfx([[2.0, 1, 2, 20], [8.0, 3, 4, 20]], "demo")
        self.assertEqual(sfx, [{"file": "_edit/demo/click-ring/click.wav", "at": 1.995, "gain_db": -7},
                               {"file": "_edit/demo/click-ring/click.wav", "at": 7.995, "gain_db": -7}])
        self.assertTrue(os.path.exists(os.path.join(SRC, "click.wav")))

    def test_layer_and_html(self):
        at, duration, rel = clicks.layer([[2.0, 1, 2, 20], [8.0, 3, 4, 20]], 14)
        self.assertEqual((at, duration), (1.9, 6.9))
        self.assertEqual(rel, [[0.1, 1, 2, 20], [6.1, 3, 4, 20]])
        self.assertIsNone(clicks.layer([], 14))
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        html = os.path.join(d, "index.html")
        shutil.copy(os.path.join(SRC, "index.html"), html)
        clicks.write_html(html, rel, 1920, 1080, duration)
        with open(html) as f:
            out = f.read()
        self.assertIn("const CLICKS = [[0.1, 1, 2, 20], [6.1, 3, 4, 20]];", out)
        self.assertIn('data-duration="6.9" data-width="1920" data-height="1080"', out)


if __name__ == "__main__":
    unittest.main()
