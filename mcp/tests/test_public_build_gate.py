"""Run the build gate with fake toolchains; never build or touch the user's cache."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/public/check-public-build.sh"


@unittest.skipUnless(SOURCE.is_file(), "The public export omits its admin build gate")
class PublicBuildGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts/public").mkdir(parents=True)
        shutil.copy2(SOURCE, self.root / "scripts/public/check-public-build.sh")
        (self.root / "scripts/test-queue.sh").write_text('LOW=(env)\ntook() { :; }\n')
        (self.root / "index").write_text("index")
        self.cache = self.root / "home/Library/Caches/takes-public-check"
        self.cache.parent.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root / "home"),
                        PATH=str(self.bin) + ":/usr/bin:/bin", TAKES_PUBLIC_FULL="")
        self.stub("seq", "printf '1\\n2\\n'")
        self.stub("sleep", ":")
        self.stub("git", 'echo git >> "$HOME/touched"; case "$*" in *--git-path*) echo index;; *write-tree*) echo tree;; esac')
        self.stub("python3", 'if [[ "$*" == *export.py* ]]; then mkdir -p "${@: -2:1}/copy"; fi')
        self.stub("rsync", ":")
        self.stub("swift", 'if [[ -n "${SWIFT_ERROR:-}" ]]; then printf "%s\\n" "$SWIFT_ERROR"; exit 1; fi')
        self.stub("xcode-select", 'echo /Library/Developer/CommandLineTools')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_gate(self):
        # The full Mac suite runs eight MCP workers; ten seconds was flaky under load.
        # Keep a hard bound, with room for scheduled-out fixture processes (2026-10-30).
        return subprocess.run(["bash", "scripts/public/check-public-build.sh"],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=60)

    def test_timeout_does_not_use_cache_or_remove_another_owners_lock(self):
        lock = Path(str(self.cache) + ".lock")
        lock.mkdir()
        (lock / "owner").write_text("another run")
        os.utime(lock, (1, 1))
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((lock / "owner").read_text(), "another run")
        self.assertFalse((self.root / "home/touched").exists())

    def test_nonmatching_failure_keeps_full_log_and_explains_it(self):
        self.env["SWIFT_ERROR"] = "toolchain disappeared"
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Full log:", result.stderr)
        self.assertEqual((self.cache / "mac.log").read_text(), "toolchain disappeared\n")
        self.assertFalse(Path(str(self.cache) + ".lock").exists())

    def test_large_failure_log_does_not_abort_diagnostics(self):
        # The same 210 KB (well over pipe capacity), without 10,000 shell printf calls.
        emit = 'import sys; sys.stdout.write("".join("error: problem %05d\\n" % i for i in range(10000))); sys.exit(1)'
        self.stub("swift", f'{shlex.quote(sys.executable)} -c {shlex.quote(emit)}')
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Full log:", result.stderr)
        self.assertIn("error: problem 09999", (self.cache / "mac.log").read_text())
        self.assertEqual((self.cache / "mac.log").stat().st_size, 210_000)

    def test_missing_phone_toolchain_is_not_a_successful_gate(self):
        # No Xcode on Linux. On a Mac, hide xcodegen with a failing command lookup.
        self.stub("xcodegen", "exit 1")
        if Path("/Applications/Xcode.app/Contents/Developer").is_dir():
            self.skipTest("Requires a host without Xcode")
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("phone compiles", result.stdout)


if __name__ == "__main__":
    unittest.main()
