"""Music: copied in from the source folder, listed with tags, one song picked per session."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"


class Music(unittest.TestCase):
    def setUp(self):
        self.root, self.src = tempfile.mkdtemp(), tempfile.mkdtemp()
        os.environ["TAKES_ROOT"], os.environ["TAKES_SOUND_SOURCE"] = self.root, self.src
        self.s = os.path.join(self.root, "Proj", "2026-09-28-test")
        os.makedirs(self.s)
        os.makedirs(os.path.join(self.src, "Music"))
        os.makedirs(os.path.join(self.src, "SFX"))
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "sine=d=3", "-metadata", "artist=Dream Cave",
                        "-metadata", "TBPM=157", "-y", os.path.join(self.src, "Music", "26428_Chasing the Truth.mp3")],
                       check=True)
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "sine=d=1", "-y",
                        os.path.join(self.src, "SFX", "47458_Whoosh.mp3")], check=True)
        open(os.path.join(self.src, "Music", "notes.txt"), "w").close()

    def tearDown(self):
        shutil.rmtree(self.root)
        shutil.rmtree(self.src)
        for k in ("TAKES_ROOT", "TAKES_SOUND_SOURCE"):
            os.environ.pop(k, None)

    def test_copies_lists_and_tags(self):
        r = t.t_list_music({})
        self.assertEqual(r["copied_new"], 2)
        self.assertTrue(os.path.exists(os.path.join(self.src, "Music", "26428_Chasing the Truth.mp3")), "originals stay")
        song = next(x for x in r["sounds"] if x["group"] == "Music")
        self.assertEqual((song["file"], song["title"], song["artist"]),
                         ("Music/26428_Chasing the Truth.mp3", "Chasing the Truth", "Dream Cave"))
        self.assertAlmostEqual(song["duration"], 3, delta=0.2)
        self.assertEqual(t.t_list_music({})["copied_new"], 0)
        self.assertEqual([x["group"] for x in t.t_list_music({"group": "sfx"})["sounds"]], ["SFX"])
        self.assertEqual(len(t.t_list_music({"query": "chasing"})["sounds"]), 1)


    def test_tags(self):
        t.t_list_music({})
        song, fx = "Music/26428_Chasing the Truth.mp3", "SFX/47458_Whoosh.mp3"
        r = t.t_tag_sounds({"files": [song, "@library/audio/" + fx], "add": ["Education", " calm  piano "]})
        self.assertEqual(r["tags"][song], ["Education", "calm piano"])
        self.assertEqual(r["all_tags"], {"Education": 2, "calm piano": 2})
        # Case-insensitive: one tag, first spelling kept; remove drops it.
        t.t_tag_sounds({"files": [fx], "add": ["education", "Whoosh"], "remove": ["CALM PIANO"]})
        self.assertEqual(t.load_sound_tags()[fx], ["Education", "Whoosh"])
        listed = t.t_list_music({"tag": "WHOOSH"})
        self.assertEqual([x["file"] for x in listed["sounds"]], [fx])
        self.assertEqual(listed["tags"]["Education"], 2)
        self.assertEqual([x["file"] for x in t.t_list_music({"query": "whoo"})["sounds"]], [fx])
        self.assertEqual(next(x for x in listed["sounds"])["tags"], ["Education", "Whoosh"])
        # tags=[] clears; an empty list is not stored.
        t.t_tag_sounds({"files": [song], "tags": []})
        self.assertNotIn(song, json.load(open(t.sound_tags_path())))
        with self.assertRaises(ValueError):
            t.t_tag_sounds({"files": ["Music/nope.mp3"], "add": ["x"]})
        with self.assertRaises(ValueError):
            t.t_tag_sounds({"files": ["../../etc/hosts"], "add": ["x"]})

    def test_tags_never_overwrite_a_broken_file(self):
        t.t_list_music({})
        with open(t.sound_tags_path(), "w") as f:
            f.write("{broken")
        self.assertEqual(t.t_list_music({})["tags"], {})
        with self.assertRaises(ValueError):
            t.t_tag_sounds({"files": ["SFX/47458_Whoosh.mp3"], "add": ["x"]})
        self.assertEqual(open(t.sound_tags_path()).read(), "{broken")


if __name__ == "__main__":
    unittest.main()
