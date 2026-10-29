import json
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class ToolDocsTests(unittest.TestCase):
    """tools/list describes every parameter and gives every tool its hints (2026-10-10): MCP
    directories such as Smithery score both."""

    def test_every_parameter_has_a_description(self):
        missing = []

        def walk(tool, schema, at):
            for k, v in schema.get("properties", {}).items():
                if not v.get("description"):
                    missing.append("%s.%s%s" % (tool, at, k))
                walk(tool, v, at + k + ".")
                if isinstance(v.get("items"), dict):
                    walk(tool, v["items"], at + k + "[].")
        for n, d, props, req, _ in t.TOOLS:
            walk(n, t.listed(n, d, props, req)["inputSchema"], "")
        self.assertEqual(missing, [], "add these to PARAM_DOC or give them a description")
        # Listing leaves the table alone.
        self.assertEqual(t.S, {"type": "string"})
        for n, d, props, req, _ in t.TOOLS:
            self.assertIn("annotations", t.listed(n, d, props, req))

    def test_hint_sets_name_real_tools(self):
        defined = {n[2:] for n in dir(t) if n.startswith("t_")}
        for hints in (t.READ_ONLY, t.DESTRUCTIVE, t.OPEN_WORLD):
            self.assertTrue(hints <= defined, hints - defined)
        self.assertFalse(t.READ_ONLY & t.DESTRUCTIVE)

    def test_always_load_only_in_the_takes_chat(self):
        try:
            os.environ["TAKES_CHAT"] = "1"
            loaded = {n for n, d, props, req, _ in t.TOOLS
                      if t.listed(n, d, props, req).get("_meta", {}).get("anthropic/alwaysLoad") is True}
            self.assertEqual(loaded, t.ALWAYS_LOAD)
            os.environ.pop("TAKES_CHAT")
            # A terminal Claude keeps every takes tool deferred.
            self.assertFalse(any("_meta" in t.listed(n, d, props, req) for n, d, props, req, _ in t.TOOLS))
        finally:
            os.environ.pop("TAKES_CHAT", None)

    def test_always_load_names_real_tools_and_stays_small(self):
        names = {n for n, *_ in t.TOOLS}
        self.assertTrue(t.ALWAYS_LOAD <= names, t.ALWAYS_LOAD - names)
        size = len(json.dumps([t.listed(n, d, props, req) for n, d, props, req, _ in t.TOOLS if n in t.ALWAYS_LOAD]))
        # 28000 since render_edit and publish_edit (2026-10-11): an edit chat calls them every version.
        # 16500 since set_storyboard, set_post and add_broll went back to deferred and the rest got
        # shorter (2026-10-11): about 15400 then.
        self.assertLess(size, 16500, "the tools that load with every Takes chat grew: keep them short")

    def test_tool_index_names_real_tools(self):
        named = set(re.findall(r"\b[a-z]+(?:_[a-z]+)+\b", t.TOOL_INDEX))
        self.assertTrue(named)
        self.assertTrue(named <= set(t.BY_NAME), named - set(t.BY_NAME))
        self.assertFalse(named & t.SOCIAL_TOOLS)
        self.assertNotIn("article", t.TOOL_INDEX)


if __name__ == "__main__":
    unittest.main()
