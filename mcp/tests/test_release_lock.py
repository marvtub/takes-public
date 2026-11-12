"""The admin release command owns its shared files for the whole release."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


RELEASE = Path(__file__).parents[2] / "scripts" / "public" / "release.sh"


@unittest.skipUnless(RELEASE.exists(), "the release scripts are admin only")
class ReleaseLock(unittest.TestCase):
    def test_a_second_release_stops_without_emptying_the_first_release_log(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            home = root / "home"
            source = root / "takes"
            fake_bin = root / "bin"
            home.mkdir()
            source.mkdir()
            fake_bin.mkdir()
            waiting = root / "fetch-started"
            finish = root / "finish-fetch"
            git = fake_bin / "git"
            git.write_text(
                "#!/bin/bash\n"
                'touch "$FETCH_STARTED"\n'
                'while [[ ! -e "$FINISH_FETCH" ]]; do sleep 0.02; done\n'
                "exit 1\n"
            )
            git.chmod(0o755)
            env = os.environ | {
                "HOME": str(home),
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "TAKES_REPO": str(source),
                "FETCH_STARTED": str(waiting),
                "FINISH_FETCH": str(finish),
            }
            first = subprocess.Popen(
                ["/bin/bash", str(RELEASE)],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not waiting.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(waiting.exists(), "the first release did not reach git fetch")

                log = home / "Library" / "Logs" / "Takes" / "release.log"
                log.write_text("first release still owns this log\n")
                second = subprocess.run(
                    ["/bin/bash", str(RELEASE)],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )

                self.assertNotEqual(second.returncode, 0)
                self.assertIn("A public release is already running", second.stderr)
                self.assertEqual(log.read_text(), "first release still owns this log\n")
            finally:
                finish.touch()
                first.communicate(timeout=5)

            self.assertFalse((home / "Library" / "Logs" / "Takes" / "release.lock").exists())


if __name__ == "__main__":
    unittest.main()
