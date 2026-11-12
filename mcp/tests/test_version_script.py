"""The build version is either complete or absent."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/version.sh"


class VersionScriptTests(unittest.TestCase):
    def run_script(self, root, env=None):
        return subprocess.run(
            ["bash", str(root / "scripts/version.sh")],
            capture_output=True,
            env=env,
            text=True,
            timeout=10,
        )

    @unittest.skipUnless(
        subprocess.run(["git", "-C", str(SOURCE.parent.parent), "rev-parse", "HEAD"], capture_output=True).returncode == 0,
        "not a git checkout (the public copy before its push)")
    def test_checkout_prints_a_complete_version(self):
        result = self.run_script(SOURCE.parent.parent)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, re.compile(r"^\d{4}\.\d{1,2}\.\d{1,2} \d+\n$"))

    def test_repository_without_commits_prints_no_partial_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(SOURCE, root / "scripts/version.sh")
            subprocess.run(
                ["git", "init", "-q", str(root)],
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            )

            result = self.run_script(root)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_failed_build_count_prints_no_partial_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(SOURCE, root / "scripts/version.sh")
            fake_bin = root / "bin"
            fake_bin.mkdir()
            git = fake_bin / "git"
            git.write_text(
                "#!/bin/bash\n"
                "case \"$1\" in\n"
                "  rev-parse) exit 0;;\n"
                "  log) printf '2026.11.6\\n';;\n"
                "  rev-list) exit 1;;\n"
                "esac\n"
            )
            git.chmod(0o755)
            env = dict(os.environ, PATH=f"{fake_bin}:{os.environ['PATH']}")

            result = self.run_script(root, env)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
