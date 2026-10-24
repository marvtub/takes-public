import json
import os
import re
import subprocess
import sys
import unittest

MCP = os.path.join(os.path.dirname(__file__), "..")
# Settings > Private, the admin list. The public copy has no such file.
FEATURE_MAP = os.path.join(MCP, "..", "Sources", "Takes", "Plugins", "Private", "FeatureMap.swift")

PROBE = """
import json, takes_mcp as t
print(json.dumps({
    "social": t.SOCIAL, "blog": t.BLOG,
    "listed": sorted(t.SOCIAL_TOOLS & ({n for n, *_ in t.TOOLS} | set(t.BY_NAME))),
    "all_social": sorted(t.SOCIAL_TOOLS),
    "article": "article" in t.PLATFORMS, "ideas_note": t.IDEAS_NOTE,
    "site_areas": sorted({"site-page", "site-reply"} & set(t.AREAS)),
    "tools": sorted({n for n, *_ in t.TOOLS} | set(t.BY_NAME)),
}))
"""


def admin_tool_names():
    """The chat tools that FeatureMap names in its removed and switched-off entries: a code that is
    not a file, a plugin or a Features switch (2026-10-22). PublicViewTests.swift checks the rest."""
    if not os.path.exists(FEATURE_MAP):
        return []
    text = open(FEATURE_MAP, encoding="utf-8").read()
    names = []
    for codes in re.findall(r"kind: \.(?:removed|switchedOff), code: \[(.*?)\]", text):
        names += [c for c in re.findall(r'"([^"]+)"', codes) if re.fullmatch(r"[a-z_]+", c)]
    return sorted(set(names))


def probe(public_view):
    env = {k: v for k, v in os.environ.items() if k != "TAKES_PUBLIC_VIEW"}
    if public_view:
        env["TAKES_PUBLIC_VIEW"] = "1"
    out = subprocess.run([sys.executable, "-c", PROBE], cwd=MCP, env=env, capture_output=True, text=True, check=True)
    return json.loads(out.stdout.strip().splitlines()[-1])


class PublicViewTests(unittest.TestCase):
    """Public view (2026-10-22): the admin app starts a chat's server with TAKES_PUBLIC_VIEW=1, and the
    server then lists only what the public copy has. The flags are read at import, so each case runs
    its own process."""

    def test_public_view_hides_the_admin_tools_and_text(self):
        r = probe(True)
        self.assertFalse(r["social"])
        self.assertFalse(r["blog"])
        self.assertEqual(r["listed"], [])
        self.assertFalse(r["article"])
        self.assertEqual(r["ideas_note"], "")
        self.assertEqual(r["site_areas"], [])

    def test_public_view_hides_every_tool_the_feature_map_names(self):
        names = admin_tool_names()
        if not names:
            return  # the public copy: no FeatureMap
        on, off = probe(True), probe(False)
        for n in names:
            self.assertIn(n, off["tools"], f"FeatureMap names {n}, but the admin server has no such tool")
            self.assertNotIn(n, on["tools"], f"{n} still shows in Public view")

    def test_without_it_the_build_shows_what_it_has(self):
        r = probe(False)
        if not r["social"]:
            return  # the public copy: nothing admin to show
        self.assertTrue(r["blog"])
        self.assertEqual(r["listed"], r["all_social"])
        self.assertTrue(r["article"])
        self.assertNotEqual(r["ideas_note"], "")
        self.assertEqual(r["site_areas"], ["site-page", "site-reply"])


if __name__ == "__main__":
    unittest.main()
