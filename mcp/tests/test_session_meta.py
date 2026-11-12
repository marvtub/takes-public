"""session.json is written whole (temp file, then rename), and a read that meets a half-written file
tries once more, so the app and the server never see each other's half files (2026-11-06)."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

META = {"title": "Demo", "createdAt": "2026-11-06T08:00:00Z", "named": True, "takes": []}


class SessionMeta(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-11-06-demo")
        os.makedirs(self.s)
        self.file = os.path.join(self.s, "session.json")
        t.write_meta(self.s, dict(META))
        self._sleep = t.time.sleep

    def tearDown(self):
        t.time.sleep = self._sleep
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_a_failed_write_keeps_the_old_file(self):
        before = t.read_text(self.file)
        with self.assertRaises(TypeError):
            t.write_meta(self.s, dict(META, title="New", bad={1, 2}))  # a set does not serialize
        self.assertEqual(t.read_text(self.file), before)
        self.assertEqual(t.read_meta(self.s)["title"], "Demo")

    def test_a_write_replaces_the_file_whole(self):
        inode = os.stat(self.file).st_ino
        t.write_meta(self.s, dict(META, title="New"))
        self.assertNotEqual(os.stat(self.file).st_ino, inode)
        self.assertEqual(t.read_meta(self.s)["title"], "New")
        self.assertFalse(os.path.exists(self.file + ".tmp"))

    def test_a_half_written_file_is_read_again(self):
        whole = json.dumps(dict(META, title="Whole"))
        with open(self.file, "w") as f:
            f.write(whole[:20])

        def finish(_):  # the other writer ends while the reader waits
            with open(self.file, "w") as f:
                f.write(whole)
        t.time.sleep = finish
        self.assertEqual(t.read_meta(self.s)["title"], "Whole")

    def test_a_broken_file_still_fails(self):
        with open(self.file, "w") as f:
            f.write("{not json")
        t.time.sleep = lambda _: None
        with self.assertRaises(ValueError):
            t.read_meta(self.s)


if __name__ == "__main__":
    unittest.main()
