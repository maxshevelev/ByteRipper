#!/usr/bin/env python3
"""Move the pinned sources forward: the Wikipedia revisions and the commit of
Intel's microcode release notes that `enrich.py` reads.

They are pinned so a run is the same run tomorrow; moving them is a decision,
and its diff — the codes that come and go in `IntelCPUIDBrandNames.json` — is
what to read before committing it.

Usage:
    pins.py            # what is pinned and what is current
    pins.py --write    # rewrite the pins in enrich.py to the current ones

stdlib only (and `git ls-remote` for the release notes' commit, which the
GitHub API would ration).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import enrich  # noqa: E402 — the file beside this one

ENRICH = os.path.join(HERE, "enrich.py")
NOTES_REPO = "https://github.com/intel/Intel-Linux-Processor-Microcode-Data-Files.git"


def current_revision(title):
    query = urllib.parse.urlencode({
        "action": "query", "prop": "revisions", "rvprop": "ids", "titles": title,
        "redirects": 1, "format": "json"
    })
    request = urllib.request.Request("https://en.wikipedia.org/w/api.php?" + query,
                                     headers={"User-Agent": enrich.USER_AGENT})
    pages = json.load(urllib.request.urlopen(request, timeout=60))["query"]["pages"]
    page = next(iter(pages.values()))
    return page["revisions"][0]["revid"]


def current_commit():
    out = subprocess.run(["git", "ls-remote", NOTES_REPO, "refs/heads/main"],
                         capture_output=True, text=True, check=True).stdout
    return out.split()[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    with open(ENRICH, encoding="utf-8") as f:
        text = f.read()
    moved = 0
    for title, pinned in enrich.WIKIPEDIA_PAGES.items():
        now = current_revision(title)
        mark = "" if now == pinned else "   <- moved"
        print(f"{title}: {pinned} -> {now}{mark}")
        if now != pinned:
            moved += 1
            text = text.replace(f'"{title}": {pinned},', f'"{title}": {now},')
    commit = current_commit()
    print(f"release notes: {enrich.INTEL_NOTES_COMMIT[:12]} -> {commit[:12]}"
          + ("" if commit == enrich.INTEL_NOTES_COMMIT else "   <- moved"))
    if commit != enrich.INTEL_NOTES_COMMIT:
        moved += 1
        text = re.sub(r'INTEL_NOTES_COMMIT = "[0-9a-f]{40}"', f'INTEL_NOTES_COMMIT = "{commit}"', text)
    if args.write and moved:
        with open(ENRICH, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"{moved} pins written to {os.path.relpath(ENRICH)}")
    elif moved:
        print(f"{moved} pins could move; --write to move them")


if __name__ == "__main__":
    main()
