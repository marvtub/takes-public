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

    def test_no_song_picks(self):
        """The app never plays a song over the video: no set_music, and get_session shows no pick."""
        names = [x[0] for x in t.TOOLS]
        self.assertNotIn("set_music", names)
        self.assertNotIn("set_sfx", names)
        self.assertNotIn("music", t.t_get_session({"session": self.s}))
        self.assertNotIn("sfx", t.t_get_session({"session": self.s}))


if __name__ == "__main__":
    unittest.main()
