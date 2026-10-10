"""The model browser's sheet (2026-10-09): Replicate prices from the model page, Higgsfield credits from
`generate cost`, settings and inputs in Takes' words, and the user's own clip times. Stand-ins answer."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

SCHEMA = {"components": {"schemas": {"Input": {"type": "object", "properties": {
    "prompt": {"type": "string"},
    "image": {"type": "string", "format": "uri"},
    "last_frame_image": {"type": "string", "format": "uri"},
    "duration": {"type": "integer", "minimum": -1, "maximum": 30},
    "resolution": {"type": "string", "enum": ["480p", "720p"]},
    "generate_audio": {"type": "boolean", "default": True}}}}}}
PAGE = ('<script>{"x": 1, "billingConfig": {"current_tiers": ['
        '{"criteria": [{"title": "target resolution", "value": "480p"}, {"title": "with audio", "value": false}],'
        ' "prices": [{"price": "$0.10", "title": "per second of output video"}]},'
        '{"criteria": [{"title": "target resolution", "value": "720p"}, {"title": "with audio", "value": true}],'
        ' "prices": [{"price": "$0.20", "title": "per second of output video"}]}]}, "y": 2}</script>')


class Details(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_NO_KEYCHAIN"] = "1"
        os.environ["REPLICATE_API_TOKEN"] = "r8_" + "x" * 37
        self.saved = t.rep_http, None, t.hf_call
        self.calls = []

        def fake(method, path, body=None, upload=None):
            self.calls.append(path)
            return {"owner": "bytedance", "name": "seedance-2.5", "description": "Video", "run_count": 5,
                    "cover_image_url": "https://r/c.png",
                    "default_example": {"output": "https://r/e.mp4", "input": {"duration": 5, "resolution": "720p"},
                                        "metrics": {"predict_time": 224.1}},
                    "latest_version": {"id": "v1", "openapi_schema": SCHEMA}}
        t.rep_http = fake

    def tearDown(self):
        t.rep_http, t.hf_call = self.saved[0], self.saved[2]
        for k in ("TAKES_ROOT", "TAKES_NO_KEYCHAIN", "REPLICATE_API_TOKEN"):
            os.environ.pop(k, None)

    def job(self, s, name, **j):
        d = os.path.join(self.root, "Proj", s, t.GENERATED_DIR, ".jobs")
        os.makedirs(d, exist_ok=True)
        json.dump(j, open(os.path.join(d, name + ".json"), "w"))

    def test_replicate_prices_speed_settings_and_your_clips(self):
        import urllib.request

        class Page:
            def __enter__(s): return s
            def __exit__(s, *a): pass
            def read(s): return PAGE.encode()
        real = urllib.request.urlopen
        urllib.request.urlopen = lambda req, timeout=0: Page()
        try:
            self.job("a", "c1", provider="replicate", model="bytedance/seedance-2.5", status="done",
                     started="2026-10-09T10:00:00Z", ended="2026-10-09T10:02:30Z")
            self.job("b", "c2", provider="replicate", model="other/x", status="done",
                     started="2026-10-09T10:00:00Z", ended="2026-10-09T11:00:00Z")
            d = t.t_replicate_details({"model": "bytedance/seedance-2.5"})
        finally:
            urllib.request.urlopen = real
        self.assertEqual(d["prices"], [{"when": "480p, without audio", "price": "$0.10 a second"},
                                       {"when": "720p, with audio", "price": "$0.20 a second"}])
        self.assertEqual(d["price_note"], "A 5 s clip costs $0.50 to $1.00, by its settings.")
        self.assertEqual(d["speed"], "Replicate's example (5 s, 720p) took 3 min 44 s.")
        self.assertEqual(d["settings"], [{"name": "Length", "value": "up to 30 s"}, {"name": "Quality", "value": "480p, 720p"}])
        self.assertEqual(d["takes"], ["Start frame", "End frame", "Sound"])
        self.assertEqual(d["yours"], "You made 1 clip with it: about 2 min 30 s each.")
        n = len(self.calls)
        t.t_replicate_details({"model": "bytedance/seedance-2.5"})  # kept a day
        self.assertEqual(len(self.calls), n)

    def test_higgsfield_credits_per_quality_and_what_is_left(self):
        model = {"display_name": "Seedance 2.5", "params": [
            {"name": "duration", "type": "integer", "default": 5}, {"name": "resolution", "enum": ["480p", "720p"]},
            {"name": "start_image"}, {"name": "image_references"}, {"name": "generate_audio", "type": "boolean", "default": True}]}
        credits = {"480p": 15, "720p": 35}

        def hf(args, timeout=60):
            if args[:2] == ["model", "get"]:
                return True, json.dumps(model)
            if args[:2] == ["generate", "cost"]:
                return True, json.dumps({"credits": credits[args[args.index("--resolution") + 1]]})
            if args == ["account", "status"]:
                return True, "me@example.com — plus plan, 657 credits"
            raise AssertionError(args)
        t.hf_call = hf
        d = t.t_higgsfield_details({"model": "seedance_2_5"})
        self.assertEqual(d["prices"], [{"when": "5 s, 480p", "price": "15 credits"}, {"when": "5 s, 720p", "price": "35 credits"}])
        self.assertEqual(d["price_note"], "You have 657 credits: about 43 clips at 5 s, 480p.")
        self.assertEqual(d["takes"], ["Start frame", "Reference images", "Sound"])
        self.assertTrue(d["default"])

    def test_higgsfield_default_model_is_used_and_checked(self):
        self.assertEqual(t.hf_default_model(), "seedance_2_5")
        t.hf_set_default("kling3_0")
        self.assertEqual(t.hf_default_model(), "kling3_0")
        with self.assertRaises(ValueError):
            t.hf_set_default("rm -rf")

    def test_higgsfield_catalog_skips_tools_and_borrows_replicate_previews(self):
        names = [{"job_type": j, "display_name": n} for j, n in
                 (("seedance_2_5", "Seedance 2.5"), ("video_upscale", "Video Upscale"), ("wan2_7", "Wan 2.7"))]
        t.hf_call = lambda args, timeout=60: (True, json.dumps(names))
        d = t.t_higgsfield_catalog({})
        self.assertEqual([c["model"] for c in d["featured"]], ["seedance_2_5"])
        self.assertEqual(d["featured"][0]["video"], "https://r/e.mp4")
        self.assertEqual(d["featured"][0]["preview_from"], "bytedance/seedance-2.5")
        self.assertEqual([c["label"] for c in d["more"]], ["Wan 2.7"])
        self.assertEqual(d["default"], "seedance_2_5")


if __name__ == "__main__":
    unittest.main()
