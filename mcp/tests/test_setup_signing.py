import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "setup-signing.sh"


class SetupSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="takes-signing-test-"))
        self.home = self.temp / "home"
        self.bin = self.temp / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.state = self.home / ".fake-security"
        self.state.mkdir()
        self.keychain = self.home / "Library/Keychains/takes-signing.keychain-db"
        self.passfile = self.home / ".config/takes/keychain-pass"

        self._command(
            "openssl",
            r'''#!/bin/bash
set -euo pipefail
case "$1" in
  rand)
    echo "0123456789abcdef0123456789abcdef0123456789abcdef"
    ;;
  req|pkcs12)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -keyout|-out)
          shift
          mkdir -p "$(dirname "$1")"
          : > "$1"
          ;;
      esac
      shift
    done
    ;;
  *)
    exit 2
    ;;
esac
''',
        )
        self._command(
            "security",
            r'''#!/bin/bash
set -euo pipefail
STATE="$HOME/.fake-security"
mkdir -p "$STATE"
command="$1"
shift
case "$command" in
  create-keychain)
    password="$2"
    keychain="$3"
    mkdir -p "$(dirname "$keychain")"
    : > "$keychain"
    printf '%s' "$password" > "$STATE/password"
    ;;
  set-keychain-settings|set-key-partition-list)
    ;;
  unlock-keychain)
    password="$2"
    [[ -f "$STATE/password" && "$(cat "$STATE/password")" == "$password" ]]
    ;;
  import)
    if [[ -f "$STATE/fail-import-once" ]]; then
      rm "$STATE/fail-import-once"
      exit 42
    fi
    : > "$STATE/identity"
    ;;
  find-identity)
    if [[ -f "$STATE/identity" ]]; then
      echo '  1) ABCDEF "Takes Local Signing"'
      echo '     1 valid identities found'
    else
      echo '     0 valid identities found'
    fi
    ;;
  list-keychains)
    if [[ "$*" == "-d user" && -f "$STATE/fail-list-once" ]]; then
      rm "$STATE/fail-list-once"
      exit 43
    fi
    shift 2
    if [[ "${1:-}" == "-s" ]]; then
      shift
      printf '%s\n' "$@" > "$STATE/search-list"
    elif [[ -f "$STATE/search-list" ]]; then
      while IFS= read -r keychain; do
        printf '    "%s"\n' "$keychain"
      done < "$STATE/search-list"
    fi
    ;;
  delete-keychain)
    rm -f "$1" "$STATE/password" "$STATE/identity"
    ;;
  *)
    echo "Unexpected security command: $command" >&2
    exit 2
    ;;
esac
''',
        )

    def tearDown(self):
        shutil.rmtree(self.temp)

    def _command(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def _run(self):
        env = dict(os.environ)
        env["HOME"] = str(self.home)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            text=True,
            capture_output=True,
        )

    def test_failed_import_is_removed_and_the_next_run_completes(self):
        (self.state / "fail-import-once").touch()

        first = self._run()
        self.assertNotEqual(first.returncode, 0)
        self.assertFalse(self.keychain.exists())
        self.assertFalse(self.passfile.exists())

        second = self._run()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertTrue(self.keychain.exists())
        self.assertTrue(self.passfile.exists())

        third = self._run()
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertIn("Signing keychain is ready", third.stdout)

    def test_existing_keychain_must_unlock_with_its_saved_password(self):
        self.keychain.parent.mkdir(parents=True)
        self.keychain.touch()
        self.passfile.parent.mkdir(parents=True)
        self.passfile.write_text("saved-password")
        (self.state / "password").write_text("different-password")

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not ready", result.stderr)
        self.assertEqual(self.passfile.read_text(), "saved-password")

    def test_existing_keychain_needs_the_identity_and_search_list_entry(self):
        created = self._run()
        self.assertEqual(created.returncode, 0, created.stderr)

        (self.state / "identity").unlink()
        missing_identity = self._run()
        self.assertNotEqual(missing_identity.returncode, 0)
        self.assertIn("not ready", missing_identity.stderr)

        (self.state / "identity").touch()
        (self.state / "search-list").write_text("")
        missing_search_entry = self._run()
        self.assertNotEqual(missing_search_entry.returncode, 0)
        self.assertIn("not ready", missing_search_entry.stderr)

    def test_failed_search_list_read_keeps_the_existing_search_list(self):
        original = "/Users/test/Library/Keychains/login.keychain-db\n/Library/Keychains/System.keychain\n"
        (self.state / "search-list").write_text(original)
        (self.state / "fail-list-once").touch()

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.state / "search-list").read_text(), original)
        self.assertFalse(self.keychain.exists())
        self.assertFalse(self.passfile.exists())


if __name__ == "__main__":
    unittest.main()
