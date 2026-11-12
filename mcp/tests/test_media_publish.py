import subprocess
import tempfile
import unittest
from pathlib import Path


PUBLISH = Path(__file__).resolve().parents[2] / "scripts/public/publish-media.sh"


@unittest.skipUnless(PUBLISH.is_file(), "The public export omits README media tooling")
class MediaPublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.staged = self.root / "staged"
        self.out = self.root / "docs"
        self.staged.mkdir()
        self.out.mkdir()
        (self.out / "banner.webp").write_bytes(b"old banner")
        (self.out / "phone.webp").write_bytes(b"old phone")
        (self.out / "keep.txt").write_bytes(b"unrelated")

    def tearDown(self):
        self.tmp.cleanup()

    def publish(self):
        return subprocess.run(
            ["bash", str(PUBLISH), str(self.staged), str(self.out), "banner", "phone"],
            capture_output=True, text=True,
        )

    def test_incomplete_media_never_replaces_the_existing_set(self):
        (self.staged / "banner.webp").write_bytes(b"new banner")

        result = self.publish()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.out / "banner.webp").read_bytes(), b"old banner")
        self.assertEqual((self.out / "phone.webp").read_bytes(), b"old phone")
        self.assertEqual((self.out / "keep.txt").read_bytes(), b"unrelated")

    def test_complete_media_replaces_only_the_generated_files(self):
        (self.staged / "banner.webp").write_bytes(b"new banner")
        (self.staged / "phone.webp").write_bytes(b"new phone")

        result = self.publish()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.out / "banner.webp").read_bytes(), b"new banner")
        self.assertEqual((self.out / "phone.webp").read_bytes(), b"new phone")
        self.assertEqual((self.out / "keep.txt").read_bytes(), b"unrelated")

    def test_unexpected_media_never_replaces_the_existing_set(self):
        (self.staged / "banner.webp").write_bytes(b"new banner")
        (self.staged / "phone.webp").write_bytes(b"new phone")
        (self.staged / "partial.webp").write_bytes(b"unexpected")

        result = self.publish()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.out / "banner.webp").read_bytes(), b"old banner")
        self.assertEqual((self.out / "phone.webp").read_bytes(), b"old phone")
        self.assertEqual((self.out / "keep.txt").read_bytes(), b"unrelated")


if __name__ == "__main__":
    unittest.main()
