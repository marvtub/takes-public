"""Run reset only in a private HOME with fake macOS/agent commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/public/tester.sh"


@unittest.skipUnless(SOURCE.is_file(), "The public export omits tester tooling")
class TesterReset(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.skills = self.home / ".claude/skills"
        self.skills.mkdir(parents=True)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.trace = self.home / "trace"
        for name in ["pgrep", "pkill", "defaults", "killall", "tccutil", "security", "claude"]:
            p = self.bin / name
            p.write_text('#!/bin/bash\nprintf "%s\\n" "' + name + ' $*" >> "$TRACE"\nexit ' + ('1' if name == 'pgrep' else '0') + '\n')
            p.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), USER="takestester", TRACE=str(self.trace),
                        PATH=str(self.bin) + ":/usr/bin:/bin")

    def reset(self, *args):
        return subprocess.run(["bash", str(SOURCE), "reset", *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def skill(self, name, managed=False):
        d = self.skills / name
        d.mkdir()
        (d / "SKILL.md").write_text("keep my skill")
        if managed:
            (d / ".takes-skill").write_text("takes")
        return d

    def test_unknown_duplicate_or_extra_flags_have_no_side_effects(self):
        keep = self.skill("unrelated") / "SKILL.md"
        for args in [("--keep-cluade",), ("--keep-claude", "extra"),
                     ("--keep-claude", "--keep-claude"), ("extra", "--keep-claude")]:
            with self.subTest(args=args):
                result = self.reset(*args)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(keep.read_text(), "keep my skill")
                self.assertFalse(self.trace.exists(), "must validate before process/keychain actions")

    def test_keep_claude_removes_only_marked_skill_directories(self):
        unrelated = self.skill("unrelated")
        # Names alone do not establish ownership.
        user_takes = self.skill("takes-storyboard")
        owned = self.skill("takes-video-edit", managed=True)
        result = self.reset("--keep-claude")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((unrelated / "SKILL.md").is_file())
        self.assertTrue((user_takes / "SKILL.md").is_file())
        self.assertFalse(owned.exists())
        self.assertNotIn("Claude Code-credentials", self.trace.read_text())

    def test_keep_claude_does_not_follow_skill_directory_symlinks(self):
        outside = self.home / "outside"
        outside.mkdir()
        (outside / ".takes-skill").write_text("takes")
        (outside / "SKILL.md").write_text("outside")
        link = self.skills / "linked"
        link.symlink_to(outside, target_is_directory=True)
        result = self.reset("--keep-claude")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual((outside / "SKILL.md").read_text(), "outside")

    def test_keep_claude_does_not_traverse_a_symlinked_skills_root(self):
        self.skills.rmdir()
        outside = self.home / "outside"
        outside.mkdir()
        (outside / ".takes-skill").write_text("takes")
        self.skills.symlink_to(outside, target_is_directory=True)
        result = self.reset("--keep-claude")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.skills.is_symlink())
        self.assertTrue((outside / ".takes-skill").is_file())

    def test_default_reset_still_removes_claude_in_tester_home(self):
        self.skill("unrelated")
        result = self.reset()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.home / ".claude").exists())
        self.assertIn("Claude Code-credentials", self.trace.read_text())


if __name__ == "__main__":
    unittest.main()
