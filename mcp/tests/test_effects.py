"""Effects: shipped and own effects are listed only by list_effects, which carries the opt-in rule."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

REPO_EFFECTS = os.path.join(os.path.dirname(__file__), "..", "..", "effects")


def make_effect(d, slug, name, **meta):
    os.makedirs(os.path.join(d, slug, "src"))
    with open(os.path.join(d, slug, "effect.json"), "w") as f:
        json.dump(dict({"name": name, "description": name + " on screen"}, **meta), f)
    with open(os.path.join(d, slug, "README.md"), "w") as f:
        f.write("# %s\n" % name)
    open(os.path.join(d, slug, "src", "index.html"), "w").close()


class Effects(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "lib")
        self.shipped = os.path.join(self.tmp, "shipped")
        os.makedirs(self.root)
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_EFFECTS"] = self.shipped
        make_effect(self.shipped, "text-behind", "Text behind", needs=["a cutout"])
        make_effect(self.shipped, "glass-graph", "Glass graph")

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        os.environ.pop("TAKES_EFFECTS", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_list_has_every_effect_and_the_rule(self):
        out = t.t_list_effects({})
        self.assertEqual([e["effect"] for e in out["effects"]], ["glass-graph", "text-behind"])
        self.assertIn("only when the user", out["rule"])
        self.assertEqual(out["effects"][1]["needs"], ["a cutout"])
        self.assertNotIn("readme", out["effects"][0])

    def test_one_effect_by_slug_or_name(self):
        for ask in ("text-behind", "Text behind", "text BEHIND"):
            out = t.t_list_effects({"effect": ask})
            self.assertEqual(out["effect"], "text-behind")
            self.assertEqual(out["readme"], "# Text behind\n")
            self.assertTrue(out["src"].endswith(os.path.join("text-behind", "src")))
            self.assertEqual(out["files"], [os.path.join("src", "index.html")])
        with self.assertRaises(ValueError):
            t.t_list_effects({"effect": "lens-flare"})

    def test_own_effect_wins_over_the_shipped_one(self):
        own = os.path.join(self.root, "_library", "effects")
        make_effect(own, "text-behind", "My text behind")
        make_effect(own, "zoom-punch", "Zoom punch")
        names = {e["effect"]: e["name"] for e in t.t_list_effects({})["effects"]}
        self.assertEqual(names, {"glass-graph": "Glass graph", "text-behind": "My text behind", "zoom-punch": "Zoom punch"})

    def test_get_library_never_shows_effects(self):
        # Opt-in (2026-10-28): the design context the agent reads first must not carry them.
        os.makedirs(os.path.join(self.root, "_library", "styles", "Magazine"))
        os.makedirs(os.path.join(self.root, "Proj"))
        out = json.dumps(t.t_get_library({"project": "Proj"}))
        self.assertNotIn("text-behind", out)
        self.assertNotIn("Text behind", out)

    def test_each_shipped_effect_is_complete(self):
        os.environ.pop("TAKES_EFFECTS")
        d = os.path.normpath(REPO_EFFECTS)
        if not os.path.isdir(d):
            self.skipTest("no effects/ in this copy")
        for slug in sorted(os.listdir(d)):
            if slug.startswith("."):
                continue
            for f in t.EFFECT_FILES + ("src",):
                self.assertTrue(os.path.exists(os.path.join(d, slug, f)), "%s has no %s" % (slug, f))
            with open(os.path.join(d, slug, "effect.json")) as f:
                meta = json.load(f)
            for k in ("name", "description", "when"):
                self.assertTrue(meta.get(k), "%s: effect.json has no %s" % (slug, k))
            # Every shipped effect lays itself out for any frame (2026-10-29), with a preview per shape.
            self.assertEqual(meta.get("shape"), "any", slug)
            for f in ("preview-16x9.mp4", "preview-1x1.mp4"):
                self.assertLess(os.path.getsize(os.path.join(d, slug, f)), 1_500_000, slug + "/" + f)
            self.assertLess(os.path.getsize(os.path.join(d, slug, "preview.mp4")), 3_000_000, slug)
            with open(os.path.join(d, slug, "README.md")) as f:
                readme = f.read()
            self.assertNotIn("/Users/", readme, slug)


if __name__ == "__main__":
    unittest.main()
