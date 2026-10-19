"""Export for Resolve / Premiere (2026-10-18): export_edit turns an edit version's recipe into an FCPXML 1.10,
a Final Cut Pro 7 XML (Premiere) and a CMX3600 EDL next to the version. Takes made with ffmpeg in a temp
library; the take's sound starts 0.2 s late, as on a real camera take. No network."""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import takes_mcp as t  # noqa: E402
from test_edit_ready import beep_times, ff, flash_take  # noqa: E402

TIME = re.compile(r"^-?\d+(/\d+)?s$")
# Apple's DTD ships inside Final Cut Pro; TAKES_FCPXML_DTD points at a copy on a Mac without it.
DTDS = ([os.environ["TAKES_FCPXML_DTD"]] if os.environ.get("TAKES_FCPXML_DTD") else []) + glob.glob(
    "/Applications/Final Cut Pro*.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_10.dtd")


def sec(x):
    """'7/2s' -> Fraction(7, 2)"""
    assert TIME.match(x), x
    return Fraction(x[:-1])


class ExportBase(unittest.TestCase):
    CUT = [{"take": 1, "kind": "camera", "in": 0.5, "out": 2.5}, {"take": 1, "kind": "camera", "in": 3.5, "out": 5.5}]

    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        t.forget_seen()
        t.CLOCKS.clear()
        self.s = os.path.join(self.root, "Proj", "2026-10-18-demo")
        os.makedirs(os.path.join(self.s, "edits"))
        t.write_meta(self.s, {"title": "demo", "createdAt": "2026-10-18T00:00:00Z", "named": True, "takes": []})
        self.take = self.add_take(1)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)
        os.environ.pop("TAKES_ROOT", None)

    def add_take(self, n, secs=6, kind="camera", **kw):
        f = "take-%02d-%s.mov" % (n, kind)
        flash_take(os.path.join(self.s, f), secs=secs, **kw)
        meta = t.read_meta(self.s)
        meta["takes"].append({"number": n, "kind": kind, "file": f, "startedAt": "2026-10-18T00:00:00Z",
                              "duration": secs})
        t.write_meta(self.s, meta)
        return f

    def publish(self, n=1, **extra):
        """edits/hook-vN.mp4 with its recipe, as publish_edit leaves them (the mp4 is not read)."""
        r = dict({"name": "hook", "edit": "edits/hook-v%d.mp4" % n, "cut": self.CUT,
                  "frame": {"shape": "source", "w": 160, "h": 120, "fps": 30}, "over": [], "music": [], "sfx": [],
                  "steps": [], "voice": {"source": "take", "keys": {}, "chain": {}}, "inputs": {},
                  "made": "2026-10-18T00:00:0%dZ" % n}, **extra)
        with open(os.path.join(self.s, "edits", "hook-v%d.mp4" % n), "wb") as f:
            f.write(b"\0")
        t.write_json(os.path.join(self.s, "edits", "hook-v%d.recipe.json" % n), r)
        return r

    def export(self, edit="hook-v1"):
        out = t.t_export_edit({"session": self.s, "edit": edit})
        x = ET.parse(os.path.join(self.s, out["fcpxml"])).getroot()
        return out, x

    def check_structure(self, x):
        """What Resolve and Final Cut need beyond well-formed XML: every ref is a resource, every time a
        rational, adjustments before anchored clips, anchored clips on a lane."""
        self.assertEqual(x.tag, "fcpxml")
        self.assertEqual(x.get("version"), "1.10")
        ids = {e.get("id") for e in x.find("resources")}
        self.assertEqual(len(ids), len(x.find("resources")), "resource ids are unique")
        for e in x.iter():
            for k in ("offset", "start", "duration", "tcStart", "frameDuration"):
                if e.get(k) is not None:
                    self.assertRegex(e.get(k), TIME)
            for k in ("ref", "format"):
                if e.get(k) is not None:
                    self.assertIn(e.get(k), ids, "%s=%s" % (k, e.get(k)))
        for a in x.find("resources").iter("asset"):
            self.assertTrue(a.find("media-rep").get("src").startswith("file:///"))
        spine = x.find("library/event/project/sequence/spine")
        for clip in spine:
            kids = [k.tag for k in clip]
            adjust = [i for i, k in enumerate(kids) if k.startswith("adjust-")]
            anchored = [i for i, k in enumerate(kids) if k in ("asset-clip", "video")]
            if adjust and anchored:
                self.assertLess(max(adjust), min(anchored), kids)
            for k in clip:
                if k.tag in ("asset-clip", "video"):
                    self.assertNotIn(k.get("lane"), (None, "0"))


