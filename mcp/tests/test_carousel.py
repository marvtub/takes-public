"""set_carousel writes posts/carousel.json, the file the Post tab's carousel reads
(Sources/Takes/Carousel.swift)."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class CarouselTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
        t.forget_seen()
        self.s = os.path.join(self.root, "P", "2026-10-26-a")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "A", "createdAt": "2026-10-26T10:00:00Z", "takes": []})

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def read(self):
        with open(os.path.join(self.s, "posts", "carousel.json")) as f:
            return json.load(f)

    def test_writes_slides_and_which_posts_show_them(self):
        out = t.t_set_carousel({"session": self.s, "docTitle": "5 things", "on": {"linkedin": True},
                                "slides": [{"kicker": "Swipe →", "title": "5 things", "body": "Save this."},
                                           {"title": "Light from the front"}]})
        self.assertEqual(out["slide_count"], 2)
        c = self.read()
        self.assertEqual(c["slides"][1], {"kicker": "", "title": "Light from the front", "body": ""})
        self.assertEqual(c["on"], {"linkedin": True})
        self.assertEqual(c["docTitle"], "5 things")
        self.assertNotIn("captions", c)
        t.t_set_carousel({"session": self.s, "on": {"vertical": True, "linkedin": False}})
        c = self.read()
        self.assertEqual(len(c["slides"]), 2)
        self.assertEqual(c["on"], {"linkedin": False, "vertical": True})
        # Old captions are dropped on the next write.
        os.makedirs(os.path.join(self.s, "posts"), exist_ok=True)
        with open(os.path.join(self.s, "posts", "carousel.json"), "w") as f:
            json.dump({"slides": [{"title": "a"}], "captions": {"linkedin": "old"}}, f)
        t.t_set_carousel({"session": self.s, "on": {"linkedin": True}})
        self.assertNotIn("captions", self.read())

    def test_the_post_says_it_is_a_carousel(self):
        t.t_set_post({"session": self.s, "text": "Hook\n"})
        self.assertNotIn("carousel", t.read_post(self.s, "linkedin"))
        t.t_set_carousel({"session": self.s, "slides": [{"title": "a"}, {"title": "b"}], "on": {"linkedin": True}})
        self.assertEqual(t.read_post(self.s, "linkedin")["carousel"]["slides"], 2)

    def test_layouts_pictures_and_look(self):
        os.makedirs(os.path.join(self.s, "stills"))
        for n in ("a.jpg", "b.jpg"):
            open(os.path.join(self.s, "stills", n), "wb").close()
        open(os.path.join(self.s, "take-01-camera.mov"), "wb").close()
        out = t.t_set_carousel({"session": self.s, "look": "bold", "accent": "00ff88", "slides": [
            {"layout": "cover", "kicker": "How I filmed this", "title": "Phone video", "media": "stills/a.jpg"},
            {"layout": "word", "title": "Light."},
            {"layout": "frames", "title": "The plan", "items": [{"media": "stills/a.jpg", "label": "WS"},
                                                                 {"media": "take-01-camera.mov", "at": 3.5, "label": "CU"}]},
            {"layout": "annotate", "title": "Setup", "media": "stills/b.jpg", "marks": [{"x": 0.3, "y": 0.2, "text": "Window"}]},
            {"layout": "video", "title": "Watch", "media": "take-01-camera.mov", "start": 2, "end": 8},
            {"title": "Save this."}]})
        self.assertEqual(out["slide_count"], 6)
        c = self.read()
        self.assertEqual((c["look"], c["accent"]), ("bold", "#00ff88"))
        self.assertEqual(c["slides"][0]["layout"], "cover")
        self.assertEqual(c["slides"][2]["items"][1], {"media": "take-01-camera.mov", "label": "CU", "text": "", "at": 3.5})
        self.assertEqual(c["slides"][4]["start"], 2.0)
        # A text slide stays as before: no layout key.
        self.assertEqual(c["slides"][5], {"kicker": "", "title": "Save this.", "body": ""})
        # Back to the default look and colour: the keys go.
        t.t_set_carousel({"session": self.s, "look": "takes", "accent": ""})
        self.assertNotIn("look", self.read())
        self.assertNotIn("accent", self.read())

    def test_refuses_slides_it_cannot_draw(self):
        os.makedirs(os.path.join(self.s, "stills"))
        open(os.path.join(self.s, "stills", "a.jpg"), "wb").close()
        bad = [
            {"layout": "hologram", "title": "x"},
            {"layout": "cover", "media": "stills/missing.jpg"},
            {"layout": "frames", "title": "x"},
            {"layout": "annotate", "media": "stills/a.jpg"},
            {"layout": "video", "media": "stills/a.jpg"},
            {"layout": "list", "title": "x"},
            {"title": "x", "media": "stills/a.jpg"},
            {"layout": "annotate", "media": "stills/a.jpg", "marks": [{"x": 2, "y": 0}]},
            {"layout": "video", "start": 5, "end": 2},
        ]
        for x in bad:
            with self.assertRaises(ValueError, msg=str(x)):
                t.t_set_carousel({"session": self.s, "slides": [x]})
        with self.assertRaises(ValueError):
            t.t_set_carousel({"session": self.s, "slides": [{"title": "a"}], "look": "neon"})
        with self.assertRaises(ValueError):
            t.t_set_carousel({"session": self.s, "slides": [{"title": "a"}], "accent": "yellow"})

    def test_refuses_bad_input(self):
        with self.assertRaises(ValueError):
            t.t_set_carousel({"session": self.s, "on": {"linkedin": True}})  # no slides yet
        with self.assertRaises(ValueError):
            t.t_set_carousel({"session": self.s, "slides": [{"title": " "}]})
        with self.assertRaises(ValueError):
            t.t_set_carousel({"session": self.s, "slides": [{"title": "a"}], "on": {"x": True}})

    def test_never_writes_over_a_file_it_cannot_read(self):
        os.makedirs(os.path.join(self.s, "posts"), exist_ok=True)
        with open(os.path.join(self.s, "posts", "carousel.json"), "w") as f:
            f.write("{not json")
        with self.assertRaises(ValueError):
            t.t_set_carousel({"session": self.s, "slides": [{"title": "a"}]})
        with open(os.path.join(self.s, "posts", "carousel.json")) as f:
            self.assertEqual(f.read(), "{not json")


if __name__ == "__main__":
    unittest.main()
