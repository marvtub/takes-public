"""ElevenLabs in Takes: voices, voice-over, fixed words, another voice. A stand-in answers for the API."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = t.find_tool("ffmpeg")


def tone(out, seconds, freq=440):
    subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=%d:duration=%.3f" % (freq, seconds),
                    "-ac", "1", "-ar", "44100", out], check=True)


@unittest.skipUnless(FFMPEG, "needs ffmpeg")
class ElevenLabs(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_NO_KEYCHAIN"] = "1"
        self.s = os.path.join(self.root, "Proj", "2026-10-06-idea")
        os.makedirs(self.s)
        # A 4 s take: video plus a tone, with a transcript.
        subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=30:duration=4",
                        "-f", "lavfi", "-i", "sine=frequency=220:duration=4", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-shortest", os.path.join(self.s, "take-01-camera.mp4")], check=True)
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-06T00:00:00Z", "named": True,
                              "takes": [{"number": 1, "kind": "camera", "file": "take-01-camera.mp4", "duration": 4}]})
        words = [["This", 0.2, 0.5], ["works", 0.6, 1.0], ["on", 1.1, 1.3], ["Monday,", 1.4, 2.0],
                 ["trust", 2.2, 2.6], ["me.", 2.7, 3.0]]
        json.dump({"words": [{"word": w, "start": a, "end": b} for w, a, b in words]},
                  open(os.path.join(self.s, "take-01-camera.words.json"), "w"))
        self.calls = []
        self.speech = 0.6  # seconds of speech the fake TTS returns
        self.real = t.eleven_http

        def fake(method, path, body=None, files=None, query=None, raw=False):
            self.calls.append((method, path, body, sorted((files or {}).keys()), query))
            if path.startswith("/v2/voices"):
                return {"voices": [{"voice_id": "v-nora", "name": "Nora PVC", "category": "professional"},
                                   {"voice_id": "v-anna", "name": "Anna", "category": "generated"}], "has_more": False}
            if path == "/v1/user/subscription":
                return {"tier": "creator", "character_count": 1000, "character_limit": 100000,
                        "voice_slots_used": 2, "voice_limit": 30}
            if path.startswith("/v1/text-to-speech/") or path.startswith("/v1/speech-to-speech/"):
                secs = self.speech
                if files:
                    secs = t.media_duration(files["audio"])
                f = os.path.join(self.root, "fake.mp3")
                tone(f, secs, 660)
                return open(f, "rb").read()
            if path == "/v1/shared-voices":
                return {"voices": [{"public_owner_id": "own1", "voice_id": "lib1", "name": "Brian", "accent": "american"}]}
            if path.startswith("/v1/voices/add/"):
                return {"voice_id": "v-brian"}
            if path == "/v1/text-to-voice/design":
                import base64
                return {"previews": [{"generated_voice_id": "g%d" % i, "audio_base_64": base64.b64encode(b"ID3").decode()}
                                     for i in range(3)]}
            if path == "/v1/text-to-voice":
                return {"voice_id": "v-new"}
            if path == "/v1/speech-to-text":
                return {"words": [{"text": "Hello", "start": 0.1, "end": 0.4, "type": "word"},
                                  {"text": " ", "start": 0.4, "end": 0.5, "type": "spacing"},
                                  {"text": "there", "start": 0.5, "end": 0.9, "type": "word"}]}
            raise AssertionError(path)
        t.eleven_http = fake

    def tearDown(self):
        t.eleven_http = self.real
        for k in ("TAKES_ROOT", "TAKES_NO_KEYCHAIN"):
            os.environ.pop(k, None)

    def test_without_a_default_voice_it_says_where_to_pick_one(self):
        with self.assertRaisesRegex(ValueError, "Settings › Voices"):
            t.t_voiceover({"session": self.s, "text": "Hi"})

    def test_a_voice_is_found_by_the_start_of_its_name_and_becomes_the_default(self):
        r = t.t_voices({"set_default": "nora"})
        self.assertEqual(r["default"], {"id": "v-nora", "name": "Nora PVC"})
        self.assertEqual(t.read_voices_config()["default"]["id"], "v-nora")
        with self.assertRaisesRegex(ValueError, "Anna, Nora PVC"):
            t.resolve_voice("Zed")

    def test_list_shows_account_and_voices_and_search_finds_library_voices(self):
        r = t.t_voices({})
        self.assertEqual(r["account"]["characters_left"], 99000)
        self.assertEqual([v["name"] for v in r["mine"]], ["Nora PVC", "Anna"])
        r = t.t_voices({"search": "deep narrator", "accent": "american"})
        self.assertEqual(r["library"][0]["add"], "own1/lib1")
        self.assertEqual(self.calls[-1][4]["accent"], "american")
        r = t.t_voices({"add": "own1/lib1", "name": "Brian", "set_default": True})
        self.assertEqual(r["default"]["id"], "v-brian")

    def test_voiceover_reads_the_script_into_a_versioned_wav_with_the_voice_noted(self):
        t.write_text(os.path.join(self.s, "script.md"), "First paragraph.\n\nSecond paragraph.")
        t.t_voices({"set_default": "Nora"})
        r = t.t_voiceover({"session": self.s})
        self.assertEqual(r["file"], "generated/voiceover-nora-pvc-v1.wav")
        self.assertTrue(os.path.getsize(os.path.join(self.s, r["file"])) > 1000)
        tts = [c for c in self.calls if c[1].startswith("/v1/text-to-speech/")]
        self.assertEqual(tts[0][1], "/v1/text-to-speech/v-nora")
        self.assertEqual(tts[0][2]["text"], "First paragraph.\n\nSecond paragraph.")
        notes = json.load(open(os.path.join(self.s, "generated", ".models.json")))
        self.assertEqual(notes["voiceover-nora-pvc-v1.wav"], "ElevenLabs · Nora PVC")
        r = t.t_voiceover({"session": self.s, "text": "Again.", "voice": "Anna", "name": "intro"})
        self.assertEqual(r["file"], "generated/intro-v1.wav")

    def test_long_text_splits_with_the_neighbours_as_context(self):
        parts = t.chunks(("A sentence here. " * 100 + "\n\n") * 4, size=2500)
        self.assertTrue(len(parts) >= 3)
        self.assertTrue(all(len(p) <= 2500 for p in parts))

    def test_fix_words_replaces_the_old_words_and_keeps_the_take_length(self):
        t.t_voices({"set_default": "Nora"})
        self.speech = 0.6  # "Monday," took 0.6 s
        r = t.t_fix_words({"session": self.s, "take": "1", "old": "monday", "new": "Tuesday,"})
        self.assertEqual(r["replaced"], "Monday,")
        self.assertTrue(r["fits"])
        self.assertEqual(r["video"], "generated/take-01-camera-fix-v1.mp4")
        self.assertAlmostEqual(t.media_duration(os.path.join(self.s, r["file"])), 4.0, delta=0.05)
        self.assertAlmostEqual(t.media_duration(os.path.join(self.s, r["video"])), 4.0, delta=0.1)
        tts = [c for c in self.calls if c[1].startswith("/v1/text-to-speech/")][0][2]
        self.assertEqual(tts["previous_text"], "This works on")
        self.assertEqual(tts["next_text"], "trust me.")

    def test_fix_words_that_do_not_fit_give_audio_only_and_say_why(self):
        t.t_voices({"set_default": "Nora"})
        self.speech = 1.5
        r = t.t_fix_words({"session": self.s, "take": "1", "old": "Monday", "new": "next Tuesday afternoon"})
        self.assertFalse(r["fits"])
        self.assertNotIn("video", r)
        self.assertIn("cut it in the edit", r["note"])
        self.assertAlmostEqual(t.media_duration(os.path.join(self.s, r["file"])), 4.9, delta=0.1)

    def test_fix_words_names_words_the_take_never_says(self):
        t.t_voices({"set_default": "Nora"})
        with self.assertRaisesRegex(ValueError, "never says 'Friday'"):
            t.t_fix_words({"session": self.s, "take": "1", "old": "Friday", "new": "Tuesday"})

    def test_a_file_without_transcript_is_transcribed_first(self):
        os.remove(os.path.join(self.s, "take-01-camera.words.json"))
        t.t_voices({"set_default": "Nora"})
        self.speech = 0.4
        r = t.t_fix_words({"session": self.s, "take": "1", "old": "there", "new": "here"})
        self.assertEqual(r["replaced"], "there")
        saved = json.load(open(os.path.join(self.s, "take-01-camera.words.json")))
        self.assertEqual([w["word"] for w in saved["words"]], ["Hello", "there"])

    def test_change_voice_keeps_timing_and_makes_a_video(self):
        r = t.t_change_voice({"session": self.s, "take": "1", "voice": "Anna", "start": 1, "end": 3})
        self.assertEqual(r["file"], "generated/take-01-camera-anna-v1.wav")
        self.assertAlmostEqual(t.media_duration(os.path.join(self.s, r["file"])), 4.0, delta=0.05)
        self.assertIn("video", r)
        sts = [c for c in self.calls if c[1].startswith("/v1/speech-to-speech/")][0]
        self.assertEqual((sts[1], sts[3]), ("/v1/speech-to-speech/v-anna", ["audio"]))

    def test_design_writes_three_samples_then_saves_one(self):
        r = t.t_design_voice({"session": self.s, "description": "Warm German woman, 40s, calm and slow", "name": "anna"})
        self.assertEqual([x["file"] for x in r["samples"]],
                         ["generated/voice-anna-%d.mp3" % i for i in (1, 2, 3)])
        r = t.t_design_voice({"save": "g1", "name": "Anna", "set_default": True})
        self.assertEqual(r["default"], {"id": "v-new", "name": "Anna"})

    def test_no_key_says_where_to_put_it(self):
        t.eleven_http = self.real
        old = os.environ.pop("ELEVENLABS_API_KEY", None)
        home = os.environ.get("HOME")
        os.environ["HOME"] = self.root  # no ~/.claude/.env
        try:
            with self.assertRaisesRegex(ValueError, "Settings › Voices"):
                t.t_voices({"set_default": "x"})
        finally:
            os.environ["HOME"] = home
            if old:
                os.environ["ELEVENLABS_API_KEY"] = old


if __name__ == "__main__":
    unittest.main()
