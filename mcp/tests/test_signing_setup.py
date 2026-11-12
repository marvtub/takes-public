"""The local signing setup keeps every existing keychain path intact."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/setup-signing.sh"


class SigningSetup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.home.mkdir()
        self.stub(
            "openssl",
            '[[ "${1:-}" == "rand" ]] && printf "test-password\\n"\nexit 0',
        )
        self.stub(
            "security",
            # The script checks its work at the end: it reads the search list again, finds the
            # identity and needs the keychain file, so the stub keeps that state too.
            r'''if [[ "$1" == "list-keychains" && "$#" -eq 3 && -f "$HOME/final-keychain-arguments" ]]; then
  tail -n +5 "$HOME/final-keychain-arguments" | while IFS= read -r k; do printf '    "%s"\n' "$k"; done
elif [[ "$1" == "list-keychains" && "$#" -eq 3 ]]; then
  printf '    "%s"\n' \
    "$HOME/Library/Keychains/login.keychain-db" \
    "$HOME/Library/Keychains/Work Keys.keychain-db"
elif [[ "$1" == "list-keychains" ]]; then
  printf '%s\n' "$@" > "$HOME/final-keychain-arguments"
elif [[ "$1" == "create-keychain" ]]; then
  mkdir -p "$(dirname "$4")"; : > "$4"
elif [[ "$1" == "find-identity" ]]; then
  echo '  1) ABCDEF "Takes Local Signing"'
fi''',
        )

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def test_existing_keychain_paths_remain_single_arguments(self):
        env = dict(
            os.environ,
            HOME=str(self.home),
            PATH=str(self.bin) + ":/usr/bin:/bin",
        )
        result = subprocess.run(
            ["bash", str(SOURCE)], env=env, capture_output=True, text=True, timeout=10
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.home / "final-keychain-arguments").read_text().splitlines(),
            [
                "list-keychains",
                "-d",
                "user",
                "-s",
                str(self.home / "Library/Keychains/login.keychain-db"),
                str(self.home / "Library/Keychains/Work Keys.keychain-db"),
                str(self.home / "Library/Keychains/takes-signing.keychain-db"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
