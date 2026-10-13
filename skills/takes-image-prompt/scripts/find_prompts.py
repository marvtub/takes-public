#!/usr/bin/env python3
"""Find example GPT Image 2.5 prompts in the YouArt collection (150 prompts, 9 use cases).

The collection: https://github.com/youart-open-source/awesome-gpt-image-2-5-prompts
It is downloaded on first use and kept for a day in ~/.cache/takes/. The prompts belong to
their authors; every result carries the author and the source link.

  find_prompts.py --categories                 # the use cases and their counts
  find_prompts.py thumbnail text               # best matches for these words
  find_prompts.py --category poster -n 3       # three from one use case
"""
import argparse, json, os, re, sys, time, urllib.request

URL = "https://raw.githubusercontent.com/youart-open-source/awesome-gpt-image-2-5-prompts/main/data/prompts.json"
CACHE = os.path.expanduser("~/.cache/takes/gpt-image-2-5-prompts.json")


def load(refresh=False):
    fresh = os.path.exists(CACHE) and time.time() - os.path.getmtime(CACHE) < 86400
    if refresh or not fresh:
        try:
            with urllib.request.urlopen(URL, timeout=20) as r:
                data = r.read()
            json.loads(data)
            os.makedirs(os.path.dirname(CACHE), exist_ok=True)
            with open(CACHE + ".tmp", "wb") as f:
                f.write(data)
            os.replace(CACHE + ".tmp", CACHE)
        except Exception as e:  # offline: an older copy still helps
            if not os.path.exists(CACHE):
                sys.exit("Could not download the prompts (%s)." % e)
    with open(CACHE, encoding="utf-8") as f:
        return json.load(f)["prompts"]


def score(p, words):
    title, body = p["title"].lower(), p["prompt"].lower()
    s = 0
    for w in words:
        s += 5 * title.count(w) + 3 * (w in p["category"]) + min(body.count(w), 3)
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("words", nargs="*", help="what the image is, e.g. youtube thumbnail bold text")
    ap.add_argument("--category", help="one use case (see --categories)")
    ap.add_argument("--categories", action="store_true", help="list the use cases")
    ap.add_argument("-n", type=int, default=4, help="how many prompts (default 4)")
    ap.add_argument("--refresh", action="store_true", help="download the collection again")
    a = ap.parse_args()
    prompts = load(a.refresh)
    if a.categories:
        counts = {}
        for p in prompts:
            counts[p["category"]] = counts.get(p["category"], 0) + 1
        for c, n in sorted(counts.items()):
            print("%-20s %d" % (c, n))
        return
    pool = [p for p in prompts if not a.category or p["category"] == a.category]
    words = [w for w in re.findall(r"[a-z0-9]+", " ".join(a.words).lower()) if len(w) > 2]
    if words:
        pool = sorted((p for p in pool if score(p, words) > 0), key=lambda p: -score(p, words))
    if not pool:
        sys.exit("No prompt matches. Try other words or --categories.")
    for p in pool[: a.n]:
        print("## %s  [%s]" % (p["title"], p["category"]))
        print("By @%s, %s (stated terms: %s)" % (p["author"], p["sourceUrl"], p.get("upstreamStatedTerms") or "unknown"))
        print()
        print(p["prompt"].strip())
        print()


if __name__ == "__main__":
    main()
