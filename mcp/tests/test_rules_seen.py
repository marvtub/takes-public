"""Rules seen, per chat on disk (2026-10-10): each message of a Takes chat is a new MCP process, so
the seen rules live in _library/.rules-seen/<chat>.json, keyed by CLAUDE_CODE_SESSION_ID. Read tools
show the rules once; write tools refuse once per chat, not once per message."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.join(os.path.dirname(__file__), "..")
sys.path.insert(0, HERE)
import takes_mcp as t  # noqa: E402


class RulesSeen(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-a-0001"
        t.forget_seen()
        self.s = os.path.join(self.root, "Proj", "2026-10-10-idea")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "Idea", "createdAt": "2026-10-10T00:00:00Z", "named": True, "takes": []})

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
        t.SEEN.clear()
        shutil.rmtree(self.root, ignore_errors=True)

    def rules(self, *pairs):
        d = t.read_lessons()
        for area, text in pairs:
            t.new_rule(d, area, text)
        t.write_lessons(d)

    def write_script(self):
        return t.t_update_session({"session": self.s, "script": "Hi."})

    def with_takes(self):
        t.write_meta(self.s, dict(t.read_meta(self.s), takes=[
            {"number": 1, "kind": "camera", "file": "take-01-camera.mov", "duration": 3, "keeper": False}]))

    def test_seen_survives_a_new_process(self):
        self.rules(("script", "Plain words."))
        with self.assertRaises(ValueError) as e:
            self.write_script()
        self.assertIn("Plain words.", str(e.exception))
        t.SEEN.clear()  # what the next message's new process starts with
        self.write_script()

    def test_other_chat_sees_them_again(self):
        self.rules(("script", "Plain words."))
        with self.assertRaises(ValueError):
            self.write_script()
        os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-b-0002"
        with self.assertRaises(ValueError):
            self.write_script()
        self.write_script()

    def test_a_changed_rule_shows_again_alone(self):
        self.rules(("script", "Plain words."), ("script", "No jargon."))
        with self.assertRaises(ValueError):
            self.write_script()
        d = t.read_lessons()
        d["rules"][1]["text"] = "No jargon at all."
        t.write_lessons(d)
        with self.assertRaises(ValueError) as e:
            self.write_script()
        self.assertIn("No jargon at all.", str(e.exception))
        self.assertNotIn("Plain words.", str(e.exception))
        self.write_script()

    def test_no_chat_id_uses_memory(self):
        os.environ.pop("CLAUDE_CODE_SESSION_ID")
        self.rules(("script", "Plain words."))
        with self.assertRaises(ValueError):
            self.write_script()
        self.write_script()
        self.assertFalse(os.path.exists(os.path.join(self.root, "_library", ".rules-seen")))

    def test_next_path_never_refuses(self):
        # Items 3 and 5 copy this test for each tool that writes into edits/ or thumbnails/.
        self.rules(("cut", "Tight pauses."), ("thumbnail", "Big face."))
        first = t.t_next_path({"kind": "edit", "session": self.s, "name": "a"})
        self.assertEqual(list(first)[0], "rules")
        self.assertEqual(first["rules"]["new"], ["- cut-1: Tight pauses."])
        self.assertTrue(first["path"].endswith("edits/a-v1.mp4"))
        self.assertNotIn("rules", t.t_next_path({"kind": "edit", "session": self.s, "name": "a"}))
        thumb = t.t_next_path({"kind": "thumbnail", "session": self.s, "name": "a"})
        self.assertEqual(list(thumb)[0], "rules")
        self.assertEqual(thumb["rules"]["new"], ["- thumbnail-1: Big face."])
        self.assertNotIn("rules", t.t_next_path({"kind": "thumbnail", "session": self.s, "name": "a"}))

    def test_get_session_gives_the_next_steps(self):
        self.rules(("script", "Plain words."), ("storyboard", "One idea per shot."), ("cut", "Tight."),
                   ("thumbnail", "Big face."))
        # (a) No takes: plan the video.
        out = t.t_get_session({"session": self.s})
        self.assertEqual(list(out)[0], "rules")
        self.assertEqual(out["rules"]["steps"], ["script", "storyboard"])
        self.write_script()  # no refusal
        t.need_rules("storyboard")  # what set_storyboard calls first: no refusal either
        # (d) The second call has no rules.
        self.assertNotIn("rules", t.t_get_session({"session": self.s}))
        # (b) Takes, no edits: the five edit steps.
        self.with_takes()
        out = t.t_get_session({"session": self.s})
        self.assertEqual(out["rules"]["steps"], t.EDIT_AREAS)
        self.assertEqual(out["rules"]["new"], ["- cut-1: Tight."])
        self.assertNotIn("rules", t.t_next_path({"kind": "edit", "session": self.s, "name": "a"}))
        # (c) A video in edits/: edit again and make the thumbnail.
        os.makedirs(os.path.join(self.s, "edits"), exist_ok=True)
        open(os.path.join(self.s, "edits", "a-v1.mp4"), "wb").close()
        t.forget_seen()
        out = t.t_get_session({"session": self.s})
        self.assertEqual(out["rules"]["steps"], t.EDIT_AREAS + ["thumbnail"])
        self.assertIn("- thumbnail-1: Big face.", out["rules"]["new"])

    def test_deleted_seen_file_shows_rules_again(self):
        self.rules(("script", "Plain words."))
        self.assertIn("rules", t.t_get_session({"session": self.s}))
        self.assertNotIn("rules", t.t_get_session({"session": self.s}))
        os.remove(t.seen_file())  # what the app does when the chat compacts
        self.assertIn("rules", t.t_get_session({"session": self.s}))
        self.write_script()

    def test_get_rules_marks_seen_and_list_does_not(self):
        self.rules(("script", "Plain words."), ("cut", "Tight."))
        t.t_get_rules({})
        self.assertEqual(t.read_seen()["rules"], {})
        t.t_get_rules({"area": "script"})
        self.write_script()
        self.assertEqual(t.t_next_path({"kind": "edit", "session": self.s, "name": "a"})["rules"]["new"], ["- cut-1: Tight."])

    def test_bad_seen_file(self):
        self.rules(("script", "Plain words."))
        os.makedirs(os.path.dirname(t.seen_file()), exist_ok=True)
        with open(t.seen_file(), "w") as f:
            f.write("{")
        with self.assertRaises(ValueError):
            self.write_script()
        with open(t.seen_file()) as f:
            self.assertIn("script-1", json.load(f)["rules"])
        self.write_script()

    def test_unwritable_library(self):
        self.rules(("script", "Plain words."))
        lib = os.path.join(self.root, "_library")
        os.chmod(lib, 0o500)
        try:
            with self.assertRaises(ValueError):
                self.write_script()
            self.write_script()  # memory holds it
            self.assertIn("path", t.t_next_path({"kind": "edit", "session": self.s, "name": "a"}))
        finally:
            os.chmod(lib, 0o755)
        self.assertFalse(os.path.exists(os.path.join(lib, ".rules-seen")))

    def test_old_seen_files_are_pruned(self):
        self.rules(("script", "Plain words."))
        folder = os.path.join(self.root, "_library", ".rules-seen")
        os.makedirs(folder)
        old, recent = os.path.join(folder, "old-chat-0001.json"), os.path.join(folder, "new-chat-0001.json")
        for p, days in ((old, 31), (recent, 1)):
            with open(p, "w") as f:
                f.write("{}")
            ago = time.time() - days * 86400
            os.utime(p, (ago, ago))
        with self.assertRaises(ValueError):
            self.write_script()
        self.assertFalse(os.path.exists(old))
        self.assertTrue(os.path.exists(recent))

    def test_bad_chat_id_is_ignored(self):
        os.environ["CLAUDE_CODE_SESSION_ID"] = "../../x"
        self.assertIsNone(t.chat_id())
        self.rules(("script", "Plain words."))
        with self.assertRaises(ValueError):
            self.write_script()
        self.write_script()
        self.assertFalse(os.path.exists(os.path.join(self.root, "_library", ".rules-seen")))
        self.assertFalse(os.path.exists(os.path.join(os.path.dirname(self.root), "x.json")))

    def test_two_processes_write_seen(self):
        rules = [{"id": "cut-%d" % i, "area": "cut", "text": "Rule %d." % i} for i in range(1, 9)]
        t.write_lessons({"rules": rules})
        code = ("import sys; sys.path.insert(0, %r); import takes_mcp as t\n"
                "rules = t.read_lessons()['rules']\n"
                "for i in range(20):\n"
                "    t.mark_seen([rules[(i + int(sys.argv[1])) %% len(rules)]])\n" % os.path.abspath(HERE))
        env = dict(os.environ)
        procs = [subprocess.Popen([sys.executable, "-c", code, str(n)], env=env) for n in (0, 4)]
        for p in procs:
            p.wait()
        with open(t.seen_file()) as f:
            self.assertTrue(json.load(f)["rules"])  # parses; lost marks are allowed
        self.assertEqual([f for f in os.listdir(os.path.dirname(t.seen_file())) if f.endswith(".tmp")], [])


    def write_cut(self, d):
        os.makedirs(t.rules_dir(), exist_ok=True)
        with open(t.area_file("cut"), "w") as f:
            json.dump(d, f)

    def test_odd_rule_file_does_not_block_get_session(self):
        # Pressure test 2026-10-10: a list file or a hand-added rule without id/text broke get_session.
        self.rules(("sound", "Clean the voice before any cut."))
        good = {"id": "cut-1", "area": "cut", "text": "Cut the breath before the hook."}
        for d in ([1, 2], {"rules": "x"}, {"rules": [good, {"text": "no id"}]},
                  {"rules": [good, {"id": "cut-77"}]}, {"rules": [good, "just a string"]}):
            t.forget_seen()
            self.write_cut(d)
            before = t.read_text(t.area_file("cut"))
            out = t.t_get_session({"session": "Proj/2026-10-10-idea"})
            self.assertIn("takes", out)
            self.assertIn("cut", t.read_lessons()["unreadable"])
            # A write to the odd area refuses, names the file and leaves it as it was.
            with self.assertRaises(ValueError) as e:
                t.t_set_rule({"area": "cut", "text": "Keep the first word whole."})
            self.assertIn(t.area_file("cut"), str(e.exception))
            if isinstance(d, dict) and isinstance(d["rules"], list):
                with self.assertRaises(ValueError):
                    t.t_set_rule({"id": "cut-1", "on": False})
            t.t_set_rule({"area": "sound", "text": "Keep the room tone under the music."})
            self.assertEqual(t.read_text(t.area_file("cut")), before)
        # The good rule of a half-good file still shows.
        self.assertIn("cut-1", [r["id"] for r in t.read_lessons()["rules"]])


if __name__ == "__main__":
    unittest.main()
