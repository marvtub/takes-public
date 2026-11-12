"""The server starts from saved bytecode (2026-11-06): compiling the whole file at each start left
about 100 MB of dirty memory in every server for as long as its chat lived (107 servers at once)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
INIT = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}\n'
LIST = b'{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n'


class PycStart(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.res = os.path.join(self.tmp, "Resources")  # like the app: no scripts/version.sh beside it
        os.makedirs(self.res)
        self.server = os.path.join(self.res, "takes_mcp.py")
        shutil.copy(os.path.join(HERE, "takes_mcp.py"), self.server)
        self.pycs = os.path.join(self.tmp, "pyc")
        self.lib = os.path.join(self.tmp, "lib")
        os.makedirs(self.lib)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def start(self, pyc_dir):
        """Start the server, ask initialize and tools/list. Returns (replies, command line, RSS in MB)."""
        env = dict(os.environ, TAKES_ROOT=self.lib, TAKES_PYC_DIR=pyc_dir)
        env.pop("CLAUDE_CODE_SESSION_ID", None)
        p = subprocess.Popen([sys.executable, self.server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             env=env, cwd=self.tmp)
        try:
            p.stdin.write(INIT + LIST)
            p.stdin.flush()
            replies = [json.loads(p.stdout.readline()), json.loads(p.stdout.readline())]
            ps = subprocess.run(["ps", "-o", "rss=,command=", "-p", str(p.pid)], capture_output=True, text=True).stdout
            rss, command = ps.strip().split(None, 1)
            return replies, command, int(rss) / 1024
        finally:
            p.stdin.close()
            p.wait(10)
            p.stdout.close()

    def saved(self):
        return [os.path.join(self.pycs, n) for n in os.listdir(self.pycs)] if os.path.isdir(self.pycs) else []

    def test_the_server_runs_from_bytecode_with_the_same_answers(self):
        plain, plain_cmd, plain_rss = self.start("off")
        self.assertNotIn(" -c ", plain_cmd)
        self.assertEqual(self.saved(), [])
        first, cmd, rss = self.start(self.pycs)  # saves the bytecode
        self.assertEqual(len(self.saved()), 1)
        again, cmd, rss = self.start(self.pycs)  # loads it
        self.assertIn(" -c ", cmd)
        self.assertIn(self.server, cmd)  # pgrep -f takes_mcp.py still finds it
        self.assertEqual(first, plain)
        self.assertEqual(again, plain)
        # The compiler's leftovers are gone: about 20 MB instead of about 128.
        self.assertLess(rss, plain_rss / 2)
        self.assertLess(rss, 60)

    def test_a_changed_file_saves_new_bytecode(self):
        self.start(self.pycs)
        pyc, = self.saved()
        with open(pyc, "rb") as f:
            before = f.read(16)
        with open(self.server, "a") as f:
            f.write("\nCHANGED = 1\n")
        replies, cmd, _ = self.start(self.pycs)
        self.assertEqual(replies[0]["id"], 1)
        with open(pyc, "rb") as f:
            self.assertNotEqual(f.read(16), before)
        # A broken saved file falls back to the source.
        with open(pyc, "r+b") as f:
            f.seek(16)
            f.write(b"\0garbage\0")
        replies, _, _ = self.start(self.pycs)
        self.assertIn("tools", replies[1]["result"])

    def test_short_commands_and_imports_do_not_re_exec(self):
        env = dict(os.environ, TAKES_ROOT=self.lib, TAKES_PYC_DIR=self.pycs)
        out = subprocess.run([sys.executable, self.server, "--session-id", self.lib], capture_output=True,
                             text=True, env=env)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.saved(), [])

    def test_a_job_runner_starts_from_bytecode(self):
        # 2026-11-07: --detach and --job-run each compiled the source, so a runner took two compiles to
        # start (over 10 s on a Mac at load 80: test_jobs timed out in full runs). From fresh bytecode: none.
        import importlib.util
        os.environ["TAKES_PYC_DIR"], os.environ["TAKES_ROOT"] = self.pycs, self.lib
        try:
            spec = importlib.util.spec_from_file_location("takes_copy", self.server)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            self.assertEqual(m.self_argv(["--x"])[1:], [self.server, "--x"])  # no bytecode yet: the source
            self.start(self.pycs)  # the server saves it
            self.assertEqual(m.self_argv(["--x"])[1], "-c")
            s = os.path.join(self.lib, "Launch", "2026-11-07-demo")
            os.makedirs(s)
            m.write_meta(s, {"title": "demo", "createdAt": "2026-11-07T00:00:00Z", "named": True, "takes": []})
            job = m.t_run_job({"session": s, "cmd": "ps -o command= -p $PPID", "outputs": [], "label": "Who runs me"})["job"]
            self.assertEqual(m.t_get_job({"id": job, "session": s, "wait_s": 30})["status"], "done")
            with open(m.job_path(s, job, ".log")) as f:
                runner = f.read()
            self.assertIn(" -c ", runner)
            self.assertIn("--job-run", runner)
            os.environ["TAKES_PYC_DIR"] = "off"
            self.assertEqual(m.self_argv(["--x"])[1:], [self.server, "--x"])
        finally:
            os.environ.pop("TAKES_PYC_DIR", None)
            os.environ.pop("TAKES_ROOT", None)


if __name__ == "__main__":
    unittest.main()
