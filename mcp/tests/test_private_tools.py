import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class PrivateToolsTests(unittest.TestCase):
    """The comment copilot and Performance tools are private (2026-10-09): the public copy's server
    (SOCIAL = False) lists none of them and refuses a call to one."""

    def test_social_tools_follow_the_switch(self):
        names = {n for n, *_ in t.TOOLS}
        if t.SOCIAL:
            self.assertTrue(t.SOCIAL_TOOLS <= names, t.SOCIAL_TOOLS - names)
        else:
            self.assertFalse(t.SOCIAL_TOOLS & names)
            self.assertFalse(t.SOCIAL_TOOLS & set(t.BY_NAME))

    def test_every_social_tool_exists(self):
        # A renamed tool must not slip out of the list and into the public server.
        defined = {n[2:] for n in dir(t) if n.startswith("t_")}
        self.assertTrue(t.SOCIAL_TOOLS <= defined, t.SOCIAL_TOOLS - defined)


if __name__ == "__main__":
    unittest.main()
