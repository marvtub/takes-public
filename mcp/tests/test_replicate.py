"""Replicate: Takes' words map to the model's own inputs, files upload, the clip lands in generated/ and on its shot.
A stand-in answers for the API."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

# Like bytedance/seedance-2.5's schema: enums sit in their own schemas behind allOf.
SCHEMA = {"components": {"schemas": {
    "Input": {"type": "object", "required": ["prompt"], "properties": {
        "prompt": {"type": "string"},
        "image": {"type": "string", "format": "uri", "description": "First frame"},
        "last_frame_image": {"type": "string", "format": "uri"},
        "reference_images": {"type": "array", "items": {"type": "string", "format": "uri"}},
        "duration": {"type": "integer", "default": 5},
        "resolution": {"allOf": [{"$ref": "#/components/schemas/resolution"}], "default": "720p"},
        "aspect_ratio": {"allOf": [{"$ref": "#/components/schemas/aspect_ratio"}]},
        "generate_audio": {"type": "boolean", "default": True},
        "seed": {"type": "integer"}}},
    "resolution": {"type": "string", "enum": ["480p", "720p", "1080p"]},
    "aspect_ratio": {"type": "string", "enum": ["16:9", "9:16", "1:1", "adaptive"]}}}}


class Replicate(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_NO_KEYCHAIN"] = "1"
        os.environ["REPLICATE_API_TOKEN"] = "r8_" + "x" * 37
        self.s = os.path.join(self.root, "Proj", "2026-10-09-idea")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-09T00:00:00Z", "named": True, "takes": []})
        open(os.path.join(self.s, "still.png"), "wb").write(b"png")
        self.out = os.path.join(self.root, "out.mp4")
        open(self.out, "wb").write(b"fake mp4")
        self.calls, self.started, self.failure = [], [], None
        self.real_http, self.real_start = t.rep_http, t.start_replicate

        def fake(method, path, body=None, upload=None):
            self.calls.append((method, path, body, upload))
            if path.startswith("/models/") and method == "GET":
                return {"name": "seedance-2.5", "description": "ByteDance video", "run_count": 9,
                        "latest_version": {"id": "v1", "openapi_schema": SCHEMA}}
            if path == "/files":
                return {"urls": {"get": "https://api.replicate.com/v1/files/" + os.path.basename(upload)}}
            if path.endswith("/predictions"):
                return {"id": "p1", "status": "starting", "urls": {"get": "https://api.replicate.com/v1/predictions/p1"}}
            if path.endswith("/predictions/p1"):
                if self.failure:
                    return {"id": "p1", "status": "failed", "error": self.failure}
                return {"id": "p1", "status": "succeeded", "output": ["https://replicate.delivery/x/out.mp4"], "metrics": {"predict_time": 61.2}}
            if path == "/account":
                return {"username": "user"}
            raise AssertionError(path)
        t.rep_http = fake
        t.start_replicate = lambda s, p: self.started.append(p)
        self.real_download = t.rep_download
        t.rep_download = lambda url, dest: open(dest, "wb").write(open(self.out, "rb").read())
        t.start_sketches = lambda s: None

    def tearDown(self):
        t.rep_http, t.start_replicate, t.rep_download = self.real_http, self.real_start, self.real_download
        for k in ("TAKES_ROOT", "TAKES_NO_KEYCHAIN", "REPLICATE_API_TOKEN"):
            os.environ.pop(k, None)

    def run_job(self):
        t.replicate_run(self.s, self.started[-1], poll=0)
        return json.load(open(self.started[-1]))

    def posted(self):
        return next(c[2] for c in self.calls if c[1].endswith("/predictions"))

    def test_the_default_model_gets_its_own_input_names_and_an_uploaded_first_frame(self):
        r = t.t_replicate({"session": self.s, "prompt": "A desk at sunrise.", "image": "still.png",
                           "duration": 8.0, "resolution": "480p", "audio": False, "aspect_ratio": "16:9"})
        self.assertEqual(r["model"], "bytedance/seedance-2.5")
        self.assertEqual(r["input"], {"prompt": "A desk at sunrise.", "image": "still.png", "duration": 8,
                                      "resolution": "480p", "generate_audio": False, "aspect_ratio": "16:9"})
        job = self.run_job()
        self.assertEqual(job["status"], "done", job.get("error"))
        sent = self.posted()["input"]
        self.assertEqual(sent["image"], "https://api.replicate.com/v1/files/still.png")
        self.assertTrue(any(c[1] == "/models/bytedance/seedance-2.5/predictions" for c in self.calls))
        self.assertEqual(open(os.path.join(self.s, r["file"]), "rb").read(), b"fake mp4")
        models = json.load(open(os.path.join(self.s, "generated", ".models.json")))
        self.assertEqual(models[os.path.basename(r["file"])], "Seedance 2.5 · Replicate")

    def test_a_shot_clip_uses_the_board_shape_and_the_sketch_only_as_a_reference(self):
        t.t_set_storyboard({"session": self.s, "format": "9:16",
                            "shots": [{"kind": "B-ROLL", "say": "Receipts pile up every month.", "sketch": "A box of receipts.", "do": "Close-up."}]})
        d = t.read_storyboard(self.s)
        d["shots"][0]["image"] = "sketch.png"
        t.write_storyboard(self.s, d)
        open(os.path.join(self.s, "storyboard", "sketch.png"), "wb").write(b"png")
        sid = d["shots"][0]["id"]
        r = t.t_replicate({"session": self.s, "shot": sid, "prompt": "Real footage of receipts.",
                           "params": {"reference_images": ["sketch"]}})
        self.assertEqual(r["input"]["aspect_ratio"], "9:16")
        self.assertEqual(r["input"]["duration"], 4)
        self.assertEqual(t.read_storyboard(self.s)["shots"][0]["generating"], r["file"])
        self.run_job()
        self.assertEqual(self.posted()["input"]["reference_images"], ["https://api.replicate.com/v1/files/sketch.png"])
        self.assertEqual(t.read_storyboard(self.s)["shots"][0]["video"], r["file"])

    def test_a_board_shape_the_model_lacks_becomes_adaptive(self):
        t.t_set_storyboard({"session": self.s, "format": "4:5",
                            "shots": [{"kind": "B-ROLL", "say": "Hi there.", "sketch": "A desk.", "do": "Wide."}]})
        sid = t.read_storyboard(self.s)["shots"][0]["id"]
        r = t.t_replicate({"session": self.s, "shot": sid, "prompt": "A desk."})
        self.assertEqual(r["input"]["aspect_ratio"], "adaptive")

    def test_calls_carry_a_user_agent(self):
        """Cloudflare answers Python's own User-Agent with error 1010 (2026-10-09)."""
        import urllib.request
        seen = []

        class Answer:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b'{"username": "user"}'
        real = urllib.request.urlopen
        urllib.request.urlopen = lambda req, timeout=None: seen.append(req.get_header("User-agent")) or Answer()
        try:
            self.real_http("GET", "/account")
        finally:
            urllib.request.urlopen = real
        self.assertTrue(seen[0].startswith("Takes"))

    def test_wrong_inputs_say_what_the_model_takes(self):
        with self.assertRaisesRegex(ValueError, "480p, 720p, 1080p"):
            t.t_replicate({"session": self.s, "prompt": "x", "resolution": "4k"})
        with self.assertRaisesRegex(ValueError, "Its inputs: .*generate_audio"):
            t.t_replicate({"session": self.s, "prompt": "x", "params": {"camera_fixed": True}})
        with self.assertRaisesRegex(ValueError, "needs prompt"):
            t.t_replicate({"session": self.s})
        with self.assertRaisesRegex(ValueError, "No file"):
            t.t_replicate({"session": self.s, "prompt": "x", "image": "nope.png"})

    def test_a_failed_prediction_marks_the_job_and_the_shot(self):
        self.failure = "NSFW content detected"
        t.t_replicate({"session": self.s, "prompt": "x"})
        job = self.run_job()
        self.assertEqual(job["status"], "error")
        self.assertIn("NSFW", job["error"])

    def test_default_models_keep_their_order_and_the_first_is_used(self):
        self.assertEqual(t.rep_models(), ["bytedance/seedance-2.5"])
        t.rep_set_models(["https://replicate.com/kwaivgi/kling-v3.0", "bytedance/seedance-2.5", "kwaivgi/kling-v3.0"])
        self.assertEqual(t.rep_models(), ["kwaivgi/kling-v3.0", "bytedance/seedance-2.5"])
        self.assertEqual(t.t_replicate_status({})["default"], "kwaivgi/kling-v3.0")
        with self.assertRaisesRegex(ValueError, "owner/name"):
            t.rep_set_models(["just-a-name"])

    def test_the_model_tool_lists_inputs_with_their_allowed_values(self):
        m = t.t_replicate_model({})
        self.assertEqual(m["inputs"]["resolution"]["enum"], ["480p", "720p", "1080p"])
        self.assertEqual(m["inputs"]["duration"]["default"], 5)

    def test_no_token_says_where_to_put_it(self):
        real = t.rep_key
        t.rep_key = lambda: None
        try:
            with self.assertRaisesRegex(ValueError, "Plugins › Replicate"):
                t.t_replicate({"session": self.s, "prompt": "x"})
            self.assertFalse(t.t_replicate_status({})["token"])
        finally:
            t.rep_key = real

    def test_the_catalog_lists_featured_then_popular_with_previews_and_keeps_a_day(self):
        def model(owner, name, runs, cover, example=None, official=True):
            return {"owner": owner, "name": name, "run_count": runs, "is_official": official, "description": name,
                    "cover_image_url": cover, "default_example": {"output": example}}
        coll = {"image-to-video": [model("bytedance", "seedance-2.0", 50, "https://r/c.webp", "https://r/e.mp4"),
                                   model("fofr", "toy", 999, "https://r/t.gif", official=False)],
                "text-to-video": [model("wan-video", "wan-fast", 900, "https://r/w.mp4"),
                                  model("bytedance", "seedance-2.0", 50, "https://r/c.webp")]}
        asked = []

        def fake(method, path, body=None, upload=None):
            asked.append(path)
            if path.startswith("/collections/"):
                return {"models": coll[path.split("/")[-1]]}
            if path == "/models/bytedance/seedance-2.5":
                return model("bytedance", "seedance-2.5", 7, "https://r/s.png", ["https://r/s.mp4"])
            raise ValueError("Replicate has no such model")
        t.rep_http = fake
        out = t.t_replicate_catalog({})
        self.assertEqual([c["model"] for c in out["featured"]], ["bytedance/seedance-2.5"])
        self.assertEqual(out["featured"][0]["image"], "https://r/s.png")
        self.assertEqual(out["featured"][0]["video"], "https://r/s.mp4")
        # Official only, most runs first; a video cover is the video.
        self.assertEqual([c["model"] for c in out["popular"]], ["wan-video/wan-fast", "bytedance/seedance-2.0"])
        self.assertEqual((out["popular"][0]["image"], out["popular"][0]["video"]), (None, "https://r/w.mp4"))
        n = len(asked)
        t.t_replicate_catalog({})
        self.assertEqual(len(asked), n)  # read from _library, no calls

    def test_labels(self):
        self.assertEqual(t.rep_label("bytedance/seedance-2.5"), "Seedance 2.5")
        self.assertEqual(t.rep_label("kwaivgi/kling-v3.0"), "Kling V3.0")
        self.assertEqual(t.rep_label("wan-video/wan-2.7-i2v"), "Wan 2.7 I2V")


if __name__ == "__main__":
    unittest.main()
