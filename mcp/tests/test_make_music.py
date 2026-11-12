"""make_music: ElevenLabs Music writes a song into _library/audio/Made/. A stand-in answers for the API."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = t.find_tool("ffmpeg")


@unittest.skipUnless(FFMPEG, "needs ffmpeg")
class MakeMusic(unittest.TestCase):
    def setUp(self):
        self.root, self.src = tempfile.mkdtemp(), tempfile.mkdtemp()
        os.environ.update(TAKES_ROOT=self.root, TAKES_SOUND_SOURCE=self.src, TAKES_NO_KEYCHAIN="1")
        tmp = os.path.join(self.root, "tone.mp3")
        subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=d=2", tmp], check=True)
        self.mp3 = open(tmp, "rb").read()
        os.remove(tmp)
        self.calls, self.refuse = [], None
        self.real = t.eleven_http

        def fake(method, path, body=None, files=None, query=None, raw=False):
            self.calls.append((path, body))
            if path == "/v1/user/subscription":
                return {"tier": "starter", "character_count": 1640, "character_limit": 40000}
            if path == "/v1/music":
                if self.refuse and self.refuse in body["prompt"]:
                    raise t.ElevenError("ElevenLabs said 400: bad prompt", 400, {
                        "status": "bad_prompt", "data": {"reason": "copyrighted_material_detected",
                                                         "prompt_suggestion": "Heroic classical strings over soft drum and bass"}})
                return self.mp3
            raise AssertionError(path)
        t.eleven_http = fake

    def tearDown(self):
        t.eleven_http = self.real
        shutil.rmtree(self.root)
        shutil.rmtree(self.src)
        for k in ("TAKES_ROOT", "TAKES_SOUND_SOURCE", "TAKES_NO_KEYCHAIN"):
            os.environ.pop(k, None)

    def test_writes_a_tagged_song_to_made_and_list_music_shows_it(self):
        r = t.t_make_music({"prompt": "Moonlight piano over soft liquid drum and bass", "seconds": 30})
        f = r["files"][0]
        self.assertEqual(f["file"], os.path.join("Made", "Moonlight piano over soft liquid v1.mp3"))
        self.assertEqual(f["ref"], "@library/audio/Made/Moonlight piano over soft liquid v1.mp3")
        self.assertTrue(os.path.isfile(t.lib_path(f["ref"])))
        body = [b for p, b in self.calls if p == "/v1/music"][0]
        self.assertEqual((body["music_length_ms"], body["force_instrumental"], body["model_id"]), (30000, True, "music_v1"))
        self.assertEqual(r["credits_left"], 38360)
        made = t.t_list_music({"group": "Made"})["sounds"]
        self.assertEqual(len(made), 1)
        self.assertEqual(made[0]["prompt"], "Moonlight piano over soft liquid drum and bass")
        self.assertEqual(made[0]["artist"], "ElevenLabs Music")
        self.assertNotIn("prompt", t.audio_tags(t.lib_path(f["ref"])), "other groups do not carry the prompt")

    def test_never_overwrites_and_clamps_length_and_variants(self):
        t.t_make_music({"prompt": "calm piano", "name": "bed"})
        r = t.t_make_music({"prompt": "calm piano", "name": "bed", "seconds": 9999, "variants": 7})
        self.assertEqual([x["file"] for x in r["files"]],
                         [os.path.join("Made", "Bed v%d.mp3" % n) for n in (2, 3, 4)])
        self.assertEqual(r["seconds"], 300)
        self.assertEqual(len([1 for p, _ in self.calls if p == "/v1/music"]), 4)

    def test_a_refused_prompt_retries_once_with_the_suggestion(self):
        self.refuse = "Ode to Joy"
        r = t.t_make_music({"prompt": "Ode to Joy strings over soft drum and bass"})
        self.assertEqual(r["prompt"], "Heroic classical strings over soft drum and bass")
        self.assertIn("changed_prompt", r)
        self.assertEqual(len(r["files"]), 1)

    def test_a_refusal_without_a_suggestion_is_the_error(self):
        def no(method, path, body=None, files=None, query=None, raw=False):
            raise t.ElevenError("ElevenLabs said 500: down", 500, {})
        t.eleven_http = no
        with self.assertRaises(ValueError):
            t.t_make_music({"prompt": "piano"})
        self.assertEqual(os.listdir(os.path.join(self.root, t.LIB)) if os.path.isdir(os.path.join(self.root, t.LIB)) else [], [])

    def test_a_key_without_music_says_which_switch(self):
        body = json.dumps({"detail": {"status": "missing_permissions", "message":
                                      "The API key you used is missing the permission music_generation to execute this operation."}})
        msg = t.eleven_problem(401, body)
        self.assertIn("Music Generation", msg)
        self.assertIn("API Keys", msg)

    def test_names_read_as_titles(self):
        self.assertEqual(t.made_name("moonlight piano, over soft D&B: 174 bpm"), "Moonlight piano over soft D&B 174")
        self.assertEqual(t.made_name("../../etc"), "Etc")
        self.assertEqual(t.made_name("   "), "Song")

    def test_needs_a_prompt(self):
        with self.assertRaises(ValueError):
            t.t_make_music({"prompt": "  "})


if __name__ == "__main__":
    unittest.main()
