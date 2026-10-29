"""--setup: the takes server in every MCP agent on the Mac, not only Claude Code (2026-10-10)."""
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class AgentSetup(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.server = os.path.join(self.home, "Takes.app/Contents/Resources/takes_mcp.py")
        self.write("Takes.app/Contents/Resources/takes_mcp.py", "")
        self.path = os.environ.get("PATH", "")
        os.environ["PATH"] = os.path.join(self.home, "bin")  # no real claude or codex

    def tearDown(self):
        os.environ["PATH"] = self.path
        shutil.rmtree(self.home)

    def write(self, rel, text):
        p = os.path.join(self.home, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        return p

    def read(self, rel):
        with open(os.path.join(self.home, rel)) as f:
            return json.load(f)

    def run_setup(self, once=False):
        return dict(t.setup_agents(self.server, self.home, once))

    def test_adds_the_server_and_keeps_the_rest_of_the_file(self):
        self.write(".cursor/mcp.json", json.dumps({"mcpServers": {"Pipedream": {"url": "https://x"}}, "z": 1, "a": 2}))
        os.makedirs(os.path.join(self.home, ".pi/agent"))
        os.makedirs(os.path.join(self.home, ".config/opencode"))
        os.makedirs(os.path.join(self.home, ".gemini/antigravity"))
        got = self.run_setup()
        self.assertEqual(got, {"Antigravity": "added", "Cursor": "added", "opencode": "added", "pi": "added"})
        # Antigravity's global config.
        self.assertEqual(self.read(".gemini/config/mcp_config.json")["mcpServers"]["takes"]["args"], [self.server])
        cursor = self.read(".cursor/mcp.json")
        self.assertEqual(list(cursor), ["mcpServers", "z", "a"])
        self.assertEqual(list(cursor["mcpServers"]), ["Pipedream", "takes"])
        self.assertEqual(cursor["mcpServers"]["takes"], {"command": "/usr/bin/python3", "args": [self.server], "env": {"TAKES_TOOLS": "core"}})
        self.assertEqual(self.read(".pi/agent/mcp.json")["mcpServers"]["takes"]["args"], [self.server])
        oc = self.read(".config/opencode/opencode.json")
        self.assertEqual(oc["mcp"]["takes"], {"type": "local", "command": ["/usr/bin/python3", self.server], "enabled": True})
        self.assertIn("$schema", oc)

    def test_agents_not_on_the_mac_are_not_touched(self):
        self.assertEqual(self.run_setup(), {})
        self.assertFalse(os.path.exists(os.path.join(self.home, ".cursor")))

    def test_a_moved_app_is_pointed_again_and_a_hand_setup_stays(self):
        self.write(".gemini/settings.json", json.dumps({"mcpServers": {"takes": {"command": "python3", "args": ["/gone/takes_mcp.py"]}}}))
        self.write(".cursor/mcp.json", json.dumps({"mcpServers": {"takes": {"command": "uvx", "args": ["my-takes"]}}}))
        got = self.run_setup()
        self.assertEqual(got, {"Gemini CLI": "updated", "Cursor": "ok"})
        self.assertEqual(self.read(".gemini/settings.json")["mcpServers"]["takes"]["args"], [self.server])
        self.assertEqual(self.read(".cursor/mcp.json")["mcpServers"]["takes"]["command"], "uvx")

    def test_a_file_with_comments_stays_as_it_is(self):
        text = '{\n  // mine\n  "mcpServers": {}\n}\n'
        self.write(".gemini/settings.json", text)
        self.assertTrue(self.run_setup()["Gemini CLI"].startswith("skipped"))
        with open(os.path.join(self.home, ".gemini/settings.json")) as f:
            self.assertEqual(f.read(), text)

    def test_status_lists_every_agent_and_changes_nothing(self):
        # Settings › Agents (2026-10-11): which agents are here and which have the server.
        self.write(".cursor/mcp.json", json.dumps({"mcpServers": {"takes": {"command": "x"}}}))
        os.makedirs(os.path.join(self.home, ".pi/agent"))
        got = {a["name"]: (a["found"], a["connected"]) for a in t.agents_status(self.home)}
        self.assertEqual(got["Cursor"], (True, True))
        self.assertEqual(got["pi"], (True, False))
        self.assertEqual(got["opencode"], (False, False))
        self.assertEqual(got["Codex"], (False, False))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".pi/agent/mcp.json")))

    def test_only_connects_one_agent(self):
        os.makedirs(os.path.join(self.home, ".cursor"))
        os.makedirs(os.path.join(self.home, ".pi/agent"))
        self.assertEqual(dict(t.setup_agents(self.server, self.home, only="pi")), {"pi": "added"})
        self.assertFalse(os.path.exists(os.path.join(self.home, ".cursor/mcp.json")))

    def test_a_codex_chat_names_its_own_rules_file(self):
        saved = {k: os.environ.pop(k, None) for k in ("TAKES_CHAT_ID", "CLAUDE_CODE_SESSION_ID")}
        try:
            os.environ["TAKES_CHAT_ID"] = "chat-codex-0001"
            os.environ["CLAUDE_CODE_SESSION_ID"] = "chat-claude-0001"
            self.assertEqual(t.chat_id(), "chat-codex-0001")
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_once_never_adds_a_removed_server_again(self):
        os.makedirs(os.path.join(self.home, ".cursor"))
        self.assertEqual(self.run_setup(once=True), {"Cursor": "added"})
        self.write(".cursor/mcp.json", json.dumps({"mcpServers": {}}))  # the user removed it
        self.assertEqual(self.run_setup(once=True), {"Cursor": "left out"})
        self.assertEqual(self.read(".cursor/mcp.json"), {"mcpServers": {}})
        self.assertEqual(self.run_setup(), {"Cursor": "added"})  # asked for in a terminal: added

    def test_codex_gets_it_through_its_own_command(self):
        log = os.path.join(self.home, "codex.log")
        cli = self.write("bin/codex", "#!/bin/sh\necho \"$@\" >> %s\n[ \"$2\" = get ] && exit 1\nexit 0\n" % log)
        os.chmod(cli, os.stat(cli).st_mode | stat.S_IEXEC)
        self.assertEqual(self.run_setup(), {"Codex": "added"})
        with open(log) as f:
            self.assertEqual(f.read().splitlines(), ["mcp get takes", "mcp add takes -- /usr/bin/python3 " + self.server])

    def test_reads_the_script_from_mcp_get_output(self):
        out = "takes\n  enabled: true\n  transport: stdio\n  command: /usr/bin/python3\n  args: /A/takes_mcp.py\n"
        self.assertEqual(t.server_scripts(out), ["/A/takes_mcp.py"])

    def test_cursor_gets_the_short_tool_list_and_a_choice_of_all_stays(self):
        self.write(".cursor/mcp.json", json.dumps({"mcpServers": {"takes": {"command": "/usr/bin/python3", "args": [self.server]}}}))
        self.assertEqual(self.run_setup(once=True), {"Cursor": "updated"})
        self.assertEqual(self.read(".cursor/mcp.json")["mcpServers"]["takes"]["env"], {"TAKES_TOOLS": "core"})
        self.write(".cursor/mcp.json", json.dumps({"mcpServers": {"takes": {"command": "/usr/bin/python3", "args": [self.server], "env": {"TAKES_TOOLS": "all"}}}}))
        self.assertEqual(self.run_setup(once=True), {"Cursor": "ok"})

    def test_the_short_list_fits_cursor_and_every_name_is_a_tool(self):
        names = {n for n, *_ in t.TOOLS}
        self.assertLessEqual(t.CORE_TOOLS, names)
        self.assertLessEqual(len(t.CORE_TOOLS), 30)
        os.environ["TAKES_TOOLS"] = "core"
        try:
            self.assertEqual({n for n in names if t.shown_tool(n)}, t.CORE_TOOLS)
        finally:
            os.environ.pop("TAKES_TOOLS")
        self.assertTrue(all(t.shown_tool(n) for n in names))
        # The instructions' tool index lists only the core tools then.
        got = []
        old = t.reply
        t.reply = lambda id_, result=None, error=None: got.append(result)
        os.environ["TAKES_TOOLS"] = "core"
        try:
            t.handle({"id": 1, "method": "initialize", "params": {}})
        finally:
            t.reply = old
            os.environ.pop("TAKES_TOOLS", None)
        index = got[0]["instructions"].split("Tools by step.")[1].split("Ideas:")[0]
        self.assertNotIn("broll", index)
        self.assertIn("check_edit", index)


if __name__ == "__main__":
    unittest.main()
