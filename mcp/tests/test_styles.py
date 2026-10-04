"""Styles: picked per video or per project, new ones from an example, edit parts kept with notes."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class Styles(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-02-test")
        os.makedirs(os.path.join(self.s, "edits"))
        open(os.path.join(self.s, "edits", "cut-v1.mp4"), "w").close()
        os.makedirs(os.path.join(self.root, "_library", "styles", "Magazine"))
        t.write_meta(self.s, t.read_meta(self.s))

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_session_pick_wins_over_project(self):
        t.t_create_style({"name": "Bold", "description": "Big yellow type", "source": "https://example.com/p"})
        self.assertEqual(t.t_get_session({"session": self.s})["style"], {"name": "Magazine", "picked_by": "default"})
        t.t_set_style({"session": self.s, "style": "Bold"})
        self.assertEqual(t.t_get_library({"session": self.s})["style"], "Bold")
        lib = t.t_get_library({})
        bold = next(x for x in lib["styles"] if x["name"] == "Bold")
        self.assertEqual((bold["status"], bold["used_by"]), ("new", ["Proj/2026-10-02-test"]))
        t.t_set_style({"session": self.s, "style": ""})
        self.assertEqual(t.t_get_library({"session": self.s})["picked_by"], "default")

    def test_save_to_library_versions_and_notes(self):
        src = os.path.join(self.s, "comp")
        os.makedirs(src)
        open(os.path.join(src, "index.html"), "w").close()
        r1 = t.t_save_to_library({"session": self.s, "file": "edits/cut-v1.mp4", "group": "Motion",
                                  "name": "lower-third", "note": "Name and role, bottom left", "source_dir": src})
        r2 = t.t_save_to_library({"session": self.s, "file": "edits/cut-v1.mp4", "group": "Motion",
                                  "name": "lower-third", "note": "Bigger"})
        self.assertEqual((r1["file"], r2["version"]), ("assets/Motion/lower-third-v1.mp4", 2))
        view = t.t_get_library({"session": self.s})["style_library"]
        v1 = view["assets"]["Motion"][0]["versions"][0]
        self.assertEqual((v1["note"], v1["from"]), ("Name and role, bottom left", "Proj/2026-10-02-test"))
        self.assertTrue(os.path.exists(os.path.join(self.root, "_library", "styles", "Magazine", "src",
                                                    "lower-third-v1", "index.html")))
        self.assertNotIn("assets.json", t.library_files(os.path.join(self.root, "_library", "styles", "Magazine")))

    def test_create_style_refuses_a_taken_name(self):
        with self.assertRaises(ValueError):
            t.t_create_style({"name": "Magazine", "description": "x"})


if __name__ == "__main__":
    unittest.main()
