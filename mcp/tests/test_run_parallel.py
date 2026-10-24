"""run_parallel.py: a chunk leaves the environment as it found it (2026-10-22)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_parallel  # noqa: E402


class Leaky(unittest.TestCase):
    """Takes a variable away and adds one, as test_site_rules took TAKES_PAGE_SHOTS away."""

    def test_changes_the_environment(self):
        if os.environ.get("TAKES_LEAK_TEST") != "1":
            self.skipTest("run only by RunParallel")
        os.environ.pop("TAKES_PAGE_SHOTS", None)
        os.environ["TAKES_LEAKED"] = "1"


class RunParallel(unittest.TestCase):
    def test_a_chunk_puts_the_environment_back(self):
        keep = dict(os.environ)
        try:
            os.environ.update({"TAKES_PAGE_SHOTS": "off", "TAKES_LEAK_TEST": "1"})
            ids, ran, skipped, bad, _, _ = run_parallel.run(["test_run_parallel.Leaky.test_changes_the_environment"])
            self.assertEqual((ran, skipped, bad), (1, 0, []))
            # Without it, the next class in that worker opened Chrome for page screenshots.
            self.assertEqual(os.environ.get("TAKES_PAGE_SHOTS"), "off")
            self.assertNotIn("TAKES_LEAKED", os.environ)
        finally:
            os.environ.clear()
            os.environ.update(keep)


if __name__ == "__main__":
    unittest.main()
