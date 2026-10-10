"""Images go straight to Nano Banana 2.1 or GPT Image 2.5 (make_image, sketches), each file notes its model; Higgsfield refuses images."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

# A stand-in for the OpenAI call: records out, prompt and inputs, writes a PNG, or fails.
FAKE = r"""
import json, os, sys
root = os.environ["IMG_FAKE_DIR"]
open(os.path.join(root, "args.json"), "w").write(json.dumps(sys.argv[1:]))
if os.path.exists(os.path.join(root, "fail")):
    print("OpenAI said 429: You have no credits remaining.", file=sys.stderr)
    sys.exit(1)
open(sys.argv[1], "wb").write(b"\x89PNG fake")
"""


class MakeImage(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["IMG_FAKE_DIR"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-06-idea")
        os.makedirs(os.path.join(self.s, "thumbnails"))
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-06T00:00:00Z", "named": True, "takes": []})
        fake = os.path.join(self.root, "fake_img.py")
        open(fake, "w").write(FAKE)
        os.environ["TAKES_IMAGE_CMD"] = json.dumps([sys.executable, fake])
        # Gemini stand-in: records (model, out) and writes the file.
        self.gemini = []
        self.real_gemini = t.draw_gemini

        def gemini(prompt, out, fmt, model, images=(), size="1K"):
            self.gemini.append((model, out))
            open(out, "wb").write(b"\x89PNG gemini")
        t.draw_gemini = gemini

    def tearDown(self):
        t.draw_gemini = self.real_gemini
        for k in ("TAKES_ROOT", "TAKES_IMAGE_CMD", "IMG_FAKE_DIR"):
            os.environ.pop(k, None)

    def args(self):
        return json.load(open(os.path.join(self.root, "args.json")))

    def test_an_image_lands_in_generated_with_a_new_version_each_time(self):
        r = t.t_make_image({"session": self.s, "prompt": "A desk at sunrise", "name": "desk"})
        self.assertEqual(r["file"], "generated/desk-v1.png")
        self.assertTrue(os.path.exists(os.path.join(self.s, r["file"])))
        self.assertEqual(t.t_make_image({"session": self.s, "prompt": "Again", "name": "desk"})["file"],
                         "generated/desk-v2.png")

    def test_a_change_sends_the_session_image(self):
        thumb = os.path.join(self.s, "thumbnails", "cover-v1.png")
        open(thumb, "wb").write(b"\x89PNG")
        t.t_make_image({"session": self.s, "prompt": "Make the sky red", "images": ["thumbnails/cover-v1.png"]})
        self.assertEqual(os.path.realpath(self.args()[2]), os.path.realpath(thumb))

    def test_bad_input_is_refused(self):
        with self.assertRaises(ValueError):
            t.t_make_image({"session": self.s, "prompt": ""})
        with self.assertRaises(ValueError):
            t.t_make_image({"session": self.s, "prompt": "x", "quality": "ultra"})
        with self.assertRaises(ValueError):
            t.t_make_image({"session": self.s, "prompt": "x", "images": ["sketch"]})

    def test_higgsfield_refuses_images(self):
        os.environ["TAKES_HIGGSFIELD_CMD"] = json.dumps([sys.executable, "-c", "pass"])
        try:
            with self.assertRaisesRegex(ValueError, "make_image"):
                t.t_higgsfield({"session": self.s, "prompt": "a cat", "kind": "image"})
        finally:
            os.environ.pop("TAKES_HIGGSFIELD_CMD")

    def models(self, folder):
        return json.load(open(os.path.join(self.s, folder, ".models.json")))

    def test_a_new_image_is_flare_a_change_is_sunburst_and_each_notes_its_model(self):
        r = t.t_make_image({"session": self.s, "prompt": "A desk", "name": "desk"})
        self.assertEqual(r["model"], "GPT Image 2.5 Flare")
        thumb = os.path.join(self.s, "thumbnails", "cover-v1.png")
        open(thumb, "wb").write(b"\x89PNG")
        r2 = t.t_make_image({"session": self.s, "prompt": "Red sky", "images": ["thumbnails/cover-v1.png"]})
        self.assertEqual(r2["model"], "GPT Image 2.5 Sunburst")
        r3 = t.t_make_image({"session": self.s, "prompt": "Cheap", "model": "nano-banana-2.1"})
        self.assertEqual(r3["model"], "Nano Banana 2.1")
        self.assertEqual(self.gemini[0][0], "gemini-nano-banana-2.1")
        self.assertEqual(self.models("generated"), {"desk-v1.png": "GPT Image 2.5 Flare",
                                                    os.path.basename(r2["file"]): "GPT Image 2.5 Sunburst",
                                                    os.path.basename(r3["file"]): "Nano Banana 2.1"})
        with self.assertRaises(ValueError):
            t.t_make_image({"session": self.s, "prompt": "x", "model": "dalle"})

    def test_when_openai_fails_nano_banana_draws(self):
        open(os.path.join(self.root, "fail"), "w").close()
        r = t.t_make_image({"session": self.s, "prompt": "A desk"})
        self.assertEqual(r["model"], "Nano Banana 2.1")

    def test_a_sketch_is_nano_banana_then_flare(self):
        out = os.path.join(self.root, "s.png")
        self.assertEqual(t.draw_sketch("one man", out, "16:9"), "Nano Banana 2.1")
        self.assertEqual(self.gemini[0][0], "gemini-nano-banana-2.1")

        def broke(*a, **k):
            raise ValueError("Gemini said 429: quota.")
        t.draw_gemini = broke
        self.assertEqual(t.draw_sketch("one man", out + "2", "16:9"), "GPT Image 2.5 Flare")
        open(os.path.join(self.root, "fail"), "w").close()
        with self.assertRaisesRegex(ValueError, "quota.*no credits"):
            t.draw_sketch("one man", out + "3", "16:9")

    def test_a_draft_says_how_to_make_its_final(self):
        r = t.t_make_image({"session": self.s, "prompt": "A desk at night", "name": "desk", "format": "16:9"})
        self.assertIn("from=generated/desk-v1.png", r["note"])
        self.assertNotIn("final", r)
        self.assertEqual(json.load(open(os.path.join(self.s, "generated", ".prompts.json")))["desk-v1.png"],
                         {"prompt": "A desk at night", "images": [], "format": "16:9"})

    def test_the_final_of_a_draft_is_nano_banana_at_4k_with_the_draft_first(self):
        # The user likes the GPT draft: from= redraws it sharp with the same prompt, references and shape.
        got = []

        def gemini(prompt, out, fmt, model, images=(), size="1K"):
            got.append(dict(prompt=prompt, fmt=fmt, model=model, images=list(images), size=size))
            open(out, "wb").write(b"\x89PNG gemini")
        t.draw_gemini = gemini
        face = os.path.join(self.s, "thumbnails", "face-v1.png")
        open(face, "wb").write(b"\x89PNG")
        d = t.t_make_image({"session": self.s, "prompt": "He waves through the window", "name": "window",
                            "images": ["thumbnails/face-v1.png"], "format": "16:9"})
        self.assertEqual(d["model"], "GPT Image 2.5 Sunburst")
        r = t.t_make_image({"session": self.s, "from": d["file"]})
        self.assertEqual((r["file"], r["model"], r["final"]), ("generated/window-v2.png", "Nano Banana 2.1", True))
        g = got[-1]
        self.assertEqual((g["model"], g["size"], g["fmt"]), ("gemini-nano-banana-2.1", "4K", "16:9"))
        self.assertEqual([os.path.relpath(x, self.s) for x in g["images"]], ["generated/window-v1.png", "thumbnails/face-v1.png"])
        self.assertTrue(g["prompt"].startswith(t.FINAL_ASK))
        self.assertIn("He waves through the window", g["prompt"])
        self.assertEqual(self.models("generated")["window-v2.png"], "Nano Banana 2.1")

    def test_a_final_falls_back_to_sunburst_and_reads_the_shape_of_an_unknown_draft(self):
        def broke(*a, **k):
            raise ValueError("Gemini said 429: quota.")
        t.draw_gemini = broke
        import struct
        png = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 1536, 864) + b"\0" * 16
        open(os.path.join(self.s, "thumbnails", "old-v3.png"), "wb").write(png)
        r = t.t_make_image({"session": self.s, "from": "thumbnails/old-v3.png", "prompt": "Warmer light"})
        self.assertEqual((r["file"], r["model"]), ("generated/old-v1.png", "GPT Image 2.5 Sunburst"))
        self.assertTrue(self.args()[1].endswith("Warmer light"))
        self.assertEqual(t.image_format(os.path.join(self.s, "thumbnails", "old-v3.png")), "16:9")
        with self.assertRaises(ValueError):
            t.t_make_image({"session": self.s, "from": "script.md"})

    def test_higgsfield_models_get_a_readable_name(self):
        self.assertEqual(t.hf_label({"args": ["generate", "create", "seedance_2_5", "--prompt", "x"]}), "Seedance 2.5")
        self.assertEqual(t.hf_label({"args": ["generate", "create", "kling3_0"]}), "Kling 3.0")
        self.assertEqual(t.hf_label({"args": ["generate", "create", "nano_banana_pro"]}), "Nano Banana Pro")
        self.assertEqual(t.hf_label({"args": ["generate", "workflow", "reframe"]}), "Higgsfield reframe")

    def test_sizes(self):
        self.assertEqual(t.openai_size("16:9"), "1536x864")
        self.assertEqual(t.openai_size("9:16"), "864x1536")
        self.assertEqual(t.openai_size("1:1"), "1536x1536")
        self.assertEqual(t.openai_size("21:9"), "1536x656")
        self.assertEqual(t.nearest_size("1536x864"), "1536x1024")
        self.assertEqual(t.nearest_size("1232x1536"), "1024x1536")


if __name__ == "__main__":
    unittest.main()
