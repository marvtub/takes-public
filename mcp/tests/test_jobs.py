"""Jobs (2026-10-10): run_job starts slow work outside the chat's process tree, get_job reads and waits
for it, stop_job ends it. Real tiny shell commands on a temp library: no network, no money."""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

# Other test files replace these in their setUp and keep them replaced: take the real ones now.
REAL = {n: getattr(t, n) for n in ("start_higgsfield", "start_replicate", "start_sketches", "spawn_detached",
                                   "rep_http", "rep_download", "video_size")}
SERVER = os.path.join(os.path.dirname(__file__), "..", "takes_mcp.py")


def ago(**kw):
    return (datetime.now(timezone.utc) - timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")


def ppid(pid):
    out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) if out else None


def descendants(pid):
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
    return [int(x) for x in out] + [d for x in out for d in descendants(int(x))]


class Jobs(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_JOB_TIMEOUT"] = "5"
        os.environ["TAKES_JOB_LOG_MAX"] = "4096"
        for k in ("TAKES_CHAT", "TAKES_BOARD"):
            os.environ.pop(k, None)
        for k, v in REAL.items():
            setattr(t, k, v)
        self.s = self.session("2026-10-10-demo")
        self.s2 = self.session("2026-10-10-other")

    def tearDown(self):
        for k, v in REAL.items():
            setattr(t, k, v)
        # A job that a test left running must not outlive it.
        for d in (self.s, self.s2):
            for j in t.all_jobs(d) if os.path.isdir(d) else []:
                if j["status"] in ("starting", "running") and j.get("pid"):
                    try:
                        os.kill(j["pid"], signal.SIGTERM)
                    except OSError:
                        pass
        time.sleep(0.2)
        shutil.rmtree(self.root, ignore_errors=True)
        for k in ("TAKES_ROOT", "TAKES_JOB_TIMEOUT", "TAKES_JOB_LOG_MAX", "TAKES_CHAT", "TAKES_BOARD"):
            os.environ.pop(k, None)

    def session(self, name):
        s = os.path.join(self.root, "Launch", name)
        os.makedirs(os.path.join(s, "edits"))
        t.write_meta(s, {"title": name, "createdAt": "2026-10-10T00:00:00Z", "named": True, "takes": []})
        return s

    def run_job(self, cmd, outputs=(), label="Render edit v1", s=None):
        return t.t_run_job({"session": s or self.s, "cmd": cmd, "outputs": list(outputs), "label": label})

    def wait(self, job, s=None, wait_s=10):
        return t.t_get_job({"id": job, "session": s or self.s, "wait_s": wait_s})

    def raw(self, job, s=None):
        return json.load(open(t.job_path(s or self.s, job)))

    def test_run_returns_at_once_and_ends_done(self):
        # Returned before the command ended: its file is not there yet. Not a stopwatch, which
        # failed at load 77 with eight test processes (2026-10-13).
        r = self.run_job("sleep 1.5; printf x > edits/a-v1.mp4", ["edits/a-v1.mp4"])
        self.assertFalse(os.path.exists(os.path.join(self.s, "edits/a-v1.mp4")))
        self.assertEqual(r["status"], "starting")
        self.assertRegex(r["job"], r"^job-[0-9a-f]{6}$")
        out = self.wait(r["job"])
        self.assertEqual(out["status"], "done")
        self.assertGreater(out["outputs"][0]["bytes"], 0)
        self.assertEqual(out["next"], "Run check_edit on it, then open_in_app.")
        self.assertTrue(os.path.exists(t.job_path(self.s, r["job"], ".told")))
        self.assertFalse(os.path.exists(t.job_path(self.s, r["job"], ".lock")))

    def test_get_job_right_after_run_is_not_lost(self):
        r = self.run_job("sleep 0.5")
        end = time.time() + 10
        while time.time() < end:
            st = t.t_get_job({"id": r["job"]})["status"]
            self.assertNotEqual(st, "lost")
            self.assertNotEqual(self.raw(r["job"])["status"], "lost")
            if st == "done":
                break
        self.assertEqual(st, "done")

    def test_runner_is_not_a_child(self):
        r = self.run_job("sleep 3")
        end = time.time() + 5
        while not self.raw(r["job"]).get("pid") and time.time() < end:
            time.sleep(0.05)
        pid = self.raw(r["job"])["pid"]
        self.assertEqual(ppid(pid), 1)
        self.assertNotIn(pid, descendants(os.getpid()))
        t.t_stop_job({"id": r["job"]})

    def test_spawn_sites_detach(self):
        calls = []
        t.spawn_detached = lambda argv: calls.append(argv) or 4242
        t.start_higgsfield(self.s, "/x/job.json")
        t.start_replicate(self.s, "/x/job.json")
        t.start_sketches(self.s, retry=True)
        src = os.path.join(self.s, "clip.mov")
        subprocess.run(["/bin/cp", "/dev/null", src])
        t.video_size = lambda p: (1920, 1080)
        t.save_broll(src, "Outdoor")
        meta = t.read_meta(self.s)
        meta["takes"] = [{"number": 1, "kind": "camera", "file": "take-01-camera.mov", "startedAt": "2026-10-10T00:00:00Z"}]
        t.write_meta(self.s, meta)
        t.start_voice(self.s, meta["takes"][0])
        self.assertEqual([c[0] for c in calls], ["--higgsfield-run", "--replicate-run", "--sketch-run",
                                                 "--broll-describe", "--voice-run"])
        self.assertEqual(t.read_voice(self.s, "take-01-camera")["pid"], 4242)  # the runner's own pid

    def test_job_survives_its_starter(self):
        # A child Python stands in for the MCP server: it starts the job and exits at once.
        code = ("import sys; sys.path.insert(0, %r); import takes_mcp as t; "
                "print(t.t_run_job({'session': %r, 'cmd': 'sleep 0.5; printf x > edits/a-v1.mp4', "
                "'outputs': ['edits/a-v1.mp4'], 'label': 'Render'})['job'])") % (os.path.dirname(SERVER), self.s)
        job = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=os.environ).stdout.strip()
        self.assertEqual(self.wait(job)["status"], "done")

    def call_server(self, env):
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "run_job", "arguments": {
                    "session": self.s, "cmd": "true", "outputs": [], "label": "Env"}}}]
        out = subprocess.run([sys.executable, SERVER], input="".join(json.dumps(m) + "\n" for m in msgs),
                             capture_output=True, text=True, env=env, timeout=30).stdout.splitlines()
        res = json.loads(out[-1])["result"]
        return self.raw(json.loads(res["content"][0]["text"])["job"])

    def test_chat_env_reaches_the_mcp(self):
        env = dict(os.environ, TAKES_CHAT="1")
        self.assertTrue(self.call_server(env)["from_chat"])
        self.assertFalse(self.call_server(dict(env, TAKES_BOARD="styles"))["from_chat"])  # a board chat
        self.assertFalse(self.call_server(dict(os.environ))["from_chat"])  # a terminal agent

    def test_progress_lines(self):
        def run(lines, **state):
            out = []
            for x in lines:
                out.append(t.job_progress(x, state))
            return out
        self.assertEqual(run(["TAKES_PROGRESS 0.4", "TAKES_PROGRESS 55%"]), [0.4, 0.55])
        self.assertEqual(run(["frame 30/120", "60/120 frames"]), [0.25, 0.5])
        self.assertEqual(run(["Downloading 45%"]), [0.45])
        ff = run(["  Duration: 00:01:40.00, start: 0.000000", "frame=  612 fps= 31 time=00:00:20.00 bitrate=1"],
                 ffmpeg=True)
        self.assertEqual(ff, [None, 0.2])
        # Without one -i (a concat, a -t) the Duration is not the output's: time= says nothing.
        self.assertEqual(run(["  Duration: 00:01:40.00", "time=00:00:20.00"], ffmpeg=False), [None, None])
        self.assertTrue(t.ffmpeg_timed("ffmpeg -i a.mov -c copy b.mp4"))
        self.assertFalse(t.ffmpeg_timed("ffmpeg -i a.mov -i b.wav c.mp4"))
        self.assertFalse(t.ffmpeg_timed("ffmpeg -i a.mov -t 5 c.mp4"))
        # A dip within one step holds the bar.
        self.assertEqual(run(["40%", "90%", "5%", "95%"]), [0.4, 0.9, None, 0.95])
        # After a step at 100% (Demucs downloads its model first) the next step starts the bar over.
        state = {}
        out = [t.job_progress(x, state) for x in
               ["100%|██| 80.2M/80.2M", " 30%|███ | 1.75/5.85", " 60%|██████ | 3.5/5.85"]]
        self.assertEqual(out, [1.0, 0.3, 0.6])
        self.assertIn("step_t", state)
        # The output runs longer than Duration (-stream_loop, a filter): the bar goes back to unknown.
        self.assertFalse(t.ffmpeg_timed("ffmpeg -y -stream_loop 4 -i a.mov b.mp4"))
        state = {"ffmpeg": True}
        out = [t.job_progress(x, state) for x in
               ["  Duration: 00:00:10.00", "time=00:00:09.90", "time=00:00:12.00", "time=00:00:30.00"]]
        self.assertEqual(out, [None, 0.99, None, None])
        self.assertIsNone(state["p"])
        self.assertEqual(run(["hello", "ERROR: no such file", ""]), [None, None, None])

    def test_failure_reason_and_partial(self):
        r = self.run_job("echo boom >&2; printf x > edits/a-v1.mp4; exit 3", ["edits/a-v1.mp4"])
        out = self.wait(r["job"])
        self.assertEqual(out["status"], "failed")
        self.assertEqual(out["exit"], 3)
        self.assertEqual(out["error"], "boom")
        self.assertEqual(out["partial"], [os.path.join(".jobs", r["job"] + ".partial", "a-v1.mp4")])
        self.assertFalse(os.path.exists(os.path.join(self.s, "edits", "a-v1.mp4")))
        self.assertIn("next_path", out["next"])

    def test_partial_pruned_after_7_days(self):
        for job, days in (("job-aaaaaa", 8), ("job-bbbbbb", 6)):
            os.makedirs(t.job_path(self.s, job, ".partial"))
            t.write_job(t.job_path(self.s, job), {"v": 1, "id": job, "label": "x", "status": "failed",
                                                  "started": ago(days=days), "ended": ago(days=days)})
        t.all_jobs(self.s)
        self.assertFalse(os.path.exists(t.job_path(self.s, "job-aaaaaa", ".partial")))
        self.assertTrue(os.path.exists(t.job_path(self.s, "job-bbbbbb", ".partial")))

    def test_exit_zero_without_output_fails(self):
        out = self.wait(self.run_job("true", ["edits/a-v1.mp4"])["job"])
        self.assertEqual(out["status"], "failed")
        self.assertEqual(out["error"], "It ended but did not write edits/a-v1.mp4.")

    def test_stop_kills_the_whole_group(self):
        mark = "takes-test-%d" % os.getpid()
        r = self.run_job("sleep 60 & exec -a %s sleep 60; wait" % mark)
        time.sleep(0.8)
        t0 = time.time()
        out = t.t_stop_job({"id": r["job"]})
        self.assertLess(time.time() - t0, 8)
        self.assertEqual(out["status"], "stopped")
        self.assertEqual(out["stopped_by"], "takes")
        time.sleep(0.3)
        self.assertEqual(subprocess.run(["pgrep", "-f", mark], capture_output=True).returncode, 1)
        self.assertEqual(t.t_stop_job({"id": r["job"]})["note"], "It already ended.")

    def test_dead_runner_reads_lost(self):
        r = self.run_job("sleep 30.0173")
        end = time.time() + 5
        while self.raw(r["job"])["status"] != "running" and time.time() < end:
            time.sleep(0.05)
        os.kill(self.raw(r["job"])["pid"], signal.SIGKILL)
        time.sleep(0.3)
        lost = t.t_get_job({"id": r["job"]})
        self.assertEqual(lost["status"], "lost")
        self.assertEqual(self.raw(r["job"])["status"], "lost")
        # The chat may have lost the command (a compaction, a new chat): get_job gives it back.
        self.assertEqual((lost["cmd"], lost["label"]), ("sleep 30.0173", "Render edit v1"))
        self.assertIn("run_job with this cmd and label", lost["next"])
        # Just started, no runner yet: not lost. 31 s later: lost.
        young = {"v": 1, "id": "job-cccccc", "label": "x", "status": "starting", "started": t.now_iso()}
        t.write_job(t.job_path(self.s, "job-cccccc"), young)
        self.assertEqual(t.read_job(self.s, "job-cccccc")["status"], "starting")
        t.write_job(t.job_path(self.s, "job-cccccc"), dict(young, started=ago(seconds=31)))
        self.assertEqual(t.read_job(self.s, "job-cccccc")["status"], "lost")
        for pid in subprocess.run(["pgrep", "-f", "sleep 30.0173"], capture_output=True, text=True).stdout.split():
            try:
                os.kill(int(pid), signal.SIGTERM)
            except ProcessLookupError:  # it ended between pgrep and here
                pass

    def test_timeout(self):
        os.environ["TAKES_JOB_TIMEOUT"] = "1"
        out = self.wait(self.run_job("sleep 30")["job"])
        self.assertEqual(out["status"], "failed")
        self.assertIn("ran over 1 s", out["error"])

    def test_output_rules(self):
        open(os.path.join(self.s, "edits", "old-v1.mp4"), "w").write("x")
        bad = {os.path.join(self.root, "x.mp4"): "outside the session", "../x.mp4": "outside the session",
               "stills/a.png": "read only", "assets/a.mp4": "read only", ".jobs/a.json": "read only",
               "take-01-camera.mov": "take file", "edits/old-v1.mp4": "next_path",
               # The Mac's volume ignores case, and the generated store is the app's too.
               "Stills/a.png": "read only", "Take-02-camera.mov": "take file",
               "generated/.jobs/evil.json": "generated/.jobs/ is read only"}
        for o, why in bad.items():
            with self.assertRaises(ValueError) as e:
                self.run_job("true", [o])
            self.assertIn(why, str(e.exception))
        r = self.run_job("sleep 2; printf x > edits/a-v1.mp4", ["edits/a-v1.mp4"])
        with self.assertRaises(ValueError) as e:
            self.run_job("true", [os.path.join(self.s, "edits/a-v1.mp4")])
        self.assertIn("A running job already writes edits/a-v1.mp4 (%s)" % r["job"], str(e.exception))
        with self.assertRaises(ValueError) as e:
            t.t_run_job({"session": self.s, "cmd": "true", "outputs": []})
        self.assertIn("Give a label", str(e.exception))
        with self.assertRaises(ValueError):
            t.t_run_job({"session": self.s, "cmd": "true", "label": "x"})
        self.assertEqual(self.wait(self.run_job("true", [])["job"])["status"], "done")

    def test_cmd_absolute_session_path_rewritten(self):
        r = self.run_job("printf x > '%s/edits/a-v1.mp4'" % self.s, ["edits/a-v1.mp4"])
        self.assertEqual(self.raw(r["job"])["cmd"], "printf x > 'edits/a-v1.mp4'")
        self.assertEqual(self.wait(r["job"])["status"], "done")
        self.assertEqual(t.job_cmd(self.s, "cd %s && ls" % self.s), "cd . && ls")

    def test_cmd_sibling_session_path_stays(self):
        sib = self.session("2026-10-10-demo-2")
        open(os.path.join(sib, "in.txt"), "w").write("x")
        cmd = 'cp "%s/in.txt" edits/copy.txt' % sib
        r = self.run_job(cmd, ["edits/copy.txt"])
        self.assertEqual(self.raw(r["job"])["cmd"], cmd)
        self.assertEqual(self.wait(r["job"])["status"], "done")

    def test_run_job_needs_a_session_folder(self):
        os.makedirs(os.path.join(self.root, "_library", "rules"))
        for bad in (None, "", "Launch", "/tmp", self.root, "_library/rules"):
            with self.assertRaises(ValueError) as e:
                t.t_run_job({"session": bad, "cmd": "true", "outputs": [], "label": "x"})
            self.assertIn("Give session: Project/folder", str(e.exception), bad)
        self.assertFalse(os.path.exists(os.path.join(self.root, ".jobs")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "Launch", ".jobs")))
        r = t.t_run_job({"session": "Launch/2026-10-10-demo", "cmd": "true", "outputs": [], "label": "x"})
        self.assertEqual(t.t_get_job({"id": r["job"], "wait_s": 10})["status"], "done")

    def test_note_promises_a_note_only_in_the_takes_chat(self):
        r = self.run_job("true")
        self.assertNotIn("sends you a note", r["note"])
        self.assertIn("check later with get_job id=%s" % r["job"], r["note"])
        os.environ["TAKES_CHAT"] = "1"
        self.assertIn("Takes sends you a note when it ends", self.run_job("true")["note"])
        os.environ["TAKES_BOARD"] = "styles"
        self.assertNotIn("sends you a note", self.run_job("true")["note"])

    def test_bad_wait_and_bad_job_file(self):
        r = self.run_job("true")
        with self.assertRaises(ValueError) as e:
            t.t_get_job({"id": r["job"], "wait_s": "abc"})
        self.assertEqual(str(e.exception), "wait_s is seconds, 0 to 50.")
        open(t.job_path(self.s, "job-dead00"), "w").write('{"id": "job-de')
        with self.assertRaises(ValueError) as e:
            t.t_get_job({"id": "job-dead00"})
        self.assertIn("Start it again with run_job.", str(e.exception))

    def test_next_path_skips_claimed_version(self):
        self.run_job("sleep 2; printf x > edits/launch-v1.mp4", ["edits/launch-v1.mp4"])
        self.assertTrue(t.t_next_path({"session": self.s, "kind": "edit", "name": "launch"})["path"].endswith("launch-v2.mp4"))
        self.assertTrue(t.t_next_path({"session": self.s, "kind": "edit", "name": "other"})["path"].endswith("other-v1.mp4"))

    def test_rename_during_job(self):
        r = self.run_job("sleep 1; printf x > edits/a-v1.mp4", ["edits/a-v1.mp4"])
        # Rename once it runs: a fixed 0.4 s was too short at load 33 (2026-10-12).
        for _ in range(100):
            if self.raw(r["job"])["status"] != "starting": break
            time.sleep(0.05)
        moved = os.path.join(self.root, "Launch", "2026-10-10-renamed")
        os.rename(self.s, moved)
        out = self.wait(r["job"], s=moved)
        self.assertEqual(out["status"], "done")
        self.assertEqual(out["session"], moved)
        self.assertTrue(os.path.exists(os.path.join(moved, "edits", "a-v1.mp4")))
        self.s = moved

    def test_ids_unique_and_ambiguous_lookup(self):
        for s in (self.s, self.s2):
            os.makedirs(t.hf_jobs_dir(s))
            t.hf_save_job(s, {"id": "shot-3-v2", "file": "generated/shot-3-v2.mp4", "kind": "video",
                              "status": "done", "started": ago(minutes=5), "ended": ago(minutes=1)})
        with self.assertRaises(ValueError) as e:
            t.t_get_job({"id": "shot-3-v2"})
        self.assertIn("Several jobs have the id shot-3-v2. Give session.", str(e.exception))
        with self.assertRaises(ValueError):
            t.t_stop_job({"id": "shot-3-v2"})
        self.assertEqual(t.t_get_job({"id": "shot-3-v2", "session": self.s2})["status"], "done")
        ids = {self.run_job("true", s=s)["job"] for s in (self.s, self.s2, self.s)}
        self.assertEqual(len(ids), 3)
        with self.assertRaises(ValueError):
            t.t_get_job({"id": "../../x"})

    def test_list_shows_running_and_recent_and_writes_no_told(self):
        a = self.run_job("sleep 3")["job"]
        b = self.run_job("true", label="Quick")["job"]
        end = time.time() + 30  # a running and b done, not a fixed second: slow on a busy Mac
        while time.time() < end:  # the list, not get_job by id: that one writes .told
            now = {j["job"]: j["status"] for j in t.t_get_job({"session": self.s})["jobs"]}
            if (now.get(a), now.get(b)) == ("running", "done"):
                break
            time.sleep(0.05)
        t.write_job(t.job_path(self.s, "job-dddddd"), {"v": 1, "id": "job-dddddd", "label": "Old", "status": "done",
                                                       "started": ago(days=2), "ended": ago(days=2)})
        jobs = t.t_get_job({"session": self.s})["jobs"]
        self.assertEqual([j["job"] for j in jobs], [a, b])
        self.assertEqual(jobs[0]["status"], "running")
        self.assertFalse(os.path.exists(t.job_path(self.s, b, ".told")))
        t.t_stop_job({"id": a})

    def test_told_is_exclusive(self):
        job = {"id": "job-eeeeee"}
        os.makedirs(t.jobs_dir(self.s))
        got = []
        threads = [threading.Thread(target=lambda: got.append(t.claim_told(self.s, job))) for _ in range(2)]
        for x in threads:
            x.start()
        for x in threads:
            x.join()
        self.assertEqual(sorted(got), [False, True])

    def test_legacy_generated_jobs_read(self):
        os.makedirs(t.hf_jobs_dir(self.s))
        t.hf_save_job(self.s, {"id": "shot-1-v1", "file": "generated/shot-1-v1.mp4", "kind": "video",
                               "status": "error", "error": "Session expired.", "started": ago(minutes=3)})
        j = t.read_job(self.s, "shot-1-v1", generate=True)
        self.assertEqual((j["status"], j["type"], j["outputs"]), ("failed", "generate", ["generated/shot-1-v1.mp4"]))
        with self.assertRaises(ValueError) as e:
            t.t_stop_job({"id": "shot-1-v1"})
        self.assertIn("cannot stop", str(e.exception))
        for mins, want in ((60, "running"), (100, "lost")):
            t.hf_save_job(self.s, {"id": "shot-2-v1", "file": "generated/shot-2-v1.mp4", "kind": "video",
                                   "status": "running", "started": ago(minutes=mins)})
            self.assertEqual(t.read_job(self.s, "shot-2-v1", generate=True)["status"], want)
        # A held lock: running however old. The file itself keeps its kind and status.
        fd = t.job_lock(t.job_path(self.s, "shot-2-v1", ".lock", generate=True))
        self.assertEqual(t.read_job(self.s, "shot-2-v1", generate=True)["status"], "running")
        t.job_unlock(fd, t.job_path(self.s, "shot-2-v1", ".lock", generate=True))
        raw = json.load(open(t.job_path(self.s, "shot-2-v1", generate=True)))
        self.assertEqual((raw["kind"], raw["status"]), ("video", "running"))

    def test_higgsfield_run_still_attaches(self):
        root = self.root
        fake = os.path.join(root, "fake_hf.py")
        open(fake, "w").write("import json, os\nout = os.path.join(%r, 'r.mp4')\nopen(out, 'wb').write(b'mp4')\n"
                              "print(json.dumps({'url': 'file://' + out}))\n" % root)
        os.environ["TAKES_HIGGSFIELD_CMD"] = json.dumps([sys.executable, fake])
        os.environ["TAKES_CHAT"] = "1"
        started = []
        t.start_higgsfield = lambda s, p: started.append(p)
        try:
            r = t.t_higgsfield({"session": self.s, "prompt": "A desk at sunrise."})
            job = json.load(open(started[0]))
            self.assertEqual(job["kind"], "video")
            self.assertEqual(job["label"], "Seedance 2.5 clip")
            self.assertTrue(job["from_chat"])
            t.higgsfield_run(self.s, started[0])
        finally:
            os.environ.pop("TAKES_HIGGSFIELD_CMD")
        self.assertEqual(open(os.path.join(self.s, r["file"]), "rb").read(), b"mp4")
        self.assertFalse(os.path.exists(started[0][:-5] + ".lock"))
        out = t.t_get_job({"id": r["job"]})
        self.assertEqual((out["status"], out["type"], out["label"]), ("done", "generate", "Seedance 2.5 clip"))

    def test_replicate_run_still_attaches(self):
        os.environ["TAKES_NO_KEYCHAIN"] = "1"
        os.environ["REPLICATE_API_TOKEN"] = "r8_" + "x" * 37
        schema = {"components": {"schemas": {"Input": {"type": "object", "properties": {"prompt": {"type": "string"}}}}}}

        def fake(method, path, body=None, upload=None):
            if path.startswith("/models/") and method == "GET":
                return {"name": "seedance-2.5", "latest_version": {"id": "v1", "openapi_schema": schema}}
            if path.endswith("/predictions"):
                return {"id": "p1", "status": "succeeded", "output": "https://replicate.delivery/x/out.mp4"}
            raise AssertionError(path)
        t.rep_http = fake
        t.rep_download = lambda url, dest: open(dest, "wb").write(b"mp4")
        started = []
        t.start_replicate = lambda s, p: started.append(p)
        try:
            r = t.t_replicate({"session": self.s, "prompt": "A desk.", "model": "bytedance/seedance-2.5"})
            t.replicate_run(self.s, started[0], poll=0)
        finally:
            os.environ.pop("TAKES_NO_KEYCHAIN")
            os.environ.pop("REPLICATE_API_TOKEN")
        job = json.load(open(started[0]))
        self.assertEqual((job["kind"], job["status"], job["label"]), ("video", "done", "Seedance 2.5 clip"))
        self.assertFalse(job["from_chat"])
        self.assertFalse(os.path.exists(started[0][:-5] + ".lock"))
        self.assertTrue(os.path.exists(os.path.join(self.s, r["file"])))

    def test_parallel_runs(self):
        ids, errors = [], []

        def go(i):
            s = self.s if i % 2 else self.s2
            try:
                ids.append((s, self.run_job("printf x > edits/p%d-v1.mp4" % i, ["edits/p%d-v1.mp4" % i], s=s)["job"]))
            except Exception as e:  # noqa: BLE001
                errors.append(e)
        threads = [threading.Thread(target=go, args=(i,)) for i in range(5)]
        for x in threads:
            x.start()
        for x in threads:
            x.join()
        self.assertEqual(errors, [])
        self.assertEqual(len({j for _, j in ids}), 5)
        for s, j in ids:
            self.assertEqual(self.wait(j, s=s)["status"], "done")

    def test_log_rotates(self):
        r = self.run_job("for i in $(seq 1 400); do echo line-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done")
        out = self.wait(r["job"])
        self.assertEqual(out["status"], "done")
        size = sum(os.path.getsize(t.job_path(self.s, r["job"], e)) for e in (".log", ".log.1")
                   if os.path.exists(t.job_path(self.s, r["job"], e)))
        self.assertLessEqual(size, 2 * 4096 + 65536)
        self.assertTrue(os.path.exists(t.job_path(self.s, r["job"], ".log.1")))
        self.assertEqual(out["log_tail"][-1], "line-400-" + "x" * 38)

    def test_wait_is_capped(self):
        old = t.JOB_WAIT_MAX
        t.JOB_WAIT_MAX = 0.5
        try:
            r = self.run_job("sleep 3")
            t0 = time.time()
            self.assertIn(t.t_get_job({"id": r["job"], "wait_s": 999})["status"], ("starting", "running"))
            self.assertLess(time.time() - t0, 1.5)
            t.t_stop_job({"id": r["job"]})
        finally:
            t.JOB_WAIT_MAX = old

    def test_job_env_path(self):
        os.environ["CLAUDECODE"] = "1"
        os.environ["CLAUDE_CODE_SESSION_ID"] = "x"
        try:
            env = t.job_env(self.s, "job-ffffff")
        finally:
            os.environ.pop("CLAUDECODE")
            os.environ.pop("CLAUDE_CODE_SESSION_ID")
        self.assertTrue(env["PATH"].startswith("/opt/homebrew/bin:/usr/local/bin"))
        self.assertFalse(any(k.startswith(("CLAUDECODE", "CLAUDE_CODE_")) for k in env))
        self.assertEqual((env["TAKES_JOB_ID"], env["TAKES_SESSION"]), ("job-ffffff", self.s))

    def test_corrupt_job_file_is_left_alone(self):
        os.makedirs(t.jobs_dir(self.s))
        p = t.job_path(self.s, "job-abcdef")
        open(p, "w").write('{"id": "job-abc')
        with self.assertRaises(ValueError) as e:
            t.t_get_job({"id": "job-abcdef"})
        self.assertIn("cannot read", str(e.exception))
        self.assertEqual(open(p).read(), '{"id": "job-abc')
        self.assertEqual(t.t_get_job({"session": self.s})["jobs"], [])

    def test_idle_session_gets_no_folder(self):
        t.t_get_session({"session": self.s}) if hasattr(t, "t_get_session") else None
        t.t_get_job({"session": self.s})
        t.t_next_path({"session": self.s, "kind": "edit", "name": "a"})
        self.assertFalse(os.path.exists(t.jobs_dir(self.s)))


if __name__ == "__main__":
    unittest.main()
