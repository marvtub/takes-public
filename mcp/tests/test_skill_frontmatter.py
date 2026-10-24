"""Every SKILL.md header is plain YAML that strict readers accept (2026-10-21: the skills CLI behind skills.sh
skipped takes-video-edit, whose description had an unquoted ': ')."""
import glob
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def skill_files():
    return [p for pat in ("scripts/public/skills/*/SKILL.md", "admin/skills/*/SKILL.md", "skills/*/SKILL.md")
            for p in glob.glob(os.path.join(ROOT, pat))]


class SkillFrontmatter(unittest.TestCase):
    def test_values_need_no_quotes_or_have_them(self):
        files = skill_files()
        self.assertTrue(files)
        for p in files:
            head = re.match(r"---\n(.*?)\n---\n", open(p, encoding="utf-8").read(), re.S)
            self.assertTrue(head, p)
            for line in head.group(1).split("\n"):
                key, _, value = line.partition(": ")
                if not value or value[0] in "\"'":
                    continue
                self.assertNotIn(": ", value, "%s: quote the %s value" % (p, key))
                self.assertNotIn(" #", value, "%s: quote the %s value" % (p, key))


if __name__ == "__main__":
    unittest.main()
