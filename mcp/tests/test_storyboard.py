"""Storyboard: shots are written at once, sketches land in the background, a kept sketch is not drawn again."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FAKE = "import sys\nopen(sys.argv[-1], 'wb').write(b'\\x89PNG fake')\n"


class Storyboard(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-03-idea")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-03T00:00:00Z", "named": True, "takes": []})
        fake = os.path.join(self.root, "fake.py")
        open(fake, "w").write(FAKE)
        os.environ["TAKES_SKETCH_CMD"] = json.dumps([sys.executable, fake])
        t.start_sketches = lambda s: None  # tests draw in the foreground

    def tearDown(self):
        for k in ("TAKES_ROOT", "TAKES_SKETCH_CMD"):
            os.environ.pop(k, None)

    def test_write_draw_keep_and_redraw(self):
        shots = [{"kind": "desk", "say": "Hello.", "do": "To lens.", "sketch": "A man at a desk."},
                 {"kind": "MG", "say": "Then this.", "sketch": "Cards fly in.", "seconds": 4}]
        r = t.t_set_storyboard({"session": self.s, "shots": shots})
        self.assertEqual(r["drawing"], 2)
        d = t.read_storyboard(self.s)
        self.assertEqual([x["kind"] for x in d["shots"]], ["DESK", "MG"])
        self.assertTrue(all("image" not in x for x in d["shots"]))
        t.sketch_run(self.s)
        d = t.read_storyboard(self.s)
        self.assertTrue(all(os.path.exists(os.path.join(self.s, "storyboard", x["image"])) for x in d["shots"]))
        self.assertEqual(t.t_get_session({"session": self.s})["storyboard"]["drawn"], 2)
        # Same sketch: kept. Changed sketch: drawn again.
        shots[1]["sketch"] = "Cards stack up."
        r = t.t_set_storyboard({"session": self.s, "shots": shots})
        self.assertEqual(r["drawing"], 1)
        self.assertIn("image", t.read_storyboard(self.s)["shots"][0])
        # The storyboard folder is not an asset.
        self.assertFalse(any("storyboard" in a.get("path", "") for a in t.t_get_session({"session": self.s})["assets"]))

    def test_a_failed_sketch_says_why(self):
        os.environ["TAKES_SKETCH_CMD"] = json.dumps([sys.executable, "-c", "import sys; sys.exit('quota')"])
        t.t_set_storyboard({"session": self.s, "shots": [{"sketch": "A man."}]})
        t.sketch_run(self.s)
        self.assertEqual(t.read_storyboard(self.s)["shots"][0]["error"], "quota")

    def test_a_shot_needs_a_sketch(self):
        with self.assertRaises(ValueError):
            t.t_set_storyboard({"session": self.s, "shots": [{"say": "Hi."}]})

    def test_a_video_shot_shows_the_clip_and_is_not_drawn(self):
        lib = os.path.join(self.root, "_library", "broll", "1 Desk")
        os.makedirs(lib)
        open(os.path.join(lib, "2023-11 Typing (V).mov"), "wb").write(b"mov")
        os.makedirs(os.path.join(self.s, "edits"))
        open(os.path.join(self.s, "edits", "cut-v1.mp4"), "wb").write(b"mp4")
        shots = [{"kind": "B-ROLL", "say": "One thing.", "sketch": "Hands typing.", "video": "1 Desk/2023-11 Typing (V).mov"},
                 {"kind": "DESK", "say": "Hi.", "video": "edits/cut-v1.mp4"},
                 {"kind": "MG", "sketch": "Cards."}]
        r = t.t_set_storyboard({"session": self.s, "shots": shots})
        self.assertEqual(r["drawing"], 1)
        d = t.read_storyboard(self.s)["shots"]
        self.assertEqual(d[0]["video"], "broll/2023-11 Typing (V).mov")
        self.assertTrue(os.path.exists(os.path.join(self.s, d[0]["video"])))
        self.assertEqual(d[1]["video"], "edits/cut-v1.mp4")
        t.sketch_run(self.s)
        d = t.read_storyboard(self.s)["shots"]
        self.assertEqual([("image" in x) for x in d], [False, False, True])
        with self.assertRaises(ValueError):
            t.t_set_storyboard({"session": self.s, "shots": [{"say": "Hi.", "video": "1 Desk/nope.mov"}]})


if __name__ == "__main__":
    unittest.main()


class StoryboardIds(Storyboard):
    def test_ids_stay_and_sections_order_the_shots(self):
        shots = [{"say": "Main one.", "sketch": "A desk."},
                 {"kind": "end", "say": "Bye.", "sketch": "A wave."},
                 {"section": "hook", "say": "Look.", "sketch": "A box."}]
        r = t.t_set_storyboard({"session": self.s, "shots": shots})
        d = t.read_storyboard(self.s)["shots"]
        self.assertEqual([x["section"] for x in d], ["hook", "main", "end"])
        ids = {x["say"]: x["id"] for x in d}
        self.assertEqual(sorted(r["ids"]), ["s1", "s2", "s3"])
        # A rewrite without ids keeps them by sketch or lines; a new shot gets a new id.
        shots[0]["sketch"] = "A desk, closer."
        shots.append({"say": "More.", "sketch": "A walk."})
        t.t_set_storyboard({"session": self.s, "shots": shots})
        d = t.read_storyboard(self.s)["shots"]
        self.assertEqual({x["say"]: x["id"] for x in d if x["say"] in ids}, ids)
        self.assertEqual([x["id"] for x in d if x["say"] == "More."], ["s4"])

    def test_takes_and_comments_show_per_shot(self):
        t.t_set_storyboard({"session": self.s, "shots": [{"say": "Hi.", "sketch": "A man."}]})
        m = t.read_meta(self.s)
        m["takes"] = [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "shot": "s1",
                       "startedAt": "2026-10-03T00:00:00Z"}]
        t.write_meta(self.s, m)
        t.write_comments(self.s, {"comments": [{"id": "c1", "file": "storyboard/storyboard.json", "shot": "s1",
                                                "text": "Closer", "status": "open", "by": "user", "at": "x"}]})
        v = t.t_get_session({"session": self.s})["storyboard"]["list"][0]
        self.assertEqual((v["takes"], v["open_comments"]), ([1], 1))
        c = t.t_get_comments({"session": self.s})["comments"][0]
        self.assertEqual(c["shot_now"]["say"], "Hi.")
        # Renaming a shot away from its takes warns.
        r = t.t_set_storyboard({"session": self.s, "shots": [{"say": "Other.", "sketch": "A cat."}]})
        self.assertEqual(r["ids"], ["s2"])
        self.assertIn("s1", r["warning"])
