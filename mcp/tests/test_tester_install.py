"""Public tester install downloads the whole installer before running it."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/public/tester.sh"


@unittest.skipUnless(SOURCE.is_file(), "The public export omits tester tooling")
class TesterInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        self.marker = self.root / "installer-ran"
        self.env = dict(os.environ, USER="takestester", HOME=str(self.root),
                        TMPDIR=str(self.downloads),
                        PATH=str(self.bin) + ":/usr/bin:/bin")

    def run_install(self, curl_status):
        curl = self.bin / "curl"
        curl.write_text(
            "#!/bin/bash\n"
            "set -eu\n"
            "output=''\n"
            "while (( $# )); do\n"
            "  if [[ \"$1\" == -o ]]; then output=$2; shift 2; else shift; fi\n"
            "done\n"
            "if [[ -n \"$output\" ]]; then\n"
            "  printf '%s\\n' 'touch \"$HOME/installer-ran\"' > \"$output\"\n"
            "else\n"
            "  printf '%s\\n' 'touch \"$HOME/installer-ran\"'\n"
            "fi\n"
            f"exit {curl_status}\n"
        )
        curl.chmod(0o755)
        return subprocess.run(["bash", str(SOURCE), "install"], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_incomplete_download_is_never_executed(self):
        result = self.run_install(18)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertEqual(list(self.downloads.iterdir()), [])

    def test_complete_download_runs_and_removes_temporary_file(self):
        result = self.run_install(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.marker.is_file())
        self.assertEqual(list(self.downloads.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
