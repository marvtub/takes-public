"""Release notes with pictures (2026-10-24): the check Takes > Release to GitHub runs before a release
(scripts/public/export.py --check-notes). Admin only: the public copy has no scripts/public."""
import importlib.util
import os
import tempfile
import unittest

EXPORT = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "public", "export.py")


@unittest.skipUnless(os.path.exists(EXPORT), "the release scripts are admin only")
class ReleaseNotes(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("export_notes", EXPORT)
        self.e = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.e)
        self.dir = tempfile.mkdtemp()
        self.e.NOTES_FILE = os.path.join(self.dir, "next.md")
        self.e.NOTES_MEDIA = os.path.join(self.dir, "media")
        os.makedirs(self.e.NOTES_MEDIA)

    def check(self, body, files=()):
        for f in files:
            open(os.path.join(self.e.NOTES_MEDIA, f), "wb").write(b"x")
        open(self.e.NOTES_FILE, "w").write(f"---\nsince: abc1234\napproved: yes\n---\n\n{body}\n")
        return self.e.check_notes("abc1234")

    def test_a_section_with_its_picture_passes(self):
        body = "### Welcome\n![The four pages, one after the other](media/welcome.webp)\n- A new welcome"
        self.assertEqual(self.check(body, ["welcome.webp"]), [])
        # Fixes need no picture.
        self.assertEqual(self.check("### Fixes\n- Update no longer waits for idle chats"), [])

    def test_a_section_without_a_picture_is_refused(self):
        bad = self.check("### Menus\n- A right-click opens the menu of the row")
        self.assertTrue(any("### Menus has no picture" in b for b in bad), bad)

    def test_pictures_no_lets_a_section_go_without_one(self):
        open(self.e.NOTES_FILE, "w").write("---\nsince: abc1234\napproved: yes\npictures: no\n---\n\n### Menus\n- A right-click opens the menu\n")
        self.assertEqual(self.e.check_notes("abc1234"), [])

    def test_a_picture_needs_its_file(self):
        bad = self.check("### Help\n![The guide](media/help.webp)\n- Takes Help opens a guide")
        self.assertTrue(any("No file for this picture" in b for b in bad), bad)

    def test_the_picture_words_get_the_same_checks(self):
        bad = self.check("### Help\n![For Product Hunt](media/help.webp)\n- Takes Help opens a guide", ["help.webp"])
        self.assertTrue(any("Internal work" in b for b in bad), bad)


if __name__ == "__main__":
    unittest.main()