class ExportEditTests(ExportBase):
    def test_the_cut_lands_on_the_right_frames(self):
        self.publish()
        out, x = self.export()
        self.check_structure(x)
        seq = x.find("library/event/project/sequence")
        fmt = {e.get("id"): e for e in x.find("resources").iter("format")}[seq.get("format")]
        self.assertEqual((fmt.get("frameDuration"), fmt.get("width"), fmt.get("height")), ("1/30s", "160", "120"))
        self.assertEqual(sec(seq.get("duration")), 4)
        self.assertEqual(seq.get("tcStart"), "3600s")
        clips = list(seq.find("spine"))
        self.assertEqual([(sec(c.get("offset")), sec(c.get("start")), sec(c.get("duration"))) for c in clips],
                         [(3600, Fraction(1, 2), 2), (3602, Fraction(7, 2), 2)])  # from 01:00:00:00
        self.assertTrue(all(c.get("srcEnable") == "video" for c in clips))
        assets = {a.get("id"): a for a in x.find("resources").iter("asset")}
        take = assets[clips[0].get("ref")]
        self.assertEqual(take.find("media-rep").get("src"), t.file_url(os.path.join(self.s, self.take)))
        self.assertEqual(out["length"], "00:00:04:00")
        self.assertEqual(out["fcpxml"], "edits/hook-v1.fcpxml")

    def test_a_picture_only_take_has_no_sound_so_resolve_does_not_double_the_voice(self):
        # Resolve 21 ignores srcEnable="video": a take asset with hasAudio put the camera's sound on A1.
        self.publish()
        _, x = self.export()
        assets = {e.get("id"): e for e in x.find("resources") if e.tag == "asset"}
        picture = {c.get("ref") for c in x.iter("asset-clip") if c.get("srcEnable") == "video"}
        sound = {c.get("ref") for c in x.iter("asset-clip") if c.get("srcEnable") == "audio"}
        self.assertTrue(picture and sound)
        for ref in picture - sound:
            self.assertIsNone(assets[ref].get("hasAudio"), assets[ref].get("name"))
        for ref in sound:
            self.assertEqual(assets[ref].get("hasAudio"), "1")
        self.check_structure(x)

    def test_parts_snap_to_whole_frames_as_the_render_cuts_them(self):
        self.publish(cut=[{"take": 1, "kind": "camera", "in": 0.51, "out": 1.0}])
        _, x = self.export()
        c = x.find("library/event/project/sequence/spine")[0]
        # 0.51 s is frame 15.3 -> 15; 0.49 s long -> 15 frames.
        self.assertEqual((sec(c.get("start")), sec(c.get("duration"))), (Fraction(15, 30), Fraction(15, 30)))

    def test_the_takes_own_sound_is_on_the_video_clock(self):
        """The camera's sound starts 0.2 s late. The exported voice WAV puts each beep on its flash frame,
        and the voice clips use the take's own in points: the cut lines up in Resolve."""
        self.publish()
        out, x = self.export()
        spine = x.find("library/event/project/sequence/spine")
        assets = {a.get("id"): a for a in x.find("resources").iter("asset")}
        voices = [k for c in spine for k in c if k.get("lane") == "-1"]
        self.assertEqual(len(voices), 2)
        wav = assets[voices[0].get("ref")].find("media-rep").get("src")
        self.assertTrue(wav.endswith("/_edit/.audio/take-01-camera.wav"), wav)
        path = os.path.join(self.s, "_edit", ".audio", "take-01-camera.wav")
        beeps = beep_times(path)
        self.assertEqual(len(beeps), 3, beeps)
        # The take's own stream, read from its first sample, has them 0.2 s early.
        raw = beep_times(os.path.join(self.s, self.take))
        for flash, got, early in zip((1.0, 3.0, 5.0), beeps, raw):
            self.assertAlmostEqual(got, flash, delta=0.02)  # the detector finds a beep up to 15 ms in
            self.assertAlmostEqual(got - early, 0.2, delta=0.003)
        for c, v in zip(spine, voices):
            self.assertEqual(v.get("srcEnable"), "audio")
            self.assertEqual(v.get("start"), c.get("start"))  # same take time as the picture
            self.assertEqual(v.get("offset"), c.get("start"))  # anchored at the clip's first frame
            self.assertEqual(v.get("duration"), c.get("duration"))
        # Made once: a second export keeps the WAV.
        m = os.path.getmtime(path)
        self.export()
        self.assertEqual(os.path.getmtime(path), m)

    def test_a_clean_voice_from_before_the_video_clock_is_shifted_by_the_offset(self):
        """A clean voice WAV made before 2026-10-11 starts at the take's first sound (0.2 s in): the clip
        starts 0.2 s earlier in the WAV, and a part that starts before the sound starts its voice later."""
        os.makedirs(os.path.join(self.s, "voice"))
        ff("-f", "lavfi", "-i", "sine=d=5.8:sample_rate=48000", "-ac", "1",
           os.path.join(self.s, "voice", "take-01-camera.wav"))
        with open(os.path.join(self.s, "voice", "take-01-camera.json"), "w") as f:
            json.dump({"state": "done", "on": True, "strength": 1.0}, f)
        self.publish(cut=[{"take": 1, "kind": "camera", "in": 0.1, "out": 1.1},
                          {"take": 1, "kind": "camera", "in": 3.5, "out": 4.5}],
                     voice={"source": "clean", "keys": {"take-01-camera": "voice/take-01-camera.wav"}, "chain": {}})
        out, x = self.export()
        self.check_structure(x)
        spine = x.find("library/event/project/sequence/spine")
        assets = {a.get("id"): a for a in x.find("resources").iter("asset")}
        v = [k for c in spine for k in c if k.get("lane") == "-1"]
        self.assertTrue(assets[v[0].get("ref")].find("media-rep").get("src").endswith("/voice/take-01-camera.wav"))
        late = Fraction(round(t.take_clock(os.path.join(self.s, self.take))["audio_offset_s"] * 48000), 48000)
        self.assertAlmostEqual(float(late), 0.2, delta=0.003)
        # Part 2: 3.5 s of the take is 3.5 - 0.2 s of the WAV.
        self.assertEqual(sec(v[1].get("start")), Fraction(7, 2) - late)
        # Part 1 starts at 0.1 s, before the sound: its voice waits ceil(0.1 s) = 3 frames, from WAV 0.
        self.assertEqual(sec(v[0].get("start")), Fraction(3, 30) - late + Fraction(3, 30))
        self.assertEqual(sec(v[0].get("offset")), Fraction(3, 30) + Fraction(3, 30))
        self.assertEqual(sec(v[0].get("duration")), 1 - Fraction(3, 30))
        self.assertFalse(os.path.exists(os.path.join(self.s, "_edit", ".audio")), "no take WAV when clean")

    def test_a_screen_part_without_sound_has_no_voice_clip(self):
        f = "take-01-screen.mov"
        ff("-f", "lavfi", "-i", "color=gray:s=320x200:r=60:d=4", "-c:v", "libx264", "-pix_fmt", "yuv420p",
           os.path.join(self.s, f))
        meta = t.read_meta(self.s)
        meta["takes"].append({"number": 1, "kind": "screen", "file": f, "startedAt": "2026-10-18T00:00:00Z"})
        t.write_meta(self.s, meta)
        self.publish(cut=[{"take": 1, "kind": "camera", "in": 0.5, "out": 1.5},
                          {"take": 1, "kind": "screen", "in": 1.0, "out": 2.0}])
        _, x = self.export()
        self.check_structure(x)
        spine = list(x.find("library/event/project/sequence/spine"))
        self.assertEqual([len([k for k in c if k.get("lane") == "-1"]) for c in spine], [1, 0])
        fmts = {e.get("id"): e for e in x.find("resources").iter("format")}
        assets = {a.get("id"): a for a in x.find("resources").iter("asset")}
        screen = fmts[assets[spine[1].get("ref")].get("format")]
        self.assertEqual((screen.get("frameDuration"), screen.get("width")), ("1/60s", "320"))
        self.assertEqual(sec(spine[1].get("start")), 1)

    def test_layers_music_and_what_is_left_out(self):
        d = os.path.join(self.s, "_edit", "hook")
        os.makedirs(d)
        ff("-f", "lavfi", "-i", "color=red:s=160x120:r=30:d=2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
           os.path.join(d, "captions.mov"))
        ff("-f", "lavfi", "-i", "color=blue:s=160x120", "-frames:v", "1", os.path.join(d, "card.png"))
        music = os.path.join(self.root, "_library", "audio", "Music")
        os.makedirs(music)
        ff("-f", "lavfi", "-i", "sine=f=300:d=10", "-ac", "2", os.path.join(music, "Calm.wav"))
        ff("-f", "lavfi", "-i", "color=green:s=160x120", "-frames:v", "1", os.path.join(self.s, "edits", "cover.png"))
        self.publish(over=[{"file": "_edit/hook/captions.mov", "at": 0.5},
                           {"file": "_edit/hook/card.png", "at": 1.0, "out": 1.0},
                           {"file": "_edit/hook/gone.mov", "at": 0}],
                     music=[{"file": "@library/audio/Music/Calm.wav", "at": 0, "in": 2, "gain_db": -18, "duck_db": 8,
                             "fade_out": 1.5}],
                     cover={"image": "edits/cover.png", "seconds": 0.1})
        out, x = self.export()
        self.check_structure(x)
        spine = list(x.find("library/event/project/sequence/spine"))
        lanes = [(k.tag, k.get("lane"), k.get("offset"), k.get("duration")) for c in spine for k in c
                 if k.tag in ("asset-clip", "video")]
        # Offsets are in the time of the V1 clip they hang on, which starts at 0.5 s of the take.
        # captions on V2 at 0.5 s for 2 s; the card overlaps it, so V3, for 1 s; music on A2 the whole cut.
        self.assertIn(("asset-clip", "2", "1s", "2s"), lanes)
        self.assertIn(("video", "3", "3/2s", "1s"), lanes)
        self.assertIn(("asset-clip", "-2", "1/2s", "4s"), lanes)
        song = next(k for c in spine for k in c if k.get("lane") == "-2")
        self.assertEqual(song.get("start"), "2s")
        self.assertEqual(song.find("adjust-volume").get("amount"), "-18dB")
        self.assertEqual(out["tracks"], {"video": 3, "audio": 2})
        said = " ".join(out["left_out"])
        for word in ("gone.mov", "cover", "ducking", "loudness"):
            self.assertIn(word, said)

    def test_a_layer_comes_from_the_frozen_copy_of_its_version(self):
        d = os.path.join(self.s, "_edit", "hook")
        os.makedirs(os.path.join(d, ".versions", "v1"))
        for p in (os.path.join(d, "captions.mov"), os.path.join(d, ".versions", "v1", "captions.mov")):
            ff("-f", "lavfi", "-i", "color=red:s=160x120:r=30:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", p)
        self.publish(over=[{"file": "_edit/hook/captions.mov", "at": 0}], src="_edit/hook/.versions/v1")
        _, x = self.export()
        srcs = [a.find("media-rep").get("src") for a in x.find("resources").iter("asset")]
        self.assertTrue(any(s.endswith("/_edit/hook/.versions/v1/captions.mov") for s in srcs), srcs)

    def test_premiere_xml_and_edl(self):
        self.publish()
        out, _ = self.export()
        x = ET.parse(os.path.join(self.s, out["premiere"])).getroot()
        self.assertEqual((x.tag, x.get("version")), ("xmeml", "5"))
        seq = x.find("sequence")
        self.assertEqual(seq.findtext("duration"), "120")
        self.assertEqual(seq.findtext("rate/timebase"), "30")
        v = seq.findall("media/video/track/clipitem")
        self.assertEqual([(c.findtext("start"), c.findtext("end"), c.findtext("in"), c.findtext("out")) for c in v],
                         [("0", "60", "15", "75"), ("60", "120", "105", "165")])
        self.assertEqual(v[0].findtext("file/pathurl"), t.file_url(os.path.join(self.s, self.take)))
        self.assertIsNone(v[1].find("file/pathurl"), "the second use of a file only names its id")
        a = seq.findall("media/audio/track/clipitem")
        self.assertEqual([(c.findtext("start"), c.findtext("in")) for c in a], [("0", "15"), ("60", "105")])
        self.assertEqual(a[0].findtext("sourcetrack/mediatype"), "audio")
        with open(os.path.join(self.s, out["edl"])) as f:
            edl = f.read()
        self.assertIn("TITLE: hook-v1\nFCM: NON-DROP FRAME\n", edl)
        self.assertIn("001  T01C     V     C        00:00:00:15 00:00:02:15 01:00:00:00 01:00:02:00\n", edl)
        self.assertIn("002  T01C     V     C        00:00:03:15 00:00:05:15 01:00:02:00 01:00:04:00\n", edl)
        self.assertIn("* FROM CLIP NAME: take-01-camera.mov", edl)

    def test_files_sit_next_to_the_version_and_are_not_misplaced(self):
        self.publish(1)
        self.publish(2, cut=[{"take": 1, "kind": "camera", "in": 1.0, "out": 2.0}])
        out = t.t_export_edit({"session": self.s})  # the newest edit
        self.assertEqual(out["edit"], "edits/hook-v2.mp4")
        for k in ("fcpxml", "premiere", "edl"):
            self.assertTrue(os.path.isfile(os.path.join(self.s, out[k])), k)
        self.assertEqual(sorted(os.listdir(os.path.join(self.s, "edits"))),
                         ["hook-v1.mp4", "hook-v1.recipe.json", "hook-v2.edl", "hook-v2.fcpxml", "hook-v2.mp4",
                          "hook-v2.premiere.xml", "hook-v2.recipe.json"])
        self.assertEqual(t.misplaced(self.s), [])
        self.assertEqual(t.versions_in(os.path.join(self.s, "edits"), "hook"), [1, 2])
        self.assertEqual(t.t_export_edit({"session": self.s, "edit": "hook-v1"})["edit"], "edits/hook-v1.mp4")
        # Again: the files are written again, not versioned.
        t.t_export_edit({"session": self.s, "edit": "hook-v2"})
        self.assertEqual(len(os.listdir(os.path.join(self.s, "edits"))), 10)

    def test_refusals_name_the_fix(self):
        with self.assertRaisesRegex(ValueError, "render_edit"):
            t.t_export_edit({"session": self.s})
        with open(os.path.join(self.s, "edits", "old-v1.mp4"), "wb") as f:
            f.write(b"\0")
        with self.assertRaisesRegex(ValueError, "no recipe"):
            t.t_export_edit({"session": self.s, "edit": "old-v1"})
        self.publish(cut=[{"take": 1, "kind": "camera", "in": 0.5, "out": 1.5}],
                     voice={"source": "clean", "keys": {"take-01-camera": "voice/take-01-camera.wav"}})
        with self.assertRaisesRegex(ValueError, "clean voice"):
            t.t_export_edit({"session": self.s, "edit": "hook-v1"})
        os.remove(os.path.join(self.s, self.take))
        t.CLOCKS.clear()
        with self.assertRaisesRegex(ValueError, "gone"):
            t.t_export_edit({"session": self.s, "edit": "hook-v1"})

    def test_the_app_command_prints_json(self):
        self.publish()
        r = subprocess.run([sys.executable, t.__file__, "--export-edit", self.s, "edits/hook-v1.mp4"],
                           capture_output=True, text=True, env=dict(os.environ), timeout=60)
        self.assertEqual(json.loads(r.stdout)["fcpxml"], "edits/hook-v1.fcpxml")
        r = subprocess.run([sys.executable, t.__file__, "--export-edit", self.s, "nope-v3"],
                           capture_output=True, text=True, env=dict(os.environ), timeout=60)
        self.assertIn("error", json.loads(r.stdout))

    @unittest.skipUnless(DTDS and shutil.which("xmllint"), "no FCPXML 1.10 DTD on this Mac (Final Cut Pro, or "
                         "TAKES_FCPXML_DTD)")
    def test_valid_against_the_fcpxml_dtd(self):
        self.test_layers_music_and_what_is_left_out()
        p = os.path.join(self.s, "edits", "hook-v1.fcpxml")
        r = subprocess.run(["xmllint", "--noout", "--dtdvalid", DTDS[0], p], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
