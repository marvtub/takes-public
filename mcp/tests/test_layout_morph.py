import importlib.util
import os
import unittest

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "effects", "layout-morph", "src")
spec = importlib.util.spec_from_file_location("morph", os.path.join(SRC, "morph.py"))
morph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(morph)


class LayoutMorphTests(unittest.TestCase):
    """The layout morph effect's morph.py: layouts for any frame, the ease between them, the whooshes (2026-10-30).
    The drawing needs numpy and OpenCV; these parts are plain Python."""

    def test_layouts_fit_every_shape(self):
        for W, H in ((1920, 1080), (1080, 1920), (1080, 1080), (1080, 1350)):
            for name in ("card", "bubble", "side", "full"):
                for corner in ("br", "bl", "tr", "tl"):
                    x, y, w, h = morph.layout(name, W, H, corner)["box"]
                    self.assertTrue(0 <= x and 0 <= y and x + w <= W and y + h <= H, (W, H, name, corner))
        # 16:9: the side panel is the right third; tall frames put it at the bottom.
        self.assertEqual(morph.panel_rect(1920, 1080), (1311, 0, 609, 1080))
        self.assertEqual(morph.panel_rect(1080, 1920), (0, 1114, 1080, 806))
        self.assertEqual(morph.layout("bubble", 1920, 1080)["radius"], 160)
        self.assertEqual(morph.layout("card", 1920, 1080, "tl")["box"][:2], (38, 38))
        with self.assertRaises(ValueError):
            morph.layout("pip", 1920, 1080)

    def test_a_change_eases_over_the_morph_time(self):
        st = morph.steps([{"at": 5, "layout": "side"}, {"at": 0, "layout": "card"}], 1920, 1080)
        card, side = st[0][1], st[1][1]
        self.assertEqual(morph.layout_at(st, 4.9), card)
        self.assertEqual(morph.layout_at(st, 5 + morph.MORPH_S), side)
        mid = morph.layout_at(st, 5 + morph.MORPH_S / 2)
        self.assertAlmostEqual(mid["panel"], 0.5)
        self.assertAlmostEqual(mid["box"][0], (card["box"][0] + side["box"][0]) / 2)

    def test_the_crop_has_the_box_aspect_and_stays_in_the_camera(self):
        L = morph.layout("side", 1920, 1080)
        cx, cy, cw, ch = morph.crop_rect(L, 1920, 1080, (1900, 500))
        self.assertAlmostEqual(cw / ch, L["box"][2] / L["box"][3])
        self.assertLessEqual(cx + cw, 1920)
        self.assertEqual(cy, 0)

    def test_a_whoosh_on_each_change_at_its_fastest_point(self):
        plan = [{"at": 0, "layout": "card"}, {"at": 9.5, "layout": "bubble"}, {"at": 19, "layout": "side"}]
        sfx = morph.whoosh_sfx(plan, 2.0, "demo")
        self.assertEqual(sfx, [{"file": "_edit/demo/layout-morph/whoosh-1.wav", "at": 11.768, "gain_db": -11},
                               {"file": "_edit/demo/layout-morph/whoosh-2.wav", "at": 21.271, "gain_db": -11}])
        for f, _ in morph.WHOOSHES:
            self.assertTrue(os.path.exists(os.path.join(SRC, f)), f)


if __name__ == "__main__":
    unittest.main()
