"""search_media: the takes-embed helper answers; a stand-in script plays it here."""
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class SearchMedia(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.models = os.path.join(self.dir, "models")
        os.makedirs(os.path.join(self.models, "text-q8"))
        self.args = os.path.join(self.dir, "args.json")
        self.helper = os.path.join(self.dir, "takes-embed")
        with open(self.helper, "w") as f:
            f.write("#!/usr/bin/python3\nimport json, sys\n"
                    "json.dump(sys.argv[1:], open(%r, 'w'))\n"
                    "print(json.dumps({'results': [\n"
                    "  {'path': '/r/a.mov', 'file': 'a.mov', 'kind': 'video', 'start': 16.0, 'end': 24.0, 'score': 0.7, 'rank': 4.1},\n"
                    "  {'path': '/r/s/script.md', 'file': 's/script.md', 'kind': 'script', 'start': 0, 'end': 0, 'text': 'Hi', 'score': 0.6, 'rank': 3}],\n"
                    "  'status': {'files': 9}}))\n" % self.args)
        os.chmod(self.helper, os.stat(self.helper).st_mode | stat.S_IEXEC)
        os.environ.update(TAKES_EMBED=self.helper, TAKES_EMBED_MODELS=self.models, TAKES_ROOT=self.dir)

    def tearDown(self):
        for k in ("TAKES_EMBED", "TAKES_EMBED_MODELS"):
            os.environ.pop(k, None)

    def test_without_the_model_it_says_so(self):
        out = t.t_search_media({"query": "hands typing"})
        self.assertIn("downloading", out["error"])

    def test_hits_carry_path_kind_and_time(self):
        open(os.path.join(self.models, "text-q8", "model.safetensors"), "w").close()
        out = t.t_search_media({"query": "hands typing", "kinds": ["video", "script"], "limit": 5})
        self.assertEqual(out["results"], [{"path": "/r/a.mov", "kind": "video", "at": 16.0},
                                          {"path": "/r/s/script.md", "kind": "script", "text": "Hi"}])
        self.assertEqual(out["indexed_files"], 9)
        args = json.load(open(self.args))
        self.assertEqual(args[0], "search")
        self.assertEqual(args[-1], "hands typing")
        self.assertIn("video,script", args)
        self.assertEqual(args[args.index("--limit") + 1], "5")

    def test_an_empty_query_is_refused(self):
        self.assertIn("error", t.t_search_media({"query": "  "}))


if __name__ == "__main__":
    unittest.main()
