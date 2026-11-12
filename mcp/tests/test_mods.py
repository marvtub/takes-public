import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


@unittest.skipUnless(t.SOCIAL, "mod_check is private")
class ModCheckTests(unittest.TestCase):
    """mod_check runs the check script the app writes into the mods folder (2026-11-06). The script is
    the app's; here a fake one stands in for it, so the test checks the tool's side only."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.environ["TAKES_MODS"] = self.dir

    def tearDown(self):
        os.environ.pop("TAKES_MODS", None)
        shutil.rmtree(self.dir, ignore_errors=True)

    def fake_check(self, out, code=0):
        path = os.path.join(self.dir, "check")
        with open(path, "w") as f:
            f.write("#!/bin/sh\necho '%s'\nexit %d\n" % (out, code))
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)

    def test_no_folder_says_how_to_start(self):
        with self.assertRaisesRegex(ValueError, "Plugins > Mods"):
            t.t_mod_check({"name": "this-week"})

    def test_names_stay_inside_the_folder(self):
        self.fake_check('{"ok": true}')
        for bad in ("", "../x", "_samples", ".hidden"):
            with self.assertRaises(ValueError):
                t.t_mod_check({"name": bad})

    def test_result_has_the_shot_and_the_app_error(self):
        self.fake_check('{"ok": false, "error": {"message": "x", "line": 3}}', 1)
        os.makedirs(os.path.join(self.dir, "m"))
        open(os.path.join(self.dir, "m", "m.shot.png"), "wb").close()
        with open(os.path.join(self.dir, "m", "m.error"), "w") as f:
            f.write("main.js:3:5: x\n")
        out = t.t_mod_check({"name": "m"})
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"]["line"], 3)
        self.assertTrue(out["shot"].endswith("m/m.shot.png"))
        self.assertEqual(out["app_error"], "main.js:3:5: x")
        self.assertTrue(out["manual"].endswith("AGENTS.md"))

    def shipped(self, name="sidebar"):
        d = os.path.join(self.dir, "_shipped", name)
        os.makedirs(d)
        with open(os.path.join(d, "mod.json"), "w") as f:
            f.write('{"name": "Sidebar", "slot": "sidebar", "version": "1.0.0"}\n')
        with open(os.path.join(d, "main.js"), "w") as f:
            f.write("function render() { return null; }\n")
        for f in os.listdir(d):
            os.chmod(os.path.join(d, f), 0o444)
        return d

    def test_clone_copies_a_shipped_part_and_never_twice(self):
        src = self.shipped()
        with open(os.path.join(src, "icon.svg"), "w") as f:
            f.write("<svg/>")
        with open(os.path.join(src, "sidebar.shot.png"), "w") as f:
            f.write("shot")
        out = t.t_mod_clone({"name": "sidebar"})
        mine = os.path.join(self.dir, "sidebar")
        self.assertEqual(out["folder"], mine)
        with open(os.path.join(mine, "icon.svg")) as f:
            self.assertEqual(f.read(), "<svg/>")
        self.assertFalse(os.path.exists(os.path.join(mine, "sidebar.shot.png")))
        with open(os.path.join(mine, "mod.json")) as f:
            m = json.load(f)
        self.assertEqual(m["cloned_from"], {"name": "sidebar", "version": "1.0.0"})
        self.assertEqual(m["slot"], "sidebar")
        # The copy is the user's to edit.
        self.assertTrue(os.access(os.path.join(mine, "main.js"), os.W_OK))
        with self.assertRaisesRegex(ValueError, "there already"):
            t.t_mod_clone({"name": "sidebar"})
        with self.assertRaisesRegex(ValueError, "Shipped: sidebar"):
            t.t_mod_clone({"name": "rail"})
        with self.assertRaises(ValueError):
            t.t_mod_clone({"name": "_shipped"})

    def test_check_finds_a_shipped_part_without_a_copy(self):
        self.fake_check('{"ok": true}')
        d = self.shipped()
        out = t.t_mod_check({"name": "sidebar"})
        self.assertEqual(out["folder"], d)
        os.makedirs(os.path.join(self.dir, "sidebar"))
        self.assertEqual(t.t_mod_check({"name": "sidebar"})["folder"], os.path.join(self.dir, "sidebar"))

    def board_files(self):
        registry = {"version": 1, "boards": {
            "climb": {"title": "Climb", "sections": [
                {"id": "climb.hill", "title": "Hill", "fields": {}, "replaceable": False},
                {"id": "climb.tickets", "title": "Tickets", "fields": {"count": "number"}, "replaceable": True}]},
            "performance": {"title": "Performance", "sections": [
                {"id": "performance.overview", "title": "Overview", "fields": {}, "replaceable": True}]}}}
        with open(os.path.join(self.dir, "sections.json"), "w") as f:
            json.dump(registry, f)
        path = os.path.join(self.dir, "_shipped", "layouts", "climb.json")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as f:
            json.dump({"sections": ["climb.hill", "climb.tickets"]}, f)
        os.chmod(path, 0o444)
        with open(os.path.join(os.path.dirname(path), "performance.json"), "w") as f:
            json.dump({"sections": ["performance.overview"]}, f)
        return registry, path

    def write_layout(self, sections):
        path = os.path.join(self.dir, "layouts", "climb.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"sections": sections}, f)
        return path

    def test_board_check_lists_registry_and_checks_shipped_layout_without_name(self):
        registry, shipped = self.board_files()
        out = t.t_mod_check({"board": "climb"})
        self.assertTrue(out["ok"])
        self.assertEqual(out["board"], "climb")
        self.assertEqual(out["sections"], registry["boards"]["climb"]["sections"])
        self.assertEqual(out["layout"], {"sections": ["climb.hill", "climb.tickets"]})
        self.assertEqual(out["path"], shipped)
        self.assertTrue(out["shipped"])
        performance = t.t_mod_check({"board": "performance"})
        self.assertTrue(performance["ok"])
        self.assertEqual(performance["sections"], registry["boards"]["performance"]["sections"])

    def test_layout_clone_is_editable_copy_and_delete_restores_shipped(self):
        _, shipped = self.board_files()
        out = t.t_mod_clone({"name": "layouts/climb.json"})
        mine = os.path.join(self.dir, "layouts", "climb.json")
        self.assertEqual(out["path"], mine)
        self.assertTrue(os.stat(mine).st_mode & stat.S_IWUSR)
        self.write_layout(["climb.tickets", "climb.hill"])
        checked = t.t_mod_check({"board": "climb"})
        self.assertEqual(checked["path"], mine)
        self.assertFalse(checked["shipped"])
        self.assertEqual(checked["layout"]["sections"], ["climb.tickets", "climb.hill"])
        with self.assertRaisesRegex(ValueError, "there already"):
            t.t_mod_clone({"board": "climb"})
        os.unlink(mine)
        self.assertEqual(t.t_mod_check({"board": "climb"})["path"], shipped)
        self.assertEqual(t.t_mod_clone({"board": "climb"})["path"], mine)

    def test_layout_check_reports_order_with_titles_and_hidden_and_unknown_ids(self):
        self.board_files()
        out = t.t_mod_check({"board": "climb"})
        self.assertEqual(out["order"], [{"id": "climb.hill", "title": "Hill"},
                                        {"id": "climb.tickets", "title": "Tickets"}])
        self.assertEqual(out["hidden"], [])
        self.assertEqual(out["unknown"], [])
        self.write_layout(["climb.tickets"])
        out = t.t_mod_check({"name": "layouts/climb.json"})
        self.assertEqual(out["order"], [{"id": "climb.tickets", "title": "Tickets"}])
        self.assertEqual(out["hidden"], ["climb.hill"])
        self.assertNotIn("shot", out)
        self.write_layout([])
        out = t.t_mod_check({"board": "climb"})
        self.assertEqual(out["order"], [])
        self.assertEqual(out["hidden"], ["climb.hill", "climb.tickets"])
        self.write_layout(["climb.typo", "performance.overview"])
        out = t.t_mod_check({"board": "climb"})
        self.assertFalse(out["ok"])
        self.assertEqual(out["unknown"], ["climb.typo", "performance.overview"])
        self.assertNotIn("order", out)

    def test_layout_check_validates_ids_duplicates_types_and_empty(self):
        self.board_files()
        for sections, message in ((["climb.missing"], "climb.missing"),
                                  (["performance.overview"], "performance.overview"),
                                  (["climb.hill", "climb.hill"], "Duplicate"),
                                  ([7], "strings"), ("climb.hill", "array")):
            with self.subTest(sections=sections):
                self.write_layout(sections)
                out = t.t_mod_check({"name": "layouts/climb.json"})
                self.assertFalse(out["ok"])
                self.assertIn(message, out["error"]["message"])
                self.assertEqual(out["error"]["file"], "layouts/climb.json")
        self.write_layout([])
        self.assertTrue(t.t_mod_check({"board": "climb"})["ok"])

    def test_board_errors_are_useful_and_layout_names_stay_inside_mods(self):
        with self.assertRaisesRegex(ValueError, "sections.json.*Plugins > Mods"):
            t.t_mod_check({"board": "climb"})
        self.board_files()
        with self.assertRaisesRegex(ValueError, "Unknown board.*climb.*performance"):
            t.t_mod_check({"board": "unknown"})
        with self.assertRaisesRegex(ValueError, "Unknown board"):
            t.t_mod_clone({"name": "layouts/unknown.json"})
        for name in ("layouts/../climb.json", "layouts/.climb.json", "layouts/climb.json/extra", "layouts/../../x.json"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                t.t_mod_clone({"name": name})
        with self.assertRaisesRegex(ValueError, "same board"):
            t.t_mod_check({"board": "performance", "name": "layouts/climb.json"})

    def test_broken_layout_never_falls_back_to_shipped_or_gets_overwritten(self):
        self.board_files()
        mine = self.write_layout([])
        with open(mine, "w") as f:
            f.write("{broken")
        out = t.t_mod_check({"board": "climb"})
        self.assertFalse(out["ok"])
        self.assertIn("JSON", out["error"]["message"])
        self.assertEqual(out["path"], mine)
        with self.assertRaisesRegex(ValueError, "there already"):
            t.t_mod_clone({"board": "climb"})
        with open(mine) as f:
            self.assertEqual(f.read(), "{broken")

    def test_layout_requires_sections_and_registry_is_the_source_of_ids(self):
        registry, _ = self.board_files()
        registry["boards"]["climb"]["sections"].append(
            {"id": "climb.future", "title": "Future", "fields": {}, "replaceable": True})
        with open(os.path.join(self.dir, "sections.json"), "w") as f:
            json.dump(registry, f)
        mine = self.write_layout(["climb.future"])
        self.assertTrue(t.t_mod_check({"board": "climb"})["ok"])
        with open(mine, "w") as f:
            json.dump({"sections": ["climb.future"], "note": "extra metadata is harmless"}, f)
        self.assertTrue(t.t_mod_check({"board": "climb"})["ok"])
        with open(mine, "w") as f:
            json.dump({"note": "no sections"}, f)
        self.assertFalse(t.t_mod_check({"board": "climb"})["ok"])

    def test_tool_schema_allows_board_without_name_and_stays_private(self):
        for name in ("mod_check", "mod_clone"):
            self.assertIn(name, t.SOCIAL_TOOLS)
            _, _, props, required, _ = t.BY_NAME[name]
            self.assertIn("board", props)
            self.assertNotIn("name", required)
        # Exercise the public-view import and actual dispatch gate, without starting a server.
        path = t.__file__
        import importlib.util
        spec = importlib.util.spec_from_file_location("takes_public_mods_test", path)
        public = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {"TAKES_PUBLIC_VIEW": "1"}):
            spec.loader.exec_module(public)
        self.assertFalse({"mod_check", "mod_clone"} & set(public.BY_NAME))
        replies = []
        public.reply = lambda *args, **kwargs: replies.append((args, kwargs))
        for name in ("mod_check", "mod_clone"):
            public.handle({"id": 1, "method": "tools/call", "params": {"name": name}})
            self.assertIn("Unknown tool", replies[-1][1]["error"]["message"])

    def test_generated_dotted_board_can_be_checked_and_cloned(self):
        registry, _ = self.board_files()
        registry["boards"]["site.overview"] = {"title": "Overview", "sections": [
            {"id": "site.overview.headline", "title": "Headline", "fields": {}, "replaceable": True}]}
        with open(os.path.join(self.dir, "sections.json"), "w") as f:
            json.dump(registry, f)
        src = os.path.join(self.dir, "_shipped", "layouts", "site.overview.json")
        with open(src, "w") as f:
            json.dump({"sections": ["site.overview.headline"]}, f)
        checked = t.t_mod_check({"board": "site.overview"})
        self.assertTrue(checked["ok"])
        self.assertEqual(checked["path"], src)
        copied = t.t_mod_clone({"name": "layouts/site.overview.json"})
        self.assertEqual(copied["path"], os.path.join(self.dir, "layouts", "site.overview.json"))
        self.assertTrue(t.t_mod_check({"name": "layouts/site.overview.json"})["ok"])
        for bad in ("layouts/site..overview.json", "layouts/..site.json", "layouts/site...json"):
            with self.subTest(name=bad), self.assertRaises(ValueError):
                t.t_mod_clone({"name": bad})


if __name__ == "__main__":
    unittest.main()
