"""Trial reels (2026-11-06, admin): the server queues vertical edits in posts/trials.json, the app sends them."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


@unittest.skipUnless(t.SOCIAL, "trial reels are admin only")
class TrialReels(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-11-06-plants")
        os.makedirs(os.path.join(self.s, "edits"))
        os.makedirs(os.path.join(self.s, "posts"))
        t.write_meta(self.s, {"title": "Plants", "createdAt": "2026-11-06T00:00:00Z", "named": True, "takes": []})
        self.sizes = {"hook-a-v1.mp4": (1080, 1920), "hook-b-v1.mp4": (1080, 1920), "wide-v1.mp4": (1920, 1080)}
        for name in self.sizes:
            with open(os.path.join(self.s, "edits", name), "wb") as f:
                f.write(b"x")
        with open(os.path.join(self.s, "posts", "vertical.md"), "w") as f:
            f.write("---\nstatus: draft\n---\nLight beats water. #plants\n")
        self.real_size = t.video_size
        t.video_size = lambda p: self.sizes.get(os.path.basename(p), (None, None))

    def tearDown(self):
        t.video_size = self.real_size
        os.environ.pop("TAKES_ROOT", None)
        shutil.rmtree(self.root, ignore_errors=True)

    def reels(self):
        with open(os.path.join(self.s, "posts", "trials.json")) as f:
            return json.load(f)["reels"]

    def test_post_queues_the_edit_with_the_vertical_caption(self):
        out = t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/hook-a-v1.mp4", "name": "Light beats water"})
        self.assertEqual(out["reel"]["status"], "queued")
        [r] = self.reels()
        self.assertEqual(r["edit"], "edits/hook-a-v1.mp4")
        self.assertEqual(r["caption"], "Light beats water. #plants")
        self.assertEqual(r["graduate"], "auto")
        self.assertEqual(r["name"], "Light beats water")

    def test_a_bare_file_name_means_edits(self):
        t.t_trial_reels({"action": "post", "session": self.s, "edit": "hook-b-v1.mp4"})
        self.assertEqual(self.reels()[0]["edit"], "edits/hook-b-v1.mp4")

    def test_a_wide_edit_is_refused(self):
        with self.assertRaisesRegex(ValueError, "vertical"):
            t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/wide-v1.mp4"})
        self.assertFalse(os.path.exists(os.path.join(self.s, "posts", "trials.json")))

    def test_the_same_edit_goes_out_once(self):
        t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/hook-a-v1.mp4"})
        with self.assertRaisesRegex(ValueError, "already"):
            t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/hook-a-v1.mp4"})

    def test_a_file_outside_edits_is_refused(self):
        with open(os.path.join(self.s, "take-01-camera.mov"), "wb") as f:
            f.write(b"x")
        with self.assertRaisesRegex(ValueError, "edits/"):
            t.t_trial_reels({"action": "post", "session": self.s, "edit": "take-01-camera.mov"})

    def test_too_many_hashtags_are_refused(self):
        with self.assertRaisesRegex(ValueError, "hashtags"):
            t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/hook-a-v1.mp4",
                             "caption": "#a #b #c #d #e #f"})

    def test_a_later_time_is_kept_in_utc(self):
        t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/hook-a-v1.mp4",
                         "at": "2026-11-07T09:13:00-08:00"})
        self.assertEqual(self.reels()[0]["at"], "2026-11-07T17:13:00Z")
        with self.assertRaisesRegex(ValueError, "zone"):
            t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/hook-b-v1.mp4", "at": "2026-11-07T09:13:00"})

    def test_list_ranks_live_ones_by_views(self):
        d = {"v": 1, "reels": [
            {"id": "a", "edit": "edits/hook-a-v1.mp4", "status": "live", "stats": {"views": 900, "skip_rate": 40}},
            {"id": "b", "edit": "edits/hook-b-v1.mp4", "status": "live", "stats": {"views": 12000, "skip_rate": 22}},
            {"id": "c", "edit": "edits/x-v1.mp4", "status": "queued"}]}
        t.write_trials(self.s, d)
        out = t.t_trial_reels({"action": "list"})
        self.assertEqual([r["id"] for r in out["sessions"][0]["reels"]], ["b", "a", "c"])
        self.assertEqual(out["best"]["id"], "b")

    def test_cancel_removes_a_queued_one_and_flags_a_scheduled_one(self):
        t.write_trials(self.s, {"v": 1, "reels": [{"id": "q", "status": "queued"}, {"id": "s", "status": "scheduled"},
                                                  {"id": "l", "status": "live"}]})
        t.t_trial_reels({"action": "cancel", "session": self.s, "id": "q"})
        t.t_trial_reels({"action": "cancel", "session": self.s, "id": "s"})
        with self.assertRaisesRegex(ValueError, "stays"):
            t.t_trial_reels({"action": "cancel", "session": self.s, "id": "l"})
        self.assertEqual([(r["id"], r["status"]) for r in self.reels()], [("s", "cancelling"), ("l", "live")])

    def test_a_broken_file_is_never_written_over(self):
        p = os.path.join(self.s, "posts", "trials.json")
        with open(p, "w") as f:
            f.write("{nope")
        with self.assertRaisesRegex(ValueError, "parse"):
            t.t_trial_reels({"action": "post", "session": self.s, "edit": "edits/hook-a-v1.mp4"})
        with open(p) as f:
            self.assertEqual(f.read(), "{nope")


if __name__ == "__main__":
    unittest.main()
