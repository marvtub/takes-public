"""The public demo pack removes its temporary media after failed builds."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "scripts/public/demo_pack.py"


@unittest.skipUnless(SOURCE.is_file(), "The public export omits demo generation tooling")
class DemoPack(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("demo_pack", SOURCE)
        cls.demo_pack = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.demo_pack)

    def test_failed_build_removes_temporary_media(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / "source"
            source.mkdir()
            (source / "session.json").write_text("{}")
            work = root / "temporary-media"

            with patch.object(sys, "argv", [str(SOURCE), str(root / "demo.zip"), str(source)]), \
                    patch.object(self.demo_pack.tempfile, "mkdtemp", return_value=str(work)):
                with self.assertRaises(FileNotFoundError):
                    self.demo_pack.main()

            self.assertFalse(work.exists())


if __name__ == "__main__":
    unittest.main()
