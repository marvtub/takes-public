"""check_edit's built-in checks: each problem a user heard or saw, made on purpose in a synthetic edit,
fails its check; the plain cut passes every one (2026-10-11)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import takes_mcp as t  # noqa: E402

os.environ["TAKES_NO_REVIEW"] = "1"  # never let a real Gemini key watch a test edit
import check_media as m  # noqa: E402

FFMPEG = t.find_tool("ffmpeg") and t.find_tool("ffprobe")


def take_meta(s, takes):
    t.write_meta(s, {"title": "Check", "createdAt": "2026-10-11T00:00:00Z", "named": True, "takes": takes})


class Base(unittest.TestCase):
    @classmethod
    def make_session(cls, name):
        s = os.path.join(cls.root, "Proj", name)
        os.makedirs(os.path.join(s, "edits"))
        return s

    def run_check(self, name, segs=None, s=None, source=None, **kw):
        """Cuts edits/<name> from the take (once) and runs check_edit. Returns (result, {check: [results]})."""
        s = s or self.s
        path = os.path.join(s, "edits", name)
        if segs is not None and not os.path.exists(path):
            m.cut(os.path.join(s, "take-01-camera.mov"), path, segs, **kw)
        r = t.t_check_edit(dict({"session": s, "file": "edits/" + name}, **({"source": source} if source else {})))
        by = {}
        for x in r["results"]:
            by.setdefault(x.get("check") or x.get("rule"), []).append(x)
        return r, by

    def failed(self, by, check):
        return [x for x in by.get(check, []) if x["pass"] is False]


@unittest.skipUnless(FFMPEG, "needs ffmpeg")
class CheckEdit(Base):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = cls.root
        cls.s = cls.make_session("2026-10-11-check")
        cls.words, script, cls.sent = m.make_take(cls.s)
        with open(os.path.join(cls.s, "script.md"), "w") as f:
            f.write(script)
        take_meta(cls.s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        cls.src = os.path.join(cls.s, "take-01-camera.mov")
        sp = cls.sent
        # Sentences 1-2 and 4-5: sentence 3 is left out on purpose (a whole sentence may go).
        cls.A = (sp[0][0] - 0.15, sp[1][1] + 0.2)
        cls.B = (sp[3][0] - 0.15, sp[4][1] + 0.2)
        cls.segs = [cls.A, cls.B]

    @classmethod
    def tearDownClass(cls):
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(cls.root, ignore_errors=True)

    def setUp(self):
        os.environ["TAKES_ROOT"] = self.root

    def gap_after(self, i):
        """The middle of the pause after take word i."""
        return (self.words[i][1] + self.words[i + 1][0]) / 2.0

    def word_index(self, sec):
        return next(i for i, (a, b, _) in enumerate(self.words) if a >= sec)

    # Alignment and the plain cut

    def test_clean_cut_passes_everything(self):
        r, by = self.run_check("clean-v1.mp4", self.segs)
        self.assertTrue(r["known"])
        self.assertEqual(r["source"], "take-01-camera.mov")
        built = [x for x in r["results"] if "check" in x]
        self.assertEqual([x["check"] for x in built], ["streams", "av_sync", "frozen_video", "band_balance", "echo",
                                                     "picture_drift", "framing", "words", "regression"])
        # framing skips only where Takes.app's face finder is not built.
        self.assertEqual([x for x in built if x["pass"] is not True
                          and not (x["check"] == "framing" and "takes-faces" in x.get("skip", ""))], [])
        self.assertTrue(r["passed"])
        self.assertIn("Every check passes", r["note"])

    def test_align_finds_segments(self):
        path = m.cut(self.src, os.path.join(self.s, "edits", "align-v1.mp4"), self.segs)
        al = t.align(t.envelope(self.s, path), t.envelope(self.s, self.src))
        self.assertEqual(len(al["segments"]), 2)
        a, b = al["segments"]
        self.assertAlmostEqual(a["src"][0] - a["edit"][0], self.A[0], delta=0.03)
        self.assertAlmostEqual(b["src"][0] - b["edit"][0], self.B[0] - (self.A[1] - self.A[0]), delta=0.03)
        self.assertAlmostEqual(a["edit"][1], self.A[1] - self.A[0], delta=0.3)
        self.assertGreater(al["coverage"], 0.9)

    def test_provenance_gives_the_segments(self):
        path = m.cut(self.src, os.path.join(self.s, "edits", "made-v1.mp4"), self.segs)
        L = self.A[1] - self.A[0]
        with open(os.path.splitext(path)[0] + ".words.json", "w") as f:
            json.dump({"v": 2, "words": [], "made_from": {"session_id": t.session_id(self.s), "cut": [
                {"take": 1, "kind": "camera", "in": self.A[0], "out": self.A[1], "at": 0.0},
                {"take": 1, "kind": "camera", "in": self.B[0], "out": self.B[1], "at": L}]}}, f)
        src = t.edit_source(self.s, "edits/made-v1.mp4")
        self.assertTrue(src["known"])
        self.assertEqual(src["segments"][1]["edit"][0], L)
        with mock.patch.object(t, "align", side_effect=AssertionError("provenance skips the search")):
            r, by = self.run_check("made-v1.mp4")
        self.assertTrue(r["known"])
        self.assertTrue(by["words"][0]["pass"])

    def test_guessed_unaligned_source_skips(self):
        other = os.path.join(self.root, "other-take.mov")
        if not os.path.exists(other):
            m.make_take(self.root, name="other-take.mov", seed=3)
        m.cut(other, os.path.join(self.s, "edits", "other-v1.mp4"), [(1.0, 9.0)], af="highpass=f=300")
        r, by = self.run_check("other-v1.mp4")
        self.assertFalse(r["known"])
        for c in ("band_balance", "echo", "picture_drift", "words"):
            self.assertIsNone(by[c][0]["pass"], c)
            self.assertEqual(by[c][0]["skip"], t.NO_SOURCE)
        self.assertTrue(r["passed"])

    def test_bad_source_argument_is_an_error(self):
        with self.assertRaises(ValueError):
            self.run_check("clean-v1.mp4", self.segs, source="take-09-camera.mov")

    def test_given_source_needs_the_edit_in_it(self):
        # A source argument is not enough: a piece of 1 s found by chance in a 58 s edit failed band_balance.
        other = os.path.join(self.root, "other-take.mov")
        if not os.path.exists(other):
            m.make_take(self.root, name="other-take.mov", seed=3)
        m.cut(other, os.path.join(self.s, "edits", "given-v1.mp4"), [(1.0, 9.0)], af="highpass=f=300")
        r, by = self.run_check("given-v1.mp4", source="take-01-camera.mov")
        self.assertFalse(r["known"])
        for c in ("band_balance", "echo", "picture_drift", "words"):
            self.assertIsNone(by[c][0]["pass"], c)
            self.assertEqual(by[c][0]["skip"], t.NOT_FOUND % "take-01-camera.mov")
        self.assertNotIn("Pass source", json.dumps(r["results"]))
        r, by = self.run_check("clean-v1.mp4", self.segs, source="take-01-camera.mov")
        self.assertTrue(r["known"])

    def test_unreadable_file_is_an_error(self):
        clean = m.cut(self.src, os.path.join(self.s, "edits", "whole-v1.mp4"), self.segs) \
            if not os.path.exists(os.path.join(self.s, "edits", "whole-v1.mp4")) else os.path.join(self.s, "edits", "whole-v1.mp4")
        with open(clean, "rb") as f:
            data = f.read()
        files = {"empty-v1.mp4": b"", "junk-v1.mp4": os.urandom(4096), "half-v1.mp4": data[:len(data) // 3]}
        for name, body in files.items():
            with open(os.path.join(self.s, "edits", name), "wb") as f:
                f.write(body)
        for f in ["edits/" + x for x in files] + ["script.md"]:
            with self.assertRaises(ValueError) as e:
                t.t_check_edit({"session": self.s, "file": f})
            self.assertEqual(str(e.exception), "Takes cannot read this file (no video or sound stream). Render it again.")

    def test_file_outside_session_or_missing_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "is not in this session. Pass an edit from get_session"):
            t.t_check_edit({"session": self.s, "file": "../../x.mp4"})
        with self.assertRaisesRegex(ValueError, "Use get_session for the edit files, or next_path"):
            t.t_check_edit({"session": self.s, "file": "edits/nothere-v1.mp4"})
        for bad in ("/etc/hosts", "edits/clean-v1.mp4"):
            with self.assertRaisesRegex(ValueError, "Pass a take file from get_session"):
                self.run_check("clean-v1.mp4", self.segs, source=bad)

    def test_bad_made_from_piece_is_left_out(self):
        path = m.cut(self.src, os.path.join(self.s, "edits", "noat-v1.mp4"), self.segs) \
            if not os.path.exists(os.path.join(self.s, "edits", "noat-v1.mp4")) else os.path.join(self.s, "edits", "noat-v1.mp4")
        with open(os.path.splitext(path)[0] + ".words.json", "w") as f:
            json.dump({"v": 2, "words": [], "made_from": {"session_id": t.session_id(self.s), "cut": [
                {"take": 1, "kind": "camera", "in": self.A[0], "out": self.A[1]}, "x"]}}, f)
        r, by = self.run_check("noat-v1.mp4")
        self.assertTrue(r["known"])

    def test_work_cut_provenance_reaches_edits(self):
        # cut_take writes _work/<name>-vN.mp4 with made_from; the agent renders the final file into edits/.
        work = os.path.join(self.s, t.WORK_DIR)
        os.makedirs(work, exist_ok=True)
        cutp = m.cut(self.src, os.path.join(work, "rough-v1.mp4"), self.segs)
        L = self.A[1] - self.A[0]
        with open(os.path.join(work, "rough-v1.words.json"), "w") as f:
            json.dump({"v": 2, "words": [], "made_from": {"session_id": t.session_id(self.s), "grade": "warm.cube",
                                                           "cut": [
                {"take": 1, "kind": "camera", "in": self.A[0], "out": self.A[1], "at": 0.0},
                {"take": 1, "kind": "camera", "in": self.B[0], "out": self.B[1], "at": L}]}}, f)
        # The final render drops the first 0.5 s of the cut.
        m.cut(cutp, os.path.join(self.s, "edits", "final-v1.mp4"), [(0.5, L + self.B[1] - self.B[0])])
        src = t.edit_source(self.s, "edits/final-v1.mp4")
        self.assertTrue(src["known"])
        self.assertEqual(src["grade"], "warm.cube")
        self.assertEqual(len(src["segments"]), 2, src["segments"])
        a, b = src["segments"]
        self.assertAlmostEqual(a["src"][0] - a["edit"][0], self.A[0] + 0.5, delta=0.05)
        self.assertAlmostEqual(b["src"][0] - b["edit"][0], self.B[0] - L + 0.5, delta=0.05)
        self.assertAlmostEqual(b["edit"][0], L - 0.5, delta=0.05)

    # Sound

    def test_highpass_fails_band_balance(self):
        r, by = self.run_check("thin-v1.mp4", self.segs, af="highpass=f=300")
        bad = self.failed(by, "band_balance")
        self.assertEqual(len(bad), 1)
        self.assertEqual(bad[0]["label"], "Thin voice")
        self.assertEqual(bad[0]["say"], "The voice sounds thin. It lost its low tones.")
        self.assertLess(bad[0]["value"], -8)
        self.assertIn("Hz band is", bad[0]["fix"])

    def test_lowpass_fails_band_balance(self):
        # A hard cut at 7 kHz, as a 14 kHz step in the chain makes it.
        r, by = self.run_check("dull-v1.mp4", self.segs, af="aresample=14000,aresample=48000")
        bad = self.failed(by, "band_balance")
        self.assertEqual(bad[0]["say"], "The voice sounds dull. It lost its high tones.")
        self.assertEqual(bad[0]["label"], "Dull voice")

    def test_lowpass_fails_floor_without_source(self):
        other = os.path.join(self.root, "other-take.mov")
        if not os.path.exists(other):
            m.make_take(self.root, name="other-take.mov", seed=3)
        m.cut(other, os.path.join(self.s, "edits", "floor-v1.mp4"), [(1.0, 9.0)], af="aresample=14000,aresample=48000")
        m.cut(other, os.path.join(self.s, "edits", "nofloor-v1.mp4"), [(1.0, 9.0)])
        r, by = self.run_check("floor-v1.mp4")
        self.assertFalse(r["known"])
        self.assertEqual(self.failed(by, "band_balance")[0]["label"], "Dull voice")
        r, by = self.run_check("nofloor-v1.mp4")
        self.assertIsNone(by["band_balance"][0]["pass"])

    @unittest.skipUnless(shutil.which("say"), "needs macOS say")
    def test_say_voice_lowpass(self):
        s = self.make_session("2026-10-11-say")
        aiff = os.path.join(s, "voice.aiff")
        subprocess.run(["say", "-o", aiff, "This is a test of the voice check. It should hear the high tones go. "
                        "Takes compares the edit with the take, word for word, and finds what changed. "
                        "A voice that lost its highs sounds dull and far away."], check=True)
        m.ff("-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30,eq=contrast=0.3:brightness=-0.3:saturation=0.4",
             "-i", aiff, "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "48000",
             os.path.join(s, "take-01-camera.mov"))
        take_meta(s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        d = t.media_seconds(os.path.join(s, "take-01-camera.mov"))
        r, by = self.run_check("say-v1.mp4", [(0.0, d)], s=s, af="lowpass=f=7000,lowpass=f=7000,lowpass=f=7000,lowpass=f=7000")
        self.assertTrue(r["known"])
        self.assertEqual(self.failed(by, "band_balance")[0]["label"], "Dull voice")

    def test_echo_fails(self):
        r, by = self.run_check("echo-v1.mp4", self.segs, af="aecho=0.8:0.6:60|120:0.5|0.3")
        bad = self.failed(by, "echo")
        self.assertEqual(len(bad), 1, by.get("echo"))
        self.assertEqual(bad[0]["say"], "The voice has more echo than the take.")
        self.assertGreater(bad[0]["value"], 0.08)
        r, by = self.run_check("clean-v1.mp4", self.segs)
        self.assertTrue(by["echo"][0]["pass"])

    def test_aecho_60_and_120_fail(self):
        # One copy of the voice 60 or 120 ms later: the tail grows too little for the tail measure
        # (2026-10-11 verify pass); the repeat measure finds it.
        for ms in (60, 120):
            r, by = self.run_check("aecho%d-v1.mp4" % ms, self.segs, af="aecho=0.8:0.6:%d:0.4" % ms)
            bad = self.failed(by, "echo")
            self.assertEqual(len(bad), 1, by.get("echo"))
            self.assertEqual(bad[0]["say"], "The voice has more echo than the take.")
            # The tail measure may find it first; the repeat measure finds it alone, at its delay.
            path = os.path.join(self.s, "edits", "aecho%d-v1.mp4" % ms)
            ee, es = t.envelope(self.s, path), t.envelope(self.s, self.src)
            segs = t.align(ee, es)["segments"]
            delay, share, noise = t.voice_repeat([ee[int(g["edit"][0] / t.FRAME):int(g["edit"][1] / t.FRAME)] for g in segs],
                                                 [es[int(g["src"][0] / t.FRAME):int(g["src"][1] / t.FRAME)] for g in segs])
            self.assertAlmostEqual(delay, ms / 1000.0, delta=0.006)
            self.assertGreater(share, t.BUILTIN["echo"]["repeat"])
            self.assertGreater(share, t.BUILTIN["echo"]["clear"] * noise)

    def test_processed_voice_has_no_echo(self):
        # A compressor, loudness and an EQ change the sound, not its timing: no echo.
        for name, af in (("comp-v1.mp4", "acompressor=threshold=0.05:ratio=6:attack=5:release=200,loudnorm"),
                         ("thin-v1.mp4", "highpass=f=300")):
            r, by = self.run_check(name, self.segs, af=af)
            self.assertTrue(by["echo"][0]["pass"], (name, by["echo"]))

    def music_over(self, base, name):
        path = os.path.join(self.s, "edits", name)
        if not os.path.exists(path):
            m.ff("-i", base, "-f", "lavfi", "-i", "sine=f=220:duration=12,volume=0.08", "-f", "lavfi", "-i",
                 "anoisesrc=color=brown:amplitude=0.05:duration=14", "-filter_complex",
                 "[1:a][2:a]amix=inputs=2:normalize=0[mu];[0:a][mu]amix=inputs=2:normalize=0:duration=first[a]",
                 "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-ar", "48000", path)
        return path

    def test_music_under_voice_still_checks_echo(self):
        clean = m.cut(self.src, os.path.join(self.s, "edits", "clean-v1.mp4"), self.segs) \
            if not os.path.exists(os.path.join(self.s, "edits", "clean-v1.mp4")) else os.path.join(self.s, "edits", "clean-v1.mp4")
        r, by = self.run_check(os.path.basename(self.music_over(clean, "music-v1.mp4")))
        self.assertTrue(by["echo"][0]["pass"], by["echo"])
        self.assertIn("Music or noise under the voice", by["echo"][0]["note"])
        self.assertIn("only the repeat", by["echo"][0]["note"])
        echo = os.path.join(self.s, "edits", "aecho60-v1.mp4")
        if not os.path.exists(echo):
            m.cut(self.src, echo, self.segs, af="aecho=0.8:0.6:60:0.4")
        r, by = self.run_check(os.path.basename(self.music_over(echo, "musicecho-v1.mp4")))
        bad = self.failed(by, "echo")
        self.assertEqual(len(bad), 1, by["echo"])
        self.assertIn("The voice repeats", bad[0]["fix"])

    def test_voice_stem_beside_the_edit_is_used(self):
        # A cut with its voice alone beside it (cut_take's .wav): the echo is read there.
        work = os.path.join(self.s, "edits", "stem-v1.mp4")
        if not os.path.exists(work):
            m.cut(self.src, work, self.segs)
            m.ff("-i", work, "-vn", "-af", "aecho=0.8:0.6:60:0.4", "-c:a", "pcm_s16le", "-ar", "48000",
                 os.path.splitext(work)[0] + ".wav")
        r, by = self.run_check("stem-v1.mp4")
        self.assertEqual(len(self.failed(by, "echo")), 1, by["echo"])

    # Sync

    def test_itsoffset_fails_av_sync(self):
        clean = os.path.join(self.s, "edits", "clean-v1.mp4")
        if not os.path.exists(clean):
            m.cut(self.src, clean, self.segs)
        m.ff("-i", clean, "-itsoffset", "0.2", "-i", clean, "-map", "0:v", "-map", "1:a", "-c", "copy",
             os.path.join(self.s, "edits", "offset-v1.mp4"))
        r, by = self.run_check("offset-v1.mp4")
        bad = self.failed(by, "av_sync")
        self.assertAlmostEqual(bad[0]["value"], 0.2, delta=0.03)
        self.assertEqual(bad[0]["say"], "The sound is late by 0.2 s.")
        self.assertEqual(bad[0]["label"], "Sound late")

    def test_baked_offset_fails_av_sync(self):
        # Both streams start at 0; the sound comes from 0.2 s earlier in the take.
        r, by = self.run_check("baked-v1.mp4", self.segs, audio_shift=0.2)
        bad = self.failed(by, "av_sync")
        self.assertAlmostEqual(bad[0]["value"], 0.2, delta=0.03)
        r, by = self.run_check("early-v1.mp4", self.segs, audio_shift=-0.2)
        bad = self.failed(by, "av_sync")
        self.assertAlmostEqual(bad[0]["value"], -0.2, delta=0.03)
        self.assertEqual(bad[0]["say"], "The sound is early by 0.2 s.")

    # Picture

    def test_framing_fails_a_face_too_big_for_its_card(self):
        lim = t.BUILTIN["framing"]
        big = [{"size": 0.55, "card": 0.8}]
        ok = [{"size": 0.32, "card": 0.8}]
        pip = [{"size": 0.7, "card": 0.3}]  # a small picture-in-picture box: not judged
        v = t.framing_verdict([(1.0, big), (5.0, ok), (9.0, big), (13.0, pip)], lim)
        self.assertEqual(v[1], [1.0, 9.0])
        self.assertIn("too tight", v[2])
        self.assertIsNone(t.framing_verdict([(1.0, big), (5.0, ok), (9.0, pip)], lim)[2], "one frame is not enough")
        self.assertIn("No face", t.framing_verdict([(1.0, [])], lim)[3]["note"])

    def test_green_fails_picture_drift(self):
        r, by = self.run_check("green-v1.mp4", self.segs, vf="colorbalance=gs=0.3")
        bad = self.failed(by, "picture_drift")
        self.assertEqual(bad[0]["say"], "The picture is greener than the take.")
        self.assertEqual(bad[0]["label"], "Picture color")

    def test_blur_fails_picture_drift(self):
        r, by = self.run_check("soft-v1.mp4", self.segs, vf="gblur=sigma=3")
        bad = self.failed(by, "picture_drift")
        self.assertEqual(bad[0]["say"], "The picture is softer than the take.")
        self.assertEqual(bad[0]["label"], "Soft picture")

    def test_graded_cut_passes(self):
        path = m.cut(self.src, os.path.join(self.s, "edits", "graded-v1.mp4"), self.segs,
                     vf="eq=saturation=0.6:gamma_r=1.1")
        r, by = self.run_check("graded-v1.mp4")
        self.assertFalse(by["picture_drift"][0]["pass"], "without the grade on record it is a change")
        L = self.A[1] - self.A[0]
        with open(os.path.splitext(path)[0] + ".words.json", "w") as f:
            json.dump({"v": 2, "words": [], "made_from": {"grade": "warm", "cut": [
                {"take": 1, "kind": "camera", "in": self.A[0], "out": self.A[1], "at": 0.0},
                {"take": 1, "kind": "camera", "in": self.B[0], "out": self.B[1], "at": L}]}}, f)
        r, by = self.run_check("graded-v1.mp4")
        self.assertTrue(by["picture_drift"][0]["pass"], by["picture_drift"])
        self.assertIn("grade", by["picture_drift"][0]["note"])

    def test_magazine_cards_pass(self):
        # A text card (a still, no voice from the take) between the two parts.
        a = m.cut(self.src, os.path.join(self.root, "mag-a.mp4"), [self.A])
        b = m.cut(self.src, os.path.join(self.root, "mag-b.mp4"), [self.B])
        m.ff("-i", a, "-f", "lavfi", "-i", "color=c=0xF2EDE4:size=320x240:rate=30:duration=3",
             "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-i", b, "-filter_complex",
             "[2:a]atrim=0:3[s];[0:v][0:a][1:v][s][3:v][3:a]concat=n=3:v=1:a=1[v][a]", "-map", "[v]", "-map", "[a]",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "48000",
             os.path.join(self.s, "edits", "mag-v1.mp4"))
        r, by = self.run_check("mag-v1.mp4")
        self.assertTrue(r["known"])
        for c in ("picture_drift", "frozen_video", "band_balance", "av_sync"):
            self.assertTrue(by[c][0]["pass"], by[c])

    @unittest.skipUnless(t.find_tool("ffmpeg") and t.has_filter("zscale"), "needs ffmpeg with zscale")
    def test_hlg_untonemapped_fails(self):
        s = self.hlg_session()
        r, by = self.run_check("hlg-raw-v1.mp4", [(0.0, 8.0)], s=s)
        self.assertIn("washed out", self.failed(by, "picture_drift")[0]["say"])

    @unittest.skipUnless(t.find_tool("ffmpeg") and t.has_filter("zscale"), "needs ffmpeg with zscale")
    def test_hlg_tonemapped_passes(self):
        s = self.hlg_session()
        r, by = self.run_check("hlg-sdr-v1.mp4", [(0.0, 8.0)], s=s,
                               vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,"
                                  "zscale=t=bt709:m=bt709:r=tv,format=yuv420p")
        self.assertTrue(by["picture_drift"][0]["pass"], by["picture_drift"])

    def hlg_session(self):
        s = os.path.join(self.root, "Proj", "2026-10-11-hlg")
        if os.path.isdir(s):
            return s
        os.makedirs(os.path.join(s, "edits"))
        m.make_take(s, seconds=10.0)
        hdr = os.path.join(s, "take-01-camera.mov")
        os.replace(hdr, os.path.join(s, "sdr.mov"))
        m.ff("-i", os.path.join(s, "sdr.mov"), "-vf", "zscale=t=arib-std-b67:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le",
             "-c:v", "ffv1", "-color_trc", "arib-std-b67", "-color_primaries", "bt2020", "-colorspace", "bt2020nc",
             "-c:a", "copy", hdr)
        os.remove(os.path.join(s, "sdr.mov"))
        take_meta(s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        return s

    def test_still_fails_frozen(self):
        other = os.path.join(self.root, "other-take.mov")
        if not os.path.exists(other):
            m.make_take(self.root, name="other-take.mov", seed=3)
        m.ff("-i", other, "-filter_complex", "[0:v]trim=0:2,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=12[v];"
             "[0:a]atrim=0:14,asetpts=PTS-STARTPTS[a]", "-map", "[v]", "-map", "[a]", "-c:v", "libx264",
             "-pix_fmt", "yuv420p", "-c:a", "aac", os.path.join(self.s, "edits", "still-v1.mp4"))
        r, by = self.run_check("still-v1.mp4")
        bad = self.failed(by, "frozen_video")
        self.assertEqual(bad[0]["label"], "Frozen picture")
        self.assertAlmostEqual(bad[0]["at"][0], 2.0, delta=0.3)
        self.assertTrue(bad[0]["say"].startswith("The picture stops from 0:02 to 0:1"), bad[0]["say"])

    def test_static_screen_cut_passes(self):
        s = os.path.join(self.root, "Proj", "2026-10-11-screen")
        os.makedirs(os.path.join(s, "edits"))
        m.make_take(s, name="take-01-camera.mov", seconds=20.0, picture="color=c=0x334455:size=320x240:rate=30")
        os.replace(os.path.join(s, "take-01-camera.mov"), os.path.join(s, "take-01-screen.mov"))
        take_meta(s, [{"number": 1, "kind": "screen", "file": "take-01-screen.mov"}])
        m.cut(os.path.join(s, "take-01-screen.mov"), os.path.join(s, "edits", "ui-v1.mp4"), [(0.2, 9.0), (11.0, 19.5)])
        r, by = self.run_check("ui-v1.mp4", s=s, source="take-01-screen.mov")
        self.assertTrue(r["known"])
        self.assertTrue(by["frozen_video"][0]["pass"], by["frozen_video"])

    def test_short_card_passes(self):
        a = m.cut(self.src, os.path.join(self.root, "card-a.mp4"), [self.A])
        m.ff("-i", a, "-f", "lavfi", "-i", "color=c=white:size=320x240:rate=30:duration=3", "-f", "lavfi", "-i",
             "anullsrc=r=48000:cl=mono", "-filter_complex", "[2:a]atrim=0:3[s];[0:v][0:a][1:v][s]concat=n=2:v=1:a=1[v][a]",
             "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "48000",
             os.path.join(self.s, "edits", "card-v1.mp4"))
        r, by = self.run_check("card-v1.mp4")
        self.assertTrue(by["frozen_video"][0]["pass"], by["frozen_video"])

    # Streams

    def test_chapter_and_data_fail_streams(self):
        clean = os.path.join(self.s, "edits", "clean-v1.mp4")
        if not os.path.exists(clean):
            m.cut(self.src, clean, self.segs)
        meta = os.path.join(self.root, "chapters.txt")
        with open(meta, "w") as f:
            f.write(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=4000\ntitle=One\n")
        m.ff("-i", clean, "-i", meta, "-map_metadata", "1", "-map_chapters", "1", "-c", "copy",
             os.path.join(self.s, "edits", "chapter-v1.mp4"))
        m.ff("-i", clean, "-c", "copy", "-timecode", "00:00:00:00", os.path.join(self.s, "edits", "data-v1.mov"))
        for name in ("chapter-v1.mp4", "data-v1.mov"):
            r, by = self.run_check(name)
            bad = self.failed(by, "streams")
            self.assertEqual(bad[0]["say"], "The file has an extra track that can freeze the video.", name)
            self.assertEqual(bad[0]["label"], "Extra track")
            self.assertIn("-map_chapters -1 -dn -sn", bad[0]["fix"])

    # Words

    def test_words_mid_sentence_fails(self):
        sp = self.sent
        i = self.word_index(sp[4][0]) + 1  # the cut stops after the second word of sentence 5
        r, by = self.run_check("mid-v1.mp4", [self.A, (self.B[0], self.gap_after(i))])
        bad = self.failed(by, "words")
        self.assertEqual(len(bad), 1, by["words"])
        self.assertEqual(bad[0]["label"], "Missing words")
        self.assertIn("The cut stops in the middle of a sentence at 0:", bad[0]["say"])
        self.assertIn(self.words[i][2], bad[0]["say"])

    def test_words_whole_sentence_dropped_passes(self):
        r, by = self.run_check("clean-v1.mp4", self.segs)
        self.assertTrue(by["words"][0]["pass"])

    def test_words_said_twice(self):
        i = self.word_index(self.sent[1][0]) + 4  # in the middle of sentence 2
        k = i - 3
        while self.gap_after(i) - self.gap_after(k) < 0.8:
            k -= 1
        r, by = self.run_check("twice-v1.mp4", [(self.A[0], self.gap_after(i)), (self.gap_after(k), self.B[1])])
        bad = self.failed(by, "words")
        self.assertEqual([x["label"] for x in bad], ["Words twice"], by["words"])
        self.assertIn("Words are said twice at 0:", bad[0]["say"])

    def test_words_clipped(self):
        w = max(range(len(self.words) - 1), key=lambda j: self.words[j][1] - self.words[j][0])
        a, b, _ = self.words[w]
        r, by = self.run_check("clip-v1.mp4", [(max(0.0, a - 3.0), (a + b) / 2.0 + 0.05)])
        bad = [x for x in self.failed(by, "words") if x["label"] == "Cut word"]
        self.assertEqual(len(bad), 1, by["words"])
        self.assertIn(self.words[w][2], bad[0]["say"])

    def test_words_pick_up_from_another_take_passes(self):
        # Sentence 2 starts in take 1 and ends in take 2 (a pick-up line): the sentence is whole.
        s = self.make_session("2026-10-11-pickup")
        w1, script, _ = m.make_take(s, seed=7)
        w2, _, _ = m.make_take(s, name="take-02-camera.mov", seed=11)
        with open(os.path.join(s, "script.md"), "w") as f:
            f.write(script)
        take_meta(s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov"},
                      {"number": 2, "kind": "camera", "file": "take-02-camera.mov"}])
        for k, e in ((8, 15), (12, 31)):
            a1, b1 = w1[0][0] - 0.15, (w1[k - 1][1] + w1[k][0]) / 2
            a2, b2 = (w2[k - 1][1] + w2[k][0]) / 2, (w2[e][1] + w2[e + 1][0]) / 2
            name = "pickup%d-v1.mp4" % k
            out = os.path.join(s, "edits", name)
            parts = ("[0:v]trim=%g:%g,setpts=PTS-STARTPTS[v0];[0:a]atrim=%g:%g,asetpts=PTS-STARTPTS[a0];"
                     "[1:v]trim=%g:%g,setpts=PTS-STARTPTS[v1];[1:a]atrim=%g:%g,asetpts=PTS-STARTPTS[a1];"
                     "[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]" % (a1, b1, a1, b1, a2, b2, a2, b2))
            m.ff("-i", os.path.join(s, "take-01-camera.mov"), "-i", os.path.join(s, "take-02-camera.mov"),
                 "-filter_complex", parts, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-ar", "48000", out)
            r, by = self.run_check(name, s=s)
            self.assertTrue(r["known"], name)
            self.assertEqual(self.failed(by, "words"), [], (name, "no made_from"))
            with open(os.path.splitext(out)[0] + ".words.json", "w") as f:
                json.dump({"v": 2, "words": [], "made_from": {"session_id": t.session_id(s), "cut": [
                    {"take": 1, "kind": "camera", "in": a1, "out": b1, "at": 0.0},
                    {"take": 2, "kind": "camera", "in": a2, "out": b2, "at": b1 - a1}]}}, f)
            r, by = self.run_check(name, s=s)
            self.assertTrue(r["known"], name)
            self.assertEqual(self.failed(by, "words"), [], (name, "made_from"))

    def test_words_numbers_normalized(self):
        self.assertEqual(t.spoken("10"), ["ten"])
        self.assertEqual(t.spoken("2,000"), ["two", "thousand"])
        self.assertEqual(t.spoken("It’s"), ["it", "is"])
        self.assertEqual(t.spoken("don't"), ["do", "not"])
        s = self.make_session("2026-10-11-numbers")
        with open(os.path.join(s, "script.md"), "w") as f:
            f.write("# Hook\n\nWe have 10 takes and it's fine. Then we cut.")
        words = [(0.0, 0.2, "we"), (0.3, 0.5, "have"), (0.6, 0.8, "ten"), (1.2, 1.5, "takes"), (1.6, 1.7, "and"),
                 (1.8, 1.9, "it"), (2.0, 2.1, "is"), (2.2, 2.5, "fine."), (2.6, 2.8, "then"), (2.9, 3.0, "we"),
                 (3.1, 3.4, "cut")]
        ends = t.sentence_ends(s, words)
        # The 0.4 s pause after "ten" is not a sentence end: the script says the sentence goes on.
        self.assertEqual([w for (_, _, w), e in zip(words, ends) if e], ["fine.", "cut"])

    def test_never_calls_eleven_transcribe(self):
        with mock.patch.object(t, "eleven_transcribe", side_effect=AssertionError("no paid transcription")):
            r, by = self.run_check("clean-v1.mp4", self.segs)
        self.assertTrue(by["words"][0]["pass"])

    def test_words_skip_without_transcript(self):
        s = self.make_session("2026-10-11-nowords")
        m.make_take(s)
        os.remove(os.path.join(s, "take-01-camera.words.json"))
        take_meta(s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        r, by = self.run_check("x-v1.mp4", [(0.2, 9.0)], s=s)
        self.assertEqual(by["words"][0]["skip"], "The take has no transcript yet.")

    def test_words_skip_with_old_transcript(self):
        # Apple's words stretch over the pauses: no exact cut points, so words does not judge them.
        s = self.make_session("2026-10-11-apple")
        m.make_take(s)
        w = os.path.join(s, "take-01-camera.words.json")
        with open(w) as f:
            words = json.load(f)["words"]
        with open(w, "w") as f:
            json.dump({"source": "apple en_US", "words": words}, f)
        take_meta(s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        r, by = self.run_check("x-v1.mp4", [(0.2, 9.0)], s=s)
        self.assertEqual(by["words"][0]["skip"], "The take has no exact word times yet. cut_take and rough_cut make them.")

    # Saving and the asset lists

    def test_saved_entry_v2_and_other_entries_kept(self):
        s = self.make_session("2026-10-11-save")
        m.make_take(s, seconds=10.0)
        take_meta(s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        old = {"edits/old-v1.mp4": {"at": "2026-10-01T00:00:00Z", "results": [{"rule": "cut-1", "pass": False}]}}
        with open(os.path.join(s, "checks.json"), "w") as f:
            json.dump(old, f)
        r, by = self.run_check("a-v1.mp4", [(0.2, 8.0)], s=s)
        with open(os.path.join(s, "checks.json")) as f:
            saved = json.load(f)
        self.assertEqual(saved["edits/old-v1.mp4"], old["edits/old-v1.mp4"])
        e = saved["edits/a-v1.mp4"]
        self.assertEqual(e["v"], 2)
        self.assertEqual(e["source"], "take-01-camera.mov")
        self.assertAlmostEqual(e["mtime"], os.path.getmtime(os.path.join(s, "edits", "a-v1.mp4")), delta=0.01)
        self.assertEqual(e["results"], r["results"])
        self.assertIn("passed", e)

    def test_unreadable_checks_json_renamed_hidden(self):
        s = self.make_session("2026-10-11-bad")
        with open(os.path.join(s, "checks.json"), "w") as f:
            f.write("{not json")
        m.ff("-f", "lavfi", "-i", "sine=f=440:duration=2", os.path.join(s, "edits", "a-v1.m4a"))
        take_meta(s, [])
        t.t_check_edit({"session": s, "file": "edits/a-v1.m4a"})
        kept = [f for f in os.listdir(s) if f.startswith(".checks-unreadable-")]
        self.assertEqual(len(kept), 1)
        self.assertEqual(open(os.path.join(s, kept[0])).read(), "{not json")
        with open(os.path.join(s, "checks.json")) as f:
            self.assertIn("edits/a-v1.m4a", json.load(f))

    def test_checks_json_not_an_asset(self):
        self.run_check("clean-v1.mp4", self.segs)
        files = [a["file"] for a in t.assets(self.s, {"take-01-camera.mov"})]
        self.assertNotIn("checks.json", files)
        self.assertTrue(os.path.exists(os.path.join(self.s, "checks.json")))

    def test_cache_not_an_asset(self):
        self.run_check("clean-v1.mp4", self.segs)
        self.assertTrue(os.listdir(os.path.join(self.s, t.CHECKS_CACHE)))
        files = [a["file"] for a in t.assets(self.s, {"take-01-camera.mov"})]
        self.assertFalse([f for f in files if ".checks" in f], files)

    def test_audio_only_edit_runs_sound_checks(self):
        m.ff("-i", self.src, "-filter_complex", "[0:a]atrim=%g:%g,asetpts=PTS-STARTPTS[a];[0:a]atrim=%g:%g,"
             "asetpts=PTS-STARTPTS[b];[a][b]concat=n=2:v=0:a=1[o]" % (self.A + self.B), "-map", "[o]",
             "-c:a", "aac", "-ar", "48000", os.path.join(self.s, "edits", "voice-v1.m4a"))
        r, by = self.run_check("voice-v1.m4a")
        self.assertEqual(sorted(by), ["band_balance", "echo", "regression", "streams", "words"])
        self.assertTrue(r["known"])
        self.assertTrue(all(x["pass"] for x in r["results"]), r["results"])

    def test_budget_skips_slow_check(self):
        with mock.patch.object(t, "CHECK_BUDGET", 0.01):
            r, by = self.run_check("budget-v1.mp4", self.segs)
        skipped = [x for x in r["results"] if x.get("skip") == t.OUT_OF_TIME]
        self.assertTrue(skipped)
        self.assertIn("did not run", r["note"])

    def test_get_session_check_states(self):
        self.run_check("state-v1.mp4", self.segs)
        self.run_check("state-v2.mp4", self.segs)   # the newest of its slug
        self.run_check("thin-v1.mp4", self.segs, af="highpass=f=300")
        m.cut(self.src, os.path.join(self.s, "edits", "fresh-v1.mp4"), self.segs)
        self.run_check("old-v1.mp4", self.segs)
        later = time.time() + 30
        os.utime(os.path.join(self.s, "edits", "old-v1.mp4"), (later, later))
        st = t.t_get_session({"session": self.s})["checks"]
        self.assertNotIn("edits/state-v1.mp4", st)
        self.assertEqual(st["edits/state-v2.mp4"], {"state": "passed"})
        self.assertEqual(st["edits/thin-v1.mp4"], {"state": "problems", "problems": ["Thin voice"]})
        self.assertEqual(st["edits/fresh-v1.mp4"], {"state": "unchecked"})
        self.assertEqual(st["edits/old-v1.mp4"], {"state": "stale"})

    def test_no_name_in_user_strings(self):
        seen = []
        for name, kw in (("thin-v1.mp4", {"af": "highpass=f=300"}), ("clean-v1.mp4", {}),
                         ("soft-v1.mp4", {"vf": "gblur=sigma=3"}), ("baked-v1.mp4", {"audio_shift": 0.2})):
            r, by = self.run_check(name, self.segs, **kw)
            seen.append(r["note"])
            seen += [x.get(k) or "" for x in r["results"] for k in ("say", "fix", "note", "skip", "label")]
        for text in seen + [t.NO_SOURCE, t.OUT_OF_TIME]:
            self.assertNotIn("The user", text)

    @unittest.skipUnless(os.environ.get("TAKES_SLOW_TESTS") == "1", "set TAKES_SLOW_TESTS=1 for the timing test")
    def test_timing_3min_edit(self):
        s = self.make_session("2026-10-11-timing")
        m.make_take(s, seconds=600.0, picture="testsrc2=size=3840x2160:rate=30")
        take_meta(s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        segs = [(20.0 + 40 * i, 40.0 + 40 * i) for i in range(9)]
        m.cut(os.path.join(s, "take-01-camera.mov"), os.path.join(s, "edits", "long-v1.mp4"), segs,
              vf="scale=1920:1080")
        t0 = time.time()
        r, by = self.run_check("long-v1.mp4", s=s)
        first = time.time() - t0
        t0 = time.time()
        self.run_check("long-v1.mp4", s=s)
        second = time.time() - t0
        self.assertTrue(r["known"])
        self.assertLess(first, 30)
        self.assertLess(second, 10)


@unittest.skipUnless(FFMPEG, "needs ffmpeg")
class Regression(Base):
    """A fix the user approved in v2 that comes undone in a later version."""

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = cls.root
        cls.s = cls.make_session("2026-10-11-reg")
        m.make_take(cls.s, seconds=16.0)
        take_meta(cls.s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        src = os.path.join(cls.s, "take-01-camera.mov")
        base = os.path.join(cls.root, "base.mp4")
        m.cut(src, base, [(0.0, 14.0)])
        loud = "if(between(t,4,8),0.5,0.03)"

        def music(name, vol, shift=0.0):
            m.ff("-i", base, "-f", "lavfi", "-i", "sine=f=220:duration=14,volume=%s:eval=frame" % ("'%s'" % vol),
                 "-filter_complex", "[1:a]adelay=%d:all=1[mu];[0:a][mu]amix=inputs=2:normalize=0:duration=first[a]"
                 % int(shift * 1000), "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-ar", "48000",
                 os.path.join(cls.s, "edits", name))
        for slug in ("hook", "intro", "outro"):
            music(slug + "-v1.mp4", loud)
            music(slug + "-v2.mp4", "0.03")
            music(slug + "-v3.mp4", loud)
        music("hook-v4.mp4", "0.01")
        music("shift-v1.mp4", loud)
        music("shift-v2.mp4", "0.03")
        # v3 starts 2 s later in the take: the same window sits 2 s earlier in the file.
        b2 = os.path.join(cls.root, "base2.mp4")
        m.cut(src, b2, [(2.0, 14.0)])
        m.ff("-i", b2, "-f", "lavfi", "-i", "sine=f=220:duration=12,volume='if(between(t,2,6),0.5,0.03)':eval=frame",
             "-filter_complex", "[0:a][1:a]amix=inputs=2:normalize=0:duration=first[a]", "-map", "0:v", "-map", "[a]",
             "-c:v", "copy", "-c:a", "aac", "-ar", "48000", os.path.join(cls.s, "edits", "shift-v3.mp4"))

        def c(cid, slug, text, time_=5.0, at="2026-10-10T00:00:00.000Z"):
            reply = {"by": "claude", "text": "Quieter", "at": "2026-10-10T01:00:00Z", "file": "edits/%s-v2.mp4" % slug}
            if time_ is not None:
                reply["time"] = time_
            return {"id": cid, "file": "edits/%s-v1.mp4" % slug, "start": 5.0, "end": 7.0, "text": text,
                    "status": "resolved", "by": "user", "at": at, "replies": [reply], "lesson": "one-off"}
        t.write_comments(cls.s, {"comments": [
            c("c12", "hook", "music too loud"),
            c("c13", "intro", "music too loud here", time_=None),
            c("c14", "outro", "music too loud"),
            {"id": "c15", "file": "edits/outro-v2.mp4", "start": 5.5, "end": 6.5, "text": "louder again please",
             "status": "resolved", "by": "user", "at": "2026-10-10T02:00:00.000Z", "replies": []},
            c("c16", "shift", "music too loud")]})

    @classmethod
    def tearDownClass(cls):
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(cls.root, ignore_errors=True)

    def setUp(self):
        os.environ["TAKES_ROOT"] = self.root

    def test_regression_reverted_fails(self):
        r, by = self.run_check("hook-v3.mp4")
        bad = self.failed(by, "regression")
        self.assertEqual(len(bad), 1, by["regression"])
        self.assertEqual(bad[0]["comment"], "c12")
        self.assertEqual(bad[0]["label"], "Fix undone")
        self.assertEqual(bad[0]["say"], "A fix you approved changed at 0:05: “music too loud” (fixed in hook-v2).")
        self.assertEqual(bad[0]["fix"], "Start from hook-v2 at 0:05. If the change is on purpose, ask the user first.")
        self.assertNotIn("c12", bad[0]["say"])

    def test_regression_global_change_passes(self):
        r, by = self.run_check("hook-v4.mp4")
        self.assertTrue(by["regression"][0]["pass"], by["regression"])

    def test_regression_fixed_version_passes(self):
        r, by = self.run_check("hook-v2.mp4")
        self.assertTrue(by["regression"][0]["pass"])

    def test_regression_without_fixed_at(self):
        r, by = self.run_check("intro-v3.mp4")
        self.assertEqual([x["comment"] for x in self.failed(by, "regression")], ["c13"])

    def test_regression_skips_newer_comment(self):
        r, by = self.run_check("outro-v3.mp4")
        self.assertTrue(by["regression"][0]["pass"], by["regression"])

    def test_regression_finds_shifted_window(self):
        r, by = self.run_check("shift-v3.mp4")
        bad = self.failed(by, "regression")
        self.assertEqual(len(bad), 1, by["regression"])
        self.assertAlmostEqual(bad[0]["at"][0], 3.0, delta=0.3)


@unittest.skipUnless(FFMPEG, "needs ffmpeg")
class Reframe(Base):
    """Vertical footage and reframed edits (a 9:16 cut of a 16:9 take, a punch-in): the picture is found in
    the take and compared at the same scale (2026-10-11 verify pass: gblur sigma 3 passed at 9:16, every
    reframe skipped)."""

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = cls.root
        cls.v = cls.make_session("2026-10-11-vertical")
        m.make_take(cls.v, seconds=12.0, picture="testsrc2=size=1080x1920:rate=30")
        take_meta(cls.v, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        cls.w = cls.make_session("2026-10-11-wide")
        m.make_take(cls.w, seconds=12.0, picture="testsrc2=size=1920x1080:rate=30")
        take_meta(cls.w, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        cls.segs = [(1.0, 5.5), (6.5, 11.0)]

    @classmethod
    def tearDownClass(cls):
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(cls.root, ignore_errors=True)

    def setUp(self):
        os.environ["TAKES_ROOT"] = self.root

    def pd(self, s, name, vf=None):
        if not os.path.exists(os.path.join(s, "edits", name)):
            m.cut(os.path.join(s, "take-01-camera.mov"), os.path.join(s, "edits", name), self.segs, vf=vf)
        r, by = self.run_check(name, s=s)
        self.assertTrue(r["known"])
        return by["picture_drift"][0]

    def test_vertical_blur_fails(self):
        self.assertTrue(self.pd(self.v, "v-v1.mp4")["pass"])
        x = self.pd(self.v, "vsoft-v1.mp4", "gblur=sigma=3")
        self.assertFalse(x["pass"], x)
        self.assertEqual(x["label"], "Soft picture")

    def test_reframed_edits_are_checked(self):
        for name, vf in (("r916-v1.mp4", "crop=608:1080:656:0,scale=1080:1920"),
                         ("punch-v1.mp4", "crop=1440:810:240:135,scale=1920:1080"),
                         ("square-v1.mp4", "crop=1080:1080:420:0,scale=720:720")):
            x = self.pd(self.w, name, vf)
            self.assertTrue(x["pass"], (name, x))
            x = self.pd(self.w, name.replace("-v1", "soft-v1"), vf + ",gblur=sigma=3")
            self.assertFalse(x["pass"], (name, x))
            self.assertEqual(x["say"], "The picture is softer than the take.")

    def test_find_region(self):
        e = os.path.join(self.w, "edits", "r916-v1.mp4")
        if not os.path.exists(e):
            m.cut(os.path.join(self.w, "take-01-camera.mov"), e, self.segs, vf="crop=608:1080:656:0,scale=1080:1920")
        region, score = t.find_region(e, 3.0, os.path.join(self.w, "take-01-camera.mov"), 4.0, (1080, 1920), (1920, 1080))
        self.assertGreater(score, 0.95)
        for got, want in zip(region, (656, 0, 608, 1080)):
            self.assertAlmostEqual(got, want, delta=24)

    def test_find_region_at_the_left_edge(self):
        # A 9:16 cut near the take's left edge: the search that looked at every place at 240 px found a
        # smaller crop lower down (486x864 at 0.972, 2026-10-22).
        e = os.path.join(self.w, "edits", "r916left-v1.mp4")
        if not os.path.exists(e):
            m.cut(os.path.join(self.w, "take-01-camera.mov"), e, self.segs, vf="crop=608:1080:40:0,scale=1080:1920")
        region, score = t.find_region(e, 3.0, os.path.join(self.w, "take-01-camera.mov"), 4.0, (1080, 1920), (1920, 1080))
        self.assertGreater(score, 0.99)
        for got, want in zip(region, (40, 0, 608, 1080)):
            self.assertAlmostEqual(got, want, delta=16)

    def test_recipe_crop_skips_the_search(self):
        name = "rec-v1.mp4"
        m.cut(os.path.join(self.w, "take-01-camera.mov"), os.path.join(self.w, "edits", name), self.segs,
              vf="crop=608:1080:656:0,scale=1080:1920")
        with open(os.path.join(self.w, "edits", "rec-v1.recipe.json"), "w") as f:
            json.dump({"name": "rec", "frame": {"shape": "9:16", "w": 1080, "h": 1920}}, f)
        self.assertEqual(t.recipe_region(self.w, "edits/" + name, (1920, 1080)), (656, 0, 608, 1080))
        with mock.patch.object(t, "find_region", side_effect=AssertionError("the recipe gives the crop")):
            r, by = self.run_check(name, s=self.w)
        self.assertTrue(by["picture_drift"][0]["pass"], by["picture_drift"])

    def test_shown_size_rotation(self):
        self.assertEqual(t.shown_size({"width": 1920, "height": 1080, "side_data_list": [{"rotation": -90}]}), (1080, 1920))
        self.assertEqual(t.shown_size({"width": 1920, "height": 1080, "tags": {"rotate": "180"}}), (1920, 1080))


@unittest.skipUnless(FFMPEG, "needs ffmpeg")
class CutRegression(Base):
    """A part the user asked to cut (a hiccup, a word said twice) that comes back in a later version: the
    sound around it is the same, so only the take's time in each version shows it (2026-10-11)."""

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = cls.root
        cls.s = cls.make_session("2026-10-11-cut")
        cls.words, _, _ = m.make_take(cls.s, seconds=20.0)
        take_meta(cls.s, [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "keeper": True}])
        src = os.path.join(cls.s, "take-01-camera.mov")
        w = cls.words
        # The "hiccup": two whole words in the middle of the take, cut at the pauses around them.
        i = next(k for k, x in enumerate(w) if x[0] > 6.0)
        cls.cut_words = w[i:i + 2]
        a = (w[i - 1][1] + w[i][0]) / 2.0
        b = (w[i + 1][1] + w[i + 2][0]) / 2.0
        cls.hole = (a, b)
        whole = [(1.0, 16.0)]
        fixed = [(1.0, a), (b, 16.0)]
        for slug in ("hic", "keep"):
            m.cut(src, os.path.join(cls.s, "edits", slug + "-v1.mp4"), whole)
            m.cut(src, os.path.join(cls.s, "edits", slug + "-v2.mp4"), fixed)
        m.cut(src, os.path.join(cls.s, "edits", "hic-v3.mp4"), whole)
        # keep-v3 keeps the cut and cuts another part (a new change, not the old one undone).
        j = next(k for k, x in enumerate(w) if x[0] > 11.0)
        m.cut(src, os.path.join(cls.s, "edits", "keep-v3.mp4"),
              [(1.0, a), (b, (w[j - 1][1] + w[j][0]) / 2.0), ((w[j + 1][1] + w[j + 2][0]) / 2.0, 16.0)])

        def c(cid, slug):
            return {"id": cid, "file": "edits/%s-v1.mp4" % slug, "start": round(a - 1.0 - 0.1, 2),
                    "end": round(b - 1.0 + 0.1, 2), "text": "cut this hiccup", "status": "resolved", "by": "user",
                    "at": "2026-10-10T00:00:00.000Z", "lesson": "one-off",
                    "replies": [{"by": "claude", "text": "Cut", "at": "2026-10-10T01:00:00Z",
                                 "file": "edits/%s-v2.mp4" % slug, "time": round(a - 1.0, 2)}]}
        t.write_comments(cls.s, {"comments": [c("c21", "hic"), c("c22", "keep")]})

    @classmethod
    def tearDownClass(cls):
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(cls.root, ignore_errors=True)

    def setUp(self):
        os.environ["TAKES_ROOT"] = self.root

    def test_cut_part_back_fails(self):
        r, by = self.run_check("hic-v3.mp4")
        bad = self.failed(by, "regression")
        self.assertEqual(len(bad), 1, by["regression"])
        self.assertEqual(bad[0]["comment"], "c21")
        self.assertEqual(bad[0]["label"], "Fix undone")
        said = " ".join(x[2] for x in self.cut_words)
        self.assertEqual(bad[0]["say"], "A part you asked to cut is back at %s: “%s” (cut in hic-v2)."
                         % (t.mmss(self.hole[0] - 1.0), said))
        self.assertAlmostEqual(bad[0]["at"][0], self.hole[0] - 1.0, delta=0.2)
        self.assertIn("Cut it again", bad[0]["fix"])
        self.assertNotIn("The user", bad[0]["say"] + bad[0]["fix"])

    def test_cut_words_back_fails_without_take_times(self):
        # No take times for the versions (another take, a file align cannot place): each version's own
        # words.json still shows the cut words back.
        def words(name, segs):
            out, at = [], 0.0
            for a, b in segs:
                out += [{"word": x[2], "start": round(at + x[0] - a, 3), "end": round(at + x[1] - a, 3)}
                        for x in self.words if a <= (x[0] + x[1]) / 2.0 <= b]
                at += b - a
            with open(os.path.join(self.s, "edits", name + ".words.json"), "w") as f:
                json.dump({"v": 2, "words": out}, f)
        a, b = self.hole
        words("hic-v1", [(1.0, 16.0)])
        words("hic-v2", [(1.0, a), (b, 16.0)])
        words("hic-v3", [(1.0, 16.0)])
        try:
            with mock.patch.object(t, "version_segments", return_value=(None, [])):
                r, by = self.run_check("hic-v3.mp4")
                bad = self.failed(by, "regression")
                self.assertEqual([x["comment"] for x in bad], ["c21"], by["regression"])
                self.assertIn(" ".join(x[2] for x in self.cut_words), bad[0]["say"])
                r, by = self.run_check("hic-v2.mp4")
                self.assertTrue(by["regression"][0]["pass"], by["regression"])
        finally:
            for v in (1, 2, 3):
                os.remove(os.path.join(self.s, "edits", "hic-v%d.words.json" % v))

    def test_cut_kept_passes(self):
        r, by = self.run_check("hic-v2.mp4")
        self.assertTrue(by["regression"][0]["pass"], by["regression"])
        r, by = self.run_check("keep-v3.mp4")
        self.assertTrue(by["regression"][0]["pass"], by["regression"])


@unittest.skipUnless(FFMPEG, "needs ffmpeg")
class Notes(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "P", "2026-10-11-n")
        os.makedirs(os.path.join(self.s, "edits"))
        take_meta(self.s, [])

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(self.root, ignore_errors=True)

    def test_no_take_skips_and_no_rule_note_stays(self):
        m.ff("-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=4", "-f", "lavfi", "-i",
             "sine=f=300:duration=4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
             os.path.join(self.s, "edits", "mg-v1.mp4"))
        r = t.t_check_edit({"session": self.s, "file": "edits/mg-v1.mp4"})
        by = {x["check"]: x for x in r["results"]}
        self.assertTrue(by["streams"]["pass"])
        self.assertEqual(by["echo"]["skip"], "The session has no take to compare with.")
        self.assertIn("No rule has a check yet", r["note"])
        self.assertIn("did not run", r["note"])
        self.assertFalse(r["known"])
        self.assertIsNone(r["source"])


if __name__ == "__main__":
    unittest.main()
