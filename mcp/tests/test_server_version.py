"""initialize names the real Takes version, not a fixed "0.5" (Glama showed 0.5 for v2026.10.13, 2026-10-15)."""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class ServerVersion(unittest.TestCase):
    def setUp(self):
        self.app = tempfile.mkdtemp()
        self.res = os.path.join(self.app, "Resources")
        os.makedirs(self.res)

    def tearDown(self):
        shutil.rmtree(self.app)

    def plist(self, **info):
        with open(os.path.join(self.app, "Info.plist"), "wb") as f:
            plistlib.dump(info, f)

    def test_the_release_tag_wins(self):
        self.plist(ReleaseTag="v2026.10.15", CFBundleShortVersionString="2026.10.14")
        self.assertEqual(t.server_version(self.res), "2026.10.15")

    def test_a_local_build_names_its_version(self):
        self.plist(CFBundleShortVersionString="2026.10.14")
        self.assertEqual(t.server_version(self.res), "2026.10.14")

    def test_a_checkout_uses_the_newest_commit_date(self):
        here = os.path.join(os.path.dirname(__file__), "..")
        # The public copy is checked without git (check-public-build.sh): no commit date there.
        if subprocess.run(["git", "-C", here, "rev-parse"], capture_output=True).returncode != 0:
            self.skipTest("not a git checkout")
        v = t.server_version(here)
        self.assertRegex(v, r"^\d{4}\.\d{1,2}\.\d{1,2}$")

    def test_no_plist_and_no_git_says_dev(self):
        self.assertEqual(t.server_version(self.res), "dev")


if __name__ == "__main__":
    unittest.main()
