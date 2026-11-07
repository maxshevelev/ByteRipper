#!/usr/bin/env python3
"""The models still without an S-SPEC under the CPUIDs asked for.

Reads the shipped table, `ark-sspec.json` and `found-sspec.json` (both beside
`update-cpuid-brand-names`'s `enrich.py`), and writes, for each model of the
given CPUIDs that has no S-SPEC there and has not been searched yet:

    {"model": "Intel Core i5-10500",
     "cpuid": "A0653",                       # the CPUID asked for
     "codeNames": ["Comet Lake S"], "steppings": ["G1"],   # of that entry
     "otherCPUIDs": {"A0655": ["Q0"]},       # where else the article lists it
     "ark": "asked: no specs (ordering.html redirects …)" | "not asked"}

into `worklist.json` and `batch<N>.json` of `--batch-size` models each, for
the agents `SKILL.md` sends.

Usage:
    worklist.py --list                         CPUIDs with models without a code
    worklist.py 606C1 A0653 --out DIR [--batch-size 8] [--again] [--model NAME …]

  --again   list models already searched too (a search is recorded in
            found-sspec.json whether or not it found anything)
  --model   only these models (exact names from the table)

A CPUID is matched as the table writes it, `X` standing for any digit.

stdlib only.
"""

import argparse
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIBLING = os.path.join(HERE, "..", "..", "update-cpuid-brand-names", "scripts")
sys.path.insert(0, SIBLING)
import enrich  # noqa: E402

TABLE = os.path.join(HERE, "..", "..", "..", "Modules", "FITTool", "Sources", "FITTool",
                     "Resources", "IntelCPUIDBrandNames.json")


def matches(pattern, cpuid):
    return len(pattern) == len(cpuid) and all(p in ("X", c) for p, c in zip(pattern, cpuid))


def load(path, key="models"):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return {m["model"]: m for m in json.load(f)[key]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cpuids", nargs="*")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--out")
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--again", action="store_true")
    parser.add_argument("--model", action="append")
    parser.add_argument("--cache")
    args = parser.parse_args()

    with open(TABLE, encoding="utf-8") as f:
        entries = json.load(f)["entries"]
    ark = load(enrich.ARK_FILE)
    found = load(enrich.FOUND_FILE)

    def missing(p):
        return not p.get("series") and not p["sSpec"]

    if args.list or not args.cpuids:
        counts = collections.Counter()
        names = {}
        for e in entries:
            n = sum(1 for p in e["processors"] if missing(p) and p["name"] not in found)
            for c in e["cpuids"]:
                counts[c] += n
                names[c] = ", ".join(e["codeNames"])
        for c, n in sorted(counts.items(), key=lambda kv: -kv[1]):
            if n:
                print(f"{c:7} {n:4}  {names[c]}")
        print(f"{sum(counts.values())} models without an S-SPEC and not yet searched "
              "(a model under two CPUIDs counts under each)")
        return

    if not args.out:
        sys.exit("--out is required with CPUIDs")
    wanted = [c.upper() for c in args.cpuids]
    steppings = enrich.intel_steppings(args.cache)

    where = collections.defaultdict(list)
    for e in entries:
        for p in e["processors"]:
            if not p.get("series"):
                where[p["name"]].append(e)

    work, seen = [], set()
    for e in entries:
        hit = [c for c in wanted if any(matches(c, x) or matches(x, c) for x in e["cpuids"])]
        if not hit:
            continue
        for p in e["processors"]:
            name = p["name"]
            if not missing(p) or name in seen:
                continue
            if args.model and name not in args.model:
                continue
            if name in found and not args.again:
                continue
            seen.add(name)
            mine = sorted(set(e["steppings"]) | {s for c in e["cpuids"] for s in steppings.get(c, ())})
            others = {c: sorted(set(o["steppings"]) | steppings.get(c, set()))
                      for o in where[name] if o is not e for c in o["cpuids"]}
            a = ark.get(name)
            work.append({
                "model": name,
                "cpuid": "/".join(e["cpuids"]),
                "codeNames": e["codeNames"],
                "steppings": mine,
                "otherCPUIDs": others,
                "ark": ("not asked" if a is None else
                        f"asked: {len(a['specs'])} specs" + (f" ({a['note']})" if a.get("note") else "")),
            })

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "worklist.json"), "w", encoding="utf-8") as f:
        json.dump(work, f, ensure_ascii=False, indent=2)
    size = max(1, args.batch_size)
    batches = [work[i:i + size] for i in range(0, len(work), size)]
    for n, part in enumerate(batches):
        with open(os.path.join(args.out, f"batch{n}.json"), "w", encoding="utf-8") as f:
            json.dump(part, f, ensure_ascii=False, indent=2)
    print(f"{len(work)} models under {' '.join(wanted)} to search, "
          f"{len(batches)} batches of up to {size} in {args.out}")


if __name__ == "__main__":
    main()
