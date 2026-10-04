"""B-roll: list_broll reads the folders and the file names, add_broll clones a clip into the session."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class Broll(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.lib = os.path.join(self.root, "_library", "broll")
        for folder, name in (("1 Desk work", "2023-11 Top View Typing (V).mov"),
                             ("3 Reactions", "2024-11 Skeptical Look (H).mp4"),
                             ("3 Reactions", "notes.txt")):
            os.makedirs(os.path.join(self.lib, folder), exist_ok=True)
            open(os.path.join(self.lib, folder, name), "wb").write(b"not a real video")
        self.s = os.path.join(self.root, "Proj", "2026-10-03-idea")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-03T00:00:00Z", "named": True, "takes": []})

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)

    def test_list_and_filter(self):
        clips = t.t_list_broll({})["clips"]
        self.assertEqual(len(clips), 2)
        c = [x for x in clips if x["folder"] == "Desk work"][0]
        self.assertEqual((c["title"], c["filmed"], c["orientation"]), ("Top View Typing", "2023-11", "vertical"))
        self.assertEqual([x["title"] for x in t.t_list_broll({"query": "skeptical"})["clips"]], ["Skeptical Look"])
        self.assertEqual(len(t.t_list_broll({"orientation": "horizontal"})["clips"]), 1)
        self.assertEqual(len(t.t_list_broll({"folder": "reactions"})["clips"]), 1)

    def test_add_to_session(self):
        r = t.t_add_broll({"session": self.s, "files": ["1 Desk work/2023-11 Top View Typing (V).mov"]})
        self.assertTrue(os.path.exists(os.path.join(self.s, "broll", "2023-11 Top View Typing (V).mov")))
        self.assertEqual(len(r["added"]), 1)
        with self.assertRaises(ValueError):
            t.t_add_broll({"session": self.s, "files": ["../../Proj/2026-10-03-idea/session.json"]})


if __name__ == "__main__":
    unittest.main()
