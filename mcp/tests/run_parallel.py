"""Runs every test in mcp/tests in parallel processes (2026-10-11). One by one the run took 280 s,
most of it ffmpeg in a few classes, so test.sh took 10 minutes and twice that with the public copy.

Each worker process runs a few tests of one class at a time, so setUpClass runs once per chunk and
os.environ changes stay in that process. The slowest chunks of the last run go first
(~/Library/Caches/takes-mcp-test-times.json), so no long chunk starts last.

    python3 mcp/tests/run_parallel.py [-j N] [--cpu]

--cpu prints the classes that used the most CPU (Python and the ffmpeg it ran). Use that, not
the times: on a busy Mac a chunk's time is mostly waiting (2026-10-22).
"""
import argparse
import json
import multiprocessing as mp
import os
import resource
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TIMES = os.path.expanduser("~/Library/Caches/takes-mcp-test-times.json")
# No test starts Chrome: the page judge's screenshots (work_page_shots) are off unless a test fakes them.
os.environ["TAKES_PAGE_SHOTS"] = "off"
CHUNK = 4  # tests per chunk: small enough to spread a big class, big enough that setUpClass pays off


def flatten(suite):
    for x in suite:
        if isinstance(x, unittest.TestSuite):
            yield from flatten(x)
        else:
            yield x


def chunks():
    """Test ids grouped by class, split into CHUNK-sized pieces, and the modules that failed to
    import, with their error."""
    by, broken = {}, []
    for t in flatten(unittest.defaultTestLoader.discover(HERE, top_level_dir=HERE)):
        if t.id().startswith("unittest.loader."):
            broken.append((t.id(), str(getattr(t, "_exception", ""))))
            continue
        by.setdefault(t.id().rsplit(".", 1)[0], []).append(t.id())
    out = []
    for cls, ids in by.items():
        for i in range(0, len(ids), CHUNK):
            out.append(ids[i:i + CHUNK])
    return out, broken


def cpu_now():
    """CPU seconds of this process and of the children it waited for (ffmpeg, say)."""
    a, b = resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)
    return a.ru_utime + a.ru_stime + b.ru_utime + b.ru_stime


def run(ids):
    """One chunk, in a worker. Returns what the parent prints and counts."""
    sys.path.insert(0, HERE)
    sys.path.insert(0, os.path.dirname(HERE))
    # A worker runs many chunks. Some setUps replace takes_mcp functions and keep them replaced,
    # so put the module back after each chunk, or the next class gets the fakes (flaky test_jobs).
    # os.environ too: test_site_rules took TAKES_PAGE_SHOTS=off away, and every class after it in that
    # worker opened Chrome for the page judge's screenshots, 29% of the run's CPU (2026-10-22).
    import takes_mcp
    saved, env = dict(vars(takes_mcp)), dict(os.environ)
    start, cpu = time.time(), cpu_now()
    try:
        suite = unittest.defaultTestLoader.loadTestsFromNames(ids)
        with open(os.devnull, "w") as null:
            r = unittest.TextTestRunner(stream=null, verbosity=0).run(suite)
    finally:
        for k in [k for k in vars(takes_mcp) if k not in saved]:
            delattr(takes_mcp, k)
        vars(takes_mcp).update(saved)
        os.environ.clear()
        os.environ.update(env)
    bad = [(t.id(), tb) for t, tb in r.failures + r.errors]
    return ids, r.testsRun, len(r.skipped), bad, time.time() - start, cpu_now() - cpu


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=max(2, min(8, (os.cpu_count() or 4) // 2)))
    ap.add_argument("--cpu", action="store_true", help="print the classes that used the most CPU")
    args = ap.parse_args()
    j = args.j
    sys.path.insert(0, HERE)
    todo, broken = chunks()
    try:
        with open(TIMES) as f:
            last = json.load(f)
    except (OSError, ValueError):
        last = {}
    todo.sort(key=lambda ids: -last.get(ids[0], 1.0))
    start = time.time()
    ran = skipped = 0
    bad, times, cpus = list(broken), {}, {}
    # spawn: a fresh interpreter per worker, as the one-by-one run had.
    with mp.get_context("spawn").Pool(j) as pool:
        for ids, n, s, b, took, cpu in pool.imap_unordered(run, todo):
            ran += n
            skipped += s
            bad += b
            times[ids[0]] = round(took, 2)
            cls = ids[0].rsplit(".", 1)[0]
            cpus[cls] = cpus.get(cls, 0.0) + cpu
    try:
        os.makedirs(os.path.dirname(TIMES), exist_ok=True)
        with open(TIMES, "w") as f:
            json.dump(times, f)
    except OSError:
        pass
    for tid, tb in bad:
        print("=" * 70 + f"\nFAIL: {tid}\n" + "-" * 70 + f"\n{tb}", file=sys.stderr)
    took = time.time() - start
    if args.cpu:
        total = sum(cpus.values())
        print("CPU %.0f s in all. Most:" % total, file=sys.stderr)
        for cls, c in sorted(cpus.items(), key=lambda x: -x[1])[:15]:
            print("%7.1f s %4.1f%%  %s" % (c, 100 * c / max(total, 1e-9), cls), file=sys.stderr)
    print(f"Ran {ran} tests in {took:.1f}s on {j} processes" + (f" ({skipped} skipped)" if skipped else ""), file=sys.stderr)
    print("FAILED (%d)" % len(bad) if bad else "OK", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
