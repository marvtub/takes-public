"""Execute demo startup only, before it imports the MCP server or makes any media."""
import ast
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "scripts/public/demo.py"


@unittest.skipUnless(SOURCE.is_file(), "The public export omits demo generation tooling")
class DemoDestination(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        tree = ast.parse(SOURCE.read_text(), filename=str(SOURCE))
        # The environment assignment marks the start of library generation. Nothing past
        # that boundary may run in these tests (pictures can use the network and keys).
        stop = next(i for i, node in enumerate(tree.body)
                    if isinstance(node, ast.Assign)
                    and ast.unparse(node.targets[0]) == "os.environ['TAKES_ROOT']")
        self.startup = compile(ast.Module(body=tree.body[:stop], type_ignores=[]), str(SOURCE), "exec")

    def start(self, path):
        with patch.object(sys, "argv", [str(SOURCE), str(path)]):
            exec(self.startup, {"__file__": str(SOURCE)})

    def test_existing_library_is_never_deleted(self):
        dest = self.root / "library"
        dest.mkdir()
        sentinel = dest / "take.mov"
        sentinel.write_bytes(b"only recording")
        with self.assertRaises((SystemExit, FileExistsError)):
            self.start(dest)
        self.assertEqual(sentinel.read_bytes(), b"only recording")

    def test_existing_empty_directory_is_not_claimed(self):
        dest = self.root / "empty"
        dest.mkdir()
        with self.assertRaises((SystemExit, FileExistsError)):
            self.start(dest)
        self.assertEqual(list(dest.iterdir()), [])

    def test_symlink_target_is_not_changed(self):
        target = self.root / "real"
        target.mkdir()
        (target / "keep").write_text("keep")
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises((SystemExit, FileExistsError, OSError)):
            self.start(link)
        self.assertTrue(link.is_symlink())
        self.assertEqual((target / "keep").read_text(), "keep")

    def test_dangling_symlink_is_not_followed(self):
        link = self.root / "link"
        target = self.root / "absent"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaises((SystemExit, FileExistsError, OSError)):
            self.start(link)
        self.assertTrue(link.is_symlink())
        self.assertFalse(target.exists())

    def test_fresh_destination_is_created(self):
        dest = self.root / "new-demo"
        self.start(dest)
        self.assertTrue(dest.is_dir())
        self.assertEqual(list(dest.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
