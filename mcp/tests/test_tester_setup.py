"""Tester setup against a scratch /Users tree and unprivileged sudo stand-in."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

# run_parallel.py imports tests as top-level modules: no mcp package (as test_edit_recipe.py).
sys.path.insert(0, os.path.dirname(__file__))
from test_tester_home import sudo_stub  # noqa: E402


SOURCE = Path(__file__).resolve().parents[2] / "scripts/public/tester.sh"


@unittest.skipUnless(SOURCE.is_file(), "The public export omits tester tooling")
class TesterSetup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.users = self.root / "Users"
        self.home = self.users / "takestester"
        self.home.mkdir(parents=True)
        self.home.chmod(0o700)
        self.rc = self.home / ".zshrc"
        self.script = self.root / "tester.sh"
        # The sudo stand-in relocates the tester child; native account commands are stubs.
        self.script.write_text(SOURCE.read_text())
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "sudo.trace"
        sudo = self.bin / "sudo"
        sudo.write_text(sudo_stub())
        sudo.chmod(0o755)
        self.stub("id", "exit 0")
        self.stub("chown", "exit 0")
        self.env = dict(os.environ, USER="admin", HOME=str(self.root), TRACE=str(self.trace),
                        TEST_HOME=str(self.home), ADMIN_SOURCE=str(self.script),
                        PATH=str(self.bin) + ":/usr/bin:/bin")

    def stub(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        p.chmod(0o755)

    def setup(self):
        return subprocess.run(["bash", str(self.script), "setup"], env=self.env,
                              capture_output=True, text=True, timeout=60)

    def test_symlink_cannot_redirect_setup_writes(self):
        target = self.root / "privileged-file"
        target.write_text("must stay unchanged\n")
        self.rc.symlink_to(target)
        result = self.setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "must stay unchanged\n")
        self.assertTrue(self.rc.is_symlink())

    def test_existing_profile_keeps_content_and_adds_alias_only_once(self):
        self.rc.write_text("# user settings\n")
        self.rc.chmod(0o600)
        for _ in range(2):
            result = self.setup()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        text = self.rc.read_text()
        self.assertTrue(text.startswith("# user settings\n"))
        self.assertEqual(text.count("alias tester="), 1)
        calls = [line for line in self.trace.read_text().splitlines() if ".zshrc" in line]
        self.assertTrue(calls)
        self.assertTrue(all(line.startswith("-u takestester /usr/bin/python3 -I -c") for line in calls), calls)

    def test_missing_profile_is_created_without_privileged_chown(self):
        result = self.setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.rc.is_file())
        self.assertIn("alias tester=", self.rc.read_text())
        self.assertNotIn("chown", self.trace.read_text())


if __name__ == "__main__":
    unittest.main()
