"""Storyboard: shots are written at once, sketches land in the background, a kept sketch is not drawn again."""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

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

    def test_the_format_is_kept_and_a_new_one_draws_again(self):
        shots = [{"say": "Hi.", "sketch": "A man at a desk."}]
        # A storyboard from before formats: 4:5, and its sketches keep their names.
        self.assertEqual(t.sketch_name("A man at a desk."), t.sketch_name("A man at a desk.", "4:5"))
        r = t.t_set_storyboard({"session": self.s, "shots": shots, "format": "16:9"})
        self.assertEqual((r["format"], r["drawing"]), ("16:9", 1))
        t.sketch_run(self.s)
        # Left out on a later call: kept, and the drawn sketch stays.
        r = t.t_set_storyboard({"session": self.s, "shots": shots})
        self.assertEqual((r["format"], r["drawing"]), ("16:9", 0))
        self.assertEqual(t.t_get_session({"session": self.s})["storyboard"]["format"], "16:9")
        r = t.t_set_storyboard({"session": self.s, "shots": shots, "format": "9:16"})
        self.assertEqual(r["drawing"], 1)
        # Any shape: 1920x1080 is 16:9; 21:9 and 7:5 are drawn in the nearest Gemini shape.
        self.assertEqual(t.t_set_storyboard({"session": self.s, "shots": shots, "format": "1920x1080"})["format"], "16:9")
        self.assertEqual(t.t_set_storyboard({"session": self.s, "shots": shots, "format": "21:9"})["format"], "21:9")
        self.assertEqual((t.draw_format("21:9"), t.draw_format("7:5"), t.draw_format("9:16")), ("21:9", "4:3", "9:16"))
        with self.assertRaises(ValueError):
            t.t_set_storyboard({"session": self.s, "shots": shots, "format": "wide"})

    def test_a_failed_sketch_says_why(self):
        os.environ["TAKES_SKETCH_CMD"] = json.dumps([sys.executable, "-c", "import sys; sys.exit('quota')"])
        t.t_set_storyboard({"session": self.s, "shots": [{"sketch": "A man."}]})
        t.sketch_run(self.s)
        self.assertEqual(t.read_storyboard(self.s)["shots"][0]["error"], "quota")

    def test_no_image_key_draws_nothing_and_tells_the_chat(self):
        os.environ.pop("TAKES_SKETCH_CMD")
        none = lambda: None  # noqa: E731
        with mock.patch.object(t, "gemini_key", none), mock.patch.object(t, "openai_key", none), \
                mock.patch.object(t, "rep_key", none):
            started = []
            with mock.patch.object(t, "start_sketches", lambda s: started.append(s)):
                r = t.t_set_storyboard({"session": self.s, "shots": [{"sketch": "A man."}, {"sketch": "A dog."}]})
            self.assertEqual((r["drawing"], r["no_sketches"], started), (0, 2, []))
            self.assertIn("image key", r["note"])
            self.assertIn("'image'", r["note"])
            self.assertTrue(t.read_storyboard(self.s)["nokey"])
            t.sketch_run(self.s, retry=True)  # Draw with still no key: still nokey, nothing drawn
            d = t.read_storyboard(self.s)
            self.assertTrue(d["nokey"])
            self.assertTrue(all("image" not in x for x in d["shots"]))
        # A key now (the test stand-in): Draw clears nokey and draws them.
        os.environ["TAKES_SKETCH_CMD"] = json.dumps([sys.executable, os.path.join(self.root, "fake.py")])
        t.sketch_run(self.s, retry=True)
        d = t.read_storyboard(self.s)
        self.assertNotIn("nokey", d)
        self.assertTrue(all(x.get("image") for x in d["shots"]))

    def test_the_chat_can_bring_its_own_sketch(self):
        mine = os.path.join(self.root, "mine.png")
        open(mine, "wb").write(b"\x89PNG mine")
        none = lambda: None  # noqa: E731
        os.environ.pop("TAKES_SKETCH_CMD")
        with mock.patch.object(t, "gemini_key", none), mock.patch.object(t, "openai_key", none), \
                mock.patch.object(t, "rep_key", none):
            r = t.t_set_storyboard({"session": self.s, "shots": [{"sketch": "A man.", "image": mine},
                                                                   {"say": "Hi.", "image": mine}]})
        self.assertEqual(r["drawing"], 0)
        self.assertNotIn("no_sketches", r)
        d = t.read_storyboard(self.s)
        self.assertNotIn("nokey", d)
        self.assertEqual(d["shots"][0]["image"], t.sketch_name("A man."))
        for x in d["shots"]:
            self.assertEqual(open(os.path.join(self.s, "storyboard", x["image"]), "rb").read(), b"\x89PNG mine")
        models = json.load(open(os.path.join(self.s, "storyboard", ".models.json")))
        self.assertEqual(models[d["shots"][0]["image"]], "Made in the chat")
        # Later calls without 'image' keep the sketch it brought.
        r = t.t_set_storyboard({"session": self.s, "shots": [{"sketch": "A man."}]})
        self.assertEqual(r["drawing"], 0)
        with self.assertRaises(ValueError):
            t.t_set_storyboard({"session": self.s, "shots": [{"sketch": "A cat.", "image": "/nope.png"}]})

    def test_replicate_is_the_last_sketch_source(self):
        self.assertEqual(t.SKETCH_MODELS[-1], "replicate-nano-banana")
        self.assertEqual(t.IMAGE_MODELS["replicate-nano-banana"][0], "replicate")
        calls = []

        def http(method, path, body=None, upload=None):
            calls.append((method, path, body))
            return {"status": "succeeded", "output": "https://x.test/out.png"}
        out = os.path.join(self.root, "r.png")
        with mock.patch.object(t, "rep_key", lambda: "k"), mock.patch.object(t, "rep_http", http), \
                mock.patch.object(t, "rep_download", lambda url, dest: open(dest, "wb").write(b"png")):
            label = t.draw_image("A man.", out, "9:16", models=("replicate-nano-banana",))
        self.assertEqual(label, "Nano Banana · Replicate")
        self.assertEqual(calls[0][1], "/models/google/nano-banana/predictions")
        self.assertEqual(calls[0][2]["input"]["aspect_ratio"], "9:16")

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

    def test_variants_keep_their_order_and_survive_a_rewrite(self):
        g = os.path.join(self.s, "generated")
        os.makedirs(g)
        for n in ("a.png", "b.png", "c.mp4"):
            open(os.path.join(g, n), "wb").write(b"x")
        shot = {"kind": "SCREEN", "say": "Comment on a frame.", "sketch": "A bubble.",
                "variants": ["generated/a.png", "generated/b.png"], "video": "generated/b.png"}
        t.t_set_storyboard({"session": self.s, "shots": [shot]})
        x = t.read_storyboard(self.s)["shots"][0]
        self.assertEqual(x["video"], "generated/b.png")
        self.assertEqual(x["variants"], ["generated/a.png", "generated/b.png"])
        self.assertEqual(t.storyboard_view(self.s)["list"][0]["variants"], x["variants"])
        # A rewrite of the lines without variants keeps them.
        t.t_set_storyboard({"session": self.s, "shots": [{"id": x["id"], "kind": "SCREEN", "say": "New line.",
                                                           "sketch": "A bubble.", "video": "generated/a.png"}]})
        x = t.read_storyboard(self.s)["shots"][0]
        self.assertEqual((x["video"], x["variants"]), ("generated/a.png", ["generated/a.png", "generated/b.png"]))
        # A video not in the list goes first; no video picks the first.
        t.t_set_storyboard({"session": self.s, "shots": [{"id": x["id"], "sketch": "A bubble.",
                                                           "variants": ["generated/a.png"], "video": "generated/c.mp4"}]})
        x = t.read_storyboard(self.s)["shots"][0]
        self.assertEqual(x["variants"], ["generated/c.mp4", "generated/a.png"])
        t.t_set_storyboard({"session": self.s, "shots": [{"id": x["id"], "sketch": "A bubble.",
                                                           "variants": ["generated/b.png", "generated/a.png"]}]})
        self.assertEqual(t.read_storyboard(self.s)["shots"][0]["video"], "generated/b.png")

    def test_a_new_clip_keeps_the_old_one_as_a_variant(self):
        x = {"video": "generated/a.mp4"}
        t.put_clip(x, "generated/b.mp4")
        self.assertEqual(x, {"video": "generated/b.mp4", "variants": ["generated/a.mp4", "generated/b.mp4"]})
        t.put_clip(x, "generated/c.mp4")
        self.assertEqual(x["variants"], ["generated/a.mp4", "generated/b.mp4", "generated/c.mp4"])
        y = {}
        t.put_clip(y, "generated/a.mp4")
        self.assertEqual(y, {"video": "generated/a.mp4"})


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
