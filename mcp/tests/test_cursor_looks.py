import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "effects", "cursor-looks", "src")
spec = importlib.util.spec_from_file_location("cursor", os.path.join(SRC, "cursor.py"))
cursor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cursor)

ARROW = {"png": "", "hot": [4, 4], "size": [17, 23], "zoom": 1}
EV = {"v": 1, "size": [2000, 1000], "scale": 2, "pointer": False, "arrow": ARROW,
      "shapes": [dict(ARROW, name="arrow"), dict(ARROW, size=[9, 18], name="text"), dict(ARROW, name="hand")],
      "moves": [[0, 100, 100, 0], [1.0, 500, 500, 2], [2.0, 600, 500, 1], [3.0, 700, 500, 0], [3.5, 900, 500, 0],
                [4.0, 1000, 500, 0]],
      "clicks": [{"t": 1.2, "x": 500, "y": 500, "button": "left", "down": True},
                 {"t": 1.3, "x": 500, "y": 500, "button": "left", "down": False},
                 {"t": 3.2, "x": 700, "y": 500, "button": "left", "down": True},
                 {"t": 3.9, "x": 1000, "y": 500, "button": "left", "down": False}]}


class CursorLooksTests(unittest.TestCase):
    """The cursor looks effect's cursor.py: the pointer, its state and its clicks in the edit (2026-10-31)."""

    def test_states_from_shapes_and_drags(self):
        self.assertEqual(cursor.take_states(EV), [(0, "move"), (1.0, "hover"), (2.0, "text"), (3.0, "move"),
                                                  (3.2, "drag"), (3.9, "move")])

    def test_unnamed_shapes_are_guessed(self):
        ev = dict(EV, shapes=[ARROW, dict(ARROW, size=[9, 18]), ARROW])
        self.assertEqual(cursor.shape_states(ev), ["move", "text", "hover"])

    def test_the_spinning_wait(self):
        moves = [[0, 1, 1, 0]] + [[1 + i * 0.1, 1, 1, 1 + i % 4] for i in range(8)] + [[3, 1, 1, 0]]
        ev = dict(EV, shapes=[dict(ARROW, name="arrow")] + [ARROW] * 4, moves=moves, clicks=[])
        self.assertEqual(cursor.take_states(ev)[:2], [(0, "move"), (1.0, "wait")])

    def test_path_follows_the_cut_crop_and_scale(self):
        cut = [{"take": 1, "kind": "screen", "in": 1.0, "out": 2.0}, {"take": 1, "kind": "camera", "in": 2, "out": 3},
               {"take": 1, "kind": "screen", "in": 3.0, "out": 4.0}]
        out = cursor.build(EV, 1, cut, 1000, 500, raw=True, fps=10)
        self.assertEqual(out["unit"], 1.0)  # half the size, 2 px a point
        self.assertEqual(out["path"][0], [0.0, 250.0, 250.0])
        # The camera part hides it; the next screen part comes 1 s later in the edit.
        self.assertEqual(out["path"][10], [1.0, None, None])
        self.assertEqual(out["path"][11], [2.0, 350.0, 250.0])
        self.assertEqual(out["clicks"], [[0.2, 250.0, 250.0], [2.2, 350.0, 250.0]])
        # The I-beam at 2.0 s is where the first part ends: the edit never shows it.
        self.assertEqual([s for _, s in out["states"]], ["hover", "move", "drag", "move"])
        self.assertEqual(out["length"], 3.0)

    def test_it_writes_the_composition(self):
        d = tempfile.mkdtemp()
        try:
            shutil.copytree(SRC, os.path.join(d, "cursor-looks"))
            with open(os.path.join(d, "ev.json"), "w") as f:
                json.dump(EV, f)
            r = subprocess.run([sys.executable, "cursor-looks/cursor.py", "--events", "ev.json", "--take", "1", "--cut",
                                json.dumps([{"take": 1, "kind": "screen", "in": 0, "out": 4}]), "--size", "1080x1920",
                                "--look", "pixel", "--wait", "[[2.5, 3, \"Rendering\"]]"],
                               cwd=d, capture_output=True, text=True, check=True)
            out = json.loads(r.stdout)
            self.assertEqual((out["at"], out["look"], out["clicks"]), (0.0, "pixel", 2))
            self.assertEqual(out["states"]["wait"], 1)
            with open(os.path.join(d, "cursor-looks", "index.html")) as f:
                html = f.read()
            self.assertIn('"look":"pixel"', html)
            self.assertIn('data-width="1080"', html)
            self.assertIn('"waits":[[2.5,3.0,"Rendering"]]', html)
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
