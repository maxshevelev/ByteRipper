#!/usr/bin/env python3
"""The models the table still has no S-SPEC for, as work for an ARK lookup.

Reads `IntelCPUIDBrandNames.json` and `ark-sspec.json`, and lists every model
that has no S-SPEC in at least one of its entries and has not been looked up
in ARK yet (a model ARK was asked about stays in `ark-sspec.json`, found or
not, so a run never asks twice). Each model goes with the CPUIDs the article
lists it under and the steppings Intel's release notes give those CPUIDs — what
a reader needs to see why a code could, or could not, be placed.

Writes the names in batches, one per line, for the agents that read ARK
(`SKILL.md`, "Filling the gaps"), and a `worklist.json` beside them.

Usage:
    gaps.py --out DIR [--batches 4] [--only missing|ambiguous|all] [--cache DIR]

  missing    models with no S-SPEC anywhere in the table
  ambiguous  models listed under more than one CPUID, without one somewhere
  all        both (the default)

stdlib only.
"""

import argparse
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import enrich  # noqa: E402 — the file beside this one

TABLE = os.path.join(HERE, "..", "..", "..", "Modules", "FITTool", "Sources", "FITTool",
                     "Resources", "IntelCPUIDBrandNames.json")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--batches", type=int, default=4)
    parser.add_argument("--only", choices=["missing", "ambiguous", "all"], default="all")
    parser.add_argument("--cache")
    args = parser.parse_args()

    with open(TABLE, encoding="utf-8") as f:
        entries = json.load(f)["entries"]
    with open(enrich.ARK_FILE, encoding="utf-8") as f:
        asked = {m["model"] for m in json.load(f)["models"]}
    steppings = enrich.intel_steppings(args.cache)

    where = collections.defaultdict(list)
    for e in entries:
        for p in e["processors"]:
            if not p.get("series"):
                where[p["name"]].append((e, p))

    work = []
    for name, places in sorted(where.items()):
        if name in asked:
            continue
        cpuids = sorted({c for e, _ in places for c in e["cpuids"]})
        empty = any(not p["sSpec"] for _, p in places)
        none = all(not p["sSpec"] for _, p in places)
        several = len({tuple(e["cpuids"]) for e, _ in places}) > 1
        if not empty:
            continue
        if args.only == "missing" and not none:
            continue
        if args.only == "ambiguous" and not several:
            continue
        work.append({
            "model": name,
            "cpuids": {c: sorted(steppings.get(c, set()) | {s for e, _ in places
                                                            if c in e["cpuids"]
                                                            for s in e["steppings"]})
                       for c in cpuids},
            "several_cpuids": several,
        })

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "worklist.json"), "w", encoding="utf-8") as f:
        json.dump(work, f, ensure_ascii=False, indent=2)
    batches = max(1, args.batches)
    for i in range(batches):
        part = [w["model"] for w in work[i::batches]]
        with open(os.path.join(args.out, f"batch{i}.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(part) + ("\n" if part else ""))
    print(f"{len(work)} models to look up ({sum(w['several_cpuids'] for w in work)} under several CPUIDs), "
          f"{batches} batches in {args.out}")


if __name__ == "__main__":
    main()
